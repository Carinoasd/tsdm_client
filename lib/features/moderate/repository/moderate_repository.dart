import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/member_ban.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// An answer of the forum: the http status and the body as dio decoded it (a JSON object, or text).
typedef ModerateResponse = ({int statusCode, Object? data});

/// Read [url]. Returns the failure of the transport as its left.
typedef ModerateGet = Future<Either<AppException, ModerateResponse>> Function(String url);

/// Post [body] to [url] once, never retried. Returns the failure of the transport as its left.
typedef ModeratePost = Future<Either<AppException, ModerateResponse>> Function(String url, Map<String, String> body);

/// Make sure the last `status` of the forum's app API is known before a flag of plugin 4.0.0 is looked at
/// ([TsdmAppApi.ensureStatus]).
typedef ModerateEnsureStatus = Future<void> Function();

/// The `status` of the app's client ([TsdmAppApi.ensureStatus]).
Future<void> moderateEnsureStatus() => TsdmAppApi.ensureStatus(getIt.get<NetClientProvider>());

/// Asks nothing: the `status` known now is used (the repositories built with injected transports).
Future<void> moderateStatusKnown() async {}

/// Ask small form [kind] of plugin 4.0.0 at [url] with [get] for account [uid] ([currentUid] the account logged in
/// now), when the last `status` lists it ([TsdmAppV4.has], after [ensureStatus]).
///
/// The form, or the forum's message instead of it ([SmallFormAnswer]); null when the app reads the web page as before
/// (nothing asked: the flag off; or an answer that is not the form: `status` forgotten, [TsdmAppApi.forgetStatus];
/// a form the app can not send as served, [SmallFormFields.usable]). An answer served to another account, or after the
/// account changed, is an [IdentityChangedException]; a failed request its failure.
Future<Either<AppException, SmallFormAnswer?>> moderateV4Form(
  SmallFormKind kind,
  String url, {
  required ModerateGet get,
  required ModerateEnsureStatus ensureStatus,
  required int uid,
  required int Function() currentUid,
}) async {
  await ensureStatus();
  if (!TsdmAppV4.has(TsdmAppV4Group.forms, kind.name)) {
    return right(null);
  }
  final resp = await get(withTsdmAppV4Form(url));
  switch (resp) {
    case Left(:final value):
      return left(value);
    case Right(:final value) when value.statusCode != HttpStatus.ok:
      return left(HttpRequestFailedException(value.statusCode));
    case Right(:final value):
      if (currentUid() != uid) {
        return left(IdentityChangedException());
      }
      final answer = smallFormAnswerOf(value.data, kind);
      if (answer == null) {
        // Asked as `status` said and answered as without it: the flag is stale.
        TsdmAppApi.forgetStatus();
        return right(null);
      }
      if (answer.uid != uid) {
        return left(IdentityChangedException());
      }
      return right(answer is SmallFormFields && !answer.usable ? null : answer);
  }
}

/// Read page [page] of thread [tid], oldest floor first, as the thread page reads it.
typedef ModerateThreadPage = Future<Either<AppException, ThreadPageInfo>> Function(String tid, int page);

/// The error handler call of the AJAX answer to a management request the forum refused (without the app API):
/// `errorhandle_mods('抱歉，您没有权限设置主题置顶', {});`, the message quoted with `\'` escaped.
final _errorHandleRe = RegExp(r"errorhandle_mods\('(?<error>(?:[^'\\]|\\.)*)'");

/// The success handler call of the AJAX answer to a management request (without the app API).
final _succeedHandleRe = RegExp(r"succeedhandle_mods\('(?:[^'\\]|\\.)*',\s*'(?<message>(?:[^'\\]|\\.)*)'");

String _unescape(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);

/// Thread management of a moderator: whether the account moderates a forum, the forum's management windows, and the
/// management requests.
///
/// Bound to the account logged in when each request is made (`currentUid`): an answer served to another account is
/// dropped ([IdentityChangedException]), and a window is never posted once the account changed.
///
/// The app decides nothing about permissions: the forum says whether the account moderates the forum, lists the
/// levels and forums the account may choose from, and refuses what the account may not do, in its own words.
final class ModerateRepository with LoggerMixin {
  /// Constructor; transports are injected so the flow is tested without the forum.
  ModerateRepository({
    required ModerateGet get,
    required ModeratePost post,
    int Function()? currentUid,
    ModerateThreadPage? threadPage,
    ModerateEnsureStatus? ensureStatus,
  }) : _get = get,
       _post = post,
       _threadPage = threadPage ?? _networkThreadPage,
       _currentUid = currentUid ?? currentLoginUid,
       _ensureStatus = ensureStatus ?? moderateStatusKnown;

  /// Uses the app's client.
  factory ModerateRepository.network() => ModerateRepository(
    get: (url) async => switch (await getIt.get<NetClientProvider>().get(url).run()) {
      Left(:final value) => left(value),
      Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
    },
    post: (url, body) async =>
        switch (await getIt.get<NetClientProvider>().postForm(url, data: body, singleAttempt: true).run()) {
          Left(:final value) => left(value),
          Right(:final value) => right((statusCode: value.statusCode ?? 0, data: value.data)),
        },
    ensureStatus: moderateEnsureStatus,
  );

  final ModerateGet _get;
  final ModeratePost _post;
  final ModerateThreadPage _threadPage;
  final int Function() _currentUid;

