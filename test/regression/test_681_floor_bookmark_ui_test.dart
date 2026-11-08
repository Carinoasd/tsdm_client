/// Floor bookmarks on screen:
///
/// * the floor menu bookmarks the floor with an optional one line note (the floor, its page, the start of its text and
///   the thread's title kept); the floor's header then shows the bookmark, and the menu edits or removes it; a hot
///   reply (a copy of a floor) has no bookmark item;
/// * the thread page's list of its bookmarks gives back the one tapped;
/// * "my bookmarks" lists them by thread; a tap opens the floor (`findpost` by its pid), a long press removes it.
///
/// Synthetic data, no real account or forum.
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/floor_bookmark/cubit/floor_bookmark_cubit.dart';
import 'package:tsdm_client/features/floor_bookmark/models/floor_bookmark.dart';
import 'package:tsdm_client/features/floor_bookmark/repository/floor_bookmark_store.dart';
import 'package:tsdm_client/features/floor_bookmark/view/floor_bookmark_page.dart';
import 'package:tsdm_client/features/floor_bookmark/widgets/floor_bookmark_widgets.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
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
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';

const _uid = 31;

Translations get t => LocaleSettings.instance.currentTranslations;

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The thread on screen: its floors as told ([show]), the events asked of it recorded, not run.
final class _ThreadBloc extends ThreadBloc {
  _ThreadBloc()
    : super(
        tid: '9',
        pid: null,
        onlyVisibleUid: null,
        reverseOrder: null,
        exactOrder: null,
        threadRepository: ThreadRepository(),
        currentUid: () => _uid,
      );

  final asked = <ThreadEvent>[];

  @override
  void add(ThreadEvent event) => asked.add(event);

  void show(List<Post> posts) => emit(state.copyWith(status: ThreadStatus.success, postList: posts, title: '测试帖'));
}

Post _floorPost(int floor, {bool hot = false}) => Post(
  postID: '${100 + floor}',
  postFloor: hot ? null : floor,
  hot: hot,
  hotFloor: hot ? floor : null,
  author: const User(name: 'u', url: 'u'),
  publishTime: DateTime(2026, 11, 3),
  data: '第$floor楼的内容<br />第二行',
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: (floor - 1) ~/ 10 + 1,
  isDraft: false,
  packetAllTaken: false,
);

