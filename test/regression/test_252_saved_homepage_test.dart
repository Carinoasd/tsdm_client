/// The homepage shows at once what it showed last (cold start, UX audit item 5): stale-while-revalidate.
///
/// 1. the answers are kept as a file per account ([SavedAnswerStore]): only ever handed back to the account they were
///    served to, not when older than a day or of another format, and gone with the account;
/// 2. the shared homepage repository saves every structured page for the account it was served to (without its
///    `document`), and forgets an account whose session the forum says is dead;
/// 3. the homepage bloc shows the saved page of the account in use while the page is asked again, then the fresh one;
///    a failed refresh keeps it with a retry, a dead session asks to log in, an account switched to shows its own
///    saved page and never another's; a guest gets the login card at once;
/// 4. the page says it shows the saved page and is updating, or that updating failed, with a retry.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/repository/guide_feed.dart';
import 'package:tsdm_client/features/homepage/view/homepage_page.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
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
import 'package:tsdm_client/widgets/card/error_card.dart';

const _dir = 'test/data/tsdmapp';

/// A fixture answer, its member renamed ([_neutral]).
Map<String, dynamic> _json(String name) =>
    _neutral(jsonDecode(File('$_dir/$name').readAsStringSync()))! as Map<String, dynamic>;

/// The member the fixtures were recorded as (read from them, never named here), renamed by [_neutral]: the tests
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

/// The same page served to another account, Bob (uid 4243).
Map<String, dynamic> _bobIndex() => _index({
  'uid': 4243,
  'user': {...(_index()['user'] as Map<String, dynamic>), 'uid': 4243, 'username': 'Bob'},
});

