import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/member_ban.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
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
  ModerateRepository({required ModerateGet get, required ModeratePost post, int Function()? currentUid})
    : _get = get,
      _post = post,
      _currentUid = currentUid ?? currentLoginUid;

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
  );

  final ModerateGet _get;
  final ModeratePost _post;
  final int Function() _currentUid;

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
  AsyncEither<ModerateWindow> fetchWindow(ModerateOperation operation, {required String tid, required int fid}) =>
      AsyncEither(() async {
        final uid = _currentUid();
        final resp = await _get(withTsdmAppJsonWrite(ModerateForm.windowUrl(operation, tid: tid, fid: fid)));
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
        return right(ModerateWindowRefused(result.reason));
      }
      final form = ModerateForm.parse(result.document, operation, tid: tid, fid: fid, uid: uid);
      return form == null ? left(HttpRequestFailedException(HttpStatus.ok)) : right(ModerateWindowReady(form));
    }
    final text = _ajaxText(tsdmAppAnswerText(data));
    // The account was checked around the request (fetchWindow): the window is that account's.
    final form = ModerateForm.parse(parseHtmlDocument(text), operation, tid: tid, fid: fid, uid: uid);
    if (form != null) {
      return right(ModerateWindowReady(form));
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
  AsyncEither<ModerateOutcome> submit(ModerateForm form, ModerateRequest request) => AsyncEither(() async {
    if (request.operation.group != form.operation.group) {
      return left(HttpRequestFailedException(null));
    }
    final uid = _currentUid();
    if (uid <= 0 || form.uid != uid) {
      return left(IdentityChangedException());
    }
    final resp = await _post(form.submitUrl, request.body(form));
    return switch (resp) {
      Left(:final value) => left(value),
      Right(:final value) when value.statusCode != HttpStatus.ok => left(HttpRequestFailedException(value.statusCode)),
      Right(:final value) => right(outcomeOf(value.data)),
    };
  });

  /// Ask the window of [operation] for threads [tids] of forum [fid]: the window of the threads the forum takes
  /// ([ModerateBatchForm.tids]), as [fetchWindow] asks the window of one thread.
  AsyncEither<ModerateBatchWindow> fetchBatchWindow(
    ModerateOperation operation, {
    required List<String> tids,
    required int fid,
  }) => AsyncEither(() async {
    final uid = _currentUid();
    final resp = await _get(withTsdmAppJsonWrite(ModerateForm.batchWindowUrl(operation, tids: tids, fid: fid)));
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
      return form == null ? left(HttpRequestFailedException(HttpStatus.ok)) : right(ModerateBatchWindowReady(form));
    }
    final text = _ajaxText(tsdmAppAnswerText(data));
    // The account was checked around the request (fetchBatchWindow): the window is that account's.
    final form = ModerateForm.parseBatch(parseHtmlDocument(text), operation, tids: tids, fid: fid, uid: uid);
    if (form != null) {
      return right(ModerateBatchWindowReady(form));
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
  /// (`admin_succeed` for a thread or a floor, `modcp_mod_succeed` for the moderation queue).
  static ModerateOutcome outcomeOf(Object? data, {String successKey = 'admin_succeed'}) {
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
      return ModerateRefused(_unescape(error));
    }
    return const ModerateRefused('');
  }

  /// Ask the window of [action] on floor [pid] of thread [tid] in forum [fid].
  ///
  /// As [fetchWindow]: the app API's `page`, or the AJAX fragment without the plugin; the forum's refusal is a
  /// [FloorModerateWindowRefused] with its words, a window served to another account an [IdentityChangedException].
  AsyncEither<FloorModerateWindow> fetchFloorWindow(
    FloorModerateAction action, {
    required String tid,
    required int fid,
    required String pid,
  }) => AsyncEither(() async {
    final uid = _currentUid();
    final resp = await _get(withTsdmAppJsonWrite(FloorModerateForm.windowUrl(action, tid: tid, fid: fid, pid: pid)));
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
    final message = moderatePageMessage(doc);
    if (message.isNotEmpty || doc.querySelector('form') != null) {
      // A message, or the panel's page without a window the app can send: nothing to offer.
      return right(MemberBanWindowRefused(message));
    }
    return left(HttpRequestFailedException(HttpStatus.ok));
  }

  /// Send the ban window [form]: ban the member from posting for [days] (null for ever), or lift the ban of a banned
  /// member, with [reason], once; never when the account changed since the window was served
  /// ([IdentityChangedException]).
  AsyncEither<MemberBanOutcome> submitMemberBan(MemberBanForm form, {int? days, String reason = ''}) =>
      AsyncEither(() async {
        final uid = _currentUid();
        if (uid <= 0 || form.uid != uid) {
          return left(IdentityChangedException());
        }
        final resp = await _post(withTsdmAppJsonWrite(MemberBanForm.submitUrl), form.body(days: days, reason: reason));
        return switch (resp) {
          Left(:final value) => left(value),
          // The forum sends the moderator back to the panel's ban page once done (its quick forward of a message).
          Right(:final value) when value.statusCode >= 300 && value.statusCode < 400 => right(const MemberBanDone('')),
          Right(:final value) when value.statusCode != HttpStatus.ok => left(
            HttpRequestFailedException(value.statusCode),
          ),
          Right(:final value) => memberBanOutcomeOf(value.data, uid: uid),
        };
      });

  /// The panel's verdict in answer [data] to a ban sent by account [uid].
  ///
  /// The panel words its success and its refusals itself (no message key): a message page is a success unless the
  /// forum marks it an error (the app API's `alert`, the page's `alert_error`); a redirect back to the ban page is a
  /// success. A page is never one: the panel's login form is [MemberBanSessionEnded], anything else a refusal without
  /// words.
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
          return right(
            result.succeeded && isMemberBanUrl(result.url) ? const MemberBanDone('') : MemberBanRefused(result.reason),
          );
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
        return right(box.classes.contains('alert_error') ? MemberBanRefused(message) : MemberBanDone(message));
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
