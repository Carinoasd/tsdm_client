import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:uuid/uuid.dart';

/// GET [action] of the app API with [query] and [headers]: the JSON answer, null when the request failed.
typedef AdminGet =
    Future<Map<String, dynamic>?> Function(String action, Map<String, String> query, Map<String, String> headers);

/// POST [form] to [action] of the app API once with [headers]: the JSON answer, null when the request failed.
typedef AdminPost =
    Future<Map<String, dynamic>?> Function(String action, Map<String, String> form, Map<String, String> headers);

/// Ask the account's login password again (the admin login dialog) after the forum answered `admin_login` with
/// [login]; true once the login succeeded and the token is kept.
typedef AdminReauth = Future<bool> Function(AdminLoginInfo login);

/// What an admin action answered.
@immutable
final class AdminReply {
  /// Constructor.
  const AdminReply(this.json, {this.identityChanged = false});

  /// The request failed or the answer was no JSON.
  static const failed = AdminReply(null);

  /// The account in use changed while the request was on its way: the answer is dropped.
  static const changed = AdminReply(null, identityChanged: true);

  /// The answer; null when there is none.
  final Map<String, dynamic>? json;

  /// The account changed meanwhile.
  final bool identityChanged;

  /// The forum did it (`ok` 1).
  bool get ok => json?['ok'] == 1;

  /// The forum's error code, empty for none.
  String get error => tsdmAppText(json?['error']);

  /// Why the forum refused (`why` of `admin_noperm`), empty for none.
  String get why => tsdmAppText(json?['why']);

  /// The seconds to wait of `busy` and `admin_locked`.
  int get retryAfter => tsdmAppInt(json?['retry_after']);
}

/// The admin token of the account that logged in last, kept in memory only (never stored, never logged), and the
/// pages using it.
///
/// One token per account at a time: a second login voids the first (on every device). The forum ends it after its
/// idle time or two hours; the app drops it when the account in use is another one, when the app lock locks and when
/// the last admin page is left (with `op=logout`, [release]).
final class AdminSession {
  /// The app's session.
  static final instance = AdminSession();

  ({int uid, String token})? _held;
  int _leases = 0;

  /// Clearings of members' posts left unfinished, by the account and the member: the cursor to go on from.
  final _clearCursors = <(int, int), AdminClearAt>{};

  /// The token of account [uid]; null when none is kept for it. Not only a read: a token (and the clearings) kept for
  /// another account are dropped here, as the account in use changed; every request asks it.
  String? tokenFor(int uid) {
    if (_held case final held? when held.uid != uid) {
      _held = null;
      _clearCursors.removeWhere((key, _) => key.$1 != uid);
    }
    return _held?.token;
  }

  /// Whether a token is kept for [uid].
  bool holds(int uid) => _held?.uid == uid;

  /// Keep [token] for account [uid].
  void keep(int uid, String token) => _held = (uid: uid, token: token);

  /// Forget the token.
  void drop() => _held = null;

  /// Forget the token when it is still [token] (a newer login keeps its own).
  void dropToken(String token) {
    if (_held?.token == token) _held = null;
  }

  /// An admin page (or the panel listing them) opened.
  void acquire() => _leases++;

  /// An admin page closed; when it was the last, the token is ended with [logout] (only while one is kept).
  void release(Future<void> Function() logout) {
    _leases = _leases > 0 ? _leases - 1 : 0;
    if (_leases == 0 && _held != null) {
      unawaited(logout());
    }
  }

  /// Pages holding the session (for tests).
  @visibleForTesting
  int get leases => _leases;

  /// Drop the token whenever [locked] says the app lock locked the app.
  StreamSubscription<bool> dropOnLock(Stream<bool> locked) => locked.where((l) => l).listen((_) => drop());

  /// The unfinished clearing of member [target]'s posts by account [uid].
  AdminClearAt? clearCursor(int uid, int target) => _clearCursors[(uid, target)];

  /// Keep where the clearing of [target]'s posts by [uid] stopped; null when it is done.
  void keepClearCursor(int uid, int target, AdminClearAt? at) {
    if (at == null) {
      _clearCursors.remove((uid, target));
    } else {
      _clearCursors[(uid, target)] = at;
    }
  }

