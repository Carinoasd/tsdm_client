import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The pages of the moderation panel (`forum.php?mod=modcp`) beyond the moderation queue: the forums it offers, the
/// recycle bins and the log. Web pages the plugin leaves as they are.
///
/// Bound to the account logged in when each request is made, as [ModerateRepository]: a page served to another account
/// is dropped ([IdentityChangedException]), and an operation is never sent once the account changed. The panel decides
/// everything: the forums offered, deleting for good, the refusals in its own words.
final class ModcpRepository with LoggerMixin {
  /// Constructor; transports are injected so the flow is tested without the forum.
  ModcpRepository({required ModerateGet get, required ModeratePost post, int Function()? currentUid})
    : _get = get,
      _post = post,
      _currentUid = currentUid ?? currentLoginUid;

  /// Uses the app's client.
  factory ModcpRepository.network() => ModcpRepository(
    get: (url) async => switch (await getIt.get<NetClientProvider>().get(url).run()) {
      Left(:final value) => left(value),
      Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
    },
    post: (url, body) async =>
        switch (await getIt.get<NetClientProvider>().postForm(url, data: body, singleAttempt: true).run()) {
          Left(:final value) => left(value),
          Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
        },
  );

  final ModerateGet _get;
  final ModeratePost _post;
  final int Function() _currentUid;

  /// The panel's login, as the moderation queue sends it.
  late final ModerateRepository _moderate = ModerateRepository(get: _get, post: _post, currentUid: _currentUid);

