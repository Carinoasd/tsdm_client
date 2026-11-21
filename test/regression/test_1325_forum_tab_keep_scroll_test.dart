import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' show right;
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/forum/bloc/forum_bloc.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_api.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/forum/view/forum_page.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
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
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';

/// GitHub #458: a forum's tab switched away from keeps where it was scrolled to. Scrolled down the thread tab, then the
/// pinned or the sub forum tab opened and the thread tab again: the thread list was back at its top (the tab was built
/// again once the switch was over; a quick switch back, before it was over, kept it). A refresh still opens the tabs
/// not shown at their top, another filter every tab.
///
/// Fake data only (the forum's app API answers built here), no network.
const _fid = 25;

/// Enough threads in each list for it to scroll well past [_scrolled].
const _pinnedCount = 30;
const _normalCount = 60;
const _subforumCount = 30;

const _scrolled = 1200.0;

/// No network in tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// A guest: no moderator check, nothing asked of the network.
final class _Auth extends AuthenticationRepository {
  final _statuses = StreamController<AuthStatus>.broadcast();

  @override
  int? get effectiveCurrentUid => null;

  @override
  Stream<AuthStatus> get status => _statuses.stream;

  @override
  Future<void> dispose() async {
    await _statuses.close();
  }
}

Map<String, dynamic> _row(int tid, {int displayorder = 0}) => {
  'tid': tid,
  'fid': _fid,
  'subject': 'Thread $tid',
  'author': 'Alice',
  'authorid': 1000,
  'dateline': 1700000000,
  'lastpost': 1700000000,
  'lastposter': 'Bob',
  'lastposterid': 1001,
  'replies': 1,
  'views': 10,
  'displayorder': displayorder,
};

/// The forum's only page: [_pinnedCount] pinned threads, [_normalCount] others, [_subforumCount] sub forums.
Map<String, dynamic> _answer() => {
  'ok': 1,
  'api': 1,
  'uid': 0,
  'type': 'forum',
  'schema': 2,
  'page': 1,
  'pages': 1,
  'forum': {'fid': _fid, 'name': 'Forum'},
  'threads': [
    for (var i = 0; i < _pinnedCount; i++) _row(9000 + i, displayorder: 1),
    for (var i = 0; i < _normalCount; i++) _row(100 + i),
  ],
  'subforums': [
    for (var i = 0; i < _subforumCount; i++) {'fid': 500 + i, 'name': 'Sub forum $i'},
  ],
};

final class _Forum implements ForumRepository {
  final asked = <(int, FilterState)>[];