  /// Asks the `status` of the forum's app API when it is not known yet; without one, what is known is used.
  final ModerateEnsureStatus _ensureStatus;

  /// Small form [kind] at [url] for account [uid] ([moderateV4Form]).
  Future<Either<AppException, SmallFormAnswer?>> _v4Form(SmallFormKind kind, String url, int uid) =>
      moderateV4Form(kind, url, get: _get, ensureStatus: _ensureStatus, uid: uid, currentUid: _currentUid);

  static Future<Either<AppException, ThreadPageInfo>> _networkThreadPage(String tid, int page) =>
      ThreadRepository().fetchThreadPage(tid: tid, pageNumber: page, reverseOrder: false).run();

  /// Read page [page] of thread [tid] for the account logged in, oldest floor first: the thread to merge, the floors
  /// to split off. A page served to another account is an [IdentityChangedException].
  AsyncEither<ThreadPageInfo> fetchThreadPage(String tid, {int page = 1}) => AsyncEither(() async {
    final uid = _currentUid();
    if (uid <= 0) {
      return left(IdentityChangedException());
    }
    final answer = await _threadPage(tid, page);
    if (_currentUid() != uid) {
      return left(IdentityChangedException());
    }
    return answer;
  });

  /// Whether an account moderates a forum, by `uid:fid`, with the time it was learnt.
  static final _moderates = <String, (bool, DateTime)>{};

  /// How long [isModerator] keeps an answer.
  static const moderatorKeptFor = Duration(minutes: 10);

  /// Forget every [isModerator] answer (tests).
  static void resetModeratorCache() => _moderates.clear();

  /// Whether the account logged in moderates forum [fid], as the forum's app API tells on the forum page
  /// (`forum.ismoderator`, plugin 2.0.0): the thread page answer does not carry it.
  ///
  /// False for a guest, a forum page that is not the structured answer (no plugin, the forum's message: no
  /// permission) and an answer served to another account; null when the request failed (ask again later). Kept for
  /// [moderatorKeptFor] per account and forum.
  Future<bool?> isModerator(int fid) async {
    final uid = _currentUid();
    if (uid <= 0 || fid <= 0) {
      return false;
    }
    final key = '$uid:$fid';
    if (_moderates[key] case (final known, final at) when DateTime.now().difference(at) < moderatorKeptFor) {
      return known;
    }
    final resp = await _get(withTsdmAppJson('$baseUrl/forum.php?mod=forumdisplay&fid=$fid'));
    final Object? data;
    switch (resp) {
      case Right(:final value) when value.statusCode == HttpStatus.ok:
        data = value.data;
      default:
        return null;
    }
    final json = tsdmAppAnswerJson(data);
    if (json == null || _currentUid() != uid) {
      return false;
    }
    final moderates = moderatorOf(json, uid: uid, fid: fid);
    if (moderates != null) {
      _moderates[key] = (moderates, DateTime.now());
    }
    return moderates ?? false;
  }

  /// Whether forum page answer [json] says account [uid] moderates forum [fid]; null when it is not that answer
  /// (no `schema`, another account, another forum).
  static bool? moderatorOf(Map<String, dynamic> json, {required int uid, required int fid}) {
    if (json['schema'] is! num || tsdmAppInt(json['uid']) != uid) {
      return null;
    }
    final forum = tsdmAppMap(json['forum']);
    if (tsdmAppInt(forum['fid']) != fid) {
      return null;
    }
    return tsdmAppInt(forum['ismoderator']) == 1;
  }

  /// Ask the window of [operation] for thread [tid] in forum [fid].
  ///
  /// The window comes as the app API's write result (plugin 2.6.0, a `page`), or as the AJAX fragment of a forum
  /// without the plugin; the forum's refusal to open it (`admin_nopermission`, no such thread) is a
  /// [ModerateWindowRefused] with its words. A window served to another account is an [IdentityChangedException].
  ///
  /// A repair has no window and is never asked one (the forum repairs the thread at its url): its window is made for
  /// the account logged in ([ModerateForm.repair]), nothing is requested.
  AsyncEither<ModerateWindow> fetchWindow(ModerateOperation operation, {required String tid, required int fid}) =>
      AsyncEither(() async {
        final uid = _currentUid();
        if (operation == ModerateOperation.repair) {
          return uid <= 0
              ? left(IdentityChangedException())
              : right(ModerateWindowReady(ModerateForm.repair(tid: tid, fid: fid, uid: uid)));
        }
        final url = ModerateForm.windowUrl(operation, tid: tid, fid: fid);
        switch (await _v4Form(SmallFormKind.moderate, url, uid)) {
          case Left(:final value):
            return left(value);
          case Right(:final value?):
            if (windowOfApi(value, operation, tid: tid, fid: fid, uid: uid) case final window?) {
              return right(window);
            }
          case Right(value: null):
            break;
        }
        final resp = await _get(withTsdmAppJsonWrite(url));
        switch (resp) {
          case Left(:final value):
            return left(value);
          case Right(:final value) when value.statusCode != HttpStatus.ok:
            return left(HttpRequestFailedException(value.statusCode));
          case Right(:final value):
            if (_currentUid() != uid) {
              return left(IdentityChangedException());
            }
            return windowOf(value.data, operation, tid: tid, fid: fid, uid: uid);
        }
      });

