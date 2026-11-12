/// The logout and the account switch tell the account of a session from the forum's app API, not from the words of a
/// page.
///
/// The logout read the settings page (`home.php?mod=spacecp`) for the account and its form hash, and took the logout
/// for done only when the forum's page said "已退出"; the switch read the same page for the account of the stored
/// session. A change of the forum's template or language pack broke both. Now `status` of the forum's app API tells
/// the account of the session (`uid`, 0 for a guest) and its form hash: the logout posts with that hash and is done
/// once `status`, asked with the cookies the logout left (the forum deletes the auth cookie), says a guest, whatever
/// the page says; the switch takes the account `status` names (the name kept from the saved login, `status` has none).
/// Without the API (no plugin, a failed or busy request) the pages are read as before. The test forum answered
/// `status` uid 31 before the logout and uid 0 right after it (2026-11-13).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);
const List<UserLoginInfo> _everyone = [_alice, _bob];

String _token(UserLoginInfo user) => user.username!.toLowerCase();

Map<String, String> _jar(UserLoginInfo user) => {
  '.index': '["$baseHost"]',
  baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=${_token(user)}; Path=/;_crt=1"}}',
};

final _authRe = RegExp('Ystv_2132_auth=([a-z]+)');

String _authedPage(UserLoginInfo user) =>
    '<html><body><div id="inner_stat"><strong><a href="home.php?mod=space&amp;uid=${user.uid}">${user.username}</a> '
    '</strong></div><input type="hidden" name="formhash" value="0a0b0c0d" /></body></html>';

const _guestPage =
    '<html><body><form id="lsform" method="post"><input type="hidden" name="formhash" value="0a0b0c0d" /> '
    '<input name="username" /></form><div id="messagetext"><p>请先登录后才能继续浏览</p></div></body></html>';

String _logoutPage(String text) =>
    '<html><body><div id="messagetext" class="alert_right"><p>$text</p></div></body></html>';

/// How the forum answers `status`.
enum _Status {
  /// The plugin: the account of the auth cookie.
  api,

  /// No plugin: the forum's page.
  none,

  /// The plugin, "too soon" for longer than is waited for.
  busy,
}

/// The forum of the two accounts: a request is answered for the account of its auth cookie, as a guest for the
/// tokens in [dead] and for a deleted cookie. The logout answers [logoutText] and deletes the auth cookie unless
/// [keepsCookie].
final class _Forum implements HttpClientAdapter {
  _Forum({
    this.status = _Status.api,
    this.logoutText = '您已退出站点，现在将以游客身份转入退出前页面',
    this.keepsCookie = false,
    this.statusUidBeforeLogout,
  });

  final _Status status;

  /// The uid `status` names before the logout, whatever the session (a cookie of another account), when set.
  final int? statusUidBeforeLogout;
  final String logoutText;
  final bool keepsCookie;
  final dead = <String>{};

  /// What was asked, in order: `status`, `spacecp`, `logout <formhash>`.
  final asked = <String>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? rs, Future<void>? cancel) async {
    final token = _authRe.firstMatch('${options.headers['cookie'] ?? options.headers['Cookie'] ?? ''}')?[1];
    final user = dead.contains(token) ? null : _everyone.where((u) => _token(u) == token).firstOrNull;
    final q = options.uri.queryParameters;
    if (q['id'] == 'tsdmapp:api') {
      asked.add('${q['action']}');
      return switch (status) {
        _Status.api => _json({
          'ok': 1,
          'api': 1,
          'version': '3.9.0',
          'uid': asked.any((e) => e.startsWith('logout')) ? user?.uid ?? 0 : statusUidBeforeLogout ?? user?.uid ?? 0,
          'formhash': 'a1b2c3d4',
        }),
        _Status.none => _html(user == null ? _guestPage : _authedPage(user)),
        _Status.busy => ResponseBody.fromString(
          jsonEncode({'ok': 0, 'error': 'busy', 'retry_after': 30}),
          429,
          headers: {
            Headers.contentTypeHeader: ['application/json; charset=utf-8'],
          },
        ),
      };
    }
    if (q['mod'] == 'spacecp') {
      asked.add('spacecp');
      return _html(user == null ? _guestPage : _authedPage(user));
    }
    if (q['mod'] == 'logging' && q['action'] == 'logout') {
      asked.add('logout ${q['formhash']}');
      return ResponseBody.fromString(
        _logoutPage(logoutText),
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
          if (!keepsCookie)
            'set-cookie': ['Ystv_2132_auth=deleted; expires=Thu, 01 Jan 1970 00:00:01 GMT; Max-Age=0; path=/'],
        },
      );
    }
    throw DioException.connectionError(requestOptions: options, reason: 'unexpected request ${options.uri}');
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _html(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/html; charset=utf-8'],
  },
);