  @override
  AsyncEither<ForumPageData> fetchForum({required String fid, required FilterState filterState, int pageNumber = 1}) {
    asked.add((pageNumber, filterState));
    // Answered a moment later, as over the network: the page shows its loading state meanwhile.
    return AsyncEither(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      return right(forumPageFromApi(_answer(), fid));
    });
  }

  @override
  AsyncEither<ForumGroup?> fetchForumGroup(String gid) => throw UnimplementedError();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  late AppDatabase db;
  late SettingsRepository settings;
  late _Forum forum;

  setUp(() async {
    ModerateRepository.resetModeratorCache();
    forum = _Forum();
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter()),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
    // The list alone, without the detail pane of the wide windows.
    await settings.setValue(SettingsKeys.twoPaneLayout, false);
  });
  tearDown(() async {
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// `pumpAndSettle` never returns while a refresh indicator animates.
  Future<void> pumpFrames(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final auth = _Auth();
    addTearDown(auth.dispose);
    final storage = getIt.get<StorageProvider>();
    final blocks = UserBlockCubit(
      repository: UserBlockRepository(storage),
      currentUid: () => null,
      authStatus: auth.status,
    );
    addTearDown(blocks.close);
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && !blocks.state.isKnown; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const ForumPage(fid: '$_fid'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<ForumRepository>.value(value: forum),
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<FragmentsRepository>(create: (_) => FragmentsRepository()),
            RepositoryProvider<NotificationRepository>(create: (_) => NotificationRepository()),
            RepositoryProvider<NotificationInfoRepository>(create: (_) => NotificationInfoRepository()),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<UserBlockCubit>.value(value: blocks),
              BlocProvider<SettingsBloc>(
                create: (ctx) => SettingsBloc(
                  settingsRepository: settings,
                  fragmentsRepository: RepositoryProvider.of<FragmentsRepository>(ctx),
                ),
              ),
              BlocProvider<NotificationStateCubit>(
                create: (ctx) => NotificationStateCubit(RepositoryProvider.of<NotificationInfoRepository>(ctx)),
              ),
              BlocProvider<NotificationBloc>(
                create: (ctx) => NotificationBloc(
                  notificationRepository: RepositoryProvider.of<NotificationRepository>(ctx),
                  infoRepository: RepositoryProvider.of<NotificationInfoRepository>(ctx),
                  authRepo: auth,
                  storageProvider: getIt.get<StorageProvider>(),
                ),
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      ),
    );
    await pumpFrames(tester);
  }

  /// The scroll controller of the list shown (the thread tab's [CustomScrollView], the other tabs' [ListView]).
  ScrollController threadList(WidgetTester tester) =>
      tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller!;
  ScrollController shownListView(WidgetTester tester) => tester.widget<ListView>(find.byType(ListView)).controller!;

  ForumBloc forumBloc(WidgetTester tester) => BlocProvider.of<ForumBloc>(tester.element(find.byType(TabBarView)));

  /// Open tab [label] and wait until the switch is over: the tab switched away from is off screen by then.
  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.widgetWithText(Tab, label));
    await tester.pumpAndSettle();
  }

  testWidgets('switched to the pinned tab and back: the thread list is where it was', (tester) async {
    await pumpPage(tester);
    threadList(tester).jumpTo(_scrolled);
    await tester.pump();
    expect(find.text('Thread 100'), findsNothing, reason: 'scrolled past the first thread');

    await openTab(tester, '置顶');
    expect(find.byType(CustomScrollView), findsNothing, reason: 'the thread tab is off screen');
    await openTab(tester, '帖子');
    expect(threadList(tester).offset, _scrolled);
    expect(find.text('Thread 100'), findsNothing);
  });

  testWidgets('switched to the sub forum tab and back: the thread list is where it was; so is each tab', (
    tester,
  ) async {
    await pumpPage(tester);
    threadList(tester).jumpTo(_scrolled);
    await tester.pump();

    await openTab(tester, '子版块');
    shownListView(tester).jumpTo(300);
    await tester.pump();
    await openTab(tester, '帖子');
    expect(threadList(tester).offset, _scrolled);

    await openTab(tester, '子版块');
    expect(shownListView(tester).offset, 300);

    // The pinned tab, two tabs away: the switch passes the thread tab, which stays where it was too.
    await openTab(tester, '置顶');
    shownListView(tester).jumpTo(500);
    await tester.pump();
    await openTab(tester, '帖子');
    expect(threadList(tester).offset, _scrolled);
    await openTab(tester, '置顶');
    expect(shownListView(tester).offset, 500);
  });

  testWidgets('a refresh opens the tabs not shown at their top; the tab shown is left as the refresh leaves it', (
    tester,
  ) async {
    await pumpPage(tester);
    threadList(tester).jumpTo(_scrolled);
    await tester.pump();

    await openTab(tester, '置顶');
    shownListView(tester).jumpTo(500);
    await tester.pump();
    forumBloc(tester).add(ForumRefreshRequested());
    await pumpFrames(tester);
    expect(forum.asked, hasLength(2), reason: 'refreshed');
    expect(shownListView(tester).offset, 500);

    await openTab(tester, '帖子');
    expect(threadList(tester).offset, 0);
  });

  testWidgets('another filter opens every tab at its top', (tester) async {
    await pumpPage(tester);
    await openTab(tester, '置顶');
    shownListView(tester).jumpTo(500);
    await tester.pump();
    await openTab(tester, '帖子');
    threadList(tester).jumpTo(_scrolled);
    await tester.pump();
    forumBloc(tester).add(
      const ForumChangeThreadFilterStateRequested(
        FilterState(filter: 'digest', filterDigest: FilterDigest(digest: true)),
      ),
    );
    // The forum's answer is on its way: the page shows the shape of the threads to come, without the tabs.
    await tester.pump();
    expect(find.byType(TabBarView), findsNothing);
    await pumpFrames(tester);
    expect(forum.asked.last.$2.isFiltering(), isTrue);
    expect(threadList(tester).offset, 0);
    await openTab(tester, '置顶');
    expect(shownListView(tester).offset, 0);
  });
}