  /// The forum refused a window by language key [key] for what asking again does not change: the account's group may
  /// not do it (`no_privilege_stampthread`…), the thread is a special one (`special_noaction`: no copy, merge or split)
  /// or has no reply to split off (`admin_split_invalid`).
  static bool _refusedForGood(String key) =>
      key.startsWith('no_privilege_') || key == 'special_noaction' || key == 'admin_split_invalid';

  /// The window of [operation] for thread [tid] of forum [fid] in the small form answer [answer] of plugin 4.0.0
  /// (`form: moderate`), asked by account [uid]: the window ([ModerateForm.fromApi]), the forum's refusal to open it in
  /// its words (`message_key` [_refusedForGood] for good), a window served without the operation
  /// ([ModerateForm.lacksOperationApi]). Null for a window the app does not read as one: the web page is read instead.
  static ModerateWindow? windowOfApi(
    SmallFormAnswer answer,
    ModerateOperation operation, {
    required String tid,
    required int fid,
    required int uid,
  }) {
    switch (answer) {
      case SmallFormMessage(:final reason, :final messageKey):
        return ModerateWindowRefused(reason, unavailable: _refusedForGood(messageKey));
      case final SmallFormFields fields:
        if (ModerateForm.fromApi(fields, operation, tid: tid, fid: fid, uid: uid) case final form?) {
          return ModerateWindowReady(form);
        }
        if (ModerateForm.lacksOperationApi(fields, operation, fid: fid, tid: tid)) {
          return const ModerateWindowRefused('', unavailable: true);
        }
        return null;
    }
  }

  /// The window of [operation] in answer [data], asked by account [uid].
  static Either<AppException, ModerateWindow> windowOf(
    Object? data,
    ModerateOperation operation, {
    required String tid,
    required int fid,
    required int uid,
  }) {
    final result = tsdmAppWriteResultOf(data);
    if (result != null) {
      if (result.uid != uid) {
        return left(IdentityChangedException());
      }
      if (result.kind != TsdmAppWriteKind.page) {
        // The account's group may not do it (`no_privilege_stampthread`…): asking again changes nothing. The AJAX
        // fragment of a forum without the plugin has no message key: its refusal is offered to retry.
        return right(ModerateWindowRefused(result.reason, unavailable: _refusedForGood(result.messageKey)));
      }
      final form = ModerateForm.parse(result.document, operation, tid: tid, fid: fid, uid: uid);
      if (form != null) {
        return right(ModerateWindowReady(form));
      }
      if (ModerateForm.lacksOperation(result.document, operation, fid: fid, tid: tid)) {
        return right(const ModerateWindowRefused('', unavailable: true));
      }
      return left(HttpRequestFailedException(HttpStatus.ok));
    }
    final text = _ajaxText(tsdmAppAnswerText(data));
    // The account was checked around the request (fetchWindow): the window is that account's.
    final doc = parseHtmlDocument(text);
    final form = ModerateForm.parse(doc, operation, tid: tid, fid: fid, uid: uid);
    if (form != null) {
      return right(ModerateWindowReady(form));
    }
    if (ModerateForm.lacksOperation(doc, operation, fid: fid, tid: tid)) {
      return right(const ModerateWindowRefused('', unavailable: true));
    }
    if (_errorHandleRe.firstMatch(text)?.namedGroup('error') case final error?) {
      return right(ModerateWindowRefused(_unescape(error)));
    }
    return left(HttpRequestFailedException(HttpStatus.ok));
  }

  /// Send [request] with the window [form] it was chosen in, once.
  ///
  /// Never sent when the account changed since the window was served ([IdentityChangedException]). The forum's
  /// verdict is read from the app API's result (the `admin_succeed` message key) or, without the plugin, from the
  /// handler the AJAX answer calls; anything else is a refusal in the forum's words.
  ///
  /// A repair is told by its own message key (`admin_repair_succeed`); without the plugin the forum calls the error
  /// handler for it too, in its success box.
  AsyncEither<ModerateOutcome> submit(ModerateForm form, ModerateRequest request) => AsyncEither(() async {
    if (request.operation.group != form.operation.group ||
        (form.operation.group == 0 && request.operation != form.operation)) {
      return left(HttpRequestFailedException(null));
    }
    final uid = _currentUid();
    if (uid <= 0 || form.uid != uid) {
      return left(IdentityChangedException());
    }
    final repair = form.operation == ModerateOperation.repair;
    final resp = await _post(form.submitUrl, request.body(form));
    return switch (resp) {
      Left(:final value) => left(value),
      Right(:final value) when value.statusCode != HttpStatus.ok => left(HttpRequestFailedException(value.statusCode)),
      Right(:final value) => right(
        repair ? outcomeOf(value.data, successKey: 'admin_repair_succeed', successBox: true) : outcomeOf(value.data),
      ),
    };
  });

