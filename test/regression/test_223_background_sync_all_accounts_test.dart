/// Background notifications for every logged-in account: the Android background message service polls every account
/// saved on this device when `backgroundSyncAllAccounts` is on, the account in use only otherwise, as before.
///
/// * Off (the default): a tick fetches the account in use and nothing else, request for request as before.
/// * On: every account, one after another (the account in use first), each with its own cookie, its own poll slot,
///   its own stored rows and fetch bound, and the plugin's `seen` posted with its own form hash; a pause between two
///   accounts that reached the forum.
/// * A notification carries its account: the payload names the uid, the title names the account and each account
///   gets a notification id of its own. A tap on the notification of another account switches to it (the avatar
///   menu's quick switch) before the notice page opens; nothing opens when the switch does not happen.
/// * An expired login, a failure or a 429 of one account is that account's outcome: the others still run and the
///   account in use is never logged out; another account known to be expired is not polled until it logs in again.
///
/// Synthetic answers and names, no real account.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' show Either;
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/background_sync/background_sync_service.dart';
import 'package:tsdm_client/features/background_sync/background_sync_tick.dart';
import 'package:tsdm_client/features/background_sync/other_accounts_auto_sync.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/multi_user/utils/switch_account.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_sync_all_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/notification/utils/poll_slot.dart';
import 'package:tsdm_client/features/notification/view/notification_sync_all_page.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/popup_route_observer.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:universal_html/parsing.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);
const _carol = UserLoginInfo(username: 'Carol', uid: 1002);
const List<UserLoginInfo> _everyone = [_alice, _bob, _carol];

/// The value of the auth cookie of [user]; the fake forum tells the accounts apart by it.
String _token(UserLoginInfo user) => user.username!.toLowerCase();

int _uidOf(String token) => _everyone.firstWhere((u) => _token(u) == token).uid!;

/// Cookie row in the format the persistent cookie jar reads back: the auth cookie is sent with every request.
Map<String, String> _jar(UserLoginInfo user) => {
  '.index': '["$baseHost"]',
  baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=${_token(user)}; Path=/;_crt=1"}}',
};

/// The forum clock: now, since the repository clamps `since` to three days ago.
final int _now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

/// The offset (hours) the forum shows the member's times with: the test machine's own zone, see test_211.
final num _offset = DateTime.now().timeZoneOffset.inMinutes / 60;

/// The form hash of account [uid] in its `notify` answer.
String _formhash(int uid) => 'fh$uid';

/// The id of the one unread notice account [uid] has.
int _noticeId(int uid) => uid * 10;

/// A `notify` answer of plugin 1.9.0 for account [uid]: one unread reply notice, two minutes old.
Map<String, Object?> _notifyOf(int uid) => {
  'ok': 1,
  'api': 1,
  'version': '1.9.0',
  'time': _now,
  'uid': uid,
  'formhash': _formhash(uid),
  'timeoffset': _offset,
  'counts': {'notice': 1, 'pm': 0, 'announce': 0},
  'pm_last': 0,
  'notices': [
    {
      'id': _noticeId(uid),
      'new': 1,
      'type': 'post',
      'category': 1,
      'authorid': 3001,
      'author': 'Peer',
      'note':
          '<a href="home.php?mod=space&uid=3001">Peer</a> 回复了您的帖子 '
          '<a href="forum.php?mod=redirect&goto=findpost&ptid=5&pid=$uid" target="_blank">Thread of $uid</a>',
      'text': 'Peer 回复了您的帖子 Thread of $uid',
      'dateline': _now - 120,
      'from_id': 5,
      'from_idtype': 'post',
      'from_num': 0,
    },
  ],
  'pms': <Object?>[],
  'announces': <Object?>[],
};

/// The `pmlist` answer of account [uid] listing [pms].
Map<String, Object?> _pmlistOf(int uid, [List<Map<String, Object?>> pms = const []]) => {
  'ok': 1,
  'api': 1,
  'time': _now,
  'uid': uid,
  'closed': 0,
  'timeoffset': _offset,
  'page': 1,
  'perpage': 20,
  'count': pms.length,
  'pms': pms,
};

/// An unread conversation with peer 3001 (the author of every notice here) for account [uid], one minute old.
Map<String, Object?> _conversationOf(int uid) => {
  'plid': uid,
  'new': 1,
  'type': 1,
  'subject': '',
  'count': 2,
  'members': 2,
  'touid': 3001,
  'tousername': 'Peer',
  'lastauthorid': 3001,
  'lastauthor': 'Peer',
  'lastsummary': 'hello $uid',
  'lastsummary_html': 'hello $uid',
  'lastdateline': _now - 60,
};

const _emptyBroadcastPage = '<html><body><div id="um"></div><div class="pml"></div></body></html>';

/// One answer of the fake forum.
final class _Answer {
  const _Answer(this.body, {this.status = 200, this.type = 'text/html'});

  _Answer.json(Object? json, {int status = 200}) : this(jsonEncode(json), status: status, type: 'application/json');

  final String body;
  final int status;
  final String type;
}

/// The plugin's answer to a cookie whose session is dead: every plugin version answers it before the action.
final _loginAnswer = _Answer.json({'ok': 0, 'error': 'login'});

/// HTTP 429 without `Retry-After`: the account is rate limited this time.
final _busy = _Answer.json({'ok': 0, 'error': 'busy'}, status: 429);

/// A server error.
const _serverError = _Answer('<html><body>Server Error</body></html>', status: 500);

/// One request the forum received: the account (the token of its auth cookie) and what was asked.
typedef _Request = ({String token, String name, DateTime at});

/// The forum of three accounts, told apart by the auth cookie each request carries.
///
/// Every account answers as plugin 1.9.0 with one unread notice unless [all] says otherwise for it; [holds] keeps the
/// `notify` of an account unanswered until completed.
final class _Forum implements HttpClientAdapter {
  /// Every request of an account (by token) answered with this.
  final all = <String, _Answer>{};

  /// The `notify` of an account (by token) answered only once this completes.
  final holds = <String, Completer<void>>{};

  /// The conversations `pmlist` lists for an account (by token), none when missing.
  final pms = <String, List<Map<String, Object?>>>{};

  /// The account `notify` answers an account's cookie as (by token), the account itself when missing.
  final servedAs = <String, int>{};

  final requests = <_Request>[];
  final seenForms = <({String token, Map<String, String> form})>[];
  final unexpected = <String>[];

  /// What [token] asked, in order.
  List<String> of(String token) => requests.where((r) => r.token == token).map((r) => r.name).toList();

  /// The accounts in the order their requests came.
  List<String> get tokens => requests.map((r) => r.token).toList();

  static final _authRe = RegExp('Ystv_2132_auth=([a-z]+)');

