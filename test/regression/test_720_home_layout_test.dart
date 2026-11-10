/// The homepage blocks can be hidden and moved (settings, appearance, home layout).
///
/// 1. `HomeBlockLayout`: the stored string, tolerant reading, moving, hiding, the default is the empty string;
/// 2. the setting travels with the cross-device sync and sits in the backup map;
/// 3. the layout page: a switch and a handle per block, reset;
/// 4. the homepage follows the setting: order, hidden blocks, and a hidden guide is not asked for.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/homepage/models/home_block.dart';
import 'package:tsdm_client/features/homepage/repository/guide_feed.dart';
import 'package:tsdm_client/features/homepage/view/homepage_page.dart';
import 'package:tsdm_client/features/homepage/widgets/guide_section.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/home_layout_page.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/saved_answer_store.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';

const _dir = 'test/data/tsdmapp';

/// A fixture answer, its member renamed ([_neutral]).
Map<String, dynamic> _json(String name) =>
    _neutral(jsonDecode(File('$_dir/$name').readAsStringSync()))! as Map<String, dynamic>;

/// speak of a neutral account.
final _fixtureMember =
    (jsonDecode(File('$_dir/index_v5_member.json').readAsStringSync()) as Map<String, dynamic>)['user']
        as Map<String, dynamic>;
final _fixtureUid = _fixtureMember['uid'] as int;
final _fixtureName = _fixtureMember['username'] as String;

/// [value] with the member of the fixtures replaced by Alice (uid 4242).
Object? _neutral(Object? value) => switch (value) {
  final Map<String, dynamic> m => {
    for (final MapEntry(:key, value: v) in m.entries)
      key: (key == 'uid' || key == 'authorid') && '$v' == '$_fixtureUid' ? (v is String ? '4242' : 4242) : _neutral(v),
  },
  final List<dynamic> l => [for (final e in l) _neutral(e)],
  final String s => s.replaceAll(_fixtureName, 'alice').replaceAll(RegExp('uid=$_fixtureUid\\b'), 'uid=4242'),
  _ => value,
};

/// The homepage answer of the member (Alice, uid 4242), lean, with [changes] on top.
Map<String, dynamic> _index([Map<String, Object?> changes = const {}]) => {
  ...(_json('index_v5_member.json')..remove('document')),
  ...changes,
};

const _alice = UserLoginInfo(uid: 4242, username: 'alice');

/// The forum: the homepage ([index], held while [hold] is pending, failing while [offline]), the guide, the profile
/// of the member.
final class _Forum implements HttpClientAdapter {
  Map<String, dynamic> Function() index = _index;
  Completer<void>? hold;
  bool offline = false;
  final requests = <Uri>[];

  Iterable<Uri> get homepage =>
      requests.where((e) => e.pathSegments.lastOrNull == 'forum.php' && e.queryParameters['mod'] == null);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add(uri);
    final q = uri.queryParameters;
    final isHome = uri.pathSegments.lastOrNull == 'forum.php' && q['mod'] == null;
    if (isHome && hold != null) {
      await hold!.future;
    }
    if (offline) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    final body = switch (uri.pathSegments.lastOrNull) {
      'forum.php' when q['mod'] == 'guide' => _json('guide_v7_index.json'),
      'forum.php' when q['mod'] == null => index(),
      'home.php' when q['mod'] == 'space' => _json('profile_v4_self.json'),
      _ => '',
    };
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [if (body is String) 'text/html; charset=utf-8' else 'application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Authentication with the current account the test sets: a page served to an account verifies it.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  @override
  int identityEpoch = 0;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  AuthStatus? get latestStatus => null;

  @override
  int? get effectiveCurrentUid => currentUser?.uid;

  @override
  UserLoginInfo? get effectiveCurrentUser => currentUser;

  @override
  AsyncVoidEither loginWithServedUser(UserLoginInfo? user, {required bool guest, int? fetchedAs, int? epoch}) =>
      AsyncVoidEither(() async {
        currentUser = guest ? null : user;
        return rightVoid();
      });

  Future<void> close() => _controller.close();
}

/// Notification bloc that only records the events (the homepage asks for an update once the fresh page shows).
final class _Notifications extends Fake implements NotificationBloc {
  final events = <NotificationEvent>[];
  final _controller = StreamController<NotificationState>.broadcast(sync: true);

