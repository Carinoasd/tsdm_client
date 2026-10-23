/// Reading progress round (UX audit items 1 and 2), where the reading stopped:
///
/// * the thread page keeps the floor at its top once the list stays still and when it is left; the start of the thread
///   is kept as "the start" (nothing to go on with);
/// * opened from a list, a thread read past its first screen offers to go on ("上次看到第 N 樓・繼續", closable), opens
///   there right away with the setting, or from the start with the other one; not for a page or floor asked for;
/// * "跳到樓層…" asks a floor, loads its page and brings it to the top;
/// * the lists dim the threads read before and tell the replies posted since ("+N"); the visit history tells how far
///   the reading went;
/// * the setting "打開看過的貼文時".
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/widgets/guide_section.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/reading_progress/cubit/reading_progress_cubit.dart';
import 'package:tsdm_client/features/reading_progress/models/reading_progress.dart';
import 'package:tsdm_client/features/reading_progress/repository/reading_progress_store.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/widgets/select_thread_open_position_dialog.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/features/thread_visit_history/widgets/thread_visit_history_card.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/thread_open_position.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/list_app_bar/menu_item_id.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 31);
const _tid = 1264975;

/// The forum: thread pages of 10 floors (3 pages, 29 replies) as web pages; records the pages asked.
final class _Forum implements HttpClientAdapter {
  final pages = <int>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final page = int.tryParse(options.uri.queryParameters['page'] ?? '') ?? 1;
    pages.add(page);
    return ResponseBody.fromString(
      _threadPage(page),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Every image request fails at once.
final class _NoImages implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

final class _Notifications extends Fake implements NotificationBloc {
  @override
  void add(NotificationEvent event) {}

  @override
  NotificationState get state => const NotificationState(status: NotificationStatus.success);

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

int _pidOf(int floor) => 9700000 + floor;

String _floor(int floor) {
  final pid = _pidOf(floor);
  return '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1000" class="xi2">Bob</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor text<br />${'line<br />' * 6}
</div></div></div></td>
</tr></tbody></table></div>''';
}

/// Page [page] of 3, 10 floors each (the last one 10 too: 30 floors, 29 replies).
String _threadPage(int page) {
  final pager =
      '<div class="pg">${[
        for (var i = 1; i <= 3; i++) i == page ? '<strong>$i</strong>' : '<a href="forum.php?mod=viewthread&tid=$_tid&page=$i">$i</a>',
      ].join()}<label><input type="text" name="custompage"/><span title="共 3 页"> / 3 页</span></label></div>';
  return '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=$_tid" /></head><body>
$pager
<div id="postlist"><table><tr><td><span class="xi1">100</span><span class="xi1">29</span></td></tr></table>
<h1 class="ts"><span id="thread_subject">Thread title</span></h1><div class="bm">
${[for (var f = (page - 1) * 10 + 1; f <= page * 10; f++) _floor(f)].join('\n')}
</div></div>
</body></html>''';
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late _Forum forum;
  late MemoryReadingProgressStore store;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });

  setUp(() async {
    TsdmAppApi.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    forum = _Forum();
    store = MemoryReadingProgressStore();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _NoImages())),
      );
    await settings.init();
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    ThreadAuthorCache.clear();
  });

  tearDown(() async {
    await settingsBloc.close();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// Let the requests (real futures) and the frames they cause finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The thread page as a list opens it (no page, no floor), under the providers of the app.
  Future<ReadingProgressCubit> pumpThread(
    WidgetTester tester, {
    String pageNumber = '1',
    String? findPostID,
    UserLoginInfo? user = _alice,
  }) async {
    final auth = AuthenticationRepository(user: user);
    final blocks = UserBlockRepository(storage);
    final info = NotificationInfoRepository();
    final counts = NotificationStateCubit(info);
    final cubit = UserBlockCubit(repository: blocks, currentUid: () => user?.uid, authStatus: auth.status);
    final progress = ReadingProgressCubit(store: store, uid: user?.uid);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('the list')),
          routes: [
            GoRoute(
              path: 'thread',
              builder: (_, _) => ThreadPage(
                threadID: findPostID == null ? '$_tid' : null,
                findPostID: findPostID,
                pageNumber: pageNumber,
                overrideReverseOrder: true,
                overrideWithExactOrder: null,
              ),
            ),
          ],
        ),
      ],
    );
    addTearDown(() async {
      router.dispose();
      await cubit.close();
      await progress.close();
      await info.dispose();
      await counts.close();
      await blocks.dispose();
      await auth.dispose();
    });
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpWidget(
      TranslationProvider(
        child: RepositoryProvider<AuthenticationRepository>.value(
          value: auth,
          child: MultiRepositoryProvider(
            providers: [RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository())],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<UserBlockCubit>.value(value: cubit),
                BlocProvider<NotificationBloc>.value(value: _Notifications()),
                BlocProvider<NotificationStateCubit>.value(value: counts),
                BlocProvider<ReadingProgressCubit>.value(value: progress),
              ],
              child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
            ),
          ),
        ),
      ),
    );
    unawaited(router.push('/thread'));
    await settle(tester);
    return progress;
  }

  Future<void> leave(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
  }

  Finder floorText(int floor) => find.textContaining('floor $floor text');

  double topOfFloor(WidgetTester tester, int floor) {
    final viewport = tester.getTopLeft(find.byType(PostList)).dy;
    return tester.getTopLeft(floorText(floor)).dy - viewport;
  }

  Future<void> remember(int floor, {int page = 3}) =>
      store.save(_alice.uid!, _tid, ReadingProgress(page: page, pid: _pidOf(floor), floor: floor, seenReplies: 29));

  group('where the reading stopped', () {
    testWidgets('is kept once the list stays still and when the page is left; the start is "the start"', (
      tester,
    ) async {
      final progress = await pumpThread(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(progress.state.of(_tid), const ReadingProgress(page: 1, floor: 1, seenReplies: 29));

      await tester.drag(find.byType(PostList), const Offset(0, -1400));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(seconds: 2));
      final kept = progress.state.of(_tid)!;
      expect(kept.floor, greaterThan(2));
      expect(kept.page, 1);
      expect(kept.pid, _pidOf(kept.floor!));
      expect(kept.pastFirstScreen, isTrue);

      // Scrolled on, then left at once: kept on the way out.
      await tester.drag(find.byType(PostList), const Offset(0, -1400));
      await tester.pump(const Duration(milliseconds: 200));
      await leave(tester);
      expect(progress.state.of(_tid)!.floor, greaterThan(kept.floor!));
    });

    testWidgets('a guest keeps nothing and is offered nothing', (tester) async {
      await remember(25);
      final progress = await pumpThread(tester, user: null);
      expect(find.byKey(const ValueKey('thread-resume-banner')), findsNothing);
      await tester.drag(find.byType(PostList), const Offset(0, -1400));
      await tester.pump(const Duration(seconds: 2));
      expect(progress.state.threads, isEmpty);
      await leave(tester);
    });
  });

  group('opened from a list', () {
    testWidgets('a thread read past its first screen offers to go on; "continue" goes there', (tester) async {
      await remember(25);
      await pumpThread(tester);
      expect(forum.pages, [1]);
      expect(find.text(t.threadPage.resume.message(floor: 25)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('thread-resume-go')));
      await settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(forum.pages, [1, 3]);
      expect(find.byKey(const ValueKey('thread-resume-banner')), findsNothing);
      expect(topOfFloor(tester, 25), lessThan(100));
      await leave(tester);
    });

    testWidgets('the offer closes, and goes away once read on from the start', (tester) async {
      await remember(25);
      await pumpThread(tester);
      await tester.tap(find.byKey(const ValueKey('thread-resume-close')));
      await tester.pump();
      expect(find.byKey(const ValueKey('thread-resume-banner')), findsNothing);
      expect(forum.pages, [1]);
      await leave(tester);

      await remember(25);
      await pumpThread(tester);
      expect(find.byKey(const ValueKey('thread-resume-banner')), findsOneWidget);
      await tester.drag(find.byType(PostList), const Offset(0, -1400));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byKey(const ValueKey('thread-resume-banner')), findsNothing);
      await leave(tester);
    });

    testWidgets('with "continue where I stopped" it opens there; with "from the start" it does not offer', (
      tester,
    ) async {
      await tester.runAsync(
        () => settings.setValue(SettingsKeys.threadOpenPosition, ThreadOpenPosition.resume.index),
      );
      await remember(25);
      await pumpThread(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(forum.pages, [3], reason: 'its page first, page 1 never asked');
      expect(topOfFloor(tester, 25), lessThan(100));
      await leave(tester);

      await tester.runAsync(
        () => settings.setValue(SettingsKeys.threadOpenPosition, ThreadOpenPosition.fromStart.index),
      );
      forum.pages.clear();
      await remember(25);
      await pumpThread(tester);
      expect(forum.pages, [1]);
      expect(find.byKey(const ValueKey('thread-resume-banner')), findsNothing);
      await leave(tester);
    });

    testWidgets('not for a page or a floor asked for, nor for a thread read within its first screen', (tester) async {
      await remember(25);
      await pumpThread(tester, pageNumber: '2');
      expect(find.byKey(const ValueKey('thread-resume-banner')), findsNothing);
      await leave(tester);

      await store.save(_alice.uid!, _tid, const ReadingProgress(page: 1, floor: 1, seenReplies: 29));
      await pumpThread(tester);
      expect(find.byKey(const ValueKey('thread-resume-banner')), findsNothing);
      await leave(tester);
    });
  });

  testWidgets('"go to floor" asks a floor, loads its page and brings it to the top', (tester) async {
    await pumpThread(tester);
    await tester.tap(find.byType(PopupMenuButton<MenuItemId>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.threadPage.jumpToFloor.menu));
    await tester.pumpAndSettle();
    expect(find.text(t.threadPage.jumpToFloor.hint(max: 30)), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('jump-to-floor-field')), '0');
    await tester.tap(find.byKey(const ValueKey('jump-to-floor-go')));
    await tester.pump();
    expect(find.text(t.threadPage.jumpToFloor.invalid), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('jump-to-floor-field')), '24');
    await tester.tap(find.byKey(const ValueKey('jump-to-floor-go')));
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(forum.pages, [1, 3], reason: '10 floors a page, worked out from the full first page');
    expect(topOfFloor(tester, 24), lessThan(100));

    // On screen already: no request.
    await tester.tap(find.byType(PopupMenuButton<MenuItemId>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.threadPage.jumpToFloor.menu));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('jump-to-floor-field')), '28');
    await tester.tap(find.byKey(const ValueKey('jump-to-floor-go')));
    await settle(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(forum.pages, [1, 3]);
    expect(topOfFloor(tester, 28), lessThan(100));
    await leave(tester);
  });

  group('the lists', () {
    Widget host(Widget child, ReadingProgressCubit cubit) => TranslationProvider(
      child: BlocProvider<SettingsBloc>.value(
        value: settingsBloc,
        child: BlocProvider<ReadingProgressCubit>.value(
          value: cubit,
          child: MaterialApp(
            home: Scaffold(body: ListView(children: [child])),
          ),
        ),
      ),
    );

    NormalThread thread(int tid, int replies) => NormalThread(
      title: 'thread $tid',
      url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
      threadID: '$tid',
      author: const User(name: 'a', url: ''),
      publishDate: null,
      latestReplyAuthor: const User(name: 'a', url: ''),
      latestReplyTime: null,
      iconUrl: '',
      threadType: null,
      replyCount: replies,
      viewCount: 0,
      price: null,
      css: null,
      stateSet: const {},
      privilege: null,
      isRecentThread: false,
    );

    double alphaOf(WidgetTester tester, String text) => tester.widget<Text>(find.text(text)).style!.color!.a;

    testWidgets('a thread read before is dimmed; the replies posted since are told', (tester) async {
      await store.save(_alice.uid!, 7, const ReadingProgress(page: 1, floor: 1, seenReplies: 10));
      final cubit = ReadingProgressCubit(store: store, uid: _alice.uid);
      addTearDown(cubit.close);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pumpWidget(
        host(Column(children: [NormalThreadCard(thread(7, 13)), NormalThreadCard(thread(8, 13))]), cubit),
      );
      await tester.pump();
      expect(alphaOf(tester, 'thread 7'), closeTo(visitedTitleOpacity, 0.01));
      expect(alphaOf(tester, 'thread 8'), 1);
      expect(find.byKey(const ValueKey('thread-card-new-replies')), findsOneWidget);
      expect(find.textContaining('+3'), findsOneWidget);

      // Read again: nothing new.
      await tester.runAsync(
        () =>
            cubit.save(uid: _alice.uid!, tid: 7, progress: const ReadingProgress(page: 2, floor: 14, seenReplies: 13)),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('thread-card-new-replies')), findsNothing);
    });

    testWidgets('the guide dims what was read; the history tells how far', (tester) async {
      await store.save(_alice.uid!, 7, const ReadingProgress(page: 2, pid: 9, floor: 14, seenReplies: 13));
      final cubit = ReadingProgressCubit(store: store, uid: _alice.uid);
      addTearDown(cubit.close);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      const items = [
        GuideItem(tid: '7', title: 'guide 7', url: ''),
        GuideItem(tid: '8', title: 'guide 8', url: ''),
      ];
      await tester.pumpWidget(
        host(const GuideModuleList(GuideModule(title: 'hot', view: 'hot', moreUrl: '', items: items)), cubit),
      );
      await tester.pump();
      expect(alphaOf(tester, 'guide 7'), closeTo(visitedTitleOpacity, 0.01));
      expect(alphaOf(tester, 'guide 8'), 1);

      ThreadVisitHistoryModel record(int uid) => ThreadVisitHistoryModel(
        uid: uid,
        username: 'Alice',
        threadId: 7,
        threadTitle: 'thread 7',
        forumId: 2,
        forumName: 'forum',
        visitTime: DateTime(2026, 10, 23),
      );
      await tester.pumpWidget(host(ThreadVisitHistoryCard(record(_alice.uid!)), cubit));
      await tester.pump();
      expect(find.text(t.threadVisitHistoryPage.readTo(floor: 14)), findsOneWidget);
      // Another account's record: its progress is the one recorded with it, not the current one's.
      await tester.pumpWidget(host(ThreadVisitHistoryCard(record(99)), cubit));
      await tester.pump();
      expect(find.byKey(const ValueKey('visit-history-read-to')), findsNothing);
      final other = ThreadVisitHistoryModel(
        uid: 99,
        username: 'Bob',
        threadId: 7,
        threadTitle: 'thread 7',
        forumId: 2,
        forumName: 'forum',
        visitTime: DateTime(2026, 10, 23),
        lastFloor: 33,
        lastPage: 4,
      );
      await tester.pumpWidget(host(ThreadVisitHistoryCard(other), cubit));
      await tester.pump();
      expect(find.text(t.threadVisitHistoryPage.readTo(floor: 33)), findsOneWidget);
    });
  });

  group('kept with the visit records (schema 17)', () {
    Future<void> visit(int uid, int tid) => storage.updateThreadVisitHistory(
      uid: uid,
      tid: tid,
      fid: 2,
      username: 'Alice',
      threadTitle: 'thread $tid',
      forumName: 'forum',
      visitTime: DateTime(2026, 10, 23),
    );

    test('written on the visit, watched, kept when the visit is recorded again, gone with it', () async {
      final db = StorageReadingProgressStore(storage);
      final seen = <Map<int, ReadingProgress>>[];
      final sub = db.watch(31).listen(seen.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(seen.last, isEmpty);

      // No visit recorded: nothing to write the progress on.
      await db.save(31, 7, const ReadingProgress(page: 2, pid: 9, floor: 14, seenReplies: 13));
      await pumpEventQueue();
      expect(seen.last, isEmpty);

      await visit(31, 7);
      await pumpEventQueue();
      expect(seen.last, {7: const ReadingProgress()}, reason: 'visited, where it stopped not known yet');
      await db.save(31, 7, const ReadingProgress(page: 2, pid: 9, floor: 14, seenReplies: 13));
      await pumpEventQueue();
      expect(seen.last, {7: const ReadingProgress(page: 2, pid: 9, floor: 14, seenReplies: 13)});

      // The thread page records the visit again at every load: the progress stays.
      await visit(31, 7);
      await pumpEventQueue();
      expect(seen.last[7], const ReadingProgress(page: 2, pid: 9, floor: 14, seenReplies: 13));

      // Another account keeps its own.
      await visit(32, 7);
      await pumpEventQueue();
      expect(seen.last.length, 1);

      await storage.deleteThreadVisitHistory(uid: 31, tid: 7);
      await pumpEventQueue();
      expect(seen.last, isEmpty, reason: 'the history cleared, the thread is not read any more');
    });
  });

  testWidgets('the setting: from the start, ask, or continue where I stopped', (tester) async {
    expect(settings.currentSettings.openPosition, ThreadOpenPosition.ask);
    ThreadOpenPosition? picked;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => picked = await showSelectThreadOpenPosition(context, ThreadOpenPosition.ask),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(t.settingsPage.behaviorSection.threadOpenPosition.fromStart), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('thread-open-position-resume')));
    await tester.pumpAndSettle();
    expect(picked, ThreadOpenPosition.resume);
    expect(ThreadOpenPosition.fromIndex(9), ThreadOpenPosition.ask);
    expect(jsonEncode(SettingsKeys.threadOpenPosition.defaultValue), '1');
  });
}