  /// Forget everything (for tests).
  @visibleForTesting
  void reset() {
    _held = null;
    _leases = 0;
    _clearCursors.clear();
  }
}

/// Where a clearing of a member's posts stopped: the cursor to go on from, the rows it counts from and those left.
typedef AdminClearAt = ({String cursor, int total, int remaining});

/// A new operation id for one write (`opid`, 8 to 64 characters): kept while the same form is sent again (after a
/// time-out, `busy`, a second login), replaced once the form changes or the forum answered it.
String newAdminOpId() => const Uuid().v4();

/// The forum's admin actions (plugin 3.9.0) for the account in use: the entry (`action=admin`), the second login and
/// the actions' GETs and POSTs with the admin token.
///
/// Bound to the account logged in when each request is made: an answer served to another account, or after the account
/// changed, is dropped ([AdminReply.changed]). The forum decides everything; the app only shows what it answered.
final class AdminRepository {
  /// Constructor; transports are injected so the flows are tested without a forum.
  AdminRepository({
    required AdminGet get,
    required AdminPost post,
    int Function()? currentUid,
    AdminSession? session,
    Future<void> Function(Duration wait)? wait,
  }) : _get = get,
       _post = post,
       _currentUid = currentUid ?? currentLoginUid,
       _session = session ?? AdminSession.instance,
       _wait = wait ?? Future<void>.delayed;

  /// Uses the app's client: GETs wait for `busy` as other API pages do, POSTs are sent once and `busy` (HTTP 429)
  /// comes back as an answer.
  factory AdminRepository.network() => AdminRepository(
    get: (action, query, headers) => TsdmAppApi.askWithHeaders(getIt.get<NetClientProvider>(), action, query, headers),
    post: (action, form, headers) =>
        TsdmAppApi.post(getIt.get<NetClientProvider>(), action, form, acceptStatus: const {429}, headers: headers),
  );

  final AdminGet _get;
  final AdminPost _post;
  final int Function() _currentUid;
  final AdminSession _session;
  final Future<void> Function(Duration wait) _wait;

  String _formHash = '';

  /// The account in use.
  int get currentUid => _currentUid();

  /// The session the token is kept in.
  AdminSession get session => _session;

  Map<String, String> _headers(int uid) => switch (_session.tokenFor(uid)) {
    final token? => {adminTokenHeader: token},
    null => const {},
  };

  /// Send once for the account in use, with its token when one is kept.
  Future<AdminReply> _send(String action, {Map<String, String>? query, Map<String, String>? form}) async {
    final uid = _currentUid();
    if (uid <= 0) {
      return AdminReply.changed;
    }
    if (form != null && _formHash.isEmpty) {
      // Every answer carries the form hash; the entry is the lightest to ask for it.
      final entry = await _get('admin', const {}, _headers(uid));
      if (_currentUid() != uid) return AdminReply.changed;
      _noteFormHash(entry, uid);
      if (_formHash.isEmpty) return AdminReply(entry);
    }
    final headers = _headers(uid);
    final json = form != null
        ? await _post(action, {...form, 'formhash': _formHash}, headers)
        : await _get(action, query ?? const {}, headers);
    if (_currentUid() != uid) {
      return AdminReply.changed;
    }
    if (form != null && json == null) {
      // A form hash the forum does not take is refused by Discuz itself (HTTP 503, no JSON): ask it again next time.
      _formHash = '';
    }
    // A batch of the clearing names the member cleared as `uid` (spec 3.9.0 §6); every other answer the account.
    if (json != null && json['op'] != 'clear' && json['uid'] is int && json['uid'] != uid && json['uid'] != 0) {
      return AdminReply.changed;
    }
    _noteFormHash(json, uid);
    final reply = AdminReply(json);
    switch (reply.error) {
      case 'admin_login':
        _session.drop();
      case 'admin_off':
        _session.drop();
        AdminAccessCache.forget(uid);
      case 'admin_noperm' when reply.why != 'perm' && reply.why != 'allowpost':
        _session.drop();
        AdminAccessCache.forget(uid);
      case 'formhash':
        _formHash = '';
    }
    return reply;
  }