  @override
  NotificationState get state => const NotificationState(status: NotificationStatus.success);

  @override
  Stream<NotificationState> get stream => _controller.stream;

  @override
  void add(NotificationEvent event) => events.add(event);

  @override
  bool get isClosed => false;

  @override
  Future<void> close() => _controller.close();
}

/// Images are not part of these tests.
final class _NoImages implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('1. the layout string', () {
    test('the default is the empty string, every block shown in order', () {
      final layout = HomeBlockLayout.parse('');
      expect(layout.isDefault, isTrue);
      expect(layout.encode(), '');
      expect(layout.visible, HomeBlock.values);
      expect(HomeBlockLayout.defaults.encode(), '');
    });

    test('moving, hiding and reading it back', () {
      var layout = HomeBlockLayout.defaults.moved(0, HomeBlock.values.length);
      expect(layout.order.last, HomeBlock.greeting);
      layout = layout.withVisible(HomeBlock.guide, visible: false);
      expect(layout.isVisible(HomeBlock.guide), isFalse);
      expect(layout.visible, isNot(contains(HomeBlock.guide)));
      expect(layout.isDefault, isFalse);
      final again = HomeBlockLayout.parse(layout.encode());
      expect(again.order, layout.order);
      expect(again.visible, layout.visible);
      expect(layout.encode(), contains('!guide'));
      // Back to the default: the empty string again.
      expect(
        HomeBlockLayout.parse(
          layout.encode(),
        ).withVisible(HomeBlock.guide, visible: true).moved(HomeBlock.values.length - 1, 0).encode(),
        '',
      );
    });

    test('reading is tolerant: unknown and repeated ids dropped, missing blocks follow, shown', () {
      final layout = HomeBlockLayout.parse('tools, nonsense,!support,tools,,!');
      expect(layout.order.take(2), [HomeBlock.tools, HomeBlock.support]);
      expect(layout.order.toSet(), HomeBlock.values.toSet());
      expect(layout.order.length, HomeBlock.values.length);
      expect(layout.isVisible(HomeBlock.support), isFalse);
      expect(layout.isVisible(HomeBlock.tools), isTrue);
      expect(layout.isVisible(HomeBlock.guide), isTrue, reason: 'missing: shown');
    });

    test('a move to the same place or out of range changes nothing', () {
      const layout = HomeBlockLayout.defaults;
      expect(layout.moved(2, 2).order, layout.order);
      expect(layout.moved(2, 3).order, layout.order, reason: 'dropped right after itself');
      expect(layout.moved(9, 0).order, layout.order);
    });
  });

  group('2. the sync and the backup', () {
    test('the setting is carried by the sync, its default is the empty string', () async {
      expect(syncedSettings.map((e) => e.key), contains(SettingsKeys.homeLayout));
      expect(syncedSettingsDefaults()['homeLayout'], '');
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final repository = SettingsRepository(StorageProvider(db, {}, {}));
      await repository.init();
      addTearDown(repository.dispose);
      expect(syncedSettingsValues(repository.currentSettings)['homeLayout'], '');

      // A document from another device is applied at once, and stored.
      final changes = syncedSettingsChanges({'homeLayout': 'tools,!guide', 'other': 1}, repository.currentSettings);
      expect(changes, [(SettingsKeys.homeLayout, 'tools,!guide')]);
      await repository.setMixedValues(changes);
      expect(repository.currentSettings.homeLayout, 'tools,!guide');
      expect(syncedSettingsValues(repository.currentSettings)['homeLayout'], 'tools,!guide');
      expect(syncedSettingsChanges({'homeLayout': 3}, repository.currentSettings), isEmpty, reason: 'not a string');
      expect(
        syncedSettingsChanges({'homeLayout': ''}, repository.currentSettings),
        [(SettingsKeys.homeLayout, '')],
        reason: 'reset on the other device',
      );
    });
  });

