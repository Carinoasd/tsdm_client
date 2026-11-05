/// Two panes on wide windows (`TwoPaneLayout`, the `twoPaneLayout` setting):
///
/// * a window at least 840dp wide shows the forum page on the left (40% of the width, within 360–480dp) and the thread
///   tapped on the right, as a widget of the forum page (no route pushed); another tap replaces it; the thread on the
///   right has no back button of its own, the empty pane shows an icon only;
/// * the system back takes the thread on the right away first, then leaves the forum page;
/// * a narrower window, or the setting off, pushes the thread as a page of its own, as before;
/// * a window turning narrow with a thread on the right goes on reading it as a page of its own, at the page read;
///   turning the setting off does the same; while another page is above the list page the panes stay until it is on
///   top again;
/// * the app's snack bars show once, on the detail pane;
/// * inside the thread on the right, a link to a thread opens above it on the right (with a back button taking it
///   away again), a member opens as a page of its own.
///
/// Synthetic forum and threads from the app API fixtures: no network.
library;

// The floor is written as the forum prints it, pieces of one html string.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/view/forum_page.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
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
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/two_pane.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

/// The thread every first floor links to.
const _linkedTid = 777;

/// The member every first floor links to.
const _authorUid = 32;

/// The forum of the fixture.
const _fid = '2';

const _wide = Size(1200, 800);
const _narrow = Size(800, 1000);

Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/data/tsdmapp/$name').readAsStringSync()) as Map<String, dynamic>;

/// The forum (schema 2) with its threads as the fixture has them.
Map<String, dynamic> _forum() => _fixture('forum_v2_fid2.json')..remove('document');

/// The thread [tid] (schema 3), one of three pages: the fixture's thread under that id, its first floor saying which
/// thread and page it is and linking to thread [_linkedTid] and to the member [_authorUid].
Map<String, dynamic> _thread(int tid, {int page = 1}) {
  final json = _fixture('thread_v3_plain.json')..remove('document');
  (json['thread'] as Map<String, dynamic>)
    ..['tid'] = tid
    ..['subject'] = 'thread $tid';
  json
    ..['page'] = math.min(page, 3)
    ..['pages'] = 3;
  final first = (json['posts'] as List).cast<Map<String, dynamic>>().first;
  first['body_html'] =
      '<div class="t_fsz"><table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_${first['pid']}">'
      '正文 $tid 第$page页<br />'
      '<a href="forum.php?mod=viewthread&amp;tid=$_linkedTid" target="_blank">看这个帖子</a><br />'
      '<a href="home.php?mod=space&amp;uid=$_authorUid" target="_blank">看作者</a><br />'
      '<a href="forum.php?mod=redirect&amp;tid=$_linkedTid&amp;goto=lastpost" target="_blank">看最后回复</a>'
      '</td></tr></table></div>';
  return json;
}

/// Answers the forum and any thread; images and anything else are offline.
final class _ForumAdapter implements HttpClientAdapter {
  final requests = <Uri>[];

  /// While set, the threads are answered only once it completes (a slow network).
  Completer<void>? hold;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    requests.add(uri);
    if (hold case final hold? when uri.queryParameters['mod'] == 'viewthread') {
      await hold.future;
    }
    final q = uri.queryParameters;
    final json = switch (uri.pathSegments.lastOrNull) {
      'forum.php' when q['mod'] == 'forumdisplay' => _forum(),
      'forum.php' when q['mod'] == 'viewthread' && q['tid'] != null => _thread(
        int.parse(q['tid']!),
        page: int.tryParse(q['page'] ?? '') ?? 1,
      ),
      _ => null,
    };
    if (json == null) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    return ResponseBody.fromString(
      jsonEncode(json),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The notification bloc: nothing unread, events dropped.
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

/// A few frames with real time in between, for the database and the fake network.
Future<void> _settle(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 60));
  }
}

/// End of a test: the pages go while frames still run, so what they write on their way out (visit history, replied
/// marks) reaches the database before it is closed; an `await` left in the test zone would never finish otherwise.
Future<void> _finish(WidgetTester tester) async {
  await _settle(tester);
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
  await _settle(tester, rounds: 3);
}

/// The app around the forum page: repositories, blocs, the fake network, Alice logged in.
final class _App {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late UserBlockRepository blocks;
  late UserBlockCubit blockCubit;
  late AuthenticationRepository auth;
  late NotificationInfoRepository info;
  late NotificationStateCubit counts;
  late ThreadVisitHistoryBloc history;
  late _ForumAdapter adapter;
  GoRouter? _router;

  /// The router, once [pump]ed.
  GoRouter get router => _router!;

