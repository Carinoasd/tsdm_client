import 'dart:async';

import 'package:flutter/widgets.dart';
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

/// The admin token of the account that logged in last, kept in memory only (never stored, never logged).
///
/// One token per account at a time: a second login voids the first (on every device). The forum ends it after its idle
/// time (`session.ttl`, 15 minutes by default) or two hours (`session.max`); the app keeps it as long as the forum's
/// last answer said ([noteAnswer]), so going from one admin page to another, or between the profile and the panel,
/// asks the password once. It is ended earlier ([AdminRepository.logout], with `op=logout`) when the account in use
/// changes, the app lock locks, the app stays in the background too long ([AdminSessionGuard]) or the user logs out
/// of it by hand.
final class AdminSession extends ChangeNotifier {
  /// Constructor; [clock] tells the time (tests).
  AdminSession({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// The app's session.
  static final instance = AdminSession();

  /// Ended this much before the forum's expiry: the forum notes the activity at most every 30 seconds.
  static const expiryMargin = Duration(seconds: 30);

  final DateTime Function() _clock;

  ({int uid, String token})? _held;

  /// When the token held is void on the forum's side; null while unknown (an answer without `session`).
  DateTime? _expires;

  /// Clearings of members' posts left unfinished, by the account and the member: the cursor to go on from.
  final _clearCursors = <(int, int), AdminClearAt>{};

  bool get _expired => _expires != null && !_clock().isBefore(_expires!);

  /// The token of account [uid]; null when none is kept for it. Not only a read: a token (and the clearings) kept for
  /// another account are dropped here, as the account in use changed, and so is a token the forum has let expire;
  /// every request asks it.
  String? tokenFor(int uid) {
    if (_held case final held? when held.uid != uid) {
      _clearCursors.removeWhere((key, _) => key.$1 != uid);
      drop();
    } else if (_held != null && _expired) {
      drop();
    }
    return _held?.token;
  }

  /// Whether a token is kept for [uid] (and has not expired).
  bool holds(int uid) => _held?.uid == uid && !_expired;

  /// Keep [token] for account [uid].
  void keep(int uid, String token) {
    _held = (uid: uid, token: token);
    _expires = null;
    notifyListeners();
  }

  /// Forget the token.
  void drop() {
    final had = _held != null;
    _held = null;
    _expires = null;
    if (had) notifyListeners();
  }

  /// Forget the token when it is still [token] (a newer login keeps its own).
  void dropToken(String token) {
    if (_held?.token == token) drop();
  }

  /// Note what the forum said of [token] in [json]: while its `session` is `active`, the token is kept until the
  /// `expires` told (as of the answer's `time`, less [expiryMargin]). An inactive one is left to the forum's
  /// `admin_login`, which asks the password again.
  void noteAnswer(String token, Map<String, dynamic>? json) {
    if (_held?.token != token || json?['session'] is! Map) {
      return;
    }
    final session = json!['session'] as Map;
    if (session['active'] != 1) {
      return;
    }
    final expires = tsdmAppInt(session['expires']);
    final now = tsdmAppInt(json['time']);
    final ttl = tsdmAppInt(session['ttl']);
    final left = expires > 0 && now > 0 ? expires - now : ttl;
    if (left > 0) {
      _expires = _clock().add(Duration(seconds: left) - expiryMargin);
    }
  }

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
    _expires = null;
    _clearCursors.clear();
  }
}

/// Ends the admin token ([AdminSession]) when the app lock locks or the app comes back after [background] or more in
/// the background (the forum would end it after its idle time anyway; this does not wait for it).
final class AdminSessionGuard {
  /// Constructor: [logout] ends the token of the account in use ([AdminRepository.logout]).
  AdminSessionGuard({
    required Future<void> Function() logout,
    DateTime Function()? clock,
    this.background = const Duration(minutes: 5),
  }) : _logout = logout,
       _clock = clock ?? DateTime.now;

  final Future<void> Function() _logout;
  final DateTime Function() _clock;

  /// How long in the background ends the token.
  final Duration background;

  DateTime? _away;
  StreamSubscription<bool>? _lock;
  AppLifecycleListener? _lifecycle;

  /// Watch [locked] (the app lock) and the app's lifecycle.
  void start(Stream<bool> locked) {
    watchLock(locked);
    _lifecycle = AppLifecycleListener(onStateChange: onLifecycle);
  }

  /// End the token whenever [locked] says the app lock locked the app.
  @visibleForTesting
  void watchLock(Stream<bool> locked) => _lock = locked.where((l) => l).listen((_) => unawaited(_logout()));