  static String _name(RequestOptions r) {
    final q = r.uri.queryParameters;
    if (q['id'] == 'tsdmapp:api') {
      return q['action'] ?? '?';
    }
    if (q['do'] == 'notice') {
      return 'notice page';
    }
    return switch (q['filter']) {
      'privatepm' => 'pm page',
      'announcepm' => 'broadcast page',
      _ => '${r.method} ${r.uri}',
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final cookie = '${options.headers['cookie'] ?? options.headers['Cookie'] ?? ''}';
    final token = _authRe.firstMatch(cookie)?[1] ?? 'no cookie';
    final name = _name(options);
    requests.add((token: token, name: name, at: DateTime.now()));
    if (requestStream != null) {
      final body = utf8.decode(await requestStream.expand((e) => e).toList());
      if (name == 'seen') {
        seenForms.add((token: token, form: Uri.splitQueryString(body)));
      }
    }
    if (name == 'notify' && holds[token] != null) {
      await holds[token]!.future;
    }
    final uid = _everyone.any((u) => _token(u) == token) ? _uidOf(token) : null;
    final answer =
        all[token] ??
        switch (name) {
          'notify' when uid != null => _Answer.json({..._notifyOf(uid), 'uid': servedAs[token] ?? uid}),
          'pmlist' when uid != null => _Answer.json(_pmlistOf(uid, pms[token] ?? const [])),
          'seen' when uid != null => _Answer.json({
            'ok': 1,
            'api': 1,
            'time': _now,
            'uid': uid,
            'notice': 1,
            'newer': 0,
            'pm': 1,
          }),
          'broadcast page' => const _Answer(_emptyBroadcastPage),
          _ => null,
        };
    if (answer == null) {
      unexpected.add('$token ${options.method} ${options.uri}');
      throw DioException.connectionError(requestOptions: options, reason: 'unexpected request');
    }
    return ResponseBody.fromString(
      answer.body,
      answer.status,
      headers: {
        Headers.contentTypeHeader: ['${answer.type}; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Ticks five minutes apart from the start of the run: the poll slots never skip them.
var _ticks = 0;
final _firstTick = DateTime.now();
DateTime _nextTick() => _firstTick.add(Duration(minutes: 5 * _ticks++));

/// Wait until [condition] holds, failing after [timeout] (a fetch that never comes would hang the test otherwise).
Future<void> _until(bool Function() condition, {Duration timeout = const Duration(seconds: 5), String? reason}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('waited ${timeout.inSeconds}s for ${reason ?? 'a condition'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// What a notice page shows the account in use as, and the order things happened in around a notification tap.
final _log = <String>[];

/// The notification bloc of the app, reduced to recording the reload asked after the switch and answering it with the
/// (empty) lists of the account in use, as the real bloc does.
final class _Notifications extends Fake implements NotificationBloc {
  _Notifications(this._auth);

  final AuthenticationRepository _auth;
  final _states = StreamController<NotificationState>.broadcast();
  NotificationState _state = const NotificationState(status: NotificationStatus.success);

  @override
  void add(NotificationEvent event) {
    _log.add('${event.runtimeType} as ${_auth.currentUser?.uid}');
    if (event is NotificationReloadFromStorageRequested) {
      _state = NotificationState(status: NotificationStatus.success, ownerUid: _auth.currentUser?.uid);
      _states.add(_state);
    }
  }

  @override
  NotificationState get state => _state;

  @override
  Stream<NotificationState> get stream => _states.stream;

  @override
  bool get isClosed => false;

  @override
  Future<void> close() => _states.close();
}

/// The check page the switch reads, as served to a logged-in [user].
String _authedPage(UserLoginInfo user) =>
    '<html><body><div id="inner_stat"><strong><a href="home.php?mod=space&amp;uid=${user.uid}">${user.username}</a> '
    '</strong></div><input type="hidden" name="formhash" value="XXXXXXXX" /></body></html>';

const _guestPage =
    '<html><body><form id="lsform" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /> '
    '<input name="username" /></form><div id="messagetext"><p>请先登录后才能继续浏览</p></div></body></html>';

/// The forum the switch checks the stored login with: the account named by the auth cookie of the request, or the
/// guest page for the tokens in [expired].
final class _SwitchForum implements HttpClientAdapter {
  final expired = <String>{};
  final requests = <String>[];

  /// When set, every check is answered once this completes.
  Completer<void>? hold;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final cookie = '${options.headers['cookie'] ?? options.headers['Cookie'] ?? ''}';
    final token = _Forum._authRe.firstMatch(cookie)?[1] ?? 'no cookie';
    requests.add(token);
    if (hold != null) {
      await hold!.future;
    }
    final user = _everyone.where((u) => _token(u) == token).firstOrNull;
    return ResponseBody.fromString(
      user == null || expired.contains(token) ? _guestPage : _authedPage(user),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The structured homepage of plugin 2.3.0 as served to [user].
Map<String, dynamic> _homepageOf(UserLoginInfo user) => {
  ...(jsonDecode(File('test/data/tsdmapp/index_v5_member.json').readAsStringSync()) as Map<String, dynamic>),
  'uid': user.uid,
  'user': {'uid': user.uid, 'username': user.username, 'avatar': 'https://forum.test/data/avatar/noavatar.svg'},
  'red_packet': null,
};

/// `forum.php` answered to the account of the auth cookie of the request (Alice without one); any other page is the
/// own profile page (the homepage reads the avatar there).
final class _HomeForum implements HttpClientAdapter {
  final paths = <String>[];

  /// The tokens of the requests of `forum.php`, in order.
  final homepageTokens = <String>[];

  /// When set, every answer waits for it.
  Completer<void>? hold;

  /// The answers of `forum.php` to an account (by token) wait for these.
  final holds = <String, Completer<void>>{};

  /// Accounts (by token) whose `forum.php` is answered with a server error.
  final failing = <String>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.uri.path);
    final cookie = '${options.headers['cookie'] ?? options.headers['Cookie'] ?? ''}';
    final token = _Forum._authRe.firstMatch(cookie)?[1];
    if (options.uri.path.endsWith('forum.php')) {
      homepageTokens.add(token ?? 'none');
    }
    if (hold != null) {
      await hold!.future;
    }
    final homepage = options.uri.path.endsWith('forum.php');
    if (homepage && holds[token] != null) {
      await holds[token]!.future;
    }
    if (homepage && failing.contains(token)) {
      return ResponseBody.fromString('<html><body>Server Error</body></html>', 500);
    }
    final user = _everyone.where((u) => _token(u) == token).firstOrNull ?? _alice;
    final body = options.uri.path.endsWith('forum.php')
        ? jsonEncode(_homepageOf(user))
        // The own profile page, read by the homepage for the avatar.
        : File('test/data/tsdmapp/profile_v4_self.json').readAsStringSync();
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The storage of the app whose write of the row of [heldUid] waits for [hold]: [writing] tells it is waiting.
final class _HeldStorage extends StorageProvider {
  _HeldStorage(AppDatabase db) : super(db, {}, {});

  int? heldUid;
  final hold = Completer<void>();
  bool writing = false;

  @override
  Future<void> saveCookie({required String username, required int uid, required Cookie cookie}) async {
    if (uid == heldUid && !hold.isCompleted) {
      writing = true;
      await hold.future;
    }
    return super.saveCookie(username: username, uid: uid, cookie: cookie);
  }
}

/// The password login of Alice: the login form (GET) gives the session the auth cookie [token]; the login (POST)
/// answers once [posted] completes.
final class _PasswordForum implements HttpClientAdapter {
  _PasswordForum(this.posted, this.token);

  final Completer<void> posted;
  final String token;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'POST') {
      await posted.future;
      return ResponseBody.fromString(
        "succeedhandle_login('url', 'ok', {'username':'Alice','uid':'1000'});",
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    return ResponseBody.fromString(
      '<div id="layer_login_login"><input name="formhash" value="newhash"></div>',
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        'set-cookie': ['Ystv_2132_auth=$token; Path=/'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Future<void> _settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Lets the snack bar and the database stream timers fire before the framework checks for pending timers.
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late _Forum forum;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() async {
    TsdmAppApi.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    forum = _Forum();
    _log.clear();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
  });

  tearDown(() async {
    TsdmAppApi.reset();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  NetClientProvider clientOf(CookieProvider cookie) => NetClientProvider.buildNoCookie(
    dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
    cookie: cookie,
  );

  NotificationSyncAllRepository repository({bool cookiesFromDatabase = false}) {
    final repo = NotificationSyncAllRepository(
      storageProvider: storage,
      notificationRepository: NotificationRepository(storageProvider: storage),
      clientFactory: clientOf,
      // One account per call, as in the service: the tick spaces the accounts.
      gap: Duration.zero,
      cookiesFromDatabase: cookiesFromDatabase,
    );
    addTearDown(repo.dispose);
    return repo;
  }

  /// Alice (in use), Bob and Carol are logged in on this device; the service is on, auto sync every minute.
  Future<void> loggedIn({required bool allAccounts}) async {
    for (final u in _everyone) {
      await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: _jar(u));
    }
    await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
    await settings.setValue(SettingsKeys.loginUsername, _alice.username!);
    await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 60);
    await settings.setValue(SettingsKeys.enableBackgroundMessageService, true);
    await settings.setValue(SettingsKeys.backgroundSyncAllAccounts, allAccounts);
  }

  Future<List<BackgroundSyncOutcome>> tick({
    DateTime? now,
    Duration gap = Duration.zero,
    Duration deadline = backgroundSyncDeadline,
    void Function(BackgroundSyncOutcome late)? onLate,
    List<BackgroundSyncOutcome>? announced,
  }) => backgroundSyncAccountsTick(
    storage: storage,
    repository: repository(),
    now: now ?? _nextTick(),
    gap: gap,
    deadline: deadline,
    onLate: onLate,
    onOutcome: announced?.add,
  );

  /// The one request shape of a first fetch with plugin 1.9.0: `notify`, then the conversation list and the broadcast
  /// page side by side, then `seen` for the unread notice and the private message prompt.
  void expectOneFetch(List<String> names, {required String reason}) {
    expect(names, hasLength(4), reason: reason);
    expect(names.first, 'notify', reason: reason);
    expect(names.sublist(1, 3), unorderedEquals(['pmlist', 'broadcast page']), reason: reason);
    expect(names.last, 'seen', reason: reason);
  }

  Future<List<int>> storedNotices(int uid) async =>
      (await storage.fetchNotificationSince(uid: uid, timestamp: 0).run()).noticeList.map((e) => e.nid).toList();

  Future<DateTime?> boundOf(int uid) async =>
      (await storage.fetchLastFetchNoticeTime(uid).run()).getOrElse((_) => null);

  Future<Set<int>> expiredUids() async => (await storage.fetchExpiredSessions()).map((e) => e.user.uid!).toSet();

  group('the setting', () {
    test('off by default; read fresh from the database by the service', () async {
      expect(SettingsKeys.backgroundSyncAllAccounts.defaultValue, isFalse);
      expect(settings.currentSettings.backgroundSyncAllAccounts, isFalse);
      expect((await readBackgroundSyncSettings(storage)).allAccounts, isFalse);

      // Written by the app's settings page, read by the service isolate through its own provider.
      await settings.setValue(SettingsKeys.backgroundSyncAllAccounts, true);
      final service = StorageProvider(db, {}, {});
      expect((await readBackgroundSyncSettings(service)).allAccounts, isTrue);
      final reread = SettingsRepository(storage);
      addTearDown(reread.dispose);
      await reread.init();
      expect(reread.currentSettings.backgroundSyncAllAccounts, isTrue);
    });

    test('named in all three languages', () async {
      final tw = await AppLocale.zhTw.build();
      final cn = await AppLocale.zhCn.build();
      final en = await AppLocale.en.build();
      expect(tw.settingsPage.behaviorSection.backgroundSyncAllAccounts.title, '背景通知：所有已登入帳號');
      expect(cn.settingsPage.behaviorSection.backgroundSyncAllAccounts.title, '后台通知：所有已登录账号');
      expect(en.settingsPage.behaviorSection.backgroundSyncAllAccounts.title, contains('all logged-in accounts'));
      expect(tw.settingsPage.behaviorSection.backgroundSyncAllAccounts.seenNote, contains('已讀'));
      expect(en.settingsPage.behaviorSection.backgroundSyncAllAccounts.seenNote, contains('read on the website'));
      for (final tr in [tw, cn, en]) {
        expect(tr.settingsPage.behaviorSection.backgroundSyncAllAccounts.detail, isNotEmpty);
        expect(tr.settingsPage.behaviorSection.backgroundSyncAllAccounts.seenNote, isNotEmpty);
        expect(tr.noticePage.syncAllPage.user.recent(unreadNotice: 1, unreadPm: 2, unreadBm: 3), contains('1/2/3'));
        expect(tr.localNotification.accountGone, isNotEmpty);
        expect(tr.localNotification.notice.titleOf(username: 'Bob'), contains('Bob'));
      }
    });
  });

  group('off: the account in use only, as before', () {
    test('one fetch of Alice, request for request; Bob and Carol are not touched', () async {
      await loggedIn(allAccounts: false);
      final announced = <BackgroundSyncOutcome>[];
      final at = _nextTick();
      final outcomes = await tick(now: at, announced: announced);

      expect(outcomes, hasLength(1));
      expect(announced, outcomes, reason: 'handed over as soon as it is done');
      final done = outcomes.single as BackgroundSyncDone;
      expect(done.uid, _alice.uid);
      expect(done.named, isFalse, reason: 'the notification looks as before');
      expect(done.result, isA<NotificationSyncResultSuccess>().having((e) => e.newNotice, 'newNotice', 1));
      expect(done.latest, isA<NotificationAutoSyncInfoNotice>());

      // The pinned request sequence of the account in use, and nothing else.
      expect(forum.tokens.toSet(), {'alice'});
      expectOneFetch(forum.of('alice'), reason: 'Alice');
      expect(forum.seenForms.map((e) => (e.token, e.form['formhash'])), [('alice', _formhash(1000))]);
      expect(forum.unexpected, isEmpty);

      expect(await storage.getInt(NotificationPollSlot.key(1000)), at.millisecondsSinceEpoch);
      for (final uid in [1001, 1002]) {
        expect(await storage.getInt(NotificationPollSlot.key(uid)), isNull, reason: 'no poll of $uid');
        expect(await storedNotices(uid), isEmpty);
        expect(await boundOf(uid), isNull);
      }
      expect(await storedNotices(1000), [_noticeId(1000)]);
    });

    test('the account switched during the fetch: stored, announced for nobody (as before)', () async {
      await loggedIn(allAccounts: false);
      forum.holds['alice'] = Completer<void>();
      final round = tick();
      await _until(() => forum.of('alice').isNotEmpty, reason: 'a request of alice');
      await settings.setValue(SettingsKeys.loginUid, _bob.uid!);
      forum.holds['alice']!.complete();
      final outcomes = await round;
      expect(
        outcomes.single,
        isA<BackgroundSyncStale>().having((e) => e.reason, 'reason', 'account switched during the fetch'),
      );
      expect(await storedNotices(1000), [_noticeId(1000)]);
      expect(forum.of('bob'), isEmpty);
    });
  });

  group('on: every account', () {
    test('polled one after another, each with its own cookie, slot, rows, bound and form hash', () async {
      await loggedIn(allAccounts: true);
      final at = _nextTick();
      final announced = <BackgroundSyncOutcome>[];
      final outcomes = await tick(now: at, announced: announced);

      expect(forum.unexpected, isEmpty);
      expect(announced, outcomes);
      expect(outcomes.map((e) => (e as BackgroundSyncDone).uid), [1000, 1001, 1002], reason: 'Alice first');
      for (final done in outcomes.cast<BackgroundSyncDone>()) {
        expect(done.named, isTrue);
        expect(done.username, _everyone.firstWhere((u) => u.uid == done.uid).username);
        expect(done.result, isA<NotificationSyncResultSuccess>().having((e) => e.newNotice, 'newNotice', 1));
        expect(done.latest, isA<NotificationAutoSyncInfoNotice>());
      }
      // One account after the other, every request of an account with that account's cookie.
      expect(forum.tokens, [...List.filled(4, 'alice'), ...List.filled(4, 'bob'), ...List.filled(4, 'carol')]);
      for (final u in _everyone) {
        expectOneFetch(forum.of(_token(u)), reason: u.username!);
      }
      // `seen` marks each account's notices read with that account's own form hash and cookie.
      expect(forum.seenForms.map((e) => (e.token, e.form['formhash'], e.form['notice'])), [
        ('alice', _formhash(1000), '$_now'),
        ('bob', _formhash(1001), '$_now'),
        ('carol', _formhash(1002), '$_now'),
      ]);
      for (final u in _everyone) {
        final uid = u.uid!;
        expect(await storedNotices(uid), [_noticeId(uid)], reason: 'rows of $uid are its own');
        expect(await storage.getInt(NotificationPollSlot.key(uid)), at.millisecondsSinceEpoch, reason: 'slot of $uid');
        expect(await boundOf(uid), isNotNull, reason: 'bound of $uid');
      }
      expect(settings.currentSettings.loginUid, 1000, reason: 'nothing switched accounts');
    });

    test("what an account deleted or blocked is its own: keyed by uid, never another account's", () async {
      await loggedIn(allAccounts: true);
      // The same peer wrote to Alice and Bob. Bob deleted the conversation from the app's list (its last message
      // remembered, here one newer than anything fetched); Carol blocked the peer, the author of her notice.
      forum.pms
        ..['alice'] = [_conversationOf(1000)]
        ..['bob'] = [_conversationOf(1001)];
      await storage.saveString('deletedPersonalMessages.1001', '{"3001": {"t": ${_now * 2}, "d": "x"}}');
      final blocks = UserBlockRepository(storage);
      addTearDown(blocks.dispose);
      await blocks.block(ownerUid: 1002, uid: 3001, username: 'Peer');

      final outcomes = (await tick()).cast<BackgroundSyncDone>();
      expect(outcomes.map((e) => e.uid), [1000, 1001, 1002]);
      // Alice: the message wins the announcement.
      expect(outcomes[0].latest, isA<NotificationAutoSyncInfoPm>().having((e) => e.msg, 'msg', 'hello 1000'));
      // Bob: the deleted conversation is neither stored nor news; his notice is.
      expect(outcomes[1].latest, isA<NotificationAutoSyncInfoNotice>());
      // Carol: the notice of the peer she blocked is stored but not announced.
      expect(outcomes[2].latest, isNull);
      expect(outcomes[2].result, isA<NotificationSyncResultSuccess>().having((e) => e.newNotice, 'no news', 0));

      PersonalMessageEntity? conversation(NotificationGroup g) => g.personalMessageList.firstOrNull;
      final alice = await storage.fetchNotificationSince(uid: 1000, timestamp: 0).run();
      final bob = await storage.fetchNotificationSince(uid: 1001, timestamp: 0).run();
      expect(conversation(alice)?.data, 'hello 1000');
      expect(conversation(bob), isNull, reason: "Bob's deletion is Bob's only");
      expect(await storage.getString('deletedPersonalMessages.1001'), isNotNull, reason: 'kept: the copy is older');
      expect(await storage.getString('deletedPersonalMessages.1000'), isNull);
      expect(await storedNotices(1002), [_noticeId(1002)]);
    });

    test('the notification payload carries the uid; title and id name the account', () async {
      await loggedIn(allAccounts: true);
      final tr = await AppLocale.zhTw.build();
      final outcomes = await tick();
      final ids = <int>[];
      for (final done in outcomes.cast<BackgroundSyncDone>()) {
        final content = localNotificationContentOf(
          tr,
          done.latest!,
          account: LocalNoticeAccount(uid: done.uid, username: done.username, named: done.named),
        );
        ids.add(content.id);
        // The account, then who did what (a single new notice of a user: "Peer 回覆了你的帖子").
        expect(content.title, startsWith('[${done.username}] '));
        expect(content.payload, startsWith('openNotification:${done.uid}'));
        expect(LocalNoticeKeys.parseOpenNotification(content.payload), (uid: done.uid));
        expect(isLocalNoticeId(content.id), isTrue);
      }
      expect(ids.toSet(), hasLength(3), reason: 'one notification per account');
      expect(ids, isNot(contains(localNoticeId)));
      expect(ids, isNot(contains(backgroundSyncNotificationId)), reason: 'never the persistent one');

      // Off: the one notification exactly as before, the payload of the account in use included.
      const info = NotificationAutoSyncInfoNotice(
        msg: 'm',
        notice: 1,
        personalMessage: 0,
        broadcastMessage: 0,
        timestamp: 0,
      );
      final single = localNotificationContentOf(tr, info, account: const LocalNoticeAccount(uid: 1000));
      expect((single.id, single.title, single.payload), (localNoticeId, '新訊息', LocalNoticeKeys.openNotification));
      // The test notification of the settings page names no account.
      final test = localNotificationContentOf(tr, info);
      expect((test.id, test.payload), (localNoticeId, LocalNoticeKeys.openNotification));
    });

    test('an expired account is recorded and skipped; the others run, the account in use stays', () async {
      await loggedIn(allAccounts: true);
      forum.all['bob'] = _loginAnswer;
      final outcomes = await tick();

      expect(outcomes.map((e) => (e as BackgroundSyncDone).uid), [1000, 1001, 1002]);
      final results = outcomes.cast<BackgroundSyncDone>().map((e) => e.result).toList();
      expect(results[0], isA<NotificationSyncResultSuccess>());
      expect(results[1], isA<NotificationSyncResultNotAuthorized>());
      expect(results[2], isA<NotificationSyncResultSuccess>(), reason: 'Carol after the expired Bob');
      expect(outcomes.cast<BackgroundSyncDone>()[1].latest, isNull, reason: 'nothing announced for Bob');
      expect(forum.of('bob'), ['notify'], reason: 'one question, answered "login"');
      expect(await expiredUids(), {1001}, reason: 'recorded for Bob only, as for the account in use');
      expect(
        await storage.getInt(NotificationPollSlot.key(1001)),
        0,
        reason: 'a poll that brought nothing is given back',
      );
      // Alice is still the account in use, her login and rows untouched.
      expect(settings.currentSettings.loginUid, 1000);
      expect(await storage.hasCookieOfUid(1000), isTrue);
      expect(await storage.hasCookieOfUid(1001), isTrue, reason: 'Bob stays saved, to log in again');

      // The next tick does not ask the forum about Bob again until he logs in again.
      forum.requests.clear();
      final next = await tick();
      expect(next.map((e) => (e as BackgroundSyncDone).uid), [1000, 1002]);
      expect(forum.of('bob'), isEmpty);
      await storage.clearSessionExpired(1001);
      forum.all.remove('bob');
      final again = await tick();
      expect(again.map((e) => (e as BackgroundSyncDone).uid), [1000, 1001, 1002]);
    });

    test('the account in use expired: recorded like before, polled again, the others still run', () async {
      await loggedIn(allAccounts: true);
      forum.all['alice'] = _loginAnswer;
      final outcomes = await tick();
      expect(
        outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.result.runtimeType)),
        [
          (1000, NotificationSyncResultNotAuthorized),
          (1001, NotificationSyncResultSuccess),
          (1002, NotificationSyncResultSuccess),
        ],
      );
      expect(await expiredUids(), {1000});
      expect(settings.currentSettings.loginUid, 1000, reason: 'the service never logs out');
      forum.requests.clear();
      final next = await tick();
      expect(next.map((e) => (e as BackgroundSyncDone).uid), [1000, 1001, 1002], reason: 'as the tick did before');
    });

    test('a server error or a 429 of one account is its own outcome', () async {
      await loggedIn(allAccounts: true);
      forum.all['alice'] = _busy;
      forum.all['bob'] = _serverError;
      final outcomes = await tick();
      expect(
        outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.result.runtimeType)),
        [
          (1000, NotificationSyncResultRateLimited),
          (1001, NotificationSyncResultFailed),
          (1002, NotificationSyncResultSuccess),
        ],
      );
      expect(await expiredUids(), isEmpty, reason: 'a failure is no expiry');
      expect(await storage.getInt(NotificationPollSlot.key(1000)), 0);
      expect(await storage.getInt(NotificationPollSlot.key(1001)), 0);
      expect(await storedNotices(1002), [_noticeId(1002)]);
    });

    test('a pause between two accounts that reached the forum', () async {
      await loggedIn(allAccounts: true);
      const gap = Duration(milliseconds: 300);
      final outcomes = await tick(gap: gap);
      expect(outcomes, hasLength(3));
      DateTime first(String token) => forum.requests.firstWhere((r) => r.token == token).at;
      DateTime last(String token) => forum.requests.lastWhere((r) => r.token == token).at;
      expect(first('bob').difference(last('alice')), greaterThanOrEqualTo(gap));
      expect(first('carol').difference(last('bob')), greaterThanOrEqualTo(gap));
    });

    test('each account takes its own poll: one polled moments ago is skipped, the others run', () async {
      await loggedIn(allAccounts: true);
      final at = _nextTick();
      // Bob was polled ten seconds ago (half an interval is thirty).
      await storage.saveInt(
        NotificationPollSlot.key(1001),
        at.subtract(const Duration(seconds: 10)).millisecondsSinceEpoch,
      );
      final outcomes = await tick(now: at);
      expect(outcomes[0], isA<BackgroundSyncDone>().having((e) => e.uid, 'uid', 1000));
      expect(
        outcomes[1],
        isA<BackgroundSyncSkipped>()
            .having((e) => e.uid, 'uid', 1001)
            .having((e) => e.reason, 'reason', 'polled by the app moments ago'),
      );
      expect(outcomes[2], isA<BackgroundSyncDone>().having((e) => e.uid, 'uid', 1002));
      expect(forum.of('bob'), isEmpty);

      // A second tick within half an interval polls nobody.
      forum.requests.clear();
      final again = await tick(now: at.add(const Duration(seconds: 20)));
      expect(again.map((e) => (e as BackgroundSyncSkipped).uid), [1000, 1001, 1002]);
      expect(forum.requests, isEmpty, reason: 'the plugin would answer 429 to a second call within its interval');
    });

    test('an account switched during its fetch is announced all the same: the notification opens it', () async {
      await loggedIn(allAccounts: true);
      forum.holds['alice'] = Completer<void>();
      final round = tick();
      await _until(() => forum.of('alice').isNotEmpty, reason: 'a request of alice');
      await settings.setValue(SettingsKeys.loginUid, _carol.uid!);
      forum.holds['alice']!.complete();
      final outcomes = await round;
      expect(outcomes.first, isA<BackgroundSyncDone>().having((e) => (e.uid, e.named), 'Alice, named', (1000, true)));
      expect(outcomes, hasLength(3));
    });

    test('switched off, or back to the account in use only, during the round: it ends there', () async {
      await loggedIn(allAccounts: true);
      forum.holds['bob'] = Completer<void>();
      var round = tick();
      await _until(() => forum.of('bob').isNotEmpty, reason: 'a request of bob');
      await settings.setValue(SettingsKeys.backgroundSyncAllAccounts, false);
      forum.holds['bob']!.complete();
      var outcomes = await round;
      expect(outcomes[0], isA<BackgroundSyncDone>());
      expect(
        outcomes[1],
        isA<BackgroundSyncStale>().having((e) => e.reason, 'reason', 'all accounts switched off during the fetch'),
      );
      expect(outcomes[2], isA<BackgroundSyncSkipped>());
      expect(outcomes, hasLength(3));
      expect(forum.of('carol'), isEmpty);
      expect(await storedNotices(1001), [_noticeId(1001)], reason: 'what came back is stored all the same');

      await settings.setValue(SettingsKeys.backgroundSyncAllAccounts, true);
      forum
        ..requests.clear()
        ..holds['bob'] = Completer<void>();
      round = tick();
      await _until(() => forum.of('bob').isNotEmpty, reason: 'a request of bob');
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, false);
      forum.holds['bob']!.complete();
      outcomes = await round;
      expect(outcomes.last, isA<BackgroundSyncDisabled>(), reason: 'the service stops');
      expect(outcomes, hasLength(2));
      expect(forum.of('carol'), isEmpty);
    });

    test('a fetch given up ends the round; what it brings later is announced for its account', () async {
      await loggedIn(allAccounts: true);
      forum.holds['bob'] = Completer<void>();
      final late = Completer<BackgroundSyncOutcome>();
      final outcomes = await tick(deadline: const Duration(milliseconds: 300), onLate: late.complete);
      expect(outcomes[0], isA<BackgroundSyncDone>().having((e) => e.uid, 'uid', 1000));
      expect(outcomes[1], isA<BackgroundSyncSkipped>().having((e) => e.uid, 'uid', 1001));
      expect(
        outcomes[2],
        isA<BackgroundSyncSkipped>()
            .having((e) => e.uid, 'uid', 1002)
            .having((e) => e.reason, 'reason', 'a fetch before it was given up'),
      );
      expect(forum.of('carol'), isEmpty, reason: 'the network the system holds would hold Carol as long');
      expect(await storage.getInt(NotificationPollSlot.key(1002)), isNull, reason: 'the next tick polls Carol');

      forum.holds['bob']!.complete();
      expect(
        await late.future,
        isA<BackgroundSyncDone>().having((e) => (e.uid, e.named, e.latest != null), 'Bob, announced', (
          1001,
          true,
          true,
        )),
      );
    });

    test('nobody logged in, or auto sync off: nothing polled, as before', () async {
      await loggedIn(allAccounts: true);
      await settings.setValue(SettingsKeys.loginUid, 0);
      expect(
        (await tick()).single,
        isA<BackgroundSyncSkipped>().having((e) => e.reason, 'reason', 'not logged in'),
      );
      await settings.setValue(SettingsKeys.loginUid, 1000);
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 0);
      expect(
        (await tick()).single,
        isA<BackgroundSyncSkipped>().having((e) => e.reason, 'reason', 'auto sync is off'),
      );
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, false);
      expect((await tick()).single, isA<BackgroundSyncDisabled>());
      expect(forum.requests, isEmpty);
    });
  });

  test('the polls of an account are forgotten with it', () async {
    await loggedIn(allAccounts: true);
    Future<List<int?>> polls(int uid) async => [
      await storage.getInt(NotificationPollSlot.key(uid)),
      await storage.getInt(NotificationPollSlot.manualKey(uid)),
    ];
    for (final uid in [1000, 1001, 1002]) {
      await storage.saveInt(NotificationPollSlot.key(uid), 1);
      await storage.saveInt(NotificationPollSlot.manualKey(uid), 1);
    }
    expect(await storage.deleteCookieByUid(1001), isTrue);
    expect(await polls(1001), [null, null]);
    expect(await storage.deleteCookiesByUids([1002]), 1);
    expect(await polls(1002), [null, null]);
    expect(await storage.deleteUserLoginInfo(1000), 1);
    expect(await polls(1000), [null, null]);
    // Removed by name only.
    await storage.saveCookie(username: 'Bob', uid: 1001, cookie: _jar(_bob));
    await storage.saveInt(NotificationPollSlot.key(1001), 1);
    await storage.saveInt(NotificationPollSlot.manualKey(1001), 1);
    // Two rows of the same name (the name is no key): both go, nothing throws.
    await storage.saveCookie(username: 'Bob', uid: 1003, cookie: _jar(_bob));
    await storage.saveInt(NotificationPollSlot.key(1003), 1);
    expect(await storage.deleteCookieByUserInfo(const UserLoginInfo(username: 'Bob', uid: null)), isTrue);
    expect(await polls(1001), [null, null]);
    expect(await polls(1003), [null, null]);
    expect(await storage.hasCookieOfUid(1001) || await storage.hasCookieOfUid(1003), isFalse);
  });

  group('in the app: the other accounts after the account in use (Android, Windows)', () {
    // As the app builds it: each account's cookie read from the database.
    Future<List<BackgroundSyncOutcome>> others({DateTime? now, Duration gap = Duration.zero}) =>
        autoSyncOtherAccountsTick(
          storage: storage,
          repository: repository(cookiesFromDatabase: true),
          now: now ?? _nextTick(),
          gap: gap,
        );

    test('off: nothing; on: every other account, without the background service switch', () async {
      await loggedIn(allAccounts: false);
      expect(await others(), isEmpty);
      expect(forum.requests, isEmpty);

      await settings.setValue(SettingsKeys.backgroundSyncAllAccounts, true);
      // Windows has no background service: its switch is off and plays no part.
      await settings.setValue(SettingsKeys.enableBackgroundMessageService, false);
      final at = _nextTick();
      final outcomes = await others(now: at);
      expect(forum.unexpected, isEmpty);
      expect(
        outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.username, e.named)),
        [
          (1001, 'Bob', true),
          (1002, 'Carol', true),
        ],
        reason: 'the account in use is polled by the in-app sync itself',
      );
      expect(forum.tokens, [...List.filled(4, 'bob'), ...List.filled(4, 'carol')]);
      expect(forum.seenForms.map((e) => (e.token, e.form['formhash'])), [
        ('bob', _formhash(1001)),
        ('carol', _formhash(1002)),
      ]);
      expect(await storage.getInt(NotificationPollSlot.key(1000)), isNull);
      for (final uid in [1001, 1002]) {
        expect(await storage.getInt(NotificationPollSlot.key(uid)), at.millisecondsSinceEpoch);
        expect(await storedNotices(uid), [_noticeId(uid)]);
      }
    });

    test('the slots are shared with the background service: whoever polls first, the other skips', () async {
      await loggedIn(allAccounts: true);
      final at = _nextTick();
      // The background service polled everyone moments ago.
      expect(await tick(now: at), hasLength(3));
      forum.requests.clear();
      final outcomes = await others(now: at.add(const Duration(seconds: 10)));
      expect(
        outcomes.map((e) => (e as BackgroundSyncSkipped).uid),
        [1001, 1002],
      );
      expect(forum.requests, isEmpty, reason: 'never asked twice within the interval');
      // And the other way round.
      final later = at.add(const Duration(minutes: 1));
      expect(await others(now: later), hasLength(2));
      forum.requests.clear();
      final service = await tick(now: later.add(const Duration(seconds: 5)));
      expect(service[0], isA<BackgroundSyncDone>().having((e) => e.uid, 'uid', 1000));
      expect(service.skip(1).map((e) => (e as BackgroundSyncSkipped).uid), [1001, 1002]);
      expect(forum.tokens.toSet(), {'alice'});
    });

    test('an expired, failing or rate-limited account stays with itself; expired ones wait for a login', () async {
      await loggedIn(allAccounts: true);
      forum.all['bob'] = _loginAnswer;
      var outcomes = await others();
      expect(outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.result.runtimeType)), [
        (1001, NotificationSyncResultNotAuthorized),
        (1002, NotificationSyncResultSuccess),
      ]);
      expect(await expiredUids(), {1001});
      expect(settings.currentSettings.loginUid, 1000, reason: 'nobody logged out');
      forum
        ..requests.clear()
        ..all['carol'] = _busy;
      outcomes = await others();
      expect(outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.result.runtimeType)), [
        (1002, NotificationSyncResultRateLimited),
      ]);
      expect(forum.of('bob'), isEmpty);
    });

    test('a pause before each account, the first one too: the account in use was just asked', () async {
      await loggedIn(allAccounts: true);
      const gap = Duration(milliseconds: 300);
      final started = DateTime.now();
      expect(await others(gap: gap), hasLength(2));
      DateTime first(String token) => forum.requests.firstWhere((r) => r.token == token).at;
      DateTime last(String token) => forum.requests.lastWhere((r) => r.token == token).at;
      expect(first('bob').difference(started), greaterThanOrEqualTo(gap));
      expect(first('carol').difference(last('bob')), greaterThanOrEqualTo(gap));
    });

    test('switched back to the account in use only during the round: it ends there', () async {
      await loggedIn(allAccounts: true);
      forum.holds['bob'] = Completer<void>();
      final round = others();
      await _until(() => forum.of('bob').isNotEmpty, reason: 'a request of bob');
      await settings.setValue(SettingsKeys.backgroundSyncAllAccounts, false);
      forum.holds['bob']!.complete();
      final outcomes = await round;
      expect(outcomes, hasLength(2));
      expect(outcomes[0], isA<BackgroundSyncStale>());
      expect(outcomes[1], isA<BackgroundSyncSkipped>());
      expect(forum.of('carol'), isEmpty);
    });

    test("each account's cookie is read from the database, its cache entry brought in line", () async {
      await loggedIn(allAccounts: true);
      // Carol logged in elsewhere on the same database (the service isolate renews cookies there): this provider's
      // cache never saw her row.
      await StorageProvider(db, {}, {}).saveCookie(username: 'Carol', uid: 1002, cookie: _jar(_carol));
      await storage.deleteCookieByUid(1002);
      await StorageProvider(db, {}, {}).saveCookie(username: 'Carol', uid: 1002, cookie: _jar(_carol));
      expect(storage.getCookieByUidSync(1002), isNull);
      final outcomes = await others();
      expect(outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.result.runtimeType)), [
        (1001, NotificationSyncResultSuccess),
        (1002, NotificationSyncResultSuccess),
      ]);
      expect(forum.of('carol'), hasLength(4));
      expect(
        storage.getCookieByUidSync(1002),
        isNotNull,
        reason: "Carol's entry brought in line with the row read, for the switch and the removal check",
      );
    });

    test('an account marked expired rests a day, then is tried once more: alive, its mark goes', () async {
      await loggedIn(allAccounts: true);
      await storage.markSessionExpired(1001, at: DateTime.now().subtract(const Duration(hours: 1)));
      await storage.markSessionExpired(1002, at: DateTime.now().subtract(const Duration(days: 2)));
      forum.all['carol'] = _loginAnswer;
      var outcomes = await others();
      expect(
        outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.result.runtimeType)),
        [
          (1002, NotificationSyncResultNotAuthorized),
        ],
        reason: 'Bob rests, Carol is tried again and is still expired',
      );
      expect(await expiredUids(), {1001, 1002});
      outcomes = await others();
      expect(outcomes, isEmpty, reason: 'Carol marked again: she rests another day');

      // A day later Bob's row answers, but as another account (it holds that account's session): the mark stays.
      await storage.markSessionExpired(1001, at: DateTime.now().subtract(const Duration(days: 1, minutes: 1)));
      forum.servedAs['bob'] = 1002;
      outcomes = await others();
      expect(outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.result.runtimeType)), [
        (1001, NotificationSyncResultSuccess),
      ]);
      expect(await expiredUids(), {1001, 1002}, reason: 'answered as somebody else: not proof of his login');

      // Another day later the mark of Bob was wrong: he answers as himself, and his mark goes.
      await storage.markSessionExpired(1001, at: DateTime.now().subtract(const Duration(days: 1, minutes: 1)));
      forum.servedAs.remove('bob');
      outcomes = await others();
      expect(outcomes.cast<BackgroundSyncDone>().map((e) => (e.uid, e.result.runtimeType)), [
        (1001, NotificationSyncResultSuccess),
      ]);
      expect(await expiredUids(), {1002});
    });

    test('the app wiring: off, the auto sync asks for nobody else; on, for every other account', () async {
      await loggedIn(allAccounts: false);
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
          cookie: CookieProvider(_alice, _jar(_alice)),
        ),
      );
      final notifications = NotificationRepository(storageProvider: storage);
      addTearDown(notifications.dispose);
      final sync = OtherAccountsAutoSync.forApp(
        storage: storage,
        notificationRepository: notifications,
        announce: (_) async {},
        clientFactory: clientOf,
      );
      final auto = AutoNotificationCubit(
        authenticationRepository: AuthenticationRepository(user: _alice),
        notificationRepository: notifications,
        storageProvider: storage,
        afterPoll: sync.afterPoll,
      );
      addTearDown(() async {
        auto.stop();
        await auto.close();
      });
      auto.start(const Duration(seconds: 1));
      await _until(() => forum.of('alice').contains('seen'), reason: "the poll of Alice's notices");
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await _until(() => !sync.isRunning, reason: 'nothing to run');
      expect(forum.tokens.toSet(), {'alice'}, reason: 'off: zero requests for the other accounts');
      auto.stop();

      await settings.setValue(SettingsKeys.backgroundSyncAllAccounts, true);
      expect(await sync.poll(), hasLength(2));
      expect(forum.tokens.toSet(), {'alice', 'bob', 'carol'});
      await sync.dispose();
    });

    test('disposed while a round runs: nothing more is announced, no round starts', () async {
      await loggedIn(allAccounts: true);
      final announced = <int>[];
      final sync = OtherAccountsAutoSync(
        storage: storage,
        repository: repository(cookiesFromDatabase: true),
        announce: (done) async => announced.add(done.uid),
        gap: Duration.zero,
      );
      forum.holds['bob'] = Completer<void>();
      unawaited(sync.poll());
      await _until(() => forum.of('bob').isNotEmpty, reason: "Bob's request");
      final disposing = sync.dispose();
      forum.holds['bob']!.complete();
      await disposing;
      expect(announced, isEmpty);
      expect(await sync.poll(), isEmpty);
    });

    test('OtherAccountsAutoSync: one round at a time, each account announced with its name and reported', () async {
      await loggedIn(allAccounts: true);
      final announced = <BackgroundSyncDone>[];
      final sync = OtherAccountsAutoSync(
        storage: storage,
        repository: repository(),
        announce: (done) async => announced.add(done),
        gap: Duration.zero,
      );
      final events = <Map<String, dynamic>?>[];
      final sub = sync.synced.listen(events.add);
      addTearDown(sub.cancel);
      forum.holds['bob'] = Completer<void>();
      final round = sync.poll(now: _nextTick());
      await _until(() => forum.of('bob').isNotEmpty, reason: 'a request of bob');
      expect(sync.isRunning, isTrue);
      expect(await sync.poll(now: _nextTick()), isEmpty, reason: 'skipped while the previous round runs');
      forum.holds['bob']!.complete();
      expect(await round, hasLength(2));
      expect(sync.isRunning, isFalse);
      await pumpEventQueue();

      final tr = await AppLocale.zhTw.build();
      expect(announced.map((e) => e.uid), [1001, 1002]);
      for (final done in announced) {
        final content = localNotificationContentOf(
          tr,
          done.latest!,
          account: LocalNoticeAccount(uid: done.uid, username: done.username, named: done.named),
        );
        expect(content.title, startsWith('[${done.username}] '), reason: 'a Windows toast names the account too');
        expect(LocalNoticeKeys.parseOpenNotification(content.payload), (uid: done.uid));
      }
      expect(events, [
        {'uid': 1001, 'notice': 1, 'personalMessage': 0, 'broadcastMessage': 0},
        {'uid': 1002, 'notice': 1, 'personalMessage': 0, 'broadcastMessage': 0},
      ], reason: 'the shape of the service, for the bridge that reloads the account switched to');
      await sync.dispose();
    });

    test('the auto sync asks for the other accounts after its own poll, and never waits for them', () async {
      await loggedIn(allAccounts: true);
      // The in-app fetch of the account in use goes through the global client, with Alice's cookie.
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
          cookie: CookieProvider(_alice, _jar(_alice)),
        ),
      );
      final notifications = NotificationRepository(storageProvider: storage);
      addTearDown(notifications.dispose);
      final sync = OtherAccountsAutoSync(
        storage: storage,
        repository: repository(),
        announce: (_) async {},
        gap: Duration.zero,
      );
      late final AutoNotificationCubit auto;
      final calls = <String>[];
      auto = AutoNotificationCubit(
        authenticationRepository: AuthenticationRepository(user: _alice),
        notificationRepository: notifications,
        storageProvider: storage,
        afterPoll: () {
          calls.add('after the poll, pending=${auto.isPending}');
          unawaited(sync.poll());
        },
      );
      addTearDown(() async {
        auto.stop();
        await auto.close();
      });
      forum
        ..holds['alice'] = Completer<void>()
        ..holds['bob'] = Completer<void>();
      auto.start(const Duration(seconds: 1));
      await _until(() => forum.of('alice').isNotEmpty, reason: 'a request of alice');
      expect(auto.isPending, isTrue);
      expect(calls, isEmpty, reason: 'the account in use first');
      forum.holds['alice']!.complete();
      await _until(() => forum.of('bob').isNotEmpty, reason: 'a request of bob');
      expect(calls, ['after the poll, pending=false']);
      expect(forum.tokens.first, 'alice');
      // An account switch pauses the auto sync: with the other accounts still being polled it gets it at once.
      expect(auto.pause('switch user'), isFalse, reason: 'not pending');
      auto.stop();
      forum.holds['bob']!.complete();
      await _until(() => !sync.isRunning, reason: 'the round of the other accounts');
      expect(forum.tokens.toSet(), {'alice', 'bob', 'carol'});
      expect(await storedNotices(1001), [_noticeId(1001)]);
      await sync.dispose();
    });
  });

  group('the sync of all accounts the user asks for', () {
    test("takes each account's poll: one polled moments ago shows what is stored, nobody is asked twice", () async {
      await loggedIn(allAccounts: true);
      final at = _nextTick();
      // The background service polled Bob ten seconds ago and stored his notice.
      final service = await tick(now: at.subtract(const Duration(seconds: 10)));
      expect(service, hasLength(3));
      await storage.saveInt(NotificationPollSlot.key(1000), 0);
      await storage.saveInt(NotificationPollSlot.key(1002), 0);
      forum.requests.clear();

      final run = await repository()
          .syncAll(accounts: _everyone, pollInterval: const Duration(seconds: 60), now: at)
          .run();
      final results = run.getOrElse((e) => fail('$e')).finished;
      expect(results.map((e) => e.$1.uid), [1000, 1001, 1002]);
      expect(
        results[1].$2,
        isA<NotificationSyncResultSuccess>().having((e) => e.recent, 'recent', isTrue).having(
          (e) => (e.newNotice, e.unreadNotice),
          'nothing new, the stored unread notice',
          (0, 1),
        ),
      );
      for (final i in [0, 2]) {
        expect(results[i].$2, isA<NotificationSyncResultSuccess>().having((e) => e.recent, 'recent', isFalse));
      }
      expect(forum.of('bob'), isEmpty, reason: 'polled moments ago: the plugin would answer 429');
      expect(forum.tokens.toSet(), {'alice', 'carol'});
      expect(await storage.getInt(NotificationPollSlot.key(1000)), at.millisecondsSinceEpoch, reason: 'recorded');
      expect(await storage.getInt(NotificationPollSlot.key(1002)), at.millisecondsSinceEpoch);

      // The auto sync right after does not ask anybody again either.
      forum.requests.clear();
      final next = await tick(now: at.add(const Duration(seconds: 5)));
      expect(next.map((e) => (e as BackgroundSyncSkipped).uid), [1000, 1001, 1002]);
      expect(forum.requests, isEmpty);
    });

    test('a poll that brought nothing is given back; auto sync set to never: every account is fetched', () async {
      await loggedIn(allAccounts: true);
      forum.all['bob'] = _serverError;
      final at = _nextTick();
      await repository().syncAll(accounts: _everyone, pollInterval: const Duration(seconds: 60), now: at).run();
      expect(await storage.getInt(NotificationPollSlot.key(1001)), 0, reason: 'the auto sync may take it after all');

      forum
        ..requests.clear()
        ..all.remove('bob');
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 0);
      final cubit = NotificationSyncAllCubit(
        repository: repository(),
        storageProvider: storage,
        authenticationRepository: AuthenticationRepository(user: _alice),
        infoRepository: NotificationInfoRepository(),
      );
      await cubit.start();
      expect(forum.tokens.toSet(), {'alice', 'bob', 'carol'}, reason: 'nobody else polls: nothing to share');
      await cubit.close();
    });

    test('the cubit asks with the auto sync interval; an earlier sync of all accounts is never reused', () async {
      await loggedIn(allAccounts: false);
      final infos = NotificationInfoRepository();
      addTearDown(infos.dispose);
      final cubit = NotificationSyncAllCubit(
        repository: repository(),
        storageProvider: storage,
        authenticationRepository: AuthenticationRepository(user: _alice),
        infoRepository: infos,
      );
      addTearDown(cubit.close);
      await cubit.start();
      expect(forum.tokens.toSet(), {'alice', 'bob', 'carol'});
      for (final uid in [1000, 1001, 1002]) {
        expect(await storage.getInt(NotificationPollSlot.key(uid)), isNot(0), reason: 'recorded for the auto sync');
      }
      // Asked again by the user right after: the forum is asked again, the earlier run is not reused.
      forum.requests.clear();
      await cubit.start();
      final finished = cubit.state as NotificationSyncAllStateFinished;
      expect(finished.results.map((e) => (e.$2 as NotificationSyncResultSuccess).recent), [false, false, false]);
      expect(forum.tokens.toSet(), {'alice', 'bob', 'carol'});
      // The auto sync still skips them right after.
      forum.requests.clear();
      expect(
        (await tick(now: DateTime.now().add(const Duration(seconds: 1)))).map((e) => e.runtimeType).toSet(),
        {BackgroundSyncSkipped},
        reason: 'off: the tick of the account in use only, skipped',
      );
      expect(forum.requests, isEmpty, reason: 'polled moments ago by the sync of all accounts');
    });

    test('an automatic poll is reused for half an interval, at most 30 seconds', () async {
      await loggedIn(allAccounts: true);
      final at = _nextTick();
      // Auto sync every ten minutes: half an interval is five minutes, reused for thirty seconds only.
      await settings.setValue(SettingsKeys.autoSyncNoticeSeconds, 600);
      await storage.saveInt(
        NotificationPollSlot.key(1000),
        at.subtract(const Duration(seconds: 20)).millisecondsSinceEpoch,
      );
      await storage.saveInt(
        NotificationPollSlot.key(1001),
        at.subtract(const Duration(seconds: 40)).millisecondsSinceEpoch,
      );
      final results =
          (await repository().syncAll(accounts: _everyone, pollInterval: const Duration(minutes: 10), now: at).run())
              .getOrElse((e) => fail('$e'))
              .finished;
      expect(results.map((e) => (e.$2 as NotificationSyncResultSuccess).recent), [true, false, false]);
      expect(forum.tokens.toSet(), {'bob', 'carol'}, reason: 'forty seconds is too old to show as fresh');
      // A shorter interval: half of it is the limit.
      expect(
        await NotificationPollSlot.takeForManualSync(
          storage,
          1002,
          const Duration(seconds: 20),
          now: at.add(const Duration(seconds: 5)),
        ),
        isNotNull,
        reason: 'a poll of the sync of all accounts itself is never reused',
      );
      await storage.saveInt(NotificationPollSlot.key(1002), at.millisecondsSinceEpoch);
      expect(
        await NotificationPollSlot.takeForManualSync(
          storage,
          1002,
          const Duration(seconds: 20),
          now: at.add(const Duration(seconds: 5)),
        ),
        isNull,
        reason: 'one of the auto sync, five seconds old, is',
      );
    });

    testWidgets('the progress page says the stored result is shown', (tester) async {
      late String text;
      await tester.pumpWidget(
        TranslationProvider(
          child: Builder(
            builder: (context) {
              text = NotificationSyncAllPage.message(
                context,
                const NotificationSyncResultSuccess(
                  newNotice: 0,
                  newPersonalMessage: 0,
                  newBroadcastMessage: 0,
                  unreadNotice: 1,
                  unreadPersonalMessage: 0,
                  unreadBroadcastMessage: 2,
                  recent: true,
                ),
              );
              return const SizedBox();
            },
          ),
        ),
      );
      expect(text, t.noticePage.syncAllPage.user.recent(unreadNotice: 1, unreadPm: 0, unreadBm: 2));
      expect(text, 'Synced moments ago, the stored notices are shown; unread 1/0/2');
    });
  });

  group('a page of the stored account arriving after a switch (review probe)', () {
    late AuthenticationRepository auth;
    late CookieProvider global;

    setUp(() async {
      for (final u in [_alice, _bob]) {
        await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: _jar(u));
      }
      await settings.setValue(SettingsKeys.loginUid, 1000);
      await settings.setValue(SettingsKeys.loginUsername, 'Alice');
      global = CookieProvider.buildEmpty();
      await global.loadCookieFromStorage(_alice);
      getIt.registerSingleton<CookieProvider>(global);
      // Cold start: the stored session is not verified yet.
      auth = AuthenticationRepository(
        clientFactory: (cookie) => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _SwitchForum(),
          cookie: cookie,
        ),
      );
      // The tap on Bob's notification switches first...
      expect((await auth.switchUser(_bob).run()).isRight(), isTrue);
    });

    tearDown(() => auth.dispose());

    String tokenIn(int uid) => RegExp('auth=([a-z]+)').firstMatch('${storage.getCookieByUidSync(uid)}')?[1] ?? 'none';

    void expectBobUnmixed() {
      expect(auth.currentUser?.uid, 1001);
      expect(settings.currentSettings.loginUid, 1001);
      expect(global.userLoginInfo.uid, 1001);
      expect(tokenIn(1000), 'alice', reason: "Alice's stored row keeps her session");
      expect(tokenIn(1001), 'bob');
    }

    test('...then the structured homepage served to Alice records nothing', () async {
      final login = await auth.loginWithServedUser(_alice, guest: false, fetchedAs: 1000).run();
      expect(login.getLeft().toNullable(), isA<IdentityChangedException>());
      expectBobUnmixed();
    });

    test('...then the web homepage served to Alice records nothing', () async {
      final login = await auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice)), fetchedAs: 1000).run();
      expect(login.getLeft().toNullable(), isA<IdentityChangedException>());
      expectBobUnmixed();
    });

    test('...then a guest page asked with her cookie marks nobody expired', () async {
      final login = await auth.loginWithDocument(parseHtmlDocument(_guestPage), fetchedAs: 1000).run();
      expect(login.getLeft().toNullable(), isA<IdentityChangedException>());
      expect(await expiredUids(), isEmpty);
      expectBobUnmixed();
    });

    test('the page of the account in use is recorded as before', () async {
      expect((await auth.loginWithServedUser(_bob, guest: false, fetchedAs: 1001).run()).isRight(), isTrue);
      expect((await auth.loginWithDocument(parseHtmlDocument(_authedPage(_bob))).run()).isRight(), isTrue);
      expectBobUnmixed();
    });
  });

  group('identity writes, one at a time (re-review probes)', () {
    late CookieProvider global;

    setUp(() async {
      for (final u in [_alice, _bob]) {
        await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: _jar(u));
      }
      await settings.setValue(SettingsKeys.loginUid, 1000);
      await settings.setValue(SettingsKeys.loginUsername, 'Alice');
      global = CookieProvider.buildEmpty();
      await global.loadCookieFromStorage(_alice);
      getIt.registerSingleton<CookieProvider>(global);
    });

    String tokenIn(int uid) => RegExp('auth=([a-z]+)').firstMatch('${storage.getCookieByUidSync(uid)}')?[1] ?? 'none';

    test("P1: Bob's cookie loaded while the record of Alice's page waits: her row keeps her session", () async {
      final auth = AuthenticationRepository();
      addTearDown(auth.dispose);
      // The homepage's page of Alice is recorded...
      final login = auth.loginWithServedUser(_alice, guest: false, fetchedAs: 1000).run();
      // ...while the cookie in use turns into Bob's.
      await global.loadCookieFromStorage(_bob);
      expect((await login).getLeft().toNullable(), isA<IdentityChangedException>());
      expect(tokenIn(1000), 'alice', reason: "Alice's row must keep her session");
      expect(tokenIn(1001), 'bob');
      expect(settings.currentSettings.loginUid, 1000, reason: 'the bare cookie load is no switch: nothing named');
      expect(auth.currentUser, isNull);
    });

    /// The authentication of the app, its isolated clients (the switch, the password login) answered by [forum].
    AuthenticationRepository authWith(
      HttpClientAdapter forum, {
      UserLoginInfo? user,
      NetClientProvider Function(UserLoginInfo user)? currentUserClient,
    }) {
      final auth = AuthenticationRepository(
        user: user,
        clientFactory: (cookie) => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
          cookie: cookie,
        ),
        currentUserClientFactory: currentUserClient,
      );
      addTearDown(auth.dispose);
      return auth;
    }

    Future<List<int>> rows() async => (await storage.getAllUsers()).map((e) => e.uid!).toList()..sort();

    test(
      'P1b: the switch holds the lock while it checks Bob: the record of the page asked as Alice is refused',
      () async {
        final forum = _SwitchForum()..hold = Completer<void>();
        final auth = authWith(forum);
        final switching = auth.switchUser(_bob).run();
        await _until(() => forum.requests.isNotEmpty, reason: "the check of Bob's login");
        // However many turns pass meanwhile, the record waits for the switch.
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        final login = auth.loginWithServedUser(_alice, guest: false, fetchedAs: 1000).run();
        forum.hold!.complete();
        expect((await switching).isRight(), isTrue);
        expect((await login).getLeft().toNullable(), isA<IdentityChangedException>());
        expect((tokenIn(1000), tokenIn(1001)), ('alice', 'bob'));
        expect((settings.currentSettings.loginUid, auth.currentUser?.uid), (1001, 1001));
      },
    );

    test('P1 mutual exclusion: a switch asked while the record of the page writes waits for it', () async {
      // The record's write of Alice's row is held: the lock is held by the record meanwhile.
      final held = _HeldStorage(db)..heldUid = 1000;
      await held.refreshCookieCache();
      getIt
        ..unregister<StorageProvider>()
        ..registerSingleton<StorageProvider>(held);
      final forum = _SwitchForum();
      final auth = authWith(forum);
      final login = auth.loginWithServedUser(_alice, guest: false, fetchedAs: 1000).run();
      await _until(() => held.writing, reason: "the record's write of Alice's row");
      final switching = auth.switchUser(_bob).run();
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(forum.requests, isEmpty, reason: 'the switch has not begun: the record holds the lock');
      held.hold.complete();
      expect((await login).isRight(), isTrue, reason: 'recorded for Alice, whose cookie asked');
      expect((await switching).isRight(), isTrue, reason: 'then switched');
      expect(forum.requests, ['bob']);
      expect((tokenIn(1000), tokenIn(1001)), ('alice', 'bob'));
      expect((settings.currentSettings.loginUid, auth.currentUser?.uid), (1001, 1001));
    });

    test('A: removing the account in use, asked while a switch to Bob runs, removes nobody', () async {
      final forum = _SwitchForum()..hold = Completer<void>();
      final auth = authWith(forum, user: _alice);
      final switching = auth.switchUser(_bob).run();
      await _until(() => forum.requests.isNotEmpty, reason: "the check of Bob's login");
      expect(auth.effectiveCurrentUid, 1000, reason: 'the page still shows Alice as the account in use');
      final forgetting = auth.forgetCurrentUser().run();
      final forgettingAlice = auth.forgetCurrentUser(uid: 1000).run();
      forum.hold!.complete();
      expect((await switching).isRight(), isTrue);
      expect((await forgetting).getLeft().toNullable(), isA<IdentityChangedException>());
      expect((await forgettingAlice).getLeft().toNullable(), isA<IdentityChangedException>());
      expect(await rows(), [1000, 1001], reason: 'nobody removed');
      expect((auth.currentUser?.uid, global.userLoginInfo.uid, settings.currentSettings.loginUid), (1001, 1001, 1001));
    });

    test('B: a logout asked while a switch to Bob runs logs nobody out', () async {
      final forum = _SwitchForum()..hold = Completer<void>();
      final loggedOutAs = <int?>[];
      final auth = authWith(
        forum,
        user: _alice,
        currentUserClient: (user) {
          loggedOutAs.add(user.uid);
          return NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = forum);
        },
      );
      final switching = auth.switchUser(_bob).run();
      await _until(() => forum.requests.isNotEmpty, reason: "the check of Bob's login");
      expect(auth.currentUser?.uid, 1000, reason: 'the profile page still shows Alice');
      final loggingOut = auth.logout().run();
      forum.hold!.complete();
      expect((await switching).isRight(), isTrue);
      expect((await loggingOut).getLeft().toNullable(), isA<IdentityChangedException>());
      expect(loggedOutAs, isEmpty, reason: 'the forum was not asked to log anybody out');
      expect(await rows(), [1000, 1001]);
      expect(auth.currentUser?.uid, 1001);
    });

    /// The forum of the password login: the login form (GET, giving the session's auth cookie [token]) and the login
    /// itself (POST, held until [posted] completes) of Alice.
    HttpClientAdapter passwordForum(Completer<void> posted, {String token = 'fresh'}) => _PasswordForum(posted, token);

    for (final recordFirst in [false, true]) {
      test(
        "C: a guest page of Alice's old session recorded ${recordFirst ? 'before' : 'after'} her password login "
        'leaves her not expired',
        () async {
          await storage.markSessionExpired(1000);
          final posted = Completer<void>();
          final auth = authWith(passwordForum(posted));
          // Asked with her old session, before the login.
          final epoch = auth.identityEpoch;
          Future<Object?> record() async =>
              (await auth.loginWithServedUser(null, guest: true, fetchedAs: 1000, epoch: epoch).run())
                  .getLeft()
                  .toNullable();
          Object? recorded;
          if (recordFirst) {
            recorded = await record();
          }
          final login = auth
              .loginWithPassword(
                const UserCredential(
                  loginField: LoginField.username,
                  loginFieldValue: 'Alice',
                  password: 'test',
                  tsdmVerify: '',
                ),
              )
              .run();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          final pending = recordFirst ? null : record();
          posted.complete();
          expect((await login).isRight(), isTrue);
          recorded ??= await pending;
          if (!recordFirst) {
            expect(recorded, isA<IdentityChangedException>(), reason: 'asked before the login: says nothing of it');
          }
          expect(await expiredUids(), isEmpty, reason: 'the fresh login is not marked expired');
          expect(auth.currentUser?.uid, 1000);
        },
      );
    }

    test('D: an account removed while its cookie is read from the database stays removed', () async {
      final sync = CookieProvider.buildEmpty();
      final loading = sync.loadCookieFromDatabase(_bob);
      expect(await storage.deleteCookieByUid(1001), isTrue);
      expect(await loading, isFalse, reason: 'removed meanwhile: nothing to poll with');
      expect(storage.getCookieByUidSync(1001), isNull, reason: 'no ghost in the cache');
      await sync.write(baseHost, '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=late; Path=/;_crt=1"}}');
      expect(await rows(), [1000], reason: 'a late Set-Cookie does not bring the row back');
    });

    test("E: a page served to Bob, asked before Alice's password login, does not move her fresh session", () async {
      // The corrupted row the adoption is for: Alice's row holds Bob's session.
      await storage.saveCookie(username: 'Alice', uid: 1000, cookie: _jar(_bob));
      await global.loadCookieFromStorage(_alice);
      final posted = Completer<void>();
      final auth = authWith(passwordForum(posted), user: _alice);
      final login = auth
          .loginWithPassword(
            const UserCredential(
              loginField: LoginField.username,
              loginFieldValue: 'Alice',
              password: 't',
              tsdmVerify: '',
            ),
          )
          .run();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      // The homepage asked with the cookie in use (Alice's row, Bob's session) before the login: served to Bob.
      final record = auth.loginWithServedUser(_bob, guest: false, fetchedAs: 1000).run();
      posted.complete();
      expect((await login).isRight(), isTrue);
      expect((await record).getLeft().toNullable(), isA<IdentityChangedException>());
      expect((auth.currentUser?.uid, settings.currentSettings.loginUid), (1000, 1000));
      expect((tokenIn(1000), tokenIn(1001)), ('fresh', 'bob'), reason: "Alice's fresh session stays hers");
    });

    test('F: the status a new listener gets first is the very status latestStatus names', () async {
      final auth = authWith(_SwitchForum(), user: _alice);
      expect((await auth.switchUser(_bob).run()).isRight(), isTrue);
      final replayed = auth.latestStatus;
      expect(identical(await auth.status.first, replayed), isTrue);
    });

    group('homepage', () {
      late _HomeForum home;
      late ForumHomeRepository forumHome;

      setUp(() {
        TsdmAppApi.reset();
        home = _HomeForum();
        getIt.registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = home),
        );
        forumHome = ForumHomeRepository();
      });
      tearDown(() => forumHome.dispose());

      HomepageBloc homepage(AuthenticationRepository auth) {
        final bloc = HomepageBloc(
          forumHomeRepository: forumHome,
          profileRepository: ProfileRepository(),
          authenticationRepository: auth,
        );
        addTearDown(bloc.close);
        return bloc;
      }

      test("P2: Alice's row holds Bob's session: the page served to Bob is adopted, as before", () async {
        await storage.saveCookie(username: 'Alice', uid: 1000, cookie: _jar(_bob));
        await global.loadCookieFromStorage(_alice);
        final auth = AuthenticationRepository();
        addTearDown(auth.dispose);
        final bloc = homepage(auth)..add(HomepageRefreshRequested());
        await _until(() => bloc.state.status != HomepageStatus.loading && auth.currentUser != null, reason: 'loaded');
        expect(auth.currentUser?.uid, 1001, reason: 'the session the forum serves is followed');
        expect(settings.currentSettings.loginUid, 1001);
        expect(tokenIn(1001), 'bob');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(bloc.state.status, isNot(HomepageStatus.loading), reason: 'never stuck loading');
        expect(
          home.paths.where((p) => p.endsWith('forum.php')),
          hasLength(1),
          reason: 'the page shown is the account it was served to: no second load',
        );
      });

      test('P3: a switch that is the first status of the run reloads the homepage for Bob', () async {
        final forum = _SwitchForum();
        final auth = AuthenticationRepository(
          clientFactory: (cookie) => NetClientProvider.buildNoCookie(
            dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
            cookie: cookie,
          ),
        );
        addTearDown(auth.dispose);
        final bloc = homepage(auth);
        expect((await auth.switchUser(_bob).run()).isRight(), isTrue);
        await _until(() => home.paths.any((p) => p.endsWith('forum.php')), reason: 'the homepage of Bob');
        await _until(() => bloc.state.status != HomepageStatus.loading, reason: 'loaded');
        expect(auth.currentUser?.uid, 1001);
      });

      test('P3 control: after an earlier status the switch reloads the homepage too', () async {
        final forum = _SwitchForum();
        final auth = AuthenticationRepository(
          clientFactory: (cookie) => NetClientProvider.buildNoCookie(
            dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
            cookie: cookie,
          ),
        );
        addTearDown(auth.dispose);
        final bloc = homepage(auth)..add(HomepageLoadRequested());
        await _until(() => bloc.state.status == HomepageStatus.success, reason: 'the homepage of Alice');
        expect(home.paths.where((p) => p.endsWith('forum.php')), hasLength(1));
        expect(auth.currentUser?.uid, 1000, reason: 'recorded by the page');
        expect((await auth.switchUser(_bob).run()).isRight(), isTrue);
        await _until(() => home.paths.where((p) => p.endsWith('forum.php')).length == 2, reason: 'reloaded for Bob');
        await _until(() => bloc.state.status != HomepageStatus.loading, reason: 'loaded');
      });

      test('a page refused while it is still the latest load asks for one refresh, and only one', () async {
        final forum = _SwitchForum();
        final auth = AuthenticationRepository(
          user: _alice,
          clientFactory: (cookie) => NetClientProvider.buildNoCookie(
            dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
            cookie: cookie,
          ),
        );
        addTearDown(auth.dispose);
        final bloc = homepage(auth);
        home.holds['alice'] = Completer<void>();
        bloc.add(HomepageRefreshRequested());
        await _until(() => home.homepageTokens.isNotEmpty, reason: "the homepage asked with Alice's session");
        // Alice's login verified again meanwhile (a new session of the same account): no account change for the
        // homepage, but the page asked before it says nothing of the new session.
        expect((await auth.switchUser(_alice).run()).isRight(), isTrue);
        home.holds['alice']!.complete();
        await _until(() => bloc.state.status == HomepageStatus.success, reason: 'the homepage loaded again');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(home.homepageTokens, ['alice', 'alice'], reason: 'the refused page, then one refresh');
        expect(bloc.state.status, HomepageStatus.success);
      });

      test("a failure of the previous account's load answered after Bob's page does not replace it", () async {
        final forum = _SwitchForum();
        final auth = AuthenticationRepository(
          clientFactory: (cookie) => NetClientProvider.buildNoCookie(
            dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
            cookie: cookie,
          ),
        );
        addTearDown(auth.dispose);
        final bloc = homepage(auth);
        home
          ..holds['alice'] = Completer<void>()
          ..failing.add('alice');
        bloc.add(HomepageRefreshRequested());
        await _until(() => home.homepageTokens.isNotEmpty, reason: "the homepage asked with Alice's cookie");
        expect((await auth.switchUser(_bob).run()).isRight(), isTrue);
        await _until(() => bloc.state.status == HomepageStatus.success, reason: "Bob's homepage");
        expect(home.homepageTokens, ['alice', 'bob']);
        home.holds['alice']!.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(bloc.state.status, HomepageStatus.success, reason: "Alice's late failure is stale");
      });

      test("a page of Alice landing after the switch is dropped and the homepage loads Bob's, never stuck", () async {
        final forum = _SwitchForum();
        final auth = AuthenticationRepository(
          clientFactory: (cookie) => NetClientProvider.buildNoCookie(
            dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
            cookie: cookie,
          ),
        );
        addTearDown(auth.dispose);
        final bloc = homepage(auth);
        // The page of Alice asked at the cold start, answered only after the switch.
        home.hold = Completer<void>();
        bloc.add(HomepageLoadRequested());
        await _until(() => home.homepageTokens.isNotEmpty, reason: "the homepage asked with Alice's cookie");
        expect((await auth.switchUser(_bob).run()).isRight(), isTrue);
        await _until(() => home.homepageTokens.length == 2, reason: 'the homepage asked again for Bob');
        home.hold!.complete();
        await _until(() => bloc.state.status == HomepageStatus.success, reason: "Bob's homepage");
        expect(home.homepageTokens, ['alice', 'bob']);
        expect(auth.currentUser?.uid, 1001);
        expect((tokenIn(1000), tokenIn(1001)), ('alice', 'bob'));
        expect(settings.currentSettings.loginUid, 1001);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(bloc.state.status, HomepageStatus.success, reason: 'the stale page of Alice changed nothing');
      });
    });
  });

  group('payload', () {
    test('the notice page as the account in use, or as a named account; anything else is not ours', () {
      expect(LocalNoticeKeys.parseOpenNotification(LocalNoticeKeys.openNotification), (uid: null));
      expect(LocalNoticeKeys.openNotificationOf(1001), 'openNotification:1001');
      expect(LocalNoticeKeys.parseOpenNotification('openNotification:1001'), (uid: 1001));
      for (final other in [null, '', 'open', 'openNotification:', 'openNotification:x', 'openNotification:0']) {
        expect(LocalNoticeKeys.parseOpenNotification(other), isNull, reason: '$other');
      }
    });

    test('ids of the notifications of the accounts', () {
      expect(isLocalNoticeId(localNoticeId), isTrue);
      expect(isLocalNoticeId(localNoticeIdOf(1)), isTrue);
      expect(isLocalNoticeId(backgroundSyncNotificationId), isFalse);
      expect(localNoticeIdOf(888), isNot(backgroundSyncNotificationId));
      expect(localNoticeIdOf(1000), isNot(localNoticeIdOf(1001)));
      expect(localNoticeIdOf(2147483647), lessThan(1 << 31), reason: 'an Android notification id is an int');
    });
  });

  group('a tap on a notification', () {
    late AuthenticationRepository auth;
    late _SwitchForum switchForum;
    late StreamSubscription<AuthStatus> authLog;

    setUp(() async {
      for (final u in _everyone) {
        await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: _jar(u));
      }
      await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
      await settings.setValue(SettingsKeys.loginUsername, _alice.username!);
      getIt.registerSingleton<CookieProvider>(CookieProvider(_alice, _jar(_alice)));
      switchForum = _SwitchForum();
      auth = AuthenticationRepository(
        user: _alice,
        clientFactory: (cookie) => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = switchForum,
          cookie: cookie,
        ),
      );
      authLog = auth.status.listen((s) => _log.add('auth ${s.runtimeType} ${auth.currentUser?.uid}'));
    });

    tearDown(() async {
      await authLog.cancel();
      await auth.dispose();
    });

    /// The notice pages built: the account in use, and the owner and the notice ids of the lists then.
    final pages = <(int?, int?, List<int>)>[];

    /// The home page of the app with a notice route, under the providers the tap reads; its context.
    Future<BuildContext> pumpHome(WidgetTester tester, {NotificationBloc? bloc}) async {
      pages.clear();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Center(child: Text('home'))),
          ),
          GoRoute(
            path: ScreenPaths.notice,
            name: ScreenPaths.notice,
            builder: (context, _) {
              _log.add('notice page as ${auth.currentUser?.uid}');
              final state = context.read<NotificationBloc>().state;
              pages.add((auth.currentUser?.uid, state.ownerUid, state.noticeList.map((e) => e.id).toList()));
              return const Scaffold(body: Center(child: Text('notice page')));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: BlocProvider<NotificationBloc>.value(
              value: bloc ?? _Notifications(auth),
              child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
            ),
          ),
        ),
      );
      await _settle(tester);
      return tester.element(find.text('home'));
    }

    /// What the home page does with the payload of the tapped notification, from [context]; the result once done.
    Future<({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})> begin(
      BuildContext context,
      String payload,
    ) {
      final open = LocalNoticeKeys.parseOpenNotification(payload)!;
      _log.clear();
      return openNoticePageOfAccount(context, uid: open.uid, popups: PopupRouteObserver());
    }

    Future<({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})?> tap(
      WidgetTester tester,
      String payload,
    ) async {
      final context = await pumpHome(tester);
      ({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})? result;
      unawaited(begin(context, payload).then((e) => result = e));
      await _settle(tester, rounds: 12);
      return result;
    }

    /// A cold start: the stored login of Alice is not verified yet, the global cookie is hers.
    Future<void> coldStart(WidgetTester tester) async {
      await tester.runAsync(() async {
        await authLog.cancel();
        await auth.dispose();
      });
      auth = AuthenticationRepository(
        clientFactory: (cookie) => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = switchForum,
          cookie: cookie,
        ),
      );
      authLog = auth.status.listen((s) => _log.add('auth ${s.runtimeType} ${auth.currentUser?.uid}'));
      expect(auth.currentUser, isNull);
      expect(auth.effectiveCurrentUid, 1000, reason: 'the stored session counts');
    }

    /// The token of the auth cookie stored in the row of [uid].
    String tokenIn(int uid) => RegExp('auth=([a-z]+)').firstMatch('${storage.getCookieByUidSync(uid)}')?[1] ?? 'none';

    testWidgets("cold start: switched right away, the homepage's late answer for the stored account records nothing", (
      tester,
    ) async {
      await coldStart(tester);
      final context = await pumpHome(tester);
      ({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})? result;
      unawaited(begin(context, LocalNoticeKeys.openNotificationOf(_bob.uid!)).then((e) => result = e));
      await _settle(tester, rounds: 12);
      expect(result?.step, LocalNoticeAccountStep.switched, reason: 'no wait for the stored login');
      expect(switchForum.requests, ['bob']);
      expect(_log, [
        'auth AuthStatusAuthed 1001',
        'NotificationReloadFromStorageRequested as 1001',
        'notice page as 1001',
      ]);

      // The homepage asked with Alice's cookie answers only now, as a guest's page or as hers: nothing recorded.
      await tester.runAsync(() async {
        expect(
          (await auth.loginWithServedUser(null, guest: true, fetchedAs: 1000).run()).getLeft().toNullable(),
          isA<IdentityChangedException>(),
        );
        expect(
          (await auth.loginWithServedUser(_alice, guest: false, fetchedAs: 1000).run()).getLeft().toNullable(),
          isA<IdentityChangedException>(),
        );
        expect(await expiredUids(), isEmpty, reason: "Alice's guest page says nothing about Bob");
      });
      expect(auth.currentUser?.uid, 1001);
      expect(settings.currentSettings.loginUid, 1001);
      expect((tokenIn(1000), tokenIn(1001)), ('alice', 'bob'), reason: 'each row keeps its own session');
      await _dispose(tester);
    });

    testWidgets('the answer for the stored account landing while the switch checks Bob waits for it, then is refused', (
      tester,
    ) async {
      await coldStart(tester);
      final context = await pumpHome(tester);
      switchForum.hold = Completer<void>();
      ({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})? result;
      unawaited(begin(context, LocalNoticeKeys.openNotificationOf(_bob.uid!)).then((e) => result = e));
      await _settle(tester);
      expect(switchForum.requests, ['bob'], reason: "the switch checks Bob's login, holding the identity lock");
      Either<AppException, void>? login;
      unawaited(auth.loginWithServedUser(_alice, guest: false, fetchedAs: 1000).run().then((e) => login = e));
      await _settle(tester);
      expect(login, isNull, reason: 'the record of the page waits for the switch');
      switchForum.hold!.complete();
      await _settle(tester, rounds: 12);
      expect(result?.step, LocalNoticeAccountStep.switched);
      expect(login?.getLeft().toNullable(), isA<IdentityChangedException>());
      expect((tokenIn(1000), tokenIn(1001)), ('alice', 'bob'));
      expect(settings.currentSettings.loginUid, 1001);
      expect(auth.currentUser?.uid, 1001);
      await _dispose(tester);
    });

    testWidgets("the page opens once the lists are the new account's, a fetch of the previous one dropped first", (
      tester,
    ) async {
      final at = DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000;
      await tester.runAsync(() async {
        for (final uid in [1000, 1001]) {
          await persistFetchedNotification(
            storage: storage,
            uid: uid,
            fetched: NotificationV2(
              status: 0,
              noticeList: [NoticeV2(id: _noticeId(uid), timestamp: at, data: 'notice of $uid')],
              personalMessageList: const [],
              broadcastMessageList: const [],
            ),
          );
        }
      });
      // The in-app fetch of the account in use goes through the global client; Alice's is held by the forum.
      forum.holds['alice'] = Completer<void>();
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
          cookie: getIt.get<CookieProvider>(),
        ),
      );
      final notifications = NotificationRepository(storageProvider: storage);
      final infos = NotificationInfoRepository();
      final bloc = NotificationBloc(
        notificationRepository: notifications,
        infoRepository: infos,
        authRepo: auth,
        storageProvider: storage,
      );
      final context = await pumpHome(tester, bloc: bloc);
      bloc.add(NotificationReloadFromStorageRequested());
      await _settle(tester);
      expect(bloc.state.ownerUid, 1000);
      expect(bloc.state.noticeList.map((e) => e.id), [_noticeId(1000)]);
      bloc.add(const NotificationUpdateAllRequested());
      await _settle(tester);
      expect(bloc.state.status, NotificationStatus.loading, reason: "Alice's fetch in flight");

      ({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})? result;
      unawaited(begin(context, LocalNoticeKeys.openNotificationOf(_bob.uid!)).then((e) => result = e));
      await _settle(tester, rounds: 12);
      expect(auth.currentUser?.uid, 1001, reason: 'switched');
      expect(result, isNull);
      expect(pages, isEmpty, reason: "the lists are still Alice's: no notice page yet");

      forum.holds['alice']!.complete();
      await _settle(tester, rounds: 16);
      expect(result?.step, LocalNoticeAccountStep.switched);
      expect(pages.map((e) => (e.$1, e.$2, e.$3.join(','))), [
        (1001, 1001, '${_noticeId(1001)}'),
      ], reason: "Bob's only");
      await tester.runAsync(() async {
        await bloc.close();
        await notifications.dispose();
        await infos.dispose();
      });
      await _dispose(tester);
    });

    testWidgets('another switch while the lists of the new account are awaited wins: no notice page', (tester) async {
      // A fetch of Alice in flight keeps the lists hers until it ends.
      forum.holds['alice'] = Completer<void>();
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
          cookie: getIt.get<CookieProvider>(),
        ),
      );
      final notifications = NotificationRepository(storageProvider: storage);
      final infos = NotificationInfoRepository();
      final bloc = NotificationBloc(
        notificationRepository: notifications,
        infoRepository: infos,
        authRepo: auth,
        storageProvider: storage,
      );
      final context = await pumpHome(tester, bloc: bloc);
      bloc.add(const NotificationUpdateAllRequested());
      await _settle(tester);
      expect(bloc.state.status, NotificationStatus.loading);
      ({LocalNoticeAccountStep step, String? top, LocalNoticeTapAction? action})? result;
      unawaited(begin(context, LocalNoticeKeys.openNotificationOf(_bob.uid!)).then((e) => result = e));
      await _settle(tester, rounds: 12);
      expect(auth.currentUser?.uid, 1001);
      expect(result, isNull, reason: "waiting for Bob's lists");
      // The avatar menu switches to Carol meanwhile.
      await tester.runAsync(() => auth.switchUser(_carol).run());
      await _settle(tester, rounds: 12);
      expect(result?.step, LocalNoticeAccountStep.notSwitched, reason: 'the later switch wins');
      expect(pages, isEmpty, reason: 'no notice page for Bob under Carol');
      forum.holds['alice']!.complete();
      await _settle(tester);
      await tester.runAsync(() async {
        await bloc.close();
        await notifications.dispose();
        await infos.dispose();
      });
      await _dispose(tester);
    });

    testWidgets('another account: switch first, its notices reloaded, then the notice page', (tester) async {
      final result = await tap(tester, LocalNoticeKeys.openNotificationOf(_bob.uid!));

      expect(result?.step, LocalNoticeAccountStep.switched);
      expect(result?.action, LocalNoticeTapAction.openNoticePage);
      expect(switchForum.requests, ['bob'], reason: 'the login of Bob checked once, with his cookie');
      expect(auth.currentUser?.uid, 1001);
      expect(settings.currentSettings.loginUid, 1001);
      expect(getIt.get<CookieProvider>().userLoginInfo.uid, 1001);
      expect(find.text('notice page'), findsOneWidget);
      expect(find.text('Switched to Bob'), findsOneWidget, reason: 'the toast of the quick switch');
      // Never Alice's notices while Bob is in use: the switch, then the lists rebuilt for Bob, then the page.
      expect(_log, [
        'auth AuthStatusAuthed 1001',
        'NotificationReloadFromStorageRequested as 1001',
        'notice page as 1001',
      ]);
      expect(isSwitchingAccount, isFalse);
      await _dispose(tester);
    });

    testWidgets('the account in use, or a notification naming none: the notice page right away', (tester) async {
      for (final payload in [LocalNoticeKeys.openNotificationOf(_alice.uid!), LocalNoticeKeys.openNotification]) {
        _log.clear();
        final result = await tap(tester, payload);
        expect(result?.step, LocalNoticeAccountStep.current, reason: payload);
        expect(result?.action, LocalNoticeTapAction.openNoticePage, reason: payload);
        expect(_log, ['notice page as 1000'], reason: payload);
      }
      expect(switchForum.requests, isEmpty, reason: 'no switch');
      expect(auth.currentUser?.uid, 1000);
      await _dispose(tester);
    });

    testWidgets('the switch fails: the notice page is not opened, the account in use stays', (tester) async {
      switchForum.expired.add('bob');
      final result = await tap(tester, LocalNoticeKeys.openNotificationOf(_bob.uid!));

      expect(result?.step, LocalNoticeAccountStep.notSwitched);
      expect(result?.action, isNull);
      expect(find.text('notice page'), findsNothing);
      expect(find.text(t.loginPage.perhapsExpired), findsOneWidget);
      expect(auth.currentUser?.uid, 1000);
      expect(settings.currentSettings.loginUid, 1000);
      expect(_log, isEmpty, reason: "Alice's notice page is not shown for Bob's notification");
      expect(await tester.runAsync(expiredUids), {1001}, reason: 'the expired login of Bob is recorded');
      await _dispose(tester);
    });

    testWidgets('an account no longer on this device: a toast, nothing opened', (tester) async {
      await tester.runAsync(() => storage.deleteCookieByUid(_carol.uid!));
      final result = await tap(tester, LocalNoticeKeys.openNotificationOf(_carol.uid!));

      expect(result?.step, LocalNoticeAccountStep.gone);
      expect(find.text(t.localNotification.accountGone), findsOneWidget);
      expect(find.text('notice page'), findsNothing);
      expect(switchForum.requests, isEmpty);
      expect(auth.currentUser?.uid, 1000);
      await _dispose(tester);
    });

    testWidgets('nobody logged in: the notice page needs a login, as before', (tester) async {
      await tester.runAsync(() async {
        await auth.dispose();
        getIt.get<CookieProvider>().clearUserInfoAndCookie();
        await settings.setValue(SettingsKeys.loginUid, 0);
      });
      auth = AuthenticationRepository();
      final result = await tap(tester, LocalNoticeKeys.openNotificationOf(_bob.uid!));
      expect(result?.step, LocalNoticeAccountStep.current);
      expect(result?.action, LocalNoticeTapAction.needLogin);
      expect(find.text('notice page'), findsNothing);
      expect(switchForum.requests, isEmpty);
      await _dispose(tester);
    });
  });
}