ResponseBody _json(Object? body) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {
    Headers.contentTypeHeader: ['application/json; charset=utf-8'],
  },
);

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() async {
    TsdmAppApi.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
    for (final u in _everyone) {
      await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: _jar(u));
    }
    await settings.setValue(SettingsKeys.loginUid, 1000);
    await settings.setValue(SettingsKeys.loginUsername, 'Alice');
    final global = CookieProvider.buildEmpty();
    await global.loadCookieFromStorage(_alice);
    getIt.registerSingleton<CookieProvider>(global);
  });

  tearDown(() async {
    TsdmAppApi.reset();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<List<int>> rows() async => (await storage.getAllUsers()).map((e) => e.uid!).toList()..sort();
  Future<Set<int>> expiredUids() async => (await storage.fetchExpiredSessions()).map((e) => e.user.uid!).toSet();

  /// The authentication of the app with Alice in use, every client asking [forum]: the logout's with the cookie of
  /// the account in use (its jar takes the cookies the forum sets), the switch's with the stored session checked.
  AuthenticationRepository authWith(_Forum forum) {
    final auth = AuthenticationRepository(
      user: _alice,
      clientFactory: (cookie) => NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
        cookie: cookie,
      ),
      currentUserClientFactory: (user) => NetClientProvider.build(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum,
        userLoginInfo: user,
      ),
    );
    addTearDown(auth.dispose);
    return auth;
  }

  group('the logout', () {
    test(
      'with the API: posted with the hash status tells, done once status says a guest, whatever the page says',
      () async {
        for (final text in ['您已退出站点，现在将以游客身份转入退出前页面', 'You have logged out.', '']) {
          final forum = _Forum(logoutText: text);
          final auth = authWith(forum);
          expect((await auth.logout().run()).isRight(), isTrue, reason: text);
          expect(forum.asked, ['status', 'logout a1b2c3d4', 'status'], reason: 'the settings page is not read');
          expect(await rows(), [1001], reason: 'her saved login removed ($text)');
          // The next round starts with Alice again.
          await storage.saveCookie(username: 'Alice', uid: 1000, cookie: _jar(_alice));
          await getIt.get<CookieProvider>().loadCookieFromStorage(_alice);
          await settings.setValue(SettingsKeys.loginUid, 1000);
          TsdmAppApi.reset();
        }
      },
    );

    test('with the API: status still names her after the logout: failed, although the page says "已退出"', () async {
      final forum = _Forum(keepsCookie: true);
      final auth = authWith(forum);
      expect((await auth.logout().run()).getLeft().toNullable(), isA<LogoutFailedException>());
      expect(await rows(), [1000, 1001], reason: 'nothing removed');
      expect(auth.effectiveCurrentUid, 1000);
    });

    test('with the API naming another account than the one logged out: the settings page, as before', () async {
      final forum = _Forum(statusUidBeforeLogout: 1001);
      final auth = authWith(forum);
      expect((await auth.logout().run()).isRight(), isTrue);
      expect(forum.asked, ['status', 'spacecp', 'logout 0a0b0c0d', 'status'], reason: 'its hash is not used');
      expect(await rows(), [1001]);
    });

    test('with the API: a guest session before the logout: the saved login removed, nothing posted', () async {
      final forum = _Forum()..dead.add('alice');
      final auth = authWith(forum);
      expect((await auth.logout().run()).isRight(), isTrue);
      expect(forum.asked, ['status']);
      expect(await rows(), [1001]);
    });

    test('without the API: the settings page and the words of the logout page, as before', () async {
      final ok = _Forum(status: _Status.none);
      expect((await authWith(ok).logout().run()).isRight(), isTrue);
      expect(ok.asked, ['status', 'spacecp', 'logout 0a0b0c0d'], reason: 'status answered a page: not asked again');
      expect(await rows(), [1001]);

      await storage.saveCookie(username: 'Alice', uid: 1000, cookie: _jar(_alice));
      await getIt.get<CookieProvider>().loadCookieFromStorage(_alice);
      await settings.setValue(SettingsKeys.loginUid, 1000);
      final changed = _Forum(status: _Status.none, logoutText: 'You have logged out.');
      expect((await authWith(changed).logout().run()).getLeft().toNullable(), isA<LogoutFailedException>());
      expect(await rows(), [1000, 1001]);
    });

    test('status too soon for longer than is waited for: the pages, as before', () async {
      final forum = _Forum(status: _Status.busy);
      expect((await authWith(forum).logout().run()).isRight(), isTrue);
      expect(forum.asked, ['status', 'spacecp', 'logout 0a0b0c0d', 'status']);
      expect(await rows(), [1001]);
    });
  });

  group('the switch', () {
    test('with the API: the account status names, the name of the saved login; no settings page', () async {
      final forum = _Forum();
      final auth = authWith(forum);
      expect((await auth.switchUser(_bob).run()).isRight(), isTrue);
      expect(forum.asked, ['status']);
      expect(auth.currentUser, _bob);
      expect(settings.currentSettings.loginUid, 1001);
    });

    test('with the API: a guest session of the stored login: not switched, its expiry recorded', () async {
      final forum = _Forum()..dead.add('bob');
      final auth = authWith(forum);
      expect((await auth.switchUser(_bob).run()).getLeft().toNullable(), isA<SwitchUserNotAuthedException>());
      expect(forum.asked, ['status']);
      expect(await expiredUids(), {1001});
      expect(auth.currentUser, _alice, reason: 'the account in use untouched');
    });

    test('with the API: the session of another account: not switched, no expiry recorded', () async {
      // Bob's stored row holds Alice's session.
      await storage.saveCookie(username: 'Bob', uid: 1001, cookie: _jar(_alice));
      final forum = _Forum();
      final auth = authWith(forum);
      expect((await auth.switchUser(_bob).run()).getLeft().toNullable(), isA<SwitchUserNotAuthedException>());
      expect(await expiredUids(), isEmpty);
      expect(auth.currentUser, _alice);
    });

    test('with the API but no saved name: the settings page is read for the name, as before', () async {
      final forum = _Forum();
      final auth = authWith(forum);
      // A login without a name is not stored again, whatever names it (as before this change).
      final result = await auth.switchUser(const UserLoginInfo(username: null, uid: 1001)).run();
      expect(result.getLeft().toNullable(), isA<LoginInvalidCredentialException>());
      expect(forum.asked, ['status', 'spacecp']);
      expect(auth.currentUser, _alice);
    });

    test('without the API: the settings page, as before', () async {
      final forum = _Forum(status: _Status.none);
      final auth = authWith(forum);
      expect((await auth.switchUser(_bob).run()).isRight(), isTrue);
      expect(forum.asked, ['status', 'spacecp']);
      expect(auth.currentUser, _bob);

      final expired = _Forum(status: _Status.none)..dead.add('alice');
      final auth2 = authWith(expired);
      expect((await auth2.switchUser(_alice).run()).getLeft().toNullable(), isA<SwitchUserNotAuthedException>());
      expect(expired.asked, ['spacecp'], reason: 'the plugin is known missing for a while');
      expect(await expiredUids(), {1000});
    });
  });
}