  /// The app's lifecycle changed to [state].
  @visibleForTesting
  void onLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        _away ??= _clock();
      case AppLifecycleState.resumed:
        final away = _away;
        _away = null;
        if (away != null && _clock().difference(away) >= background) {
          unawaited(_logout());
        }
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  /// Stop watching.
  Future<void> dispose() async {
    _lifecycle?.dispose();
    await _lock?.cancel();
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

  /// Send once for the account in use, with its token when one is kept ([token] instead: a logout, the token already
  /// dropped here).
  Future<AdminReply> _send(
    String action, {
    Map<String, String>? query,
    Map<String, String>? form,
    String? token,
  }) async {
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
    final headers = token != null ? {adminTokenHeader: token} : _headers(uid);
    final sent = headers[adminTokenHeader];
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
    // The top `uid` of every answer is the account asking, a batch of the clearing too (its member is `target_uid`).
    if (json != null && json['uid'] is int && json['uid'] != uid && json['uid'] != 0) {
      return AdminReply.changed;
    }
    _noteFormHash(json, uid);
    if (sent != null) _session.noteAnswer(sent, json);
    final reply = AdminReply(json);
    switch (reply.error) {
      case 'admin_login':
        // Only the token this request carried is void: one a login made meanwhile got is kept.
        if (sent != null) _session.dropToken(sent);
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
      _session
        ..keep(uid, token)
        ..noteAnswer(token, json);
    }
    // The token stays in the session only: the answer handed on goes without it.
    return json == null || !json.containsKey('token')
        ? reply
        : AdminReply({...json}..remove('token'), identityChanged: reply.identityChanged);
  }

  /// End the token (`op=logout`, sent with it) and forget it; nothing is sent when none is kept for the account in use.
  /// It is forgotten here before the logout is sent, so a page cannot use it meanwhile and a failed logout leaves
  /// none. The forum answers `admin_login` when the token was void already (and changes nothing): logged out all the
  /// same. `busy` (the login and the logout share the forum's interval) is waited for once.
  Future<void> logout() async {
    final uid = _currentUid();
    final token = uid > 0 ? _session.tokenFor(uid) : null;
    if (token == null) {
      _session.drop();
      return;
    }
    // A page opened meanwhile may log in again: only the token logged out is forgotten.
    _session.dropToken(token);
    try {
      final reply = await _send('admin', form: const {'op': 'logout'}, token: token);
      if (reply.error == 'busy' && reply.retryAfter <= 10 && _currentUid() == uid) {
        await _wait(Duration(milliseconds: (reply.retryAfter > 0 ? reply.retryAfter : 1) * 1000 + 300));
        if (_currentUid() == uid) await _send('admin', form: const {'op': 'logout'}, token: token);
      }
    } on Exception catch (e) {
      talker.debug('admin logout failed: $e');
    }
  }

  /// Log out of the token of the account in use when one is kept ([logout]), before the account in use changes (a
  /// switch, a login, a logout, a removal): the forum ends a token only for the account it belongs to, so it cannot be
  /// ended once the cookie is another account's. Waits [limit] at most; the token is dropped here all the same.
  static Future<void> logoutBeforeIdentityChange({
    AdminRepository? repository,
    Duration limit = const Duration(seconds: 4),
  }) async {
    final repo = repository ?? AdminRepository.network();
    final uid = repo.currentUid;
    if (uid <= 0 || !repo.session.holds(uid)) {
      return;
    }
    try {
      await repo.logout().timeout(limit);
    } on TimeoutException {
      talker.debug('admin logout before the account changed: no answer in time');
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
/// Where it stopped is kept in the session ([AdminSession.clearCursor]) before each batch, for the progress shown when
/// the page comes back; the forum keeps the progress itself and does not read the cursor (sent back all the same), so
/// what goes on is what its `clear_pending` says. An expired token mid-way asks the password again through [reauth]
/// and the same cursor is sent again. The batches need no `opid` and are not rate limited.
///
/// `clear_start` (no clearing of the member open: a new ban with `post` starts one) and `clear_stuck` (a batch made no
/// progress) stop it with the forum's answer; the cursor kept is dropped for the former.
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
    final step = adminClearStepOf(reply.json, target: target);
    if (step == null) {
      if (reply.error == 'clear_start' || (reply.json != null && reply.ok)) {
        // No clearing of this member is open on the forum (left over a day, another member's started since, or an
        // answer about another member): only a new ban with `post` starts one, the cursor kept is of no use.
        repository.session.keepClearCursor(uid, target, null);
      }
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