const _alice = UserLoginInfo(uid: 4242, username: 'alice');
const _bob = UserLoginInfo(uid: 4243, username: 'Bob');

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
  late Directory tmp;
  late DateTime now;
  late SavedAnswerStore store;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });
  setUp(() {
    TsdmAppApi.reset();
    tmp = Directory.systemTemp.createTempSync('tsdm_saved_answers_');
    now = DateTime(2026, 10, 23, 9);
    store = SavedAnswerStore(directory: () async => tmp, now: () => now);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('1. the saved answers', () {
    test('handed back to the account they were served to, the guest apart', () async {
      store
        ..save(SavedAnswerKind.homepage, _index())
        ..save(SavedAnswerKind.homepage, _bobIndex())
        ..save(SavedAnswerKind.homepage, _json('index_v5_guest.json'));
      final alice = await store.load(SavedAnswerKind.homepage, uid: 4242);
      expect(alice?.answer['uid'], 4242);
      expect(alice?.savedAt, now);
      expect((await store.load(SavedAnswerKind.homepage, uid: 4243))?.answer['uid'], 4243);
      expect((await store.load(SavedAnswerKind.homepage, uid: null))?.answer['uid'], 0);
      expect(await store.load(SavedAnswerKind.homepage, uid: 37), isNull);
      expect(await store.load(SavedAnswerKind.guide, uid: 4242), isNull, reason: 'another kind');
    });

    test('a file naming another account than its name is not read', () async {
      store.save(SavedAnswerKind.homepage, _index());
      await store.pendingWrites;
      File('${tmp.path}/homepage_4242.json').renameSync('${tmp.path}/homepage_4243.json');
      expect(await store.load(SavedAnswerKind.homepage, uid: 4243), isNull);
      await store.pendingWrites;
      expect(File('${tmp.path}/homepage_4243.json').existsSync(), isFalse, reason: 'dropped');
    });

    test('older than a day, from the future or of another format: not used, and dropped', () async {
      store.save(SavedAnswerKind.homepage, _index());
      now = now.add(const Duration(days: 1, minutes: 1));
      expect(await store.load(SavedAnswerKind.homepage, uid: 4242), isNull);
      await store.pendingWrites;
      expect(tmp.listSync(), isEmpty);

      store.save(SavedAnswerKind.homepage, _index());
      now = now.subtract(const Duration(hours: 1));
      expect(await store.load(SavedAnswerKind.homepage, uid: 4242), isNull, reason: 'the clock went back');

      final file = File('${tmp.path}/homepage_4242.json')
        ..writeAsStringSync(
          jsonEncode({
            'v': SavedAnswerStore.formatVersion + 1,
            'kind': 'homepage',
            'uid': 4242,
            'savedAt': now.millisecondsSinceEpoch,
            'answer': _index(),
          }),
        );
      expect(await store.load(SavedAnswerKind.homepage, uid: 4242), isNull);
      file.writeAsStringSync('{not json');
      expect(await store.load(SavedAnswerKind.homepage, uid: 4242), isNull);
    });

    test('nothing of the session is kept on disk: no form hash, daily login request or red packet', () async {
      store.save(SavedAnswerKind.homepage, _index({'checknewpm': 'home.php?mod=spacecp&ac=pm&op=checknewpm'}));
      final saved = (await store.load(SavedAnswerKind.homepage, uid: 4242))!.answer;
      expect(saved.keys, isNot(anyOf(contains('formhash'), contains('checknewpm'), contains('red_packet'))));
      expect(File('${tmp.path}/homepage_4242.json').readAsStringSync(), isNot(contains('formhash')));
    });

    test('gone with the account; an answer naming nobody is not saved', () async {
      store
        ..save(SavedAnswerKind.homepage, _index())
        ..save(SavedAnswerKind.guide, _json('guide_v7_index.json'))
        ..save(SavedAnswerKind.homepage, {'ok': 1})
        ..forget(4242);
      await store.pendingWrites;
      expect(tmp.listSync(), isEmpty);
    });

    test('an account removed from the device takes its saved pages along', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final storage = StorageProvider(db, {}, {});
      getIt.registerSingleton<SavedAnswerStore>(store);
      addTearDown(getIt.reset);
      await storage.saveCookie(username: 'alice', uid: 4242, cookie: {});
      store.save(SavedAnswerKind.homepage, _index());
      await store.pendingWrites;
      await storage.deleteCookieByUid(4242);
      await store.pendingWrites;
      expect(await store.load(SavedAnswerKind.homepage, uid: 4242), isNull);
    });
  });

  group('2, 3 and 4. the homepage', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late CookieProvider cookie;
    late _Forum forum;
    late _Auth auth;
    late ForumHomeRepository forumHome;
    late GuideFeed guide;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      cookie = CookieProvider(_alice, {});
      forum = _Forum();
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
    });
    tearDown(() async {
      await forumHome.dispose();
      await auth.close();
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    HomepageBloc homepage() {
      final bloc = HomepageBloc(
        forumHomeRepository: forumHome,
        profileRepository: ProfileRepository(),
        authenticationRepository: auth,
        guideFeed: guide,
      );
      addTearDown(bloc.close);
      return bloc;
    }

    /// The pages saved for Alice by an earlier start, [age] ago ([homepage] of `forum.php`).
    Future<void> savedEarlier({Duration age = const Duration(hours: 3), Map<String, dynamic>? homepage}) async {
      final at = now;
      now = now.subtract(age);
      store
        ..save(SavedAnswerKind.homepage, homepage ?? _index())
        ..save(SavedAnswerKind.guide, _json('guide_v7_index.json'));
      await store.pendingWrites;
      now = at;
    }

    test('2. every structured page is saved for the account it was served to, without its document', () async {
      forum.index = () => _index({'document': '<div>x</div>'});
      await forumHome.fetchHomePage().run();
      await store.pendingWrites;
      final saved = await forumHome.savedPageOf(4242);
      expect(saved?.page.servedUid, 4242);
      expect(saved?.page.json.containsKey('document'), isFalse);
      expect(await forumHome.savedPageOf(4243), isNull);
      expect(await forumHome.savedPageOf(null), isNull);
    });

    test("2. the guest page while an account is in use: that account's session is dead, its pages go", () async {
      await savedEarlier();
      forum.index = () => _json('index_v5_guest.json');
      await forumHome.fetchHomePage().run();
      await store.pendingWrites;
      expect(await forumHome.savedPageOf(4242), isNull);
      expect(await store.load(SavedAnswerKind.guide, uid: 4242), isNull);
      expect(await forumHome.savedPageOf(null), isNotNull, reason: 'what the guest was served');
    });

    test('3. the saved page shows while the page is asked again, then the fresh one', () async {
      await savedEarlier();
      forum
        ..index = (() => _index({
          'stats': {'todayposts': 4242, 'yesterdayposts': 1, 'posts': 2},
        }))
        ..hold = Completer<void>();
      final bloc = homepage();
      final states = <HomepageState>[];
      final sub = bloc.stream.listen(states.add);
      addTearDown(sub.cancel);
      bloc.add(HomepageLoadRequested());
      final saved = await bloc.stream.firstWhere((s) => s.savedAt != null);
      expect(saved.status, HomepageStatus.success);
      expect(saved.savedAt, now.subtract(const Duration(hours: 3)));
      expect(saved.loggedUserInfo?.username, 'alice');
      expect(saved.pinnedThreadGroupList, isNotEmpty);
      expect(saved.dailyRedPacket, isNull, reason: 'nothing to claim from an old page');
      expect(saved.formHash, isNull);
      expect(auth.currentUser, isNull, reason: 'the saved page verifies nothing');
      expect(guide.savedModules, isNotEmpty, reason: 'the guide card shows the saved guide at once');
      // The guide is asked while the homepage is still on its way, not once it arrived.
      for (var i = 0; i < 50 && !forum.requests.any((e) => e.queryParameters['mod'] == 'guide'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(forum.requests.where((e) => e.queryParameters['mod'] == 'guide'), hasLength(1), reason: 'asked along');
      expect(forum.hold!.isCompleted, isFalse);

      forum.hold!.complete();
      final fresh = await bloc.stream.firstWhere((s) => s.status == HomepageStatus.success && s.savedAt == null);
      expect(fresh.forumStatus.todayCount, '4242');
      expect(fresh.dailyRedPacket?.dateFlag, isNotNull);
      expect(auth.currentUser?.uid, 4242);
      expect(states.map((s) => s.status), everyElement(HomepageStatus.success), reason: 'never a spinner');
    });

    test('3. the fresh page failed: the saved one stays with a retry, which asks again', () async {
      await savedEarlier();
      forum.offline = true;
      final bloc = homepage()..add(HomepageLoadRequested());
      final failed = await bloc.stream.firstWhere((s) => s.refreshFailed);
      expect(failed.status, HomepageStatus.success);
      expect(failed.savedAt, isNotNull);

      forum.offline = false;
      bloc.add(HomepageLoadRequested());
      final fresh = await bloc.stream.firstWhere((s) => s.status == HomepageStatus.success && s.savedAt == null);
      expect(fresh.refreshFailed, isFalse);
    });

    test('3. the forum says the session is dead: the login card replaces the saved page', () async {
      await savedEarlier();
      forum.index = () => _json('index_v5_guest.json');
      final bloc = homepage()..add(HomepageLoadRequested());
      final login = await bloc.stream.firstWhere((s) => s.status == HomepageStatus.needLogin);
      expect(login.savedAt, isNull);
      expect(login.loggedUserInfo?.username ?? '', isEmpty);
    });

    test('3. too old, or nothing saved: the page loads as before', () async {
      await savedEarlier(age: const Duration(hours: 25));
      forum.hold = Completer<void>();
      final bloc = homepage()..add(HomepageLoadRequested());
      expect((await bloc.stream.first).status, HomepageStatus.loading);
      forum.hold!.complete();
      await bloc.stream.firstWhere((s) => s.status == HomepageStatus.success);
    });

    test('3. an account switched to shows its own saved page, never the previous one', () async {
      await savedEarlier();
      final bloc = homepage()..add(HomepageLoadRequested());
      await bloc.stream.firstWhere((s) => s.status == HomepageStatus.success && s.savedAt == null);

      // Bob has no saved page: the page loads as before, nothing of Alice's shows.
      await cookie.updateUserInfo(_bob);
      forum
        ..index = _bobIndex
        ..hold = Completer<void>();
      bloc.add(HomepageRefreshRequested(userLoginInfo: _bob));
      final switched = await bloc.stream.first;
      expect(switched.status, HomepageStatus.loading);
      forum.hold!.complete();
      forum.hold = null;
      await bloc.stream.firstWhere((s) => s.status == HomepageStatus.success && s.loggedUserInfo?.username == 'Bob');
      await store.pendingWrites;

      // Back to Alice: her saved page shows at once, then hers fresh.
      await cookie.updateUserInfo(_alice);
      auth.identityEpoch++;
      forum
        ..index = _index
        ..hold = Completer<void>();
      bloc.add(HomepageRefreshRequested(userLoginInfo: _alice));
      final back = await bloc.stream.firstWhere((s) => s.status != HomepageStatus.success || s.savedAt != null);
      expect(back.savedAt, isNotNull);
      expect(back.loggedUserInfo?.username, 'alice');
      forum.hold!.complete();

      // Bob's page was saved for Bob only.
      expect((await forumHome.savedPageOf(4243))?.page.servedUid, 4243);
    });

    test('3. a guest: the login card at once, the page still asked', () async {
      cookie.clearUserInfoAndCookie();
      await settings.setValue(SettingsKeys.loginUid, 0);
      await settings.setValue(SettingsKeys.loginUsername, '');
      forum
        ..index = (() => _json('index_v5_guest.json'))
        ..hold = Completer<void>();
      final bloc = homepage()..add(HomepageLoadRequested());
      expect((await bloc.stream.first).status, HomepageStatus.needLogin);
      forum.hold!.complete();
      for (var i = 0; i < 50 && !forumHome.hasCache(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(forumHome.hasCache(), isTrue, reason: 'the page was asked all the same');
      expect(forum.homepage, hasLength(1));
      expect(forum.requests.where((e) => e.queryParameters['mod'] == 'guide'), isEmpty, reason: 'no guide card');
    });

    group('4. the page', () {
      late UserBlockRepository blocks;
      late NotificationInfoRepository info;
      late NotificationStateCubit counts;
      late SettingsBloc settingsBloc;

      /// The page without its slides: the images of the swiper are no part of these tests.
      Map<String, dynamic> noSlides() => _index({'slides': <Object?>[]});

      setUp(() {
        forum.index = noSlides;
        blocks = UserBlockRepository(storage);
        info = NotificationInfoRepository();
        counts = NotificationStateCubit(info);
        settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      });
      tearDown(() async {
        await settingsBloc.close();
        await counts.close();
        await info.dispose();
        await blocks.dispose();
      });

      Future<void> settle(WidgetTester tester) async {
        for (var i = 0; i < 8; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      Future<void> openHomepage(WidgetTester tester) async {
        tester.view
          ..physicalSize = const Size(384, 792)
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
      }

      testWidgets('says it shows the saved page and is updating, then the fresh page alone', (tester) async {
        await tester.runAsync(() => savedEarlier(homepage: noSlides()));
        forum.hold = Completer<void>();
        await openHomepage(tester);
        await settle(tester);
        expect(find.byKey(const ValueKey('homepage-saved-note')), findsOneWidget);
        expect(find.textContaining('updating'), findsOneWidget);
        expect(tester.takeException(), isNull);

        forum.hold!.complete();
        await settle(tester);
        expect(find.byKey(const ValueKey('homepage-saved-note')), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('updating failed: the saved page stays, with a retry', (tester) async {
        await tester.runAsync(() => savedEarlier(homepage: noSlides()));
        forum.offline = true;
        await openHomepage(tester);
        await settle(tester);
        expect(find.textContaining('Could not update'), findsOneWidget);
        expect(find.byType(ErrorCard), findsNothing, reason: 'no full-page retry over the saved page');
        forum.offline = false;
        await tester.tap(find.widgetWithText(TextButton, context(tester).t.homepage.saved.retry));
        await settle(tester);
        expect(find.byKey(const ValueKey('homepage-saved-note')), findsNothing);
        expect(tester.takeException(), isNull);
      });
    });
  });
}

BuildContext context(WidgetTester tester) => tester.element(find.byType(Scaffold).first);