  /// The categories a thread copied to forum [fid] may be put in (`forum.php?mod=ajax&action=getthreadtypes`, the
  /// select the copy window loads once a forum is picked), in the forum's order: `0` (none) among them unless the
  /// forum requires one, `0` alone for a forum without categories. Those of moderators only are listed to a moderator
  /// of [fid] only.
  ///
  /// An answer served to another account is an [IdentityChangedException].
  AsyncEither<List<ModerateChoice>> fetchThreadTypes(int fid) => AsyncEither(() async {
    final uid = _currentUid();
    final url = '$baseUrl/forum.php?mod=ajax&action=getthreadtypes&fid=$fid&inajax=1';
    switch (await _v4Form(SmallFormKind.threadtypes, url, uid)) {
      case Left(:final value):
        return left(value);
      case Right(value: final SmallFormFields fields):
        if (threadTypesOfApi(fields) case final types?) {
          return right(types);
        }
      case Right(value: SmallFormMessage() || null):
        // The forum does not refuse the select; anything else is read from the web page.
        break;
    }
    final resp = await _get(withTsdmAppJsonWrite(url));
    switch (resp) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (_currentUid() != uid) {
          return left(IdentityChangedException());
        }
        return threadTypesOf(value.data, uid: uid);
    }
  });

  /// The categories of a forum in the small form [answer] of plugin 4.0.0 (`form: threadtypes`, its `select`), as
  /// [threadTypesOf] reads the select of the web page; null when it holds none.
  static List<ModerateChoice>? threadTypesOfApi(SmallFormFields answer) {
    final types = <ModerateChoice>[];
    for (final option in tsdmAppList(tsdmAppMap(answer.json['select'])['choices'])) {
      final value = switch (option['value']) {
        final String s => s,
        final num n => '$n',
        _ => '',
      };
      if (int.tryParse(value) == null || types.any((e) => e.value == value)) {
        continue;
      }
      types.add(ModerateChoice(value: value, label: tsdmAppText(option['label']).trim()));
    }
    return types.isEmpty ? null : types;
  }

  /// The categories of a forum in answer [data] to [fetchThreadTypes], asked by account [uid].
  static Either<AppException, List<ModerateChoice>> threadTypesOf(Object? data, {required int uid}) {
    final uh.Document doc;
    if (tsdmAppWriteResultOf(data) case final result?) {
      if (result.uid != uid) {
        return left(IdentityChangedException());
      }
      if (result.kind != TsdmAppWriteKind.page) {
        return left(HttpRequestFailedException(HttpStatus.ok));
      }
      doc = result.document;
    } else {
      doc = parseHtmlDocument(_ajaxText(tsdmAppAnswerText(data)));
    }
    final select = doc.querySelector('select[name="threadtypeid"]');
    if (select == null) {
      return left(HttpRequestFailedException(HttpStatus.ok));
    }
    final types = <ModerateChoice>[];
    for (final option in select.querySelectorAll('option')) {
      final value = option.attributes['value'] ?? '';
      if (int.tryParse(value) == null || types.any((e) => e.value == value)) {
        continue;
      }
      types.add(ModerateChoice(value: value, label: option.text?.trim() ?? ''));
    }
    return types.isEmpty ? left(HttpRequestFailedException(HttpStatus.ok)) : right(types);
  }

  /// Ask the window of [operation] for threads [tids] of forum [fid]: the window of the threads the forum takes
  /// ([ModerateBatchForm.tids]), as [fetchWindow] asks the window of one thread.
  AsyncEither<ModerateBatchWindow> fetchBatchWindow(
    ModerateOperation operation, {
    required List<String> tids,
    required int fid,
  }) => AsyncEither(() async {
    final uid = _currentUid();
    final url = ModerateForm.batchWindowUrl(operation, tids: tids, fid: fid);
    switch (await _v4Form(SmallFormKind.moderate, url, uid)) {
      case Left(:final value):
        return left(value);
      case Right(:final value?):
        if (batchWindowOfApi(value, operation, tids: tids, fid: fid, uid: uid) case final window?) {
          return right(window);
        }
      case Right(value: null):
        break;
    }
    final resp = await _get(withTsdmAppJsonWrite(url));
    switch (resp) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (_currentUid() != uid) {
          return left(IdentityChangedException());
        }
        return batchWindowOf(value.data, operation, tids: tids, fid: fid, uid: uid);
    }
  });

  /// The window of [operation] for threads [tids] of forum [fid] in the small form answer [answer] of plugin 4.0.0,
  /// asked by account [uid], as [windowOfApi] reads the window of one thread; null when the web page is read instead.
  static ModerateBatchWindow? batchWindowOfApi(
    SmallFormAnswer answer,
    ModerateOperation operation, {
    required List<String> tids,
    required int fid,
    required int uid,
  }) {
    switch (answer) {
      case SmallFormMessage(:final reason):
        return ModerateBatchWindowRefused(reason);
      case final SmallFormFields fields:
        if (ModerateForm.batchFromApi(fields, operation, tids: tids, fid: fid, uid: uid) case final form?) {
          return ModerateBatchWindowReady(form);
        }
        if (ModerateForm.lacksOperationApi(fields, operation, fid: fid, tids: tids)) {
          return const ModerateBatchWindowRefused('', unavailable: true);
        }
        return null;
    }
  }

  /// The window of [operation] for threads [tids] in answer [data], asked by account [uid].
  static Either<AppException, ModerateBatchWindow> batchWindowOf(
    Object? data,
    ModerateOperation operation, {
    required List<String> tids,
    required int fid,
    required int uid,
  }) {
    final result = tsdmAppWriteResultOf(data);
    if (result != null) {
      if (result.uid != uid) {
        return left(IdentityChangedException());
      }
      if (result.kind != TsdmAppWriteKind.page) {
        return right(ModerateBatchWindowRefused(result.reason));
      }
      final form = ModerateForm.parseBatch(result.document, operation, tids: tids, fid: fid, uid: uid);
      if (form != null) {
        return right(ModerateBatchWindowReady(form));
      }
      if (ModerateForm.lacksOperation(result.document, operation, fid: fid, tids: tids)) {
        return right(const ModerateBatchWindowRefused('', unavailable: true));
      }
      return left(HttpRequestFailedException(HttpStatus.ok));
    }
    final text = _ajaxText(tsdmAppAnswerText(data));
    // The account was checked around the request (fetchBatchWindow): the window is that account's.
    final doc = parseHtmlDocument(text);
    final form = ModerateForm.parseBatch(doc, operation, tids: tids, fid: fid, uid: uid);
    if (form != null) {
      return right(ModerateBatchWindowReady(form));
    }
    if (ModerateForm.lacksOperation(doc, operation, fid: fid, tids: tids)) {
      return right(const ModerateBatchWindowRefused('', unavailable: true));
    }
    if (_errorHandleRe.firstMatch(text)?.namedGroup('error') case final error?) {
      return right(ModerateBatchWindowRefused(_unescape(error)));
    }
    return left(HttpRequestFailedException(HttpStatus.ok));
  }

  /// Do [request] on threads [tids] of forum [fid], starting with window [first] (asked for [tids]), and tell what
  /// became of each thread.
  ///
  /// The forum answers one verdict for the threads of a request and acts on those its window holds only (no more than
  /// the account's threads per page): the threads it held are posted once, and the window is asked again for the
  /// threads left until none is left. A thread no window takes failed in the forum's words of the last window; a
  /// refusal fails the threads not done yet in its words, and nothing is sent after it; a request sent whose verdict
  /// was lost (the network, an answer the app can not read) leaves its threads unknown. Nothing is sent once the
  /// account changed since a window was served.
  Future<ModerateBatchReport> runBatch(
    ModerateBatchForm first,
    ModerateRequest request, {
    required List<String> tids,
    required int fid,
  }) async {
    final results = <String, ModerateBatchResult>{};
    final remaining = [...tids];
    void failRemaining(ModerateBatchFailure kind, [String message = '']) {
      for (final tid in remaining) {
        results[tid] ??= ModerateBatchFailed(kind, message);
      }
      remaining.clear();
    }

    /// The threads of a request whose answer was lost: the forum may have done them.
    void unknown(List<String> sent) {
      for (final tid in sent) {
        results[tid] = const ModerateBatchFailed(ModerateBatchFailure.unknown);
      }
    }

    ModerateBatchFailure failureOf(AppException e) =>
        e is IdentityChangedException ? ModerateBatchFailure.accountChanged : ModerateBatchFailure.failed;

    var batch = first;
    while (remaining.isNotEmpty) {
      final uid = _currentUid();
      if (uid <= 0 || batch.window.uid != uid || request.operation.group != batch.window.operation.group) {
        failRemaining(ModerateBatchFailure.accountChanged);
        break;
      }
      final resp = await _post(batch.window.submitUrl, batch.body(request));
      switch (resp) {
        case Left(:final value):
          if (value is! IdentityChangedException) {
            unknown(batch.tids);
          }
          failRemaining(failureOf(value));
        case Right(:final value) when value.statusCode != HttpStatus.ok:
          unknown(batch.tids);
          failRemaining(ModerateBatchFailure.failed);
        case Right(:final value):
          switch (outcomeOf(value.data)) {
            case ModerateSucceeded():
              for (final tid in batch.tids) {
                results[tid] = const ModerateBatchDone();
              }
              remaining.removeWhere(batch.tids.contains);
            case ModerateRefused(:final message):
              if (message.isEmpty) {
                // An answer the app can not read (a maintenance page, a proxy's): the forum may have done them.
                unknown(batch.tids);
              }
              failRemaining(ModerateBatchFailure.refused, message);
          }
      }
      if (remaining.isEmpty) {
        break;
      }
      switch (await fetchBatchWindow(batch.window.operation, tids: remaining, fid: fid).run()) {
        case Left(:final value):
          failRemaining(failureOf(value));
        case Right(value: ModerateBatchWindowRefused(:final message)):
          failRemaining(ModerateBatchFailure.refused, message);
        case Right(value: ModerateBatchWindowReady(:final form)):
          batch = form;
      }
    }
    return ModerateBatchReport({for (final tid in tids) tid: ?results[tid]});
  }

  /// The forum's verdict in answer [data] to a management request; [successKey] is the language key of its success
  /// (`admin_succeed` for a thread or a floor, `modcp_mod_succeed` for the moderation queue, `admin_repair_succeed`
  /// for a repair).
  ///
  /// Without the plugin a success calls the success handler, but with [successBox] also the error handler inside the
  /// forum's success box (`div.alert_right`): a message the forum shows without sending the window on (a repair).
  static ModerateOutcome outcomeOf(Object? data, {String successKey = 'admin_succeed', bool successBox = false}) {
    if (tsdmAppWriteResultOf(data) case final result?) {
      // Told by the language key, not by the words.
      if (result.succeeded && result.messageKey == successKey) {
        return ModerateSucceeded(result.message);
      }
      return ModerateRefused(result.reason);
    }
    final text = _ajaxText(tsdmAppAnswerText(data));
    if (_succeedHandleRe.firstMatch(text) case final match?) {
      return ModerateSucceeded(_unescape(match.namedGroup('message')!).trim());
    }
    if (_errorHandleRe.firstMatch(text)?.namedGroup('error') case final error?) {
      if (successBox && parseHtmlDocument(text).querySelector('div.alert_right') != null) {
        return ModerateSucceeded(_unescape(error).trim());
      }
      return ModerateRefused(_unescape(error));
    }
    return const ModerateRefused('');
  }

  /// Ask the window of [action] on floor [pid] of thread [tid] in forum [fid].
  ///
  /// As [fetchWindow]: the app API's `page`, or the AJAX fragment without the plugin; the forum's refusal is a
  /// [FloorModerateWindowRefused] with its words, a window served to another account an [IdentityChangedException].
  /// [undo] asks the window of a choosable action with the undoing checked ([FloorModerateForm.windowUrl]).
  AsyncEither<FloorModerateWindow> fetchFloorWindow(
    FloorModerateAction action, {
    required String tid,
    required int fid,
    required String pid,
    bool undo = false,
  }) => AsyncEither(() async {
    final uid = _currentUid();
    final url = FloorModerateForm.windowUrl(action, tid: tid, fid: fid, pid: pid, undo: undo);
    if (action.apiForm case final kind?) {
      switch (await _v4Form(kind, url, uid)) {
        case Left(:final value):
          return left(value);
        case Right(:final value?):
          if (floorWindowOfApi(value, action, tid: tid, fid: fid, pid: pid, uid: uid) case final window?) {
            return right(window);
          }
        case Right(value: null):
          break;
      }
    }
    final resp = await _get(withTsdmAppJsonWrite(url));
    switch (resp) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (_currentUid() != uid) {
          return left(IdentityChangedException());
        }
        return floorWindowOf(value.data, action, tid: tid, fid: fid, pid: pid, uid: uid);
    }
  });

  /// The window of [action] on floor [pid] in the small form answer [answer] of plugin 4.0.0, asked by account [uid]:
  /// the window ([FloorModerateForm.fromApi]) or the forum's refusal in its words (the first floor's deletion, which
  /// the forum sends on to the thread's, without words, as the web page's window); null when the web page is read
  /// instead.
  static FloorModerateWindow? floorWindowOfApi(
    SmallFormAnswer answer,
    FloorModerateAction action, {
    required String tid,
    required int fid,
    required String pid,
    required int uid,
  }) => switch (answer) {
    SmallFormMessage(:final reason, :final url) => FloorModerateWindowRefused(
      _isThreadDeletion(url) && reason.trim().isEmpty ? '' : reason,
    ),
    final SmallFormFields fields => switch (FloorModerateForm.fromApi(
      fields,
      action,
      tid: tid,
      fid: fid,
      pid: pid,
      uid: uid,
    )) {
      final form? => FloorModerateWindowReady(form),
      null => null,
    },
  };

  /// [url] is where the forum sends a floor's deletion of the first floor on to: the thread's deletion
  /// (`topicadmin&action=moderate&operation=delete`).
  static bool _isThreadDeletion(String url) {
    final query = Uri.tryParse(url)?.queryParameters ?? const {};
    return query['mod'] == 'topicadmin' && query['action'] == 'moderate' && query['operation'] == 'delete';
  }

  /// The window of [action] on floor [pid] in answer [data], asked by account [uid].
  static Either<AppException, FloorModerateWindow> floorWindowOf(
    Object? data,
    FloorModerateAction action, {
    required String tid,
    required int fid,
    required String pid,
    required int uid,
  }) {
    final result = tsdmAppWriteResultOf(data);
    if (result != null) {
      if (result.uid != uid) {
        return left(IdentityChangedException());
      }
      if (result.kind != TsdmAppWriteKind.page) {
        // A refusal, or the redirect of the first floor to the thread's deletion: no window of this floor.
        return right(FloorModerateWindowRefused(result.kind == TsdmAppWriteKind.redirect ? '' : result.reason));
      }
      final form = FloorModerateForm.parse(result.document, action, tid: tid, fid: fid, pid: pid, uid: uid);
      return form == null ? left(HttpRequestFailedException(HttpStatus.ok)) : right(FloorModerateWindowReady(form));
    }
    final text = _ajaxText(tsdmAppAnswerText(data));
    // The account was checked around the request (fetchFloorWindow): the window is that account's.
    final form = FloorModerateForm.parse(parseHtmlDocument(text), action, tid: tid, fid: fid, pid: pid, uid: uid);
    if (form != null) {
      return right(FloorModerateWindowReady(form));
    }
    if (_errorHandleRe.firstMatch(text)?.namedGroup('error') case final error?) {
      return right(FloorModerateWindowRefused(_unescape(error)));
    }
    return left(HttpRequestFailedException(HttpStatus.ok));
  }

  /// Send the window [form] of a floor with [reason] and [notify], once; never when the account changed since the
  /// window was served ([IdentityChangedException]). Succeeded on `admin_succeed` only.
  AsyncEither<ModerateOutcome> submitFloor(FloorModerateForm form, {String reason = '', bool notify = false}) =>
      AsyncEither(() async {
        final uid = _currentUid();
        if (uid <= 0 || form.uid != uid) {
          return left(IdentityChangedException());
        }
        final resp = await _post(form.submitUrl, form.body(reason: reason, notify: notify));
        return switch (resp) {
          Left(:final value) => left(value),
          Right(:final value) when value.statusCode != HttpStatus.ok => left(
            HttpRequestFailedException(value.statusCode),
          ),
          Right(:final value) => right(outcomeOf(value.data)),
        };
      });

  /// Read page [page] of list [kind] of the moderation queue of forum [fid] (the moderation panel's web page; the
  /// plugin leaves it as it is).
  ///
  /// The panel's login form is a [ModerateQueueNeedsLogin]; its refusal (no access, locked, no permission) a
  /// [ModerateQueueRefused] with its words. A page served to another account is an [IdentityChangedException].
  AsyncEither<ModerateQueueAnswer> fetchQueue(ModerateQueueKind kind, {required int fid, int page = 1}) =>
      AsyncEither(() async {
        final uid = _currentUid();
        if (uid <= 0) {
          return left(IdentityChangedException());
        }
        final resp = await _get(ModerateQueueList.url(kind, fid: fid, page: page));
        switch (resp) {
          case Left(:final value):
            return left(value);
          case Right(:final value) when value.statusCode != HttpStatus.ok:
            return left(HttpRequestFailedException(value.statusCode));
          case Right(:final value):
            if (_currentUid() != uid) {
              return left(IdentityChangedException());
            }
            return queueOf(value.data, kind, fid: fid, uid: uid, page: page);
        }
      });

  /// The list [kind] of forum [fid] in answer [data], asked by account [uid].
  static Either<AppException, ModerateQueueAnswer> queueOf(
    Object? data,
    ModerateQueueKind kind, {
    required int fid,
    required int uid,
    int page = 1,
  }) {
    final doc = parseHtmlDocument(tsdmAppAnswerText(data));
    if (moderatePageUid(doc) case final served? when served != uid) {
      return left(IdentityChangedException());
    }
    if (moderatePanelLoginFormHash(doc) case final formHash?) {
      return right(ModerateQueueNeedsLogin(formHash: formHash));
    }
    if (parseModerateQueue(doc, kind, fid: fid, uid: uid, page: page) case final list?) {
      return right(ModerateQueueReady(list));
    }
    final message = moderatePageMessage(doc);
    if (message.isNotEmpty) {
      return right(ModerateQueueRefused(message));
    }
    return left(HttpRequestFailedException(HttpStatus.ok));
  }

  /// Log in to the moderation panel with the account's [password], on the login form of form hash [formHash] (forum
  /// [fid]), once. The password is sent only here and kept nowhere.
  AsyncEither<ModeratePanelLogin> loginPanel({
    required String formHash,
    required int fid,
    required String password,
  }) => AsyncEither(() async {
    final uid = _currentUid();
    if (uid <= 0) {
      return left(IdentityChangedException());
    }
    final resp = await _post('$baseUrl/forum.php?mod=modcp&action=login', {
      'formhash': formHash,
      'fid': '$fid',
      'submit': 'yes',
      'login_panel': 'yes',
      'cppwd': password,
    });
    return switch (resp) {
      Left(:final value) => left(value),
      // The forum sends the account on to the panel (the redirect is not followed for a post).
      Right(:final value) when value.statusCode >= 300 && value.statusCode < 400 => right(
        const ModeratePanelLoggedIn(),
      ),
      Right(:final value) when value.statusCode != HttpStatus.ok => left(HttpRequestFailedException(value.statusCode)),
      Right(:final value) => _currentUid() != uid ? left(IdentityChangedException()) : right(panelLoginOf(value.data)),
    };
  });

  /// How the panel answered a password in [data].
  static ModeratePanelLogin panelLoginOf(Object? data) {
    final uh.Document doc;
    if (tsdmAppWriteResultOf(data) case final result?) {
      switch (result.kind) {
        case TsdmAppWriteKind.redirect:
          return const ModeratePanelLoggedIn();
        case TsdmAppWriteKind.message || TsdmAppWriteKind.handle:
          return ModeratePanelRefused(result.reason);
        case TsdmAppWriteKind.page:
          doc = result.document;
      }
    } else {
      doc = parseHtmlDocument(tsdmAppAnswerText(data));
    }
    if (moderatePanelLoginFormHash(doc) != null) {
      return const ModeratePanelWrongPassword();
    }
    if (moderatePageMessage(doc) case final message
        when message.isNotEmpty && doc.querySelector('div#messagetext') != null) {
      return ModeratePanelRefused(message);
    }
    // The page the forum sent the account on to: the panel.
    return const ModeratePanelLoggedIn();
  }

  /// Do [action] on [item] of list [page] with [reason], once; never when the account changed since the list was
  /// served ([IdentityChangedException]). Succeeded on `modcp_mod_succeed` only; an answer the app can not read (the
  /// panel's session ended: its login form, or the forum's error page) is a refusal without words.
  AsyncEither<ModerateOutcome> submitQueue(
    ModerateQueueList page,
    ModerateQueueAction action,
    ModerateQueueItem item, {
    String reason = '',
  }) => AsyncEither(() async {
    final uid = _currentUid();
    if (uid <= 0 || page.uid != uid) {
      return left(IdentityChangedException());
    }
    final resp = await _post(page.submitUrl, page.body(action, item, reason: reason));
    return switch (resp) {
      Left(:final value) => left(value),
      Right(:final value) when value.statusCode != HttpStatus.ok => left(HttpRequestFailedException(value.statusCode)),
      Right(:final value) => right(outcomeOf(value.data, successKey: 'modcp_mod_succeed')),
    };
  });

  /// Ask the moderation panel's window banning member [memberUid] from posting (the website's 禁止用户 of the floor's
  /// author column).
  ///
  /// The panel's page, as the plugin leaves it: its login form is a [MemberBanNeedsLogin]; its refusal (no access, a
  /// member that can not be banned directly) a [MemberBanWindowRefused] with its words. A page served to another
  /// account is an [IdentityChangedException].
  AsyncEither<MemberBanWindow> fetchMemberBanWindow(int memberUid) => AsyncEither(() async {
    final uid = _currentUid();
    if (uid <= 0 || memberUid <= 0) {
      return left(IdentityChangedException());
    }
    final resp = await _get(MemberBanForm.windowUrl(memberUid));
    switch (resp) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        if (_currentUid() != uid) {
          return left(IdentityChangedException());
        }
        return memberBanWindowOf(value.data, memberUid: memberUid, uid: uid);
    }
  });

  /// The ban window of member [memberUid] in answer [data], asked by account [uid].
  static Either<AppException, MemberBanWindow> memberBanWindowOf(
    Object? data, {
    required int memberUid,
    required int uid,
  }) {
    final doc = parseHtmlDocument(tsdmAppAnswerText(data));
    if (moderatePageUid(doc) case final served? when served != uid) {
      return left(IdentityChangedException());
    }
    if (moderatePanelLoginFormHash(doc) case final formHash?) {
      return right(MemberBanNeedsLogin(formHash: formHash));
    }
    if (MemberBanForm.parse(doc, memberUid: memberUid, uid: uid) case final form?) {
      return right(MemberBanWindowReady(form));
    }
    var message = moderatePageMessage(doc);
    if (message.isEmpty) {
      // The panel's search form alone, with why the member was not loaded in its caption (staff of the forum).
      message = (doc.querySelector('div.mn form caption')?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    if (message.isNotEmpty || doc.querySelector('form') != null) {
      // A message, or the panel's page without a window the app can send: nothing to offer.
      return right(MemberBanWindowRefused(message));
    }
    return left(HttpRequestFailedException(HttpStatus.ok));
  }

  /// Send the ban window [form]: ban the member from posting for [days] (null for ever), or lift the ban of a banned
  /// member, with [reason], once; never when the account changed since the window was served
  /// ([IdentityChangedException]).
  AsyncEither<MemberBanOutcome> submitMemberBan(MemberBanForm form, {int? days, String reason = ''}) => AsyncEither(
    () async {
      final uid = _currentUid();
      if (uid <= 0 || form.uid != uid) {
        return left(IdentityChangedException());
      }
      final resp = await _post(withTsdmAppJsonWrite(MemberBanForm.submitUrl), form.body(days: days, reason: reason));
      return switch (resp) {
        Left(:final value) => left(value),
        // The panel answers a ban with its message page, never a redirect (its quick forward is asked by the message's
        // language key, and the panel gives translated words): whatever sent this one, the ban may have been done.
        Right(:final value) when value.statusCode >= 300 && value.statusCode < 400 => right(const MemberBanUnknown()),
        Right(:final value) when value.statusCode != HttpStatus.ok => left(
          HttpRequestFailedException(value.statusCode),
        ),
        Right(:final value) => memberBanOutcomeOf(value.data, uid: uid),
      };
    },
  );

  /// The panel's verdict in answer [data] to a ban sent by account [uid].
  ///
  /// The panel words its success and its refusals itself (no message key): a message page is a success unless the
  /// forum marks it an error (the app API's `alert`; the page's class other than `alert_info` or `alert_right`). A
  /// redirect is not the panel's answer ([MemberBanUnknown]), unless to the login. A page is never a success: the
  /// panel's login form is [MemberBanSessionEnded], anything else a refusal without words.
  static Either<AppException, MemberBanOutcome> memberBanOutcomeOf(Object? data, {required int uid}) {
    final uh.Document doc;
    if (tsdmAppWriteResultOf(data) case final result?) {
      if (result.uid != uid) {
        return left(IdentityChangedException());
      }
      switch (result.kind) {
        case TsdmAppWriteKind.message:
          return right(
            result.succeeded && !result.isError ? MemberBanDone(result.message) : MemberBanRefused(result.reason),
          );
        case TsdmAppWriteKind.redirect:
          return right(result.login ? MemberBanRefused(result.reason) : const MemberBanUnknown());
        case TsdmAppWriteKind.handle:
          return right(MemberBanRefused(result.reason));
        case TsdmAppWriteKind.page:
          doc = result.document;
      }
    } else {
      doc = parseHtmlDocument(tsdmAppAnswerText(data));
      if (moderatePageUid(doc) case final served? when served != uid) {
        return left(IdentityChangedException());
      }
      if (doc.querySelector('div#messagetext') case final box?) {
        final message = moderatePageMessage(doc);
        // Success as the panel shows it (`alert_info`, or `alert_right`); anything else a refusal.
        final done = box.classes.contains('alert_info') || box.classes.contains('alert_right');
        return right(done ? MemberBanDone(message) : MemberBanRefused(message));
      }
    }
    if (moderatePanelLoginFormHash(doc) case final formHash?) {
      return right(MemberBanSessionEnded(formHash: formHash));
    }
    return right(const MemberBanRefused(''));
  }

  /// The html inside the AJAX answer [text] (`<root><![CDATA[…]]></root>`), [text] itself when it is not one.
  static String _ajaxText(String text) {
    if (!text.trimLeft().startsWith('<?xml')) {
      return text;
    }
    try {
      return parseXmlDocument(text).documentElement?.text ?? text;
    } on Object catch (_) {
      return text;
    }
  }
}
