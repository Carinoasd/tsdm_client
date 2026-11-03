/// Immersive reading and swiping pages on the thread page:
///
/// * a tap on the floors that nothing in them takes hides the app bar and the reply bar, another one shows them; the
///   floor's own tap (`tapToReply`) stays the floor's; scrolling never brings the hidden app bar back;
/// * with "左右滑动翻页" on, a swipe to the left loads the next page and one to the right the page before (nothing before
///   the first page); off, or scrolling up and down, it does nothing;
/// * with the thread search open the bars stay whatever is tapped or scrolled; the search closed, the bars stay shown
///   and follow the list again; a page swiped to is searched too;
/// * [ThreadReadingGestures]: a swipe across something that scrolls sideways (a table in a floor), from the edge of the
///   screen or with two fingers is no swipe; a button keeps its tap; a tap that stops a fling is no tap.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
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
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread/v1/widgets/collapsing_app_bar.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/features/thread/v1/widgets/reading_gestures.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/thread_floor_interaction_mode.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 31);
const _tid = 1264975;

/// The forum: thread pages of 10 floors (3 pages) as web pages; records the pages asked.
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

String _floor(int floor) {
  final pid = 9700000 + floor;
  return '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1000" class="xi2">Bob</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor text<br />${'line<br />' * 6}
</div></div></div>
<div class="pob"><em><a class="fastre" href="forum.php?mod=post&amp;action=reply&amp;fid=8&amp;tid=$_tid&amp;repquote=$pid">回复</a></em></div>
</td>
</tr></tbody></table></div>''';
}

/// Page [page] of 3, 10 floors each.
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

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('the thread page', () {
    setUp(() async {
      TsdmAppApi.reset();
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      forum = _Forum();
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

    Future<void> pumpThread(WidgetTester tester) async {
      const user = _alice;
      final auth = AuthenticationRepository(user: user);
      final blocks = UserBlockRepository(storage);
      final info = NotificationInfoRepository();
      final counts = NotificationStateCubit(info);
      final cubit = UserBlockCubit(repository: blocks, currentUid: () => user.uid, authStatus: auth.status);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('the list')),
            routes: [
              GoRoute(
                path: 'thread',
                builder: (_, _) => const ThreadPage(
                  threadID: '$_tid',
                  findPostID: null,
                  pageNumber: '1',
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
                ],
                child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
              ),
            ),
          ),
        ),
      );
      unawaited(router.push('/thread'));
      await settle(tester);
    }

    Future<void> leave(WidgetTester tester) async {
      await tester.binding.handlePopRoute();
      await settle(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    }

    Future<void> set<T>(WidgetTester tester, SettingsKeys<T> key, T value) async {
      await tester.runAsync(() => settings.setValue<T>(key, value));
      await tester.pump();
    }

    /// Shown part of the app bar.
    double appBarShown(WidgetTester tester) => tester.widget<CollapsingAppBar>(find.byType(CollapsingAppBar)).shown;

    /// Height of the reply bar (and the banner above it) on screen.
    double bottomBarsHeight(WidgetTester tester) =>
        tester.getSize(find.byKey(const ValueKey('thread-bottom-bars'))).height;

    final listTitle = find.descendant(of: find.byType(PostList), matching: find.text('Thread title'));
    Finder floorText(int floor) => find.textContaining('floor $floor text');

    Future<void> swipe(WidgetTester tester, Offset by) async {
      await tester.drag(find.byType(PostList), by);
      await tester.pump(const Duration(milliseconds: 300));
      await settle(tester);
    }

    group('immersive reading', () {
      testWidgets('a tap on the floors hides the app bar and the reply bar, another one shows them', (tester) async {
        await pumpThread(tester);
        expect(find.byType(ReplyBar), findsOneWidget);
        final bottom = bottomBarsHeight(tester);
        expect(appBarShown(tester), 1);
        expect(bottom, greaterThan(0));

        await tester.tap(listTitle);
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 0);
        expect(bottomBarsHeight(tester), 0);
        expect(find.byType(ReplyBar), findsOneWidget, reason: 'kept built: the reply written stays');

        // The floor's text, not a link: also nothing in the floor takes the tap (menu on a long press).
        await tester.tap(floorText(1));
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 1);
        expect(bottomBarsHeight(tester), bottom);
        await leave(tester);
      });

      testWidgets('the floor tap of "tap to reply" stays the floor\'s', (tester) async {
        await set(tester, SettingsKeys.threadFloorInteractionMode, ThreadFloorInteractionMode.tapToReply);
        await pumpThread(tester);
        await tester.tap(floorText(1));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget, reason: 'the floor took the tap: the editor for it');
        expect(appBarShown(tester), 1);
        expect(bottomBarsHeight(tester), greaterThan(0));
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsNothing);

        // Outside the floors (the title above them) it still hides the bars.
        await tester.tap(listTitle);
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 0);
        await leave(tester);
      });

      testWidgets('scrolling never brings the hidden app bar back; the next tap does', (tester) async {
        await pumpThread(tester);
        await tester.tap(listTitle);
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 0);

        await tester.drag(find.byType(PostList), const Offset(0, -900));
        await tester.pumpAndSettle();
        await tester.drag(find.byType(PostList), const Offset(0, 400));
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 0, reason: 'scrolled up: the bar would show without immersive reading');
        await tester.drag(find.byType(PostList), const Offset(0, 3000));
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 0, reason: 'nor at the top of the list');
        expect(bottomBarsHeight(tester), 0);

        await tester.tap(listTitle);
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 1);

        // Back to following the scrolling.
        await tester.drag(find.byType(PostList), const Offset(0, -900));
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 0);
        await tester.drag(find.byType(PostList), const Offset(0, 300));
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 1);
        await leave(tester);
      });

      testWidgets('replying to a floor shows the bars again', (tester) async {
        await set(tester, SettingsKeys.threadFloorInteractionMode, ThreadFloorInteractionMode.tapToReply);
        await pumpThread(tester);
        await tester.tap(listTitle);
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 0);
        expect(bottomBarsHeight(tester), 0);

        await tester.tap(floorText(1));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget, reason: 'the editor for the floor');
        expect(appBarShown(tester), 1);
        expect(bottomBarsHeight(tester), greaterThan(0));
        await leave(tester);
      });

      testWidgets('no immersive reading while the editor is open', (tester) async {
        await set(tester, SettingsKeys.threadFloorInteractionMode, ThreadFloorInteractionMode.tapToReply);
        await pumpThread(tester);
        await tester.tap(floorText(1));
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);

        await tester.tap(listTitle);
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 1);
        expect(bottomBarsHeight(tester), greaterThan(0));
        await leave(tester);
      });
    });

    group('swiping pages', () {
      testWidgets('off by default: a swipe does nothing', (tester) async {
        expect(settings.currentSettings.threadSwipePaging, isFalse);
        await pumpThread(tester);
        await swipe(tester, const Offset(-250, 0));
        expect(forum.pages, [1]);
        expect(floorText(1), findsOneWidget);
        await leave(tester);
      });

      testWidgets('on: to the left the next page, to the right the one before, nothing before the first', (
        tester,
      ) async {
        await set(tester, SettingsKeys.threadSwipePaging, true);
        await pumpThread(tester);

        await swipe(tester, const Offset(250, 0));
        expect(forum.pages, [1], reason: 'the first page: nothing before it');

        await swipe(tester, const Offset(-250, 0));
        expect(forum.pages, [1, 2]);
        expect(floorText(11), findsOneWidget);
        expect(floorText(1), findsNothing, reason: 'the page replaced, as a jump does');

        await swipe(tester, const Offset(250, 0));
        expect(forum.pages, [1, 2, 1]);
        expect(floorText(1), findsOneWidget);
        await leave(tester);
      });

      testWidgets('on: nothing after the last page', (tester) async {
        await set(tester, SettingsKeys.threadSwipePaging, true);
        await pumpThread(tester);
        await swipe(tester, const Offset(-250, 0));
        await swipe(tester, const Offset(-250, 0));
        expect(forum.pages, [1, 2, 3]);
        expect(floorText(21), findsOneWidget);

        await swipe(tester, const Offset(-250, 0));
        expect(forum.pages, [1, 2, 3]);
        expect(floorText(21), findsOneWidget);
        await leave(tester);
      });

      testWidgets('on: scrolling up and down, or askew, turns no page', (tester) async {
        await set(tester, SettingsKeys.threadSwipePaging, true);
        await pumpThread(tester);
        await swipe(tester, const Offset(0, -300));
        await swipe(tester, const Offset(0, 200));
        await swipe(tester, const Offset(-90, -100));
        await swipe(tester, const Offset(40, 0));
        expect(forum.pages, [1]);
        await leave(tester);
      });
    });

    group('with the thread search', () {
      final searchField = find.byKey(const ValueKey('thread-search-field'));

      Future<void> openSearch(WidgetTester tester) async {
        await tester.tap(find.descendant(of: find.byType(AppBar), matching: find.byIcon(Icons.more_vert)));
        await tester.pump(const Duration(milliseconds: 500));
        await settle(tester);
        await tester.tap(find.text('搜索本帖'));
        await tester.pump(const Duration(milliseconds: 500));
        await settle(tester);
        expect(searchField, findsOneWidget);
      }

      Future<void> closeSearch(WidgetTester tester) async {
        await tester.tap(find.byKey(const ValueKey('thread-search-close')));
        await tester.pumpAndSettle();
        expect(searchField, findsNothing);
      }

      testWidgets('searching, a tap on the floors hides no bar, nor does scrolling', (tester) async {
        await pumpThread(tester);
        final bottom = bottomBarsHeight(tester);
        await openSearch(tester);
        expect(appBarShown(tester), 1);
        expect(bottomBarsHeight(tester), bottom);

        await tester.tap(listTitle);
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 1, reason: 'the search bar cannot be hidden');
        expect(bottomBarsHeight(tester), bottom);
        await tester.tap(floorText(1));
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 1);
        expect(bottomBarsHeight(tester), bottom);

        await tester.drag(find.byType(PostList), const Offset(0, -900));
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 1, reason: 'the search bar stays while the floors are scrolled');
        await leave(tester);
      });

      testWidgets('the search closed, the bars stay and follow the list again; the next tap hides them', (
        tester,
      ) async {
        await pumpThread(tester);
        final bottom = bottomBarsHeight(tester);
        // Immersive reading first; the bars are brought back to reach the menu.
        await tester.tap(listTitle);
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 0);
        await tester.tap(listTitle);
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 1);

        await openSearch(tester);
        await closeSearch(tester);
        expect(appBarShown(tester), 1, reason: 'immersive reading is not taken up again');
        expect(bottomBarsHeight(tester), bottom);

        await tester.drag(find.byType(PostList), const Offset(0, -900));
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 0, reason: 'the bar follows the list, as before the search');
        await tester.drag(find.byType(PostList), const Offset(0, 300));
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 1);

        // Back at the top of the list, where the title is.
        await tester.drag(find.byType(PostList), const Offset(0, 3000));
        await tester.pumpAndSettle();
        await tester.tap(listTitle);
        await tester.pumpAndSettle();
        expect(appBarShown(tester), 0, reason: 'immersive reading works again');
        expect(bottomBarsHeight(tester), 0);
        await leave(tester);
      });

      testWidgets('searching and swiping pages go together: the hits are counted on the page swiped to', (
        tester,
      ) async {
        await set(tester, SettingsKeys.threadSwipePaging, true);
        await pumpThread(tester);
        await openSearch(tester);
        await tester.enterText(searchField, 'floor 12');
        await tester.pump(const Duration(milliseconds: 350));
        await settle(tester);
        final count = find.byKey(const ValueKey('thread-search-count'));
        expect(tester.widget<Text>(count).data, '0 / 0', reason: 'floor 12 is on the second page');

        await swipe(tester, const Offset(-250, 0));
        expect(forum.pages, [1, 2]);
        expect(searchField, findsOneWidget, reason: 'the search stays open over the page turned');
        expect(appBarShown(tester), 1);
        expect(tester.widget<Text>(count).data, '1 / 1');
        // "Next" brings the hit into view: marked.
        await tester.tap(find.byKey(const ValueKey('thread-search-next')));
        await settle(tester);
        expect(find.byKey(const ValueKey('thread-search-hit-${9700000 + 12}')), findsOneWidget);
        await leave(tester);
      });
    });
  });

  group('ThreadReadingGestures', () {
    late List<ThreadSwipe> swipes;
    late int taps;
    late int buttonTaps;
    late int longPresses;

    Future<void> pumpGestures(WidgetTester tester) async {
      swipes = [];
      taps = 0;
      buttonTaps = 0;
      longPresses = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ThreadReadingGestures(
              onTap: () => taps++,
              onSwipe: swipes.add,
              child: ListView(
                children: [
                  SizedBox(
                    key: const ValueKey('wide'),
                    height: 120,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      children: [for (var i = 0; i < 10; i++) SizedBox(width: 300, child: Text('cell $i'))],
                    ),
                  ),
                  TextButton(onPressed: () => buttonTaps++, child: const Text('button')),
                  // A floor's menu on a long press (`AdaptiveInkResponse` on a phone).
                  GestureDetector(
                    onLongPressStart: (_) => longPresses++,
                    child: const SizedBox(height: 60, child: Text('hold')),
                  ),
                  for (var i = 0; i < 60; i++) SizedBox(height: 60, child: Text('row $i')),
                ],
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('a swipe across something that scrolls sideways is its own', (tester) async {
      await pumpGestures(tester);
      await tester.drag(find.byKey(const ValueKey('wide')), const Offset(-200, 0));
      await tester.pumpAndSettle();
      expect(swipes, isEmpty);
      // At its start already: dragged past its end, still its own.
      await tester.drag(find.byKey(const ValueKey('wide')), const Offset(600, 0));
      await tester.pumpAndSettle();
      await tester.drag(find.byKey(const ValueKey('wide')), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(swipes, isEmpty);

      await tester.drag(find.text('row 3'), const Offset(-200, 0));
      await tester.pumpAndSettle();
      await tester.drag(find.text('row 3'), const Offset(200, 10));
      await tester.pumpAndSettle();
      expect(swipes, [ThreadSwipe.next, ThreadSwipe.previous]);
    });

    testWidgets('no swipe from the edge of the screen, nor with two fingers', (tester) async {
      await pumpGestures(tester);
      final y = tester.getCenter(find.text('row 3')).dy;
      await tester.dragFrom(Offset(4, y), const Offset(200, 0));
      await tester.pumpAndSettle();
      expect(swipes, isEmpty);

      final first = await tester.startGesture(Offset(300, y));
      final second = await tester.startGesture(Offset(500, y));
      await first.moveBy(const Offset(-150, 0));
      await second.moveBy(const Offset(-150, 0));
      await first.up();
      await second.up();
      await tester.pumpAndSettle();
      expect(swipes, isEmpty);
    });

    testWidgets('a long press is no swipe, even sliding sideways after it', (tester) async {
      await pumpGestures(tester);
      final hold = await tester.startGesture(tester.getCenter(find.text('hold')));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      expect(longPresses, 1);
      await hold.moveBy(const Offset(-100, 0));
      await hold.moveBy(const Offset(-100, 0));
      await hold.up();
      await tester.pumpAndSettle();
      expect(swipes, isEmpty);

      // Moving first, then a pause on the way: still a swipe.
      final slow = await tester.startGesture(tester.getCenter(find.text('row 3')));
      await slow.moveBy(const Offset(-40, 0));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await slow.moveBy(const Offset(-160, 0));
      await slow.up();
      await tester.pumpAndSettle();
      expect(swipes, [ThreadSwipe.next]);
    });

    testWidgets('a mouse dragging is no swipe, whatever the button', (tester) async {
      await pumpGestures(tester);
      final y = tester.getCenter(find.text('row 3')).dy;
      for (final buttons in [kPrimaryButton, kSecondaryButton, kMiddleMouseButton]) {
        await tester.dragFrom(Offset(400, y), const Offset(-200, 0), kind: PointerDeviceKind.mouse, buttons: buttons);
        await tester.pumpAndSettle();
      }
      expect(swipes, isEmpty);

      await tester.dragFrom(Offset(400, y), const Offset(-200, 0), kind: PointerDeviceKind.stylus);
      await tester.pumpAndSettle();
      expect(swipes, [ThreadSwipe.next]);
    });

    testWidgets('a button keeps its tap; a tap that stops a fling is no tap', (tester) async {
      await pumpGestures(tester);
      await tester.tap(find.text('button'));
      await tester.pumpAndSettle();
      expect((buttonTaps, taps), (1, 0));

      await tester.tap(find.text('row 3'));
      await tester.pumpAndSettle();
      expect(taps, 1);

      await tester.fling(find.text('row 3'), const Offset(0, -400), 3000);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(taps, 1, reason: 'stopped the list, nothing else');

      await tester.tapAt(const Offset(400, 300));
      await tester.pumpAndSettle();
      expect(taps, 2);
    });
  });
}
