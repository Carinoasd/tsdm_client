import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/checkin/bloc/auto_checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/auto_checkin_repository.dart';
import 'package:tsdm_client/features/multi_user/bloc/manage_account_bloc.dart';
import 'package:tsdm_client/features/multi_user/view/manage_account_page.dart';
import 'package:tsdm_client/features/notification/bloc/notification_sync_all_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Issue #6: accounts can be deleted from this device, several at once from the manage accounts page and the current
/// one without a working forum session; a deleted account does not come back through a late Set-Cookie.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);
const _carol = UserLoginInfo(username: 'Carol', uid: 1002);

/// What the forum renders for a guest: the login form, no user node.
const _guestPage =
    '<html><body><form id="lsform" method="post"><input type="hidden" name="formhash" value="XXXXXXXX" /> '
    '<input name="username" /></form><div id="messagetext"><p>请先登录后才能继续浏览</p></div></body></html>';

/// A 200 answer that is neither a logged-in page nor the guest page (maintenance, interstitial).
const _maintenancePage = '<html><body><p>系统繁忙，请稍后再试</p></body></html>';

/// Answers every request with [body] (the guest page by default) and an optional Set-Cookie, records requests.
final class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter({this.setCookie, this.body = _guestPage});

  final String? setCookie;
  final String body;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        if (setCookie != null) 'set-cookie': [setCookie!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Storage whose batch delete waits until [release] completes, so an event can be handled while it is in flight.
final class _SlowStorage extends StorageProvider {
  _SlowStorage(AppDatabase db) : super(db, {}, {});

  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<int> deleteCookiesByUids(Iterable<int> uids) async {
    started.complete();
    await release.future;
    return super.deleteCookiesByUids(uids);
  }
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
      // Only the auth marker: the cookie jar keys (`.index`, `.domains`) are written by the jar itself.
      await storage.saveCookie(
        username: u.username!,
        uid: u.uid!,
        cookie: {'Ystv_2132_auth': u.username!.toLowerCase()},
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

  Future<List<int?>> uids() async => (await storage.getAllUsers()).map((e) => e.uid).toList();

  test('deleteCookiesByUids removes the rows and the cached cookies, leaves the others', () async {
    expect(await storage.deleteCookiesByUids(const []), 0);
    expect(await storage.deleteCookiesByUids([1000, 1001, 4242]), 2, reason: 'unknown uids count nothing');
    expect(await uids(), [1002]);
    expect(storage.getCookieByUidSync(1000), isNull);
    expect(storage.getCookieByUidSync(1001), isNull);
    expect(storage.getCookieByUidSync(1002), containsPair('Ystv_2132_auth', 'carol'));
  });

  test('forgetCurrentUser removes the current account offline and signs this device out', () async {
    final auth = AuthenticationRepository(user: _alice);
    final statuses = <AuthStatus>[];
    final sub = auth.status.listen(statuses.add);

    final result = await auth.forgetCurrentUser().run();
    expect(result.isRight(), isTrue, reason: '$result');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(await uids(), [1001, 1002]);
    expect(auth.currentUser, isNull);
    expect(statuses, contains(isA<AuthStatusNotAuthed>()));
    expect(current.userLoginInfo.uid, isNull, reason: 'the cookie in memory is cleared');
    expect(await settings.getValue<int>(SettingsKeys.loginUid), SettingsKeys.loginUid.defaultValue);
    // A second call has nothing to do and does not fail.
    expect((await auth.forgetCurrentUser().run()).isRight(), isTrue);
    await auth.dispose();
  });

  test('logout removes the saved login when the forum no longer knows the session', () async {
    final adapter = _FakeAdapter();
    final auth = AuthenticationRepository(
      user: _alice,
      currentUserClientFactory: (_) => NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
        cookie: current,
      ),
    );
    final statuses = <AuthStatus>[];
    final sub = auth.status.listen(statuses.add);

    final result = await auth.logout().run();
    expect(result.isRight(), isTrue, reason: '$result');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(adapter.requests, hasLength(1), reason: 'only the auth check, there is no session to end');
    expect(await uids(), [1001, 1002], reason: 'the row used to stay and the account stayed "online"');
    expect(auth.currentUser, isNull);
    expect(statuses, contains(isA<AuthStatusNotAuthed>()));
    await auth.dispose();
  });

  test('logout keeps the saved login when the forum answers a page it can not read', () async {
    final adapter = _FakeAdapter(body: _maintenancePage);
    final auth = AuthenticationRepository(
      user: _alice,
      currentUserClientFactory: (_) => NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
        cookie: current,
      ),
    );
    final statuses = <AuthStatus>[];
    final sub = auth.status.listen(statuses.add);

    final result = await auth.logout().run();
    expect(result.isRight(), isTrue, reason: '$result');
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();

    expect(adapter.requests, hasLength(1));
    expect(await uids(), [1000, 1001, 1002], reason: 'the page says nothing about the session: the row stays');
    expect(auth.currentUser, isNull, reason: 'the previous behaviour: only the authed state is left');
    expect(statuses, contains(isA<AuthStatusNotAuthed>()));
    await auth.dispose();
  });

  test('a back press while deleting neither resets the selection nor skips the current account', () async {
    final slow = _SlowStorage(db);
    final auth = AuthenticationRepository(user: _alice);
    final bloc = ManageAccountBloc(storageProvider: slow, authenticationRepository: auth)
      ..add(const ManageAccountSelectAllRequested([1000, 1001]))
      ..add(const ManageAccountDeleteSelectedRequested());
    await slow.started.future;
    expect(bloc.state.status, ManageAccountStatus.deleting);

    // The system back while the rows are being deleted.
    bloc.add(const ManageAccountSelectionCleared());
    await Future<void>.delayed(Duration.zero);
    expect(bloc.state.status, ManageAccountStatus.deleting, reason: 'clearing is ignored while deleting');
    expect(bloc.state.selectedUids, {1000, 1001});

    slow.release.complete();
    await bloc.stream.firstWhere((s) => s.status == ManageAccountStatus.deleted).timeout(const Duration(seconds: 10));
    expect(bloc.state.deletedCount, 2, reason: 'the current account used to be skipped after the back press');
    expect(bloc.state.selecting, isFalse);
    expect(await uids(), [1002]);
    expect(auth.currentUser, isNull);
    await bloc.close();
    await auth.dispose();
  });

  group('the current account whose session was not verified in this run', () {
    late CookieProvider global;

    setUp(() async {
      // At startup the global provider is built from the stored row of settings.loginUid; the repository has no user
      // until the homepage verifies the session, which never happens offline or once the session expired.
      await getIt.unregister<CookieProvider>();
      global = CookieProvider.build();
      getIt.registerSingleton<CookieProvider>(global);
    });

    test('is the effective current account and forgetCurrentUser removes it', () async {
      final auth = AuthenticationRepository();
      expect(auth.currentUser, isNull);
      expect(auth.effectiveCurrentUid, 1000);
      // A client of the current account built before the removal, its late answer carries a Set-Cookie.
      final adapter = _FakeAdapter(setCookie: 'Ystv_2132_auth=fresh-alice-token; Path=/');
      final client = NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter);

      final result = await auth.forgetCurrentUser().run();
      expect(result.isRight(), isTrue, reason: '$result');
      expect(await uids(), [1001, 1002]);
      expect(await settings.getValue<int>(SettingsKeys.loginUid), SettingsKeys.loginUid.defaultValue);
      expect(settings.currentSettings.loginUid, SettingsKeys.loginUid.defaultValue, reason: 'in memory as well');
      expect(global.userLoginInfo.uid, isNull);
      expect(auth.effectiveCurrentUid, isNull);

      // The client is bound to the removed account: its request is dropped and the Set-Cookie never reaches the
      // provider (a Set-Cookie that does reach it is covered below).
      final late = await client.get('$baseUrl/forum.php').run();
      expect(late.isLeft(), isTrue, reason: '$late');
      expect(adapter.requests, isEmpty);
      expect(await uids(), [1001, 1002], reason: 'the late Set-Cookie must not recreate the row');
      expect(storage.getCookieByUidSync(1000), isNull);
      await auth.dispose();
    });

    test('a Set-Cookie after a plain row delete does not recreate the row of a provider built at startup', () async {
      expect(await storage.deleteCookieByUid(1000), isTrue);
      await global.write('.domains', '{"$baseHost":{"/":{"Ystv_2132_auth":"fresh-alice-token"}}}');
      expect(
        storage.getCookieByUidSync(1000),
        isNull,
        reason: 'build() mirrors a stored row like loadCookieFromStorage',
      );
      expect(await uids(), [1001, 1002]);
    });

    test('control: without a deletion the same Set-Cookie is saved into the row', () async {
      await global.write('.domains', '{"$baseHost":{"/":{"Ystv_2132_auth":"fresh-alice-token"}}}');
      expect(storage.getCookieByUidSync(1000)!.values.join(), contains('fresh-alice-token'));
      expect(await uids(), [1000, 1001, 1002]);
    });
  });

  group('a deleted account does not come back', () {
    test('through a Set-Cookie received by a client loaded from its row', () async {
      // The per-account client of auto check-in: an empty provider loaded from storage.
      final cookie = getIt.get<CookieProvider>(instanceName: ServiceKeys.empty);
      expect(await cookie.loadCookieFromStorage(_bob), isTrue);
      final adapter = _FakeAdapter(setCookie: 'Ystv_2132_auth=fresh-bob-token; Path=/');
      final client = NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
        cookie: cookie,
      );

      // The user removes Bob while the request is on its way.
      expect(await storage.deleteCookieByUid(1001), isTrue);
      final result = await client.get('$baseUrl/plugin.php?id=dsu_paulsign:sign').run();
      expect(result.isRight(), isTrue, reason: '$result');

      expect(await uids(), [1000, 1002], reason: 'the Set-Cookie must not recreate the row');
      expect(storage.getCookieByUidSync(1001), isNull);
      expect(
        await cookie.read(baseHost),
        contains('fresh-bob-token'),
        reason: 'the Set-Cookie did reach the provider and stays in memory; only the row is not written',
      );
    });

    test('control: without a deletion the same Set-Cookie is saved into the row', () async {
      final cookie = getIt.get<CookieProvider>(instanceName: ServiceKeys.empty);
      expect(await cookie.loadCookieFromStorage(_bob), isTrue);
      final adapter = _FakeAdapter(setCookie: 'Ystv_2132_auth=fresh-bob-token; Path=/');
      final client = NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
        cookie: cookie,
      );
      expect((await client.get('$baseUrl/forum.php').run()).isRight(), isTrue);
      expect(storage.getCookieByUidSync(1001)!.values.join(), contains('fresh-bob-token'));
      expect(await uids(), [1000, 1001, 1002]);
    });

    test('but a provider that got its identity from a login still creates its row', () async {
      final cookie = getIt.get<CookieProvider>(instanceName: ServiceKeys.empty);
      const dave = UserLoginInfo(username: 'Dave', uid: 1003);
      await cookie.write('.domains', '{"Dave":1}');
      await cookie.updateUserInfo(dave);
      await cookie.write('.index', 'Ystv_2132_auth=dave-token');
      expect(await uids(), contains(1003));
    });
  });

  group('manage accounts page', () {
    late AuthenticationRepository auth;
    late AutoCheckinBloc checkin;

    setUp(() {
      getIt.registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
      auth = AuthenticationRepository(user: _alice);
      checkin = AutoCheckinBloc(
        autoCheckinRepository: AutoCheckinRepository(storageProvider: storage),
        settingsRepository: settings,
        storageProvider: storage,
      );
    });

    tearDown(() async {
      await checkin.close();
      await auth.dispose();
      await getIt.get<ImageCacheProvider>().dispose();
    });

    Widget host() => TranslationProvider(
      child: RepositoryProvider<AuthenticationRepository>.value(
        value: auth,
        child: BlocProvider<AutoCheckinBloc>.value(
          value: checkin,
          // The sync-all button in the app bar reads this cubit; a fresh, idle one is enough here.
          child: BlocProvider<NotificationSyncAllCubit>(
            create: (_) => NotificationSyncAllCubit(
              repository: NotificationSyncAllRepository(
                storageProvider: storage,
                notificationRepository: NotificationRepository(),
              ),
              storageProvider: storage,
              authenticationRepository: auth,
              infoRepository: NotificationInfoRepository(),
            ),
            child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: const ManageAccountPage()),
          ),
        ),
      ),
    );

    /// Pumps with real async so the drift stream can deliver, until [finder] finds something or 1 s passed.
    Future<void> settle(WidgetTester tester, Finder finder) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
    }

    /// Disposes the tree and lets the stream close timers and the snack bar timer fire before the framework checks
    /// for pending timers.
    Future<void> dispose(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }

    testWidgets('long press selects, tap adds, delete asks and removes the rows', (tester) async {
      await tester.pumpWidget(host());
      await settle(tester, find.text('Alice'));
      expect(find.text('Carol'), findsOneWidget);
      expect(find.text('Manage account'), findsOneWidget);
      expect(find.text('Not checked in today'), findsNWidgets(3));

      await tester.longPress(find.text('Bob'));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsOneWidget);

      // Alice is the current account: the confirmation warns that this device signs out.
      await tester.tap(find.text('Alice'));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNWidgets(2));

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('Delete 2 account(s)'), findsOneWidget);
      expect(find.textContaining('signed out'), findsOneWidget);

      await tester.tap(find.text('Ok'));
      await tester.pump();
      await settle(tester, find.text('Deleted 2 account(s)'));
      // Let the dialog finish closing.
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Deleted 2 account(s)'), findsOneWidget);
      expect(find.text('Alice'), findsNothing);
      expect(find.text('Bob'), findsNothing);
      expect(find.text('Carol'), findsOneWidget);
      expect(find.text('Manage account'), findsOneWidget, reason: 'selection mode is left');
      expect(find.text('Online'), findsNothing, reason: 'the current account was removed');
      expect(await uids(), [1002]);
      expect(auth.currentUser, isNull);
      await dispose(tester);
    });

    testWidgets('the app bar action enters selection, select all counts every row, close and back leave it', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await settle(tester, find.text('Alice'));

      await tester.tap(find.byIcon(Icons.checklist_outlined));
      await tester.pump();
      expect(find.text('0 selected'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.select_all_outlined));
      await tester.pump();
      expect(find.text('3 selected'), findsOneWidget);

      // A tap on a selected row unselects it.
      await tester.tap(find.text('Carol'));
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.text('Manage account'), findsOneWidget);

      await tester.longPress(find.text('Carol'));
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('Manage account'), findsOneWidget, reason: 'back leaves selection mode instead of the page');
      expect(await uids(), [1000, 1001, 1002], reason: 'nothing was deleted');
      await dispose(tester);
    });

    testWidgets('the account of an expired session shows as online and is removed for good', (tester) async {
      // Expired-session start: the global provider still holds Alice, the repository has no verified user.
      await auth.dispose();
      auth = AuthenticationRepository();
      await getIt.unregister<CookieProvider>();
      getIt.registerSingleton<CookieProvider>(CookieProvider.build());

      await tester.pumpWidget(host());
      await settle(tester, find.text('Alice'));
      expect(find.text('Online'), findsOneWidget, reason: 'the account in use is current, verified or not');

      await tester.longPress(find.text('Alice'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.textContaining('signed out'), findsOneWidget, reason: 'removing it signs this device out');
      await tester.tap(find.text('Ok'));
      await tester.pump();
      await settle(tester, find.text('Deleted 1 account(s)'));
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsNothing);
      expect(find.text('Online'), findsNothing);
      expect(await uids(), [1001, 1002]);
      expect(await settings.getValue<int>(SettingsKeys.loginUid), SettingsKeys.loginUid.defaultValue);

      // The next answer of the global client carries a Set-Cookie: the row must stay gone.
      await getIt.get<CookieProvider>().write('.domains', '{"$baseHost":{"/":{"Ystv_2132_auth":"alice"}}}');
      expect(await uids(), [1001, 1002], reason: 'the account used to come back with the next Set-Cookie');
      await dispose(tester);
    });
  });
}
