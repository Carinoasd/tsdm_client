import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/checkin/bloc/auto_checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/repository/auto_checkin_repository.dart';
import 'package:tsdm_client/features/multi_user/view/manage_account_page.dart';
import 'package:tsdm_client/features/notification/bloc/notification_sync_all_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/session_expiry/cubit/session_expiry_cubit.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Issue #25: when the forum answers the guest page to the cookie of a stored account, the account is recorded as
/// expired (auto check-in, the sync of all accounts, the notification fetch of the current account, a failed
/// switch), a login or a switch of that account clears it, the manage accounts page says so on the tile with a
/// way to sign in again, and the user is told at app start and when the account in use expires.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);
const _carol = UserLoginInfo(username: 'Carol', uid: 1002);

const _signPage =
    '<html><body><div id="um"><a href="home.php?mod=space&amp;uid=1000">Alice</a></div> '
    '<form id="qiandao" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /></form></body></html>';
const _guestPage =
    '<html><body><form id="lsform" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /> '
    '<input name="username" /></form></body></html>';
const _successXml =
    '<?xml version="1.0" encoding="utf-8"?>\n<root><![CDATA[<div class="c">恭喜你签到成功!获得随机奖励 天使币 10 .</div> '
    '<script type="text/javascript" reload="1">hideWindow("qwindow");</script>]]></root>';

/// The check page as served to a logged-in account.
String _loggedPage(UserLoginInfo user) =>
    '<div id="inner_stat"><strong><a href="home.php?uid=${user.uid}">${user.username}</a></strong></div>';