  /// Read [url] for the account logged in and hand its document to [read]; a page served to another account, or the account
  /// changed meanwhile, is an [IdentityChangedException]; the panel's login form a [ModcpNeedsLogin]; a page [read]
  /// does not know is the panel's message ([ModcpRefused]), or a failure without one.
  Future<Either<AppException, ModcpAnswer<T>>> _page<T>(String url, T? Function(uh.Document doc, int uid) read) async {
    final uid = _currentUid();
    if (uid <= 0) {
      return left(IdentityChangedException());
    }
    final resp = await _get(url);
    switch (resp) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (_currentUid() != uid) {
          return left(IdentityChangedException());
        }
        return answerOf(value.data, uid: uid, read: read);
    }
  }

  /// The answer [data] asked by account [uid], read by [read].
  static Either<AppException, ModcpAnswer<T>> answerOf<T>(
    Object? data, {
    required int uid,
    required T? Function(uh.Document doc, int uid) read,
  }) {
    final doc = parseHtmlDocument(tsdmAppAnswerText(data));
    if (moderatePageUid(doc) case final served? when served != uid) {
      return left(IdentityChangedException());
    }
    if (moderatePanelLoginFormHash(doc) case final formHash?) {
      return right(ModcpNeedsLogin(formHash: formHash));
    }
    if (read(doc, uid) case final value?) {
      return right(ModcpReady(value));
    }
    final message = moderatePageMessage(doc);
    if (message.isNotEmpty) {
      return right(ModcpRefused(message));
    }
    return left(HttpRequestFailedException(HttpStatus.ok));
  }

  /// The forums the moderation queue offers (its forum select), to choose the one whose queue is shown.
  AsyncEither<ModcpAnswer<List<ModcpForum>>> fetchQueueForums() => AsyncEither(
    () => _page(ModerateQueueList.url(ModerateQueueKind.threads, fid: 0), queueForumsOf),
  );

  /// The forums of the queue's page [doc]; null when it is not the queue.
  static List<ModcpForum>? queueForumsOf(uh.Document doc, int uid) {
    final isQueue = doc
        .querySelectorAll('ul.tb > li.a > a')
        .map((e) => modcpQuery(e.attributes['href'] ?? ''))
        .any((q) => q != null && q['mod'] == 'modcp' && q['action'] == 'moderate');
    return isQueue ? modcpForums(doc).$1 : null;
  }

  /// Read page [page] of bin [kind] of forum [fid] (none for 0: the forums offered only).
  AsyncEither<ModcpAnswer<RecycleBinList>> fetchRecycleBin(RecycleBinKind kind, {int fid = 0, int page = 1}) =>
      AsyncEither(
        () => _page(
          RecycleBinList.url(kind, fid: fid, page: page),
          (doc, uid) => parseRecycleBin(doc, kind, fid: fid, uid: uid, page: page),
        ),
      );

  /// The bin [kind] of forum [fid] in answer [data], asked by account [uid].
  static Either<AppException, ModcpAnswer<RecycleBinList>> recycleBinOf(
    Object? data,
    RecycleBinKind kind, {
    required int fid,
    required int uid,
    int page = 1,
  }) => answerOf(
    data,
    uid: uid,
    read: (doc, uid) => parseRecycleBin(doc, kind, fid: fid, uid: uid, page: page),
  );

  /// Do [action] on the items [ids] of bin [list], once; never when the account changed since the list was served
  /// ([IdentityChangedException]).
  ///
  /// The panel answers with the bin again, no message: what it still lists was not done. The items picked may be on
  /// the pages up to [lastPage]; the answer is the first page and the later ones up to it are read again, as an item
  /// left moves up, never down.
  AsyncEither<RecycleBinOutcome> submitRecycleBin(
    RecycleBinList list,
    RecycleBinAction action,
    List<String> ids, {
    int lastPage = 1,
  }) => AsyncEither(() async {
    final uid = _currentUid();
    if (uid <= 0 || list.uid != uid || list.fid <= 0) {
      return left(IdentityChangedException());
    }
    final resp = await _post(list.submitUrl, list.body(action, ids));
    final Object? data;
    switch (resp) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        // The panel's session ended: it fails on the fields of the operation before showing its login form.
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        data = value.data;
    }
    if (_currentUid() != uid) {
      return left(IdentityChangedException());
    }
    final listed = <String>{};
    switch (recycleBinOf(data, list.kind, fid: list.fid, uid: uid)) {
      case Left(:final value):
        return left(value);
      case Right(value: ModcpNeedsLogin()):
        return right(const RecycleBinSessionEnded());
      case Right(value: ModcpRefused(:final message)):
        return right(RecycleBinRefused(message));
      case Right(value: ModcpReady(:final value)) when value.fid != list.fid:
        // Not the bin of this forum: nothing to tell what was done.
        return left(HttpRequestFailedException(HttpStatus.ok));
      case Right(value: ModcpReady(:final value)):
        listed.addAll(value.items.map((e) => e.id));
        var more = value.hasNext;
        for (var page = 2; more && page <= lastPage; page++) {
          final next = await fetchRecycleBin(list.kind, fid: list.fid, page: page).run();
          switch (next) {
            case Right(value: ModcpReady(:final value)) when value.fid == list.fid:
              listed.addAll(value.items.map((e) => e.id));
              more = value.hasNext;
            case Left(value: IdentityChangedException()):
              return left(IdentityChangedException());
            default:
              // Sent and answered, but what the later pages hold is not known: not told done.
              return right(const RecycleBinUnknown());
          }
        }
    }
    final remaining = ids.where(listed.contains).toList();
    return right(
      remaining.isEmpty
          ? RecycleBinDone(ids.length)
          : RecycleBinNotDone(done: ids.length - remaining.length, remaining: remaining),
    );
  });

  /// Read page [page] of the panel's log, the lines containing [keyword] only when not empty.
  AsyncEither<ModcpAnswer<ModcpLogPage>> fetchLog({String keyword = '', int page = 1}) => AsyncEither(
    () => _page(
      ModcpLogPage.url(keyword: keyword, page: page),
      (doc, uid) => parseModcpLog(doc, uid: uid, keyword: keyword, page: page),
    ),
  );

  /// The log in answer [data], asked by account [uid].
  static Either<AppException, ModcpAnswer<ModcpLogPage>> logOf(
    Object? data, {
    required int uid,
    String keyword = '',
    int page = 1,
  }) => answerOf(
    data,
    uid: uid,
    read: (doc, uid) => parseModcpLog(doc, uid: uid, keyword: keyword, page: page),
  );

  /// Log in to the panel with the account's [password] on the login form of form hash [formHash], once.
  AsyncEither<ModeratePanelLogin> loginPanel({required String formHash, required String password}) =>
      _moderate.loginPanel(formHash: formHash, fid: 0, password: password);
}