  group('3. the layout page', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      settings = SettingsRepository(StorageProvider(db, {}, {}));
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });
    tearDown(() async {
      await settingsBloc.close();
      await settings.dispose();
      await db.close();
    });

    testWidgets('a switch per block hides it, the handle moves it, reset brings the default back', (tester) async {
      tester.view
        ..physicalSize = const Size(420, 1200)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: BlocProvider<SettingsBloc>.value(
            value: settingsBloc,
            child: MaterialApp.router(
              routerConfig: GoRouter(
                routes: [GoRoute(path: '/', builder: (_, _) => const SettingsHomeLayoutPage())],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> settle() async {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
      }

      final tr = t.settingsPage.appearanceSection.homeLayout;
      for (final block in HomeBlock.values) {
        expect(find.byKey(ValueKey('home-layout-switch-${block.id}')), findsOneWidget);
      }
      expect(find.text(tr.guide), findsOneWidget);
      final reset = find.byKey(const ValueKey('home-layout-reset'));
      expect(tester.widget<IconButton>(reset).onPressed, isNull, reason: 'nothing to reset');

      await tester.tap(find.byKey(const ValueKey('home-layout-switch-guide')));
      await settle();
      expect(settings.currentSettings.homeLayout, contains('!guide'));
      expect(tester.widget<Switch>(find.byKey(const ValueKey('home-layout-switch-guide'))).value, isFalse);
      expect(tester.widget<IconButton>(reset).onPressed, isNotNull);

      // Drag the first block (greeting) below the second.
      final handle = find.byKey(const ValueKey('home-layout-handle-greeting'));
      final gesture = await tester.startGesture(tester.getCenter(handle));
      await tester.pump(const Duration(milliseconds: 50));
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(0, 20));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      await settle();
      final layout = HomeBlockLayout.parse(settings.currentSettings.homeLayout);
      expect(layout.order.first, HomeBlock.support);
      expect(layout.isVisible(HomeBlock.guide), isFalse, reason: 'hiding kept');

      await tester.tap(reset);
      await settle();
      expect(settings.currentSettings.homeLayout, '');
      expect(tester.widget<IconButton>(reset).onPressed, isNull);
    });
  });

  group('4. the homepage', () {
    late Directory tmp;
    late SavedAnswerStore store;
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;
    late CookieProvider cookie;
    late _Forum forum;
    late _Auth auth;
    late ForumHomeRepository forumHome;
    late GuideFeed guide;
    late UserBlockRepository blocks;
    late NotificationInfoRepository info;
    late NotificationStateCubit counts;
    var open = true;

    setUp(() async {
      TsdmAppApi.reset();
      tmp = Directory.systemTemp.createTempSync('tsdm_home_layout_');
      open = true;
      store = SavedAnswerStore(directory: () async => open ? tmp : throw StateError('over'), now: DateTime.now);
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      cookie = CookieProvider(_alice, {});
      forum = _Forum()..index = () => _index({'slides': <Object?>[]});
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<CookieProvider>(cookie)
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
        )
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _NoImages())),
        );
      await settings.init();
      await settings.setValue(SettingsKeys.loginUsername, _alice.username!);
      await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
      auth = _Auth(null);
      forumHome = ForumHomeRepository(savedAnswers: store);
      guide = GuideFeed(savedAnswers: store);
      blocks = UserBlockRepository(storage);
      info = NotificationInfoRepository();
      counts = NotificationStateCubit(info);
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });
    tearDown(() async {
      open = false;
      // Bounded: a test that failed leaves what it waits for pending.
      await Future.wait([forumHome.dailyRewardsDone, store.pendingWrites]).timeout(
        const Duration(seconds: 5),
        onTimeout: () => const [],
      );
      await settingsBloc.close();
      await counts.close();
      await info.dispose();
      await blocks.dispose();
      await forumHome.dispose();
      await auth.close();
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
      tmp.deleteSync(recursive: true);
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> openHomepage(WidgetTester tester, {double width = 384}) async {
      tester.view
        ..physicalSize = Size(width, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final home = HomeCubit();
      final checkin = CheckinBloc(
        checkinRepository: CheckinRepository(storageProvider: storage),
        authenticationRepository: auth,
        settingsRepository: settings,
      );
      final blockCubit = UserBlockCubit(
        repository: blocks,
        currentUid: () => auth.currentUser?.uid,
        authStatus: auth.status,
        retryDelays: const [],
      );
      final notifications = _Notifications();
      addTearDown(() async {
        await notifications.close();
        await blockCubit.close();
        await home.close();
        await checkin.close();
      });
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const HomepagePage())],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<AuthenticationRepository>.value(value: auth),
              RepositoryProvider<NotificationInfoRepository>.value(value: info),
              RepositoryProvider<ForumHomeRepository>.value(value: forumHome),
              RepositoryProvider<GuideFeed>.value(value: guide),
              RepositoryProvider<ProfileRepository>(create: (_) => ProfileRepository()),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<UserBlockCubit>.value(value: blockCubit),
                BlocProvider<NotificationBloc>.value(value: notifications),
                BlocProvider<NotificationStateCubit>.value(value: counts),
                BlocProvider<HomeCubit>.value(value: home),
                BlocProvider<CheckinBloc>.value(value: checkin),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          ),
        ),
      );
      await settle(tester);
    }

    Future<void> drain(WidgetTester tester) async {
      var drained = false;
      unawaited(Future.wait([forumHome.dailyRewardsDone, store.pendingWrites]).then((_) => drained = true));
      for (var i = 0; i < 250 && !drained; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump();
      }
    }

    final byBlock = <HomeBlock, Finder>{
      HomeBlock.greeting: find.byType(HomeGreetingCard),
      HomeBlock.support: find.byType(HomeSupportCard),
      HomeBlock.guide: find.byType(GuideSection),
      HomeBlock.stats: find.byType(HomeForumStatsCard),
      HomeBlock.tools: find.byType(HomeToolsCard),
    };

    /// The blocks on the page, top to bottom.
    List<HomeBlock> shown(WidgetTester tester) {
      final found = <(HomeBlock, double)>[
        for (final MapEntry(:key, :value) in byBlock.entries)
          if (value.evaluate().isNotEmpty) (key, tester.getTopLeft(value).dy),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      return [for (final (block, _) in found) block];
    }

    Iterable<Uri> guideRequests() => forum.requests.where((e) => e.queryParameters['mod'] == 'guide');

    testWidgets('the default arrangement, the guide asked for', (tester) async {
      await openHomepage(tester);
      expect(shown(tester), [
        HomeBlock.greeting,
        HomeBlock.support,
        HomeBlock.guide,
        HomeBlock.stats,
        HomeBlock.tools,
      ]);
      expect(guideRequests(), isNotEmpty);
      expect(tester.takeException(), isNull);
      await drain(tester);
    });

    testWidgets('moved and hidden blocks follow the setting, a hidden guide is not asked for', (tester) async {
      await tester.runAsync(() async {
        await settings.setValue(SettingsKeys.homeLayout, 'tools,!guide,greeting,stats,!support');
        // The bloc of the settings learns of it through the stream.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await openHomepage(tester);
      expect(shown(tester), [HomeBlock.tools, HomeBlock.greeting, HomeBlock.stats]);
      expect(guideRequests(), isEmpty);
      expect(tester.takeException(), isNull);

      // Changed while the page is open (the layout page, or the sync): the page follows, the guide is asked for once
      // it is shown again.
      await tester.runAsync(() => settings.setValue(SettingsKeys.homeLayout, 'support,guide'));
      await settle(tester);
      expect(shown(tester).take(2), [HomeBlock.support, HomeBlock.guide]);
      expect(shown(tester), hasLength(5));
      expect(guideRequests(), isNotEmpty);
      expect(tester.takeException(), isNull);
      await drain(tester);
    });

    testWidgets('every block hidden leaves the page empty without failing', (tester) async {
      await tester.runAsync(() async {
        await settings.setValue(SettingsKeys.homeLayout, HomeBlock.values.map((e) => '!${e.id}').join(','));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await openHomepage(tester);
      expect(shown(tester), isEmpty);
      expect(find.byKey(const ValueKey('success')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await drain(tester);
    });

    /// Restores what [openDesktop] changed; the test calls it before it ends (the binding checks the platform then).
    var desktopDone = () {};

    /// A desktop window [width] wide: the medium and wide arrangements only exist on desktop platforms.
    Future<void> openDesktop(WidgetTester tester, double width) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      // The pinned card of the desktop arrangement overflows in the fonts of the tests; no part of these checks.
      final onError = FlutterError.onError;
      FlutterError.onError = (details) {
        if (!details.exceptionAsString().contains('overflowed')) {
          onError?.call(details);
        }
      };
      desktopDone = () {
        debugDefaultTargetPlatformOverride = null;
        FlutterError.onError = onError;
      };
      await openHomepage(tester, width: width);
    }

    Offset topLeftOf(WidgetTester tester, HomeBlock block) => tester.getTopLeft(byBlock[block]!);

    /// The default order with [blocks] hidden.
    String hidden(List<HomeBlock> blocks) =>
        blocks.fold(HomeBlockLayout.defaults, (layout, block) => layout.withVisible(block, visible: false)).encode();

    Future<void> setLayout(WidgetTester tester, String raw) => tester.runAsync(() async {
      await settings.setValue(SettingsKeys.homeLayout, raw);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    testWidgets('medium: statistics and support side by side, hiding one block moves no other', (tester) async {
      await openDesktop(tester, 800);
      expect(topLeftOf(tester, HomeBlock.stats).dy, topLeftOf(tester, HomeBlock.support).dy);
      expect(topLeftOf(tester, HomeBlock.stats).dx, lessThan(topLeftOf(tester, HomeBlock.support).dx));
      expect(shown(tester).last, HomeBlock.tools);
      final guideAt = topLeftOf(tester, HomeBlock.guide).dy;

      await setLayout(tester, hidden([HomeBlock.tools]));
      await settle(tester);
      expect(byBlock[HomeBlock.tools], findsNothing);
      expect(topLeftOf(tester, HomeBlock.stats).dy, topLeftOf(tester, HomeBlock.support).dy, reason: 'still a pair');
      expect(topLeftOf(tester, HomeBlock.greeting).dy, lessThan(topLeftOf(tester, HomeBlock.stats).dy));
      expect(topLeftOf(tester, HomeBlock.guide).dy, guideAt);
      expect(tester.takeException(), isNull);
      await drain(tester);
      desktopDone();
    });

    testWidgets('medium: moved blocks pair only when next to each other', (tester) async {
      await setLayout(tester, 'greeting,stats,guide,support,tools');
      await openDesktop(tester, 800);
      expect(topLeftOf(tester, HomeBlock.stats).dy, lessThan(topLeftOf(tester, HomeBlock.guide).dy));
      expect(topLeftOf(tester, HomeBlock.support).dy, greaterThan(topLeftOf(tester, HomeBlock.guide).dy));
      expect(tester.takeException(), isNull);
      await drain(tester);
      desktopDone();
    });

    testWidgets('wide: the side column keeps its order when a main block is hidden', (tester) async {
      await openDesktop(tester, 1200);
      final railX = topLeftOf(tester, HomeBlock.stats).dx;
      expect(railX, greaterThan(topLeftOf(tester, HomeBlock.greeting).dx + 400));
      expect(topLeftOf(tester, HomeBlock.stats).dy, lessThan(topLeftOf(tester, HomeBlock.tools).dy));
      expect(topLeftOf(tester, HomeBlock.tools).dy, lessThan(topLeftOf(tester, HomeBlock.support).dy));

      await setLayout(tester, hidden([HomeBlock.guide]));
      await settle(tester);
      expect(byBlock[HomeBlock.guide], findsNothing);
      expect(topLeftOf(tester, HomeBlock.stats).dx, railX);
      expect(topLeftOf(tester, HomeBlock.stats).dy, lessThan(topLeftOf(tester, HomeBlock.tools).dy));
      expect(topLeftOf(tester, HomeBlock.tools).dy, lessThan(topLeftOf(tester, HomeBlock.support).dy));
      expect(tester.takeException(), isNull);

      // Only side blocks left: they take the main column, not the right edge.
      await setLayout(tester, hidden([HomeBlock.greeting, HomeBlock.guide, HomeBlock.pinned, HomeBlock.online]));
      await settle(tester);
      expect(topLeftOf(tester, HomeBlock.stats).dx, lessThan(railX));
      expect(tester.takeException(), isNull);
      await drain(tester);
      desktopDone();
    });
  });
}