  void _noteFormHash(Map<String, dynamic>? json, int uid) {
    final hash = tsdmAppText(json?['formhash']);
    if (hash.isNotEmpty) _formHash = hash;
  }

  /// Send [action] (a GET with [query], or a POST of [form] when given) with the admin token. When the forum asks for
  /// the admin login (`admin_login`), [reauth] asks the password and the very same request is sent once more (a write
  /// with the same `opid`); a second `admin_login` is given back.
  Future<AdminReply> request(
    String action, {
    Map<String, String>? query,
    Map<String, String>? form,
    AdminReauth? reauth,
  }) async {
    final uid = _currentUid();
    final reply = await _send(action, query: query, form: form);
    if (reply.error != 'admin_login' || reauth == null) {
      return reply;
    }
    final loggedIn = await reauth(AdminLoginInfo.fromJson(reply.json?['login']));
    if (!loggedIn) {
      return reply;
    }
    if (_currentUid() != uid) {
      return AdminReply.changed;
    }
    final again = await _send(action, query: query, form: form);
    // The forum checks the interval before the token: the request sent right after the login may be answered `busy`.
    // Nothing was done then (and a write carries the same `opid`), so it is sent once more after the wait asked.
    if (again.error == 'busy' && again.retryAfter <= 10) {
      await _wait(Duration(milliseconds: (again.retryAfter > 0 ? again.retryAfter : 1) * 1000 + 300));
      if (_currentUid() != uid) {
        return AdminReply.changed;
      }
      return _send(action, query: query, form: form);
    }
    return again;
  }

  /// The entry `action=admin`: what the account may use (with the token when one is kept, so `session.active` tells
  /// whether it still holds).
  Future<AdminReply> entry() => _send('admin');

  /// What the account may use; null when the forum could not tell.
  Future<AdminAccess?> access() async => AdminAccess.fromJson((await entry()).json);

  /// The second login with the account's login [password] (and the security question [questionId] with [answer] when
  /// asked): the token is kept on success and never given back. The password is only sent, never kept or logged.
  Future<AdminReply> login({required String password, int questionId = 0, String answer = ''}) async {
    final uid = _currentUid();
    final reply = await _send(
      'admin',
      form: {
        'op': 'login',
        'password': password,
        if (questionId > 0) ...{'questionid': '$questionId', 'answer': answer},
      },
    );
    final json = reply.json;
    final token = tsdmAppText(json?['token']);
    if (reply.ok && token.isNotEmpty && _currentUid() == uid) {
      _session.keep(uid, token);
    }
    // The token stays in the session only: the answer handed on goes without it.
    return json == null || !json.containsKey('token')
        ? reply
        : AdminReply({...json}..remove('token'), identityChanged: reply.identityChanged);
  }

  /// End the token (`op=logout`) and forget it; nothing is sent when none is kept for the account in use.
  Future<void> logout() async {
    final uid = _currentUid();
    final token = uid > 0 ? _session.tokenFor(uid) : null;
    if (token == null) {
      _session.drop();
      return;
    }
    try {
      await _send('admin', form: const {'op': 'logout'});
    } on Exception catch (e) {
      talker.debug('admin logout failed: $e');
    } finally {
      // A page opened meanwhile may have logged in again: only the token logged out is forgotten.
      _session.dropToken(token);
    }
  }
}

/// What an account may do with the forum's admin actions, asked once per account and kept for ten minutes.
///
/// Asked only for an account of a management group (the callers check it first), so an ordinary member sends nothing.
/// First the forum's switch (`status.admin`, asked for the account), then `action=admin`.
/// An answer that could not be had is not kept; `eligible 0` and the switch off are answers and are kept.
abstract final class AdminAccessCache {
  static const _keep = Duration(minutes: 10);

  static final _known = <int, ({AdminAccess access, DateTime at})>{};
  static final _asking = <int, Future<AdminAccess?>>{};

  /// The kept answer for [uid], null when none is kept or it is stale.
  static AdminAccess? cached(int uid) {
    final known = _known[uid];
    if (known == null || DateTime.now().difference(known.at) >= _keep) {
      return null;
    }
    return known.access;
  }