  Future<void> setUp({bool twoPane = true}) async {
    TsdmAppApi.reset();
    ThreadAuthorCache.clear();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    adapter = _ForumAdapter();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
    await settings.setValue(SettingsKeys.loginUsername, _alice.username!);
    await settings.setValue(SettingsKeys.loginUid, _alice.uid!);
    if (!twoPane) {
      await settings.setValue(SettingsKeys.twoPaneLayout, false);
    }
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    blocks = UserBlockRepository(storage);
    auth = AuthenticationRepository(user: _alice);
    blockCubit = UserBlockCubit(
      repository: blocks,
      currentUid: () => auth.currentUser?.uid,
      authStatus: auth.status,
      retryDelays: const [],
    );
    info = NotificationInfoRepository();
    counts = NotificationStateCubit(info);
    history = ThreadVisitHistoryBloc(ThreadVisitHistoryRepo(storage));
  }

  Future<void> tearDown() async {
    _router?.dispose();
    await history.close();
    await counts.close();
    await info.dispose();
    await blockCubit.close();
    await settingsBloc.close();
    await blocks.dispose();
    await auth.dispose();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  }

  /// Pump the app in a [size] window with the forum page open above a home page.
  Future<void> pump(WidgetTester tester, {Size size = _wide}) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    _router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          name: '/',
          builder: (_, _) => const Scaffold(body: Text('home')),
        ),
        AppRoute(
          path: ScreenPaths.forum,
          builder: (s) => ForumPage(fid: s.pathParameters['fid']!, title: s.uri.queryParameters['appBarTitle']),
        ),
        AppRoute(path: ScreenPaths.threadV1, builder: (s) => ThreadPage.fromQuery(s.uri.queryParameters)),
        AppRoute(
          path: ScreenPaths.profile,
          builder: (s) =>
              Scaffold(body: Text('profile ${s.uri.queryParameters['uid']}', key: const ValueKey('profile'))),
        ),
      ],
    );
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<NotificationInfoRepository>.value(value: info),
            RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
            RepositoryProvider<FragmentsRepository>(create: (_) => FragmentsRepository()),
            RepositoryProvider<ForumRepository>(create: (_) => ForumRepository()),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>.value(value: settingsBloc),
              BlocProvider<UserBlockCubit>.value(value: blockCubit),
              BlocProvider<NotificationBloc>.value(value: _Notifications()),
              BlocProvider<NotificationStateCubit>.value(value: counts),
              BlocProvider<ThreadVisitHistoryBloc>.value(value: history),
            ],
            child: MaterialApp.router(
              debugShowCheckedModeBanner: false,
              routerConfig: router,
              scaffoldMessengerKey: snackbarKey,
            ),
          ),
        ),
      ),
    );
    await _settle(tester, rounds: 3);
    unawaited(router.push('/forum/$_fid'));
    await _settle(tester);
  }

  /// Names of the pages of the root navigator, bottom first.
  List<String?> get stack => router.routerDelegate.navigatorKey.currentState!.widget.pages.map((p) => p.name).toList();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  late _App app;

  setUp(() => app = _App());

  /// The thread cards of the forum page, as listed.
  Finder cards() => find.byType(NormalThreadCard);

  String tidOf(WidgetTester tester, Finder card) => tester.widget<NormalThreadCard>(card).thread.threadID;

  /// Tap the [index]th card of the forum page; its thread id.
  Future<String> tapCard(WidgetTester tester, int index) async {
    final card = cards().at(index);
    final tid = tidOf(tester, card);
    await tester.tap(card);
    await _settle(tester);
    return tid;
  }

  /// The thread page shown, in the pane or as a page.
  ThreadPage threadPage(WidgetTester tester) => tester.widget<ThreadPage>(find.byType(ThreadPage));

  /// The thread page shown in the detail pane (a widget under the forum page), none when the pane is empty.
  Finder paneThread() => find.descendant(of: find.byType(ForumPage), matching: find.byType(ThreadPage));

  /// The back button of the thread page.
  Finder threadBack() => find.descendant(of: find.byType(ThreadPage), matching: find.byType(BackButton));

  /// Open the link [text] of a floor: through the recognizer of its span, as a tap on it does.
  void openLink(WidgetTester tester, String text) {
    GestureRecognizer? recognizer;
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text == text && span.recognizer != null) {
          recognizer = span.recognizer;
          return false;
        }
        return true;
      });
      if (recognizer != null) {
        break;
      }
    }
    expect(recognizer, isNotNull, reason: 'no link "$text" on screen');
    switch (recognizer) {
      case final TapGestureRecognizer tap:
        (tap.onTapDown ?? (_) => tap.onTap!())(TapDownDetails());
      case final LongPressGestureRecognizer longPress:
        longPress.onLongPressCancel!();
      case _:
        fail('unknown recognizer $recognizer');
    }
  }

  group('wide window', () {
    setUp(() => app.setUp());
    tearDown(() => app.tearDown());

    testWidgets('a thread tapped opens on the right, the next tap replaces it, no route is pushed', (tester) async {
      await app.pump(tester);
      expect(cards(), findsWidgets);
      expect(find.byType(TwoPaneEmptyDetail), findsOneWidget, reason: 'nothing opened yet');
      expect(find.byType(ThreadPage), findsNothing);
      // The list keeps 40% of the window, at least 360 and at most 480.
      final listWidth = tester.getSize(find.byType(Scaffold).first).width;
      expect(listWidth, 480);
      expect(tester.getRect(find.byType(TwoPaneEmptyDetail)).left, 481, reason: 'a 1px divider between the panes');

      final first = await tapCard(tester, 0);
      expect(paneThread(), findsOneWidget);
      expect(threadPage(tester).threadID, first);
      expect(find.textContaining('正文 $first', findRichText: true), findsOneWidget, reason: 'the thread loaded');
      expect(app.stack, ['/', ScreenPaths.forum], reason: 'the thread is a widget of the forum page');
      expect(find.byType(TwoPaneEmptyDetail), findsNothing);
      expect(threadBack(), findsNothing, reason: 'the thread on the right has no back button of its own');
      expect(find.byType(BackButton), findsOneWidget, reason: 'the forum page keeps its own');
      expect(tester.getRect(find.byType(ThreadPage)).left, 481);

      final second = await tapCard(tester, 1);
      expect(second, isNot(first));
      expect(find.byType(ThreadPage), findsOneWidget);
      expect(threadPage(tester).threadID, second);
      expect(find.textContaining('正文 $second', findRichText: true), findsOneWidget);
      expect(app.stack, ['/', ScreenPaths.forum]);
      await _finish(tester);
    });

    testWidgets('back takes the thread on the right away first, then leaves the forum page', (tester) async {
      await app.pump(tester);
      await tapCard(tester, 0);
      expect(paneThread(), findsOneWidget);

      await tester.binding.handlePopRoute();
      await _settle(tester, rounds: 4);
      expect(find.byType(ThreadPage), findsNothing);
      expect(find.byType(TwoPaneEmptyDetail), findsOneWidget);
      expect(app.stack, ['/', ScreenPaths.forum], reason: 'the forum page stays');

      await tester.binding.handlePopRoute();
      await _settle(tester, rounds: 4);
      expect(app.stack, ['/']);
      expect(find.text('home'), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('a window turning narrow goes on reading the thread as a page of its own', (tester) async {
      await app.pump(tester);
      final tid = await tapCard(tester, 0);
      expect(paneThread(), findsOneWidget);

      tester.view.physicalSize = _narrow;
      await _settle(tester, rounds: 4);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.threadV1]);
      expect(paneThread(), findsNothing);
      expect(find.byType(TwoPaneEmptyDetail), findsNothing);
      expect(threadPage(tester).threadID, tid);

      // Back closes that page; the forum page shows alone (narrow), nothing moves into a pane when wide again.
      await tester.binding.handlePopRoute();
      await _settle(tester, rounds: 4);
      expect(app.stack, ['/', ScreenPaths.forum]);
      tester.view.physicalSize = _wide;
      await _settle(tester, rounds: 4);
      expect(find.byType(TwoPaneEmptyDetail), findsOneWidget);
      expect(find.byType(ThreadPage), findsNothing);
      await _finish(tester);
    });

    testWidgets('turning the setting off while a thread is on the right does the same', (tester) async {
      await app.pump(tester);
      final tid = await tapCard(tester, 0);
      // Written outside the test zone (a write awaited inside it would never finish); the bloc follows the repository.
      await tester.runAsync(() => app.settings.setValue(SettingsKeys.twoPaneLayout, false));
      await _settle(tester, rounds: 4);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.threadV1]);
      expect(paneThread(), findsNothing);
      expect(threadPage(tester).threadID, tid);
      expect(find.byType(TwoPaneEmptyDetail), findsNothing);
      await _finish(tester);
    });

    testWidgets('a thread link inside the thread on the right opens above it on the right, with a back button', (
      tester,
    ) async {
      await app.pump(tester);
      final first = await tapCard(tester, 0);
      openLink(tester, '看这个帖子');
      await _settle(tester);
      expect(find.byType(ThreadPage), findsOneWidget);
      expect(threadPage(tester).threadID, '$_linkedTid');
      expect(find.textContaining('正文 $_linkedTid', findRichText: true), findsOneWidget);
      expect(app.stack, ['/', ScreenPaths.forum], reason: 'still in the pane');
      expect(threadBack(), findsOneWidget, reason: 'back to the thread under it');

      await tester.tap(threadBack());
      await _settle(tester);
      expect(threadPage(tester).threadID, first);
      expect(threadBack(), findsNothing);
      expect(app.stack, ['/', ScreenPaths.forum]);

      // The system back does the same.
      openLink(tester, '看这个帖子');
      await _settle(tester);
      expect(threadPage(tester).threadID, '$_linkedTid');
      await tester.binding.handlePopRoute();
      await _settle(tester, rounds: 4);
      expect(threadPage(tester).threadID, first);
      await _finish(tester);
    });

    testWidgets('a window turning narrow with another page above waits for the list page to be on top again', (
      tester,
    ) async {
      await app.pump(tester);
      final tid = await tapCard(tester, 0);
      unawaited(app.router.pushNamed(ScreenPaths.profile, queryParameters: {'uid': '5'}));
      await _settle(tester, rounds: 4);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.profile]);

      tester.view.physicalSize = _narrow;
      await _settle(tester, rounds: 4);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.profile], reason: 'nothing pushed above the profile');
      expect(find.byType(ThreadPage, skipOffstage: false), findsOneWidget, reason: 'the pane is held meanwhile');

      await tester.binding.handlePopRoute();
      await _settle(tester, rounds: 6);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.threadV1], reason: 'on top again: a page of its own');
      expect(threadPage(tester).threadID, tid);
      await _finish(tester);
    });

    testWidgets('a window turning narrow goes on at the page read, not the first one', (tester) async {
      await app.pump(tester);
      final tid = await tapCard(tester, 0);
      expect(find.textContaining('正文 $tid 第1页', findRichText: true), findsOneWidget);
      BlocProvider.of<ThreadBloc>(tester.element(find.byType(PostList))).add(const ThreadJumpPageRequested(2));
      await _settle(tester);
      expect(find.textContaining('正文 $tid 第2页', findRichText: true), findsOneWidget);

      tester.view.physicalSize = _narrow;
      await _settle(tester, rounds: 6);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.threadV1]);
      expect(threadPage(tester).threadID, tid);
      expect(threadPage(tester).pageNumber, '2');
      expect(find.textContaining('正文 $tid 第2页', findRichText: true), findsOneWidget);
      await _finish(tester);
    });

    testWidgets('the page in view counts, not the last page loaded on the way down', (tester) async {
      await app.pump(tester);
      final tid = await tapCard(tester, 0);
      final element = tester.element(find.byType(PostList));
      // The next page loaded under the one in view (as scrolling near the end does), the indicator still on page 1.
      BlocProvider.of<ThreadBloc>(element).add(const ThreadLoadMoreRequested(2));
      await _settle(tester);
      expect(BlocProvider.of<ThreadBloc>(element).state.currentPage, 2, reason: 'the last page loaded');
      expect(BlocProvider.of<JumpPageCubit>(element).state.currentPage, 1, reason: 'the page in view');

      tester.view.physicalSize = _narrow;
      await _settle(tester, rounds: 6);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.threadV1]);
      expect(threadPage(tester).threadID, tid);
      expect(threadPage(tester).pageNumber, '1');

      // Read on to the next page (the indicator follows the floors in view), then back to the wide window: the thread
      // stays a page of its own, and the pane is empty.
      await _finish(tester);
    });

    testWidgets('a thread still loading goes on as asked for, the last floor here, not at page 1', (tester) async {
      await app.pump(tester);
      await tapCard(tester, 0);
      // The last floor of the linked thread, answered slowly.
      app.adapter.hold = Completer<void>();
      openLink(tester, '看最后回复');
      await _settle(tester, rounds: 4);
      expect(threadPage(tester).threadID, '$_linkedTid');
      expect(threadPage(tester).lastPost, isTrue);
      expect(find.textContaining('正文 $_linkedTid', findRichText: true), findsNothing, reason: 'still loading');

      tester.view.physicalSize = _narrow;
      await _settle(tester, rounds: 6);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.threadV1]);
      expect(threadPage(tester).threadID, '$_linkedTid');
      expect(threadPage(tester).lastPost, isTrue, reason: 'as asked for, the page indicator said nothing yet');
      expect(threadPage(tester).overrideReverseOrder, isFalse);

      app.adapter.hold!.complete();
      app.adapter.hold = null;
      await _settle(tester);
      final bloc = BlocProvider.of<ThreadBloc>(tester.element(find.byType(PostList)));
      expect(bloc.state.currentPage, 3, reason: 'the last page, as the forum answers a page past the end');
      await _finish(tester);
    });

    testWidgets('the author filter switched on the right is kept', (tester) async {
      await app.pump(tester);
      final tid = await tapCard(tester, 0);
      final element = tester.element(find.byType(PostList));
      BlocProvider.of<ThreadBloc>(element).add(const ThreadOnlyViewAuthorRequested('$_authorUid'));
      await _settle(tester);
      // The floors were built anew for the filter: their element too.
      final bloc = BlocProvider.of<ThreadBloc>(tester.element(find.byType(PostList)));
      expect(bloc.state.onlyVisibleUid, '$_authorUid');

      tester.view.physicalSize = _narrow;
      await _settle(tester, rounds: 6);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.threadV1]);
      expect(threadPage(tester).threadID, tid);
      expect(threadPage(tester).onlyVisibleUid, '$_authorUid');
      await _finish(tester);
    });

    testWidgets('a snack bar shows once, on the detail pane', (tester) async {
      await app.pump(tester);
      snackbarKey.currentState!.showSnackBar(const SnackBar(content: Text('toast 1')));
      await _settle(tester, rounds: 4);
      expect(find.byType(SnackBar), findsOneWidget, reason: 'not one per pane');
      expect(tester.getRect(find.byType(SnackBar)).left, greaterThanOrEqualTo(481));
      await _settle(tester);

      await tapCard(tester, 0);
      snackbarKey.currentState!.showSnackBar(const SnackBar(content: Text('toast 2')));
      await _settle(tester, rounds: 4);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.getRect(find.byType(SnackBar)).left, greaterThanOrEqualTo(481));
      await _finish(tester);
    });

    testWidgets('a member linked inside the thread on the right opens as a page of its own', (tester) async {
      await app.pump(tester);
      final tid = await tapCard(tester, 0);
      openLink(tester, '看作者');
      await _settle(tester, rounds: 4);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.profile]);
      expect(find.byKey(const ValueKey('profile')), findsOneWidget);
      expect(find.text('profile $_authorUid'), findsOneWidget);

      // Back to the forum page, the thread still on the right.
      await tester.binding.handlePopRoute();
      await _settle(tester, rounds: 4);
      expect(app.stack, ['/', ScreenPaths.forum]);
      expect(paneThread(), findsOneWidget);
      expect(threadPage(tester).threadID, tid);
      await _finish(tester);
    });
  });

  group('narrow window', () {
    setUp(() => app.setUp());
    tearDown(() => app.tearDown());

    testWidgets('a narrow window pushes the thread as a page, as before', (tester) async {
      await app.pump(tester, size: _narrow);
      expect(find.byType(TwoPaneEmptyDetail), findsNothing);
      final tid = await tapCard(tester, 0);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.threadV1]);
      expect(paneThread(), findsNothing);
      expect(threadPage(tester).threadID, tid);
      expect(threadBack(), findsOneWidget, reason: 'a page of its own has its back button');
      await _finish(tester);
    });
  });

  group('setting off', () {
    setUp(() => app.setUp(twoPane: false));
    tearDown(() => app.tearDown());

    testWidgets('one pane at any width', (tester) async {
      await app.pump(tester);
      expect(find.byType(TwoPaneEmptyDetail), findsNothing);
      expect(tester.getSize(find.byType(Scaffold).first).width, 1200, reason: 'the forum page takes the window');
      final tid = await tapCard(tester, 0);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.threadV1]);
      expect(paneThread(), findsNothing);
      expect(threadPage(tester).threadID, tid);
      await _finish(tester);
    });
  });

  test('the settings page has the switch, on by default', () {
    final source = File('lib/features/settings/view/settings_page.dart').readAsStringSync();
    expect(source, contains("ValueKey('settings-two-pane-layout')"));
    expect(SettingsKeys.twoPaneLayout.defaultValue, isTrue);
    for (final locale in ['zh-CN', 'zh-TW', 'en']) {
      final json = jsonDecode(File('lib/i18n/$locale.i18n.json').readAsStringSync()) as Map<String, dynamic>;
      final section = (json['settingsPage'] as Map<String, dynamic>)['appearanceSection'] as Map<String, dynamic>;
      expect((section['twoPaneLayout'] as Map<String, dynamic>)['title'], isNotEmpty, reason: locale);
    }
  });
}
