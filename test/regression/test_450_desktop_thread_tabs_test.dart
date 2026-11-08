/// Tabs in the detail pane of a wide list page (`TwoPaneTabs`):
///
/// * one tab is the pane as it was, no strip; Ctrl with a click, a middle click or the card menu opens a thread in a
///   new tab behind the one shown, the strip shows then, the thread read stays as it is;
/// * Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+1..9 and the strip show a tab, Ctrl+W and the cross close one; the thread of a tab
///   shown again opens where it was read;
/// * a link opened with Ctrl inside the thread goes to a new tab;
/// * a window turning narrow takes the tab shown out as a page of its own, the others stay for the window turning wide;
/// * at most 20 tabs, a move keeps the tab shown, a tab whose last thread goes back closes.
///
/// Synthetic forum and threads from the app API fixtures (as test 281): no network.
library;

// The floor is written as the forum prints it, pieces of one html string.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:tsdm_client/features/keyboard/widgets/keyboard_shortcuts_host.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
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
              builder: (context, child) => KeyboardShortcutsHost(onSearch: () {}, onSettings: () {}, child: child!),
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

  group('the tabs', () {
    Map<String, String> q(int tid) => {'tid': '$tid'};
    String? tidOf(TwoPaneController? tab) => tab?.top?.query['tid'];

    test('the first thread opens a tab, the next ones replace it unless asked for a new tab', () {
      final tabs = TwoPaneTabs();
      addTearDown(tabs.dispose);
      tabs.open(q(1));
      expect(tabs.length, 1);
      tabs.open(q(2));
      expect(tabs.length, 1);
      expect(tidOf(tabs.active), '2');
      expect(tabs.openInNewTab(q(3)), isTrue);
      expect(tabs.length, 2);
      expect(tabs.activeIndex, 0, reason: 'a new tab opens behind the one shown');
      expect(tidOf(tabs.active), '2');
    });

    test('at most 20 tabs: one more opens in the tab shown', () {
      final tabs = TwoPaneTabs();
      addTearDown(tabs.dispose);
      tabs.open(q(0));
      for (var i = 1; i < twoPaneMaxTabs; i++) {
        expect(tabs.openInNewTab(q(i)), isTrue);
      }
      expect(tabs.length, twoPaneMaxTabs);
      expect(tabs.openInNewTab(q(99)), isFalse);
      expect(tabs.length, twoPaneMaxTabs);
      expect(tidOf(tabs.active), '99');
    });

    test('closing the tab shown shows the one after it, or the one before at the end', () {
      final tabs = TwoPaneTabs();
      addTearDown(tabs.dispose);
      tabs
        ..open(q(1))
        ..openInNewTab(q(2))
        ..openInNewTab(q(3))
        ..select(1)
        ..close(1);
      expect(tidOf(tabs.active), '3');
      tabs.close(1);
      expect(tidOf(tabs.active), '1');
      tabs
        ..openInNewTab(q(4))
        ..close(0);
      expect(tidOf(tabs.active), '4', reason: 'a tab before the one shown closed: the same tab stays shown');
      tabs.close(0);
      expect(tabs.isEmpty, isTrue);
      expect(tabs.active, isNull);
    });

    test('a move keeps the tab shown; next and previous go round', () {
      final tabs = TwoPaneTabs();
      addTearDown(tabs.dispose);
      tabs
        ..open(q(1))
        ..openInNewTab(q(2))
        ..openInNewTab(q(3))
        ..move(0, 2);
      expect(tabs.tabs.map(tidOf), ['2', '3', '1']);
      expect(tabs.activeIndex, 2);
      expect(tidOf(tabs.active), '1');
      tabs.selectNext();
      expect(tidOf(tabs.active), '2');
      tabs.selectPrevious();
      expect(tidOf(tabs.active), '1');
    });

    test('a tab whose last thread goes back closes', () {
      final tabs = TwoPaneTabs();
      addTearDown(tabs.dispose);
      tabs
        ..open(q(1))
        ..openInNewTab(q(2))
        ..select(1);
      tabs.active!.push(q(3));
      expect(tabs.active!.pop(), isTrue);
      expect(tabs.length, 2);
      expect(tabs.active!.pop(), isTrue);
      expect(tabs.length, 1);
      expect(tidOf(tabs.active), '1');
    });

    test('a thread left for another tab is kept where it is read', () {
      final tabs = TwoPaneTabs();
      addTearDown(tabs.dispose);
      tabs
        ..open(q(1))
        ..openInNewTab(q(2));
      final top = tabs.active!.top!;
      Map<String, String> resolve(Map<String, String> opened) => {...opened, 'page': '3'};
      top.resolver = resolve;
      tabs.select(1);
      final kept = tabs.tabs[0].top!;
      expect(kept.query, {'tid': '1', 'page': '3'});
      expect(kept.id, isNot(top.id), reason: 'shown again it is a page of its own');
    });
  });

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
    late _App app;

    setUp(() async {
      KeyboardShortcutsHost.enabledOverride = true;
      app = _App();
      await app.setUp();
    });
    tearDown(() async {
      KeyboardShortcutsHost.enabledOverride = null;
      await app.tearDown();
    });

    Finder cards() => find.byType(NormalThreadCard);
    String tidOfCard(WidgetTester tester, int index) =>
        tester.widget<NormalThreadCard>(cards().at(index)).thread.threadID;
    Finder paneThread() => find.descendant(of: find.byType(ForumPage), matching: find.byType(ThreadPage));
    String titleOfCard(WidgetTester tester, int index) =>
        tester.widget<NormalThreadCard>(cards().at(index)).thread.title;
    String? shownTid(WidgetTester tester) => tester.widget<ThreadPage>(paneThread()).threadID;
    Finder strip() => find.byType(ReorderableListView);

    /// The tabs of the strip, by their cross.
    Finder stripTabs() => find.descendant(of: strip(), matching: find.byIcon(Icons.close));

    Future<void> withControl(WidgetTester tester, Future<void> Function() action) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      try {
        await action();
      } finally {
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      }
    }

    Future<void> keys(WidgetTester tester, LogicalKeyboardKey key, {bool shift = false}) async {
      await withControl(tester, () async {
        if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(key);
        if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      });
      await _settle(tester);
    }

    testWidgets('Ctrl+click opens a new tab behind, the keys go through the tabs and close them', (tester) async {
      await app.pump(tester);
      final first = tidOfCard(tester, 0);
      final second = tidOfCard(tester, 1);
      final third = tidOfCard(tester, 2);
      await tester.tap(cards().at(0));
      await _settle(tester);
      expect(shownTid(tester), first);
      expect(strip(), findsNothing, reason: 'one tab: no strip');
      final state = tester.state(paneThread());

      await withControl(tester, () => tester.tap(cards().at(1)));
      await _settle(tester);
      expect(strip(), findsOneWidget);
      expect(stripTabs(), findsNWidgets(2));
      expect(shownTid(tester), first, reason: 'the new tab opens behind');
      expect(tester.state(paneThread()), same(state), reason: 'the thread read stays as it is');
      expect(app.stack, ['/', ScreenPaths.forum]);

      await withControl(tester, () => tester.tap(cards().at(2)));
      await _settle(tester);
      expect(stripTabs(), findsNWidgets(3));

      await keys(tester, LogicalKeyboardKey.tab);
      expect(shownTid(tester), second);
      expect(find.textContaining('正文 $second', findRichText: true), findsOneWidget);
      await keys(tester, LogicalKeyboardKey.tab, shift: true);
      expect(shownTid(tester), first);
      await keys(tester, LogicalKeyboardKey.digit3);
      expect(shownTid(tester), third);
      await keys(tester, LogicalKeyboardKey.digit9);
      expect(shownTid(tester), third, reason: 'no ninth tab: nothing happens');
      // A plain tap replaces the tab shown.
      await tester.tap(cards().at(0));
      await _settle(tester);
      expect(shownTid(tester), first);
      expect(stripTabs(), findsNWidgets(3));

      await keys(tester, LogicalKeyboardKey.keyW);
      expect(stripTabs(), findsNWidgets(2));
      expect(shownTid(tester), second, reason: 'the last tab closed: the one before it shows');
      await keys(tester, LogicalKeyboardKey.keyW);
      expect(strip(), findsNothing);
      expect(shownTid(tester), first);
      await keys(tester, LogicalKeyboardKey.keyW);
      expect(paneThread(), findsNothing);
      expect(find.byType(TwoPaneEmptyDetail), findsOneWidget);
      expect(app.stack, ['/', ScreenPaths.forum], reason: 'Ctrl+W closes tabs only');
      await _finish(tester);
    });

    testWidgets('the card menu and a middle click open new tabs, the strip shows and closes them', (tester) async {
      await app.pump(tester);
      final first = tidOfCard(tester, 0);
      final second = tidOfCard(tester, 1);
      await tester.tap(cards().at(1), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('在新标签页打开'));
      await _settle(tester);
      expect(shownTid(tester), second, reason: 'the first tab is shown');
      expect(strip(), findsNothing);

      await tester.tap(cards().at(0), buttons: kMiddleMouseButton);
      await _settle(tester);
      expect(stripTabs(), findsNWidgets(2));
      expect(shownTid(tester), second);

      // The tabs tell their thread.
      final firstTitle = find.descendant(of: strip(), matching: find.text(titleOfCard(tester, 0)));
      expect(find.descendant(of: strip(), matching: find.text(titleOfCard(tester, 1))), findsOneWidget);
      expect(firstTitle, findsOneWidget);
      await tester.tap(firstTitle);
      await _settle(tester);
      expect(shownTid(tester), first);

      await tester.tap(stripTabs().at(1));
      await _settle(tester);
      expect(strip(), findsNothing);
      expect(shownTid(tester), second);
      await _finish(tester);
    });

    testWidgets('a link opened with Ctrl inside the thread goes to a new tab', (tester) async {
      await app.pump(tester);
      final first = tidOfCard(tester, 0);
      await tester.tap(cards().at(0));
      await _settle(tester);
      final pane = TwoPaneScope.readOf(tester.element(paneThread()))!;
      await withControl(tester, () async => openLink(tester, '看这个帖子'));
      await _settle(tester);
      expect(pane.tabs.length, 2);
      expect(pane.tabs.tabs[1].top!.query['tid'], '$_linkedTid');
      expect(shownTid(tester), first);
      expect(pane.tabs.active!.threads, hasLength(1), reason: 'nothing went above the thread read');
      expect(
        find.descendant(of: strip(), matching: find.text('…')),
        findsOneWidget,
        reason: 'not loaded yet',
      );
      await keys(tester, LogicalKeyboardKey.digit2);
      expect(shownTid(tester), '$_linkedTid');
      expect(
        find.descendant(of: strip(), matching: find.text('thread $_linkedTid')),
        findsOneWidget,
        reason: 'the title loaded',
      );
      await _finish(tester);
    });

    testWidgets('a window turning narrow takes the tab shown out as a page, the others stay', (tester) async {
      await app.pump(tester);
      final first = tidOfCard(tester, 0);
      final second = tidOfCard(tester, 1);
      await tester.tap(cards().at(0));
      await _settle(tester);
      await withControl(tester, () => tester.tap(cards().at(1)));
      await _settle(tester);
      expect(stripTabs(), findsNWidgets(2));

      tester.view.physicalSize = _narrow;
      await _settle(tester, rounds: 4);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.threadV1]);
      expect(tester.widget<ThreadPage>(find.byType(ThreadPage)).threadID, first);
      expect(strip(), findsNothing);
      await keys(tester, LogicalKeyboardKey.keyW);
      expect(app.stack, ['/', ScreenPaths.forum, ScreenPaths.threadV1], reason: 'no tabs while narrow');

      await tester.binding.handlePopRoute();
      await _settle(tester, rounds: 4);
      expect(app.stack, ['/', ScreenPaths.forum]);

      tester.view.physicalSize = _wide;
      await _settle(tester, rounds: 4);
      expect(shownTid(tester), second, reason: 'the other tab is back');
      expect(strip(), findsNothing, reason: 'one tab left');
      await _finish(tester);
    });
  });
}