  /// Forget the answer kept for [uid] (an admin action answered `admin_off` or `admin_noperm`).
  static void forget(int uid) => _known.remove(uid);

  /// What [uid] may use; null when the forum could not tell.
  ///
  /// [switchOn] tells the forum's switch (null: could not tell), [repository] asks `action=admin`; both default to the
  /// app's client. When [stillCurrent] says the account is no longer in use once the forum answered, nothing is kept.
  static Future<AdminAccess?> check(
    int uid, {
    AdminRepository? repository,
    Future<bool?> Function()? switchOn,
    bool Function()? stillCurrent,
  }) {
    final kept = cached(uid);
    if (kept != null) {
      return Future.value(kept);
    }
    return _asking[uid] ??= _ask(
      uid,
      repository,
      switchOn,
      stillCurrent,
    ).whenComplete(() => unawaited(_asking.remove(uid)));
  }

  /// Asked for the account each time (once per account and ten minutes): the plugin answers `admin: 1` only to an
  /// administrator logged in, so what another account's `status` told does not hold for this one.
  static Future<bool?> _switchOn() async {
    final status = await TsdmAppApi.askWaiting(getIt.get<NetClientProvider>(), 'status');
    if (status == null || status['ok'] != 1) {
      return null;
    }
    // A `status` without the switch is an older plugin: no admin actions.
    return status['admin'] == 1;
  }

  static Future<AdminAccess?> _ask(
    int uid,
    AdminRepository? repository,
    Future<bool?> Function()? switchOn,
    bool Function()? stillCurrent,
  ) async {
    try {
      final on = await (switchOn ?? _switchOn)();
      if (on == null || !(stillCurrent?.call() ?? true)) {
        return null;
      }
      final access = on ? await (repository ?? AdminRepository.network()).access() : AdminAccess.off;
      if (access == null || !(stillCurrent?.call() ?? true)) {
        return null;
      }
      _known[uid] = (access: access, at: DateTime.now());
      return access;
    } on Exception {
      return null;
    }
  }

  /// Forget everything kept.
  @visibleForTesting
  static void reset() {
    _known.clear();
    _asking.clear();
  }
}

/// How a clearing of a member's posts ended: all done, stopped by the page (left), or refused or failed with `reply`.
typedef AdminClearOutcome = ({bool done, AdminReply? reply});

/// Clear member [target]'s posts batch by batch (`op=clear`) from [cursor] until the forum says done, telling each
/// batch to [onStep]. [total] is the rows the progress counts from (`post_rows`), [remaining] those left now.
///
/// Where it stopped is kept in the session ([AdminSession.clearCursor]) before each batch, so a page left, an answer
/// that failed or the app's next visit of the member goes on from there; the forum takes any cursor again (a batch
/// already in the recycle bin is not counted twice), and `0-0` starts over. An expired token mid-way asks the password
/// again through [reauth] and the same cursor is sent again. The batches need no `opid` and are not rate limited.
Future<AdminClearOutcome> runAdminClear(
  AdminRepository repository, {
  required int target,
  required String cursor,
  required int total,
  required int remaining,
  required void Function(AdminClearStep step) onStep,
  required bool Function() stopped,
  AdminReauth? reauth,
}) async {
  final uid = repository.currentUid;
  var at = cursor.isEmpty ? adminClearStart : cursor;
  var left = remaining;
  while (true) {
    repository.session.keepClearCursor(uid, target, (cursor: at, total: total, remaining: left));
    if (stopped()) {
      return (done: false, reply: null);
    }
    final reply = await repository.request(
      AdminActions.ban,
      form: adminClearForm(uid: target, cursor: at),
      reauth: reauth,
    );
    final step = adminClearStepOf(reply.json);
    if (step == null) {
      return (done: false, reply: reply);
    }
    onStep(step);
    if (step.done) {
      repository.session.keepClearCursor(uid, target, null);
      return (done: true, reply: reply);
    }
    if (step.cursor.isEmpty || step.cursor == at) {
      // A cursor that does not move would ask the same batch forever.
      return (done: false, reply: reply);
    }
    at = step.cursor;
    left = step.remaining;
  }
}