void main() {
  late AppDatabase db;
  late SettingsRepository settingsRepository;
  late SettingsBloc settings;
  late FloorBookmarkStore store;
  late FloorBookmarkCubit cubit;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settingsRepository = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settingsRepository)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settingsRepository.init();
    settings = SettingsBloc(settingsRepository: settingsRepository, fragmentsRepository: FragmentsRepository());
  });

  /// The store and the cubit, made in the test's own zone: their streams deliver within its frames.
  void makeBookmarks() {
    store = FloorBookmarkStore.memory(now: () => DateTime.fromMillisecondsSinceEpoch(1700000000000));
    cubit = FloorBookmarkCubit(store: store, uid: _uid);
    addTearDown(() async {
      await cubit.close();
      await store.dispose();
    });
  }

  tearDown(() async {
    await settings.close();
    await settingsRepository.dispose();
    await getIt.reset();
    await db.close();
  });

  group('the floor', () {
    late _ThreadBloc thread;

    setUp(() => thread = _ThreadBloc());
    tearDown(() => thread.close());

    Future<void> pump(WidgetTester tester, List<Post> posts) async {
      thread.show(posts);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<SettingsBloc>.value(value: settings),
            BlocProvider<ThreadBloc>.value(value: thread),
            BlocProvider<FloorBookmarkCubit>.value(value: cubit),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(child: Column(children: [for (final p in posts) PostCard(p)])),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Finder menuButtons() => find.byWidgetPredicate((w) => w is PopupMenuButton);

    testWidgets('bookmarked with a note from its menu: kept, shown in its header, then removed', (tester) async {
      makeBookmarks();
      final posts = [_floorPost(1), _floorPost(12)];
      await pump(tester, posts);
      expect(find.byKey(const ValueKey('floor-bookmarked-112')), findsNothing);

      await tester.tap(menuButtons().at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.floorBookmark.add));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('floor-bookmark-note')), '  看到这里\n了 ');
      await tester.tap(find.byKey(const ValueKey('floor-bookmark-save')));
      await tester.pumpAndSettle();

      final kept = cubit.state.of(tid: 9, pid: 112)!;
      expect((kept.floor, kept.page, kept.note, kept.threadTitle), (12, 2, '看到这里了', '测试帖'));
      expect(kept.excerpt, '第12楼的内容 第二行');
      expect(find.byKey(const ValueKey('floor-bookmarked-112')), findsOneWidget);
      expect(find.byKey(const ValueKey('floor-bookmarked-101')), findsNothing);

      // The menu now edits it, and removes it.
      await tester.tap(menuButtons().at(1));
      await tester.pumpAndSettle();
      expect(find.text(t.floorBookmark.add), findsNothing);
      await tester.tap(find.text(t.floorBookmark.edit));
      await tester.pumpAndSettle();
      expect(find.text('看到这里了'), findsWidgets, reason: 'the note to edit');
      await tester.tap(find.byKey(const ValueKey('floor-bookmark-remove')));
      await tester.pumpAndSettle();
      expect(cubit.state.items, isEmpty);
      expect(find.byKey(const ValueKey('floor-bookmarked-112')), findsNothing);
      expect((await store.items(_uid)).single.deleted, isTrue, reason: 'kept as the record of its deletion');
      expect(tester.takeException(), isNull);
    });

    testWidgets('cancelled: nothing kept; a hot reply has no bookmark item', (tester) async {
      makeBookmarks();
      await pump(tester, [_floorPost(12, hot: true), _floorPost(3)]);
      await tester.tap(menuButtons().at(0));
      await tester.pumpAndSettle();
      expect(find.text(t.floorBookmark.add), findsNothing);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      await tester.tap(menuButtons().at(1));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.floorBookmark.add));
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.general.cancel));
      await tester.pumpAndSettle();
      expect(cubit.state.items, isEmpty);
      expect(await store.items(_uid), isEmpty);
    });

    testWidgets('shown newest first: no page kept (the one on screen is not the thread page)', (tester) async {
      makeBookmarks();
      thread.emit(thread.state.copyWith(reverseOrder: true));
      await tester.pumpWidget(const SizedBox());
      final posts = [_floorPost(12)];
      thread.emit(thread.state.copyWith(status: ThreadStatus.success, postList: posts, title: '测试帖'));
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<SettingsBloc>.value(value: settings),
            BlocProvider<ThreadBloc>.value(value: thread),
            BlocProvider<FloorBookmarkCubit>.value(value: cubit),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(body: SingleChildScrollView(child: PostCard(posts.single))),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(menuButtons().first);
      await tester.pumpAndSettle();
      await tester.tap(find.text(t.floorBookmark.add));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('floor-bookmark-save')));
      await tester.pumpAndSettle();
      final kept = cubit.state.of(tid: 9, pid: 112)!;
      expect((kept.floor, kept.page, kept.note), (12, null, ''));
    });
  });

  testWidgets("the thread's list gives back the one tapped, in floor order", (tester) async {
    final bookmarks = [
      FloorBookmark(tid: 9, pid: 101, updated: 1, floor: 1, excerpt: '第一楼'),
      FloorBookmark(tid: 9, pid: 130, updated: 2, floor: 30, page: 3, note: '重点', excerpt: '第三十楼'),
    ];
    FloorBookmark? picked;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => picked = await showThreadBookmarksSheet(context, bookmarks),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#30'), findsOneWidget);
    expect(find.text('重点'), findsOneWidget);
    expect(find.text('第三十楼'), findsOneWidget, reason: 'the excerpt under the note');
    await tester.tap(find.byKey(const ValueKey('thread-bookmark-9:130')));
    await tester.pumpAndSettle();
    expect(picked?.key, '9:130');
  });

  group('my bookmarks', () {
    late GoRouter router;
    late List<Map<String, String>> opened;

    Future<void> pump(WidgetTester tester) async {
      opened = [];
      router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const FloorBookmarkPage()),
          GoRoute(
            path: ScreenPaths.threadV1,
            name: ScreenPaths.threadV1,
            builder: (_, state) {
              opened.add(state.uri.queryParameters);
              return const Scaffold(body: Text('thread'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        BlocProvider<FloorBookmarkCubit>.value(
          value: cubit,
          child: TranslationProvider(child: MaterialApp.router(routerConfig: router)),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('none: says so', (tester) async {
      makeBookmarks();
      await pump(tester);
      expect(find.text(t.floorBookmark.empty), findsOneWidget);
    });

    testWidgets('by thread; a tap opens the floor by its pid, a long press removes it', (tester) async {
      makeBookmarks();
      await store.put(_uid, tid: 9, pid: 105, floor: 5, excerpt: '第五楼', threadTitle: '测试帖');
      await store.put(_uid, tid: 8, pid: 201, floor: 1, note: '另一帖的备注', excerpt: '一楼', threadTitle: '另一帖');
      await store.put(_uid, tid: 9, pid: 102, floor: 2, excerpt: '第二楼', threadTitle: '测试帖');
      await pump(tester);
      expect(find.text('测试帖'), findsOneWidget);
      expect(find.text('另一帖'), findsOneWidget);
      expect(find.text('另一帖的备注'), findsOneWidget);
      // Floors of a thread in order.
      expect(
        tester.getTopLeft(find.text('#2')).dy,
        lessThan(tester.getTopLeft(find.text('#5')).dy),
      );

      await tester.tap(find.text('第五楼'));
      await tester.pumpAndSettle();
      expect(opened.single, {'pid': '105', 'appBarTitle': '测试帖'});
      router.pop();
      await tester.pumpAndSettle();

      await tester.longPress(find.text('第二楼'));
      await tester.pumpAndSettle();
      expect(find.text(t.floorBookmark.removeConfirm), findsOneWidget);
      await tester.tap(find.text(t.general.ok));
      await tester.pumpAndSettle();
      expect(find.text('第二楼'), findsNothing);
      expect(cubit.state.items.map((e) => e.key), unorderedEquals(['9:105', '8:201']));
      expect(tester.takeException(), isNull);
    });
  });
}