/// Answers requests from a script in order.
final class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.script);

  final List<(int, String)> script;
  var _next = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (_next >= script.length) {
      fail('unexpected request #${_next + 1}: ${options.uri}');
    }
    final (status, body) = script[_next++];
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers every request with [body].
final class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter(this.body);

  final String body;
  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests += 1;
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Never answers: avatars are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late CookieProvider current;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
    for (final u in [_alice, _bob, _carol]) {
      await storage.saveCookie(
        username: u.username!,
        uid: u.uid!,
        cookie: {'.domains': '{"${u.username}":1}', 'Ystv_2132_auth': u.username!.toLowerCase()},
      );
    }
    // Alice is the current account.
    await settings.setValue<int>(SettingsKeys.loginUid, 1000);
    await settings.setValue<String>(SettingsKeys.loginUsername, 'Alice');
    current = CookieProvider(_alice, {'.domains': '{"Alice":1}', 'Ystv_2132_auth': 'alice'});
    getIt.registerSingleton<CookieProvider>(current);
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<Set<int>> expired() async => (await storage.fetchExpiredSessions()).map((e) => e.user.uid!).toSet();

  NetClientProvider clientOf(CookieProvider cookie, HttpClientAdapter adapter) => NetClientProvider.buildNoCookie(
    dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
    cookie: cookie,
  );

  group('storage', () {
    test('mark, list, watch and clear the expiry of an account', () async {
      expect(await expired(), isEmpty);
      final seen = <Set<int>>[];
      final sub = storage.watchExpiredSessionUids().listen(seen.add);
      while (seen.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(seen.last, isEmpty);

      final at = DateTime(2026, 9, 9, 8, 30);
      await storage.markSessionExpired(1001, at: at);
      while (seen.length < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(seen.last, {1001});
      expect(await expired(), {1001});
      final accounts = await storage.allAccountsStream().first;
      expect(accounts.singleWhere((e) => e.user.uid == 1001).sessionExpiredAt, at);
      expect(accounts.singleWhere((e) => e.user.uid == 1000).sessionExpiredAt, isNull);

      // An unknown account and a repeated mark change nothing visible.
      await storage.markSessionExpired(4242);
      await storage.markSessionExpired(1001);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(seen.last, {1001});
      expect(await expired(), {1001});

      await storage.clearSessionExpired(1001);
      while (seen.length < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(seen.last, isEmpty);
      expect(await expired(), isEmpty);
      await sub.cancel();
    });

    test('a later cookie save keeps the mark, deleting the account drops it', () async {
      await storage.markSessionExpired(1001);
      await storage.saveCookie(username: 'Bob', uid: 1001, cookie: {'Ystv_2132_auth': 'bob-again'});
      expect(await expired(), {1001}, reason: 'a Set-Cookie is not a verified session');
      expect(await storage.deleteCookieByUid(1001), isTrue);
      expect(await expired(), isEmpty);
    });
  });

  group('sources', () {
    test('auto check-in "not authorized" marks the account, a later successful switch clears it', () async {
      final adapter = _ScriptedAdapter([
        // Alice checks in, Bob's session is gone.
        (200, _signPage),
        (200, _successXml),
        (200, _guestPage),
      ]);
      final repo = AutoCheckinRepository(
        storageProvider: storage,
        clientFactory: (cookie) => clientOf(cookie, adapter),
        gap: Duration.zero,
        retryDelays: const [],
      );
      final seen = <AutoCheckinInfo>[];
      final sub = repo.status.listen(seen.add);
      final result = await repo
          .checkinAll(waitingList: [_alice, _bob], skippedList: const [], feeling: CheckinFeeling.happy, message: 'hi')
          .run();
      expect(result.isRight(), isTrue, reason: '$result');
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await repo.dispose();
      expect(seen.last.failed.map((e) => (e.$1.uid, e.$2)), [(1001, const CheckinResultNotAuthorized())]);
      expect(await expired(), {1001});

      // Bob logs in again through an account switch that verifies his session.
      final auth = AuthenticationRepository(
        user: _alice,
        clientFactory: (cookie) => clientOf(cookie, _FixedAdapter(_loggedPage(_bob))),
      );
      addTearDown(auth.dispose);
      final switched = await auth.switchUser(_bob).run();
      expect(switched.isRight(), isTrue, reason: '$switched');
      expect(auth.currentUser?.uid, 1001);
      expect(await expired(), isEmpty);
    });

    test('a switch answered with the guest page marks that account and keeps the current one', () async {
      final auth = AuthenticationRepository(
        user: _alice,
        clientFactory: (cookie) => clientOf(cookie, _FixedAdapter(_guestPage)),
      );
      addTearDown(auth.dispose);
      final switched = await auth.switchUser(_carol).run();
      expect(switched.isLeft(), isTrue);
      expect(switched.getLeft().toNullable(), isA<SwitchUserNotAuthedException>());
      expect(auth.currentUser?.uid, 1000);
      expect(await expired(), {1002});
    });

    test('the sync of all accounts marks the account answered with the guest page', () async {
      final adapter = _FixedAdapter(_guestPage);
      final repo = NotificationSyncAllRepository(
        storageProvider: storage,
        notificationRepository: NotificationRepository(storageProvider: storage),
        clientFactory: (cookie) => clientOf(cookie, adapter),
        gap: Duration.zero,
      );
      final result = await repo.syncAll(accounts: [_bob]).run();
      await repo.dispose();
      expect(result.isRight(), isTrue, reason: '$result');
      final info = result.getOrElse((_) => throw StateError('unreachable'));
      expect(info.finished.single.$2, isA<NotificationSyncResultNotAuthorized>());
      expect(await expired(), {1001});
    });

    test('the notification fetch of the current account marks it when the forum answers the guest page', () async {
      final adapter = _FixedAdapter(_guestPage);
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      );
      final repo = NotificationRepository(storageProvider: storage);
      final result = await repo.fetchNotificationV2(uid: 1000).run();
      await repo.dispose();
      expect(result.getLeft().toNullable(), isA<NotificationUserNotFound>());
      expect(await expired(), {1000});
    });
  });

  group('when to tell the user', () {
    test('the rule: once at start, again when the account in use expires, again after it logged in again', () {
      final notifier = SessionExpiryNotifier();
      expect(notifier.onExpired(const {}, currentUid: 1000), isNull, reason: 'nothing expired at start');
      expect(notifier.startupDone, isTrue);
      expect(notifier.onExpired(const {1001}, currentUid: 1000), isNull, reason: 'another account, not announced');
      expect(notifier.onExpired(const {1001, 1000}, currentUid: 1000), 2, reason: 'the account in use expired');
      expect(notifier.onExpired(const {1001, 1000}, currentUid: 1000), isNull, reason: 'already announced');
      expect(notifier.onExpired(const {1001}, currentUid: 1000), isNull, reason: 'logged in again');
      expect(notifier.onExpired(const {1001, 1000}, currentUid: 1000), 2, reason: 'expired again');
      expect(notifier.onExpired(const {1001, 1000}, currentUid: null), isNull, reason: 'no account in use');

      final atStart = SessionExpiryNotifier();
      expect(atStart.onExpired(const {1001, 1002}, currentUid: 1000), 2, reason: 'two expired accounts at start');
      expect(atStart.onExpired(const {1001, 1002}, currentUid: 1000), isNull);
      expect(atStart.onExpired(const {1001, 1002, 1000}, currentUid: 1000), 3);
      final startWithCurrent = SessionExpiryNotifier();
      expect(startWithCurrent.onExpired(const {1000}, currentUid: 1000), 1);
      expect(startWithCurrent.onExpired(const {1000}, currentUid: 1000), isNull, reason: 'announced at start already');
    });

    test('the cubit watches the stored accounts and counts the hints', () async {
      await storage.markSessionExpired(1001);
      final cubit = SessionExpiryCubit(storageProvider: storage, currentUid: () => 1000, startupDelay: Duration.zero)
        ..start();
      addTearDown(cubit.close);
      Future<void> waitFor(bool Function(SessionExpiryState s) done) async {
        for (var i = 0; i < 200 && !done(cubit.state); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(done(cubit.state), isTrue, reason: '$cubit.state');
      }

      await waitFor((s) => s.noticeSeq == 1);
      expect(cubit.state.expiredUids, {1001});
      expect(cubit.state.noticeCount, 1, reason: 'one stored account expired at start');

      await storage.markSessionExpired(1002);
      await waitFor((s) => s.expiredUids.contains(1002));
      expect(cubit.state.noticeSeq, 1, reason: 'another account expiring later is not announced');

      await storage.markSessionExpired(1000);
      await waitFor((s) => s.noticeSeq == 2);
      expect(cubit.state.noticeCount, 3, reason: 'the account in use expired: all three are counted');

      await storage.clearSessionExpired(1000);
      await waitFor((s) => !s.expiredUids.contains(1000));
      await storage.markSessionExpired(1000);
      await waitFor((s) => s.noticeSeq == 3);
    });
  });

  testWidgets('the manage accounts page tells which login expired and offers to sign in again', (tester) async {
    getIt.registerSingleton<ImageCacheProvider>(
      ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
    );
    await tester.runAsync(() => storage.markSessionExpired(1001));
    final auth = AuthenticationRepository(user: _alice);
    final autoCheckin = AutoCheckinBloc(
      autoCheckinRepository: AutoCheckinRepository(storageProvider: storage),
      settingsRepository: settings,
      storageProvider: storage,
    );
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const ManageAccountPage()),
        GoRoute(
          path: ScreenPaths.login,
          name: ScreenPaths.login,
          builder: (_, state) => Scaffold(body: Center(child: Text('login ${state.uri.queryParameters['username']}'))),
        ),
      ],
    );
    addTearDown(() async {
      router.dispose();
      await autoCheckin.close();
      await auth.dispose();
      await getIt.get<ImageCacheProvider>().dispose();
    });

    await tester.runAsync(() async {
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MultiBlocProvider(
              providers: [
                BlocProvider<AutoCheckinBloc>.value(value: autoCheckin),
                // The sync-all button in the app bar reads this cubit; a fresh, idle one is enough here.
                BlocProvider<NotificationSyncAllCubit>(
                  create: (_) => NotificationSyncAllCubit(
                    repository: NotificationSyncAllRepository(
                      storageProvider: storage,
                      notificationRepository: NotificationRepository(),
                    ),
                    storageProvider: storage,
                    authenticationRepository: auth,
                    infoRepository: NotificationInfoRepository(),
                  ),
                ),
              ],
              child: MaterialApp.router(scaffoldMessengerKey: snackbarKey, routerConfig: router),
            ),
          ),
        ),
      );
      // Let the storage stream deliver the accounts.
      for (var i = 0; i < 50 && find.text('Alice').evaluate().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 20));
      }
    });
    await tester.pump();

    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Carol'), findsOneWidget);
    final tr = tester.element(find.text('Bob')).t.manageAccountPage.sessionExpired;
    expect(find.text(tr.hint), findsOneWidget, reason: 'only Bob expired');
    expect(find.widgetWithText(TextButton, tr.loginAgain), findsOneWidget);
    expect(find.text('Online'), findsOneWidget, reason: 'Alice keeps the online chip');
    final bobTile = find.ancestor(of: find.text('Bob'), matching: find.byType(ListTile));
    expect(find.descendant(of: bobTile, matching: find.text(tr.hint)), findsOneWidget);
    expect(find.descendant(of: bobTile, matching: find.widgetWithText(TextButton, tr.loginAgain)), findsOneWidget);

    // The button opens the login page with Bob's name filled in.
    await tester.tap(find.widgetWithText(TextButton, tr.loginAgain));
    await tester.pumpAndSettle();
    expect(router.state.uri.path, ScreenPaths.login);
    expect(router.state.uri.queryParameters['username'], 'Bob');
    expect(find.text('login Bob'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Dispose the tree here and let the stream close timers fire before the framework checks for pending timers.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}
