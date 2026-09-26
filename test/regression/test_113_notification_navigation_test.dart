import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:responsive_framework/responsive_framework.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/home/cubit/init_cubit.dart';
import 'package:tsdm_client/features/home/view/home_page.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/routes/popup_route_observer.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/back_to_home_button.dart';

/// GitHub #117: each tap on the auto sync notification while reading a thread opened out of the notice page pushed
/// another notice page, they piled up; and there was no way back to the homepage but pressing back through all of them.
///
/// The router is a real GoRouter shaped like the app's: the home shell with two tabs, pages pushed on the root
/// navigator with the page name set to the route path as `AppRoute` does. Taps go through [openNoticePageForTap], the
/// function the home page calls.
Translations get tr => LocaleSettings.instance.currentTranslations;

/// Stand-in for the reply bar: the page reports its unsent text through [RouteDrafts] like the reply bar does.
class _DraftPage extends StatefulWidget {
  const _DraftPage(this.label);

  final String label;

  @override
  State<_DraftPage> createState() => _DraftPageState();
}

class _DraftPageState extends State<_DraftPage> {
  static final drafts = <String, bool>{};

  Route<dynamic>? _route;

  bool _hasDraft() => drafts[widget.label] ?? false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of(context);
    RouteDrafts.register(_route!, _hasDraft);
  }

  @override
  void dispose() {
    RouteDrafts.unregister(_route!, _hasDraft);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Text(widget.label);
}

/// Route like `AppRoute`: page name is the path.
GoRoute _appRoute(String path, Widget Function(GoRouterState state) builder) => GoRoute(
  path: path,
  name: path,
  pageBuilder: (_, state) => MaterialPage<void>(name: path, child: Scaffold(body: builder(state))),
);

void main() {
  late GoRouter router;
  late PopupRouteObserver popups;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(_DraftPageState.drafts.clear);

  /// With [homePage] the shell is the app's [HomePage] with its navigation bar, otherwise the bare branch navigator.
  Future<void> pumpApp(WidgetTester tester, {bool homePage = false}) async {
    popups = PopupRouteObserver();
    router = GoRouter(
      initialLocation: ScreenPaths.homepage,
      observers: [popups],
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, _, navigator) => homePage ? HomePage(showNavigationBar: true, child: navigator) : navigator,
          branches: [
            StatefulShellBranch(routes: [_appRoute(ScreenPaths.homepage, (_) => const Text('home'))]),
            StatefulShellBranch(routes: [_appRoute(ScreenPaths.topic, (_) => const Text('topic'))]),
          ],
        ),
        _appRoute(
          ScreenPaths.notice,
          (_) => const Column(children: [Text('notice'), BackToHomeButton()]),
        ),
        _appRoute(ScreenPaths.threadV1, (state) => _DraftPage('thread ${state.uri.queryParameters['tid']}')),
        _appRoute(ScreenPaths.reply, (state) => _DraftPage('reply ${state.pathParameters['target']}')),
        // Not a reading page: may hold a form, never closed by the app.
        _appRoute(ScreenPaths.editPost, (_) => const Text('edit post')),
        // A page guarding its content with PopScope.
        _appRoute(
          ScreenPaths.profile,
          (_) => const PopScope(canPop: false, child: Column(children: [Text('guarded'), BackToHomeButton()])),
        ),
      ],
    );
    addTearDown(router.dispose);
    final init = InitCubit()..skipAutoClearImageCache();
    addTearDown(init.close);
    await tester.pumpWidget(
      TranslationProvider(
        child: BlocProvider.value(
          value: init,
          child: MaterialApp.router(
            routerConfig: router,
            scaffoldMessengerKey: snackbarKey,
            builder: (_, child) => ResponsiveBreakpoints.builder(
              breakpoints: WindowSize.values.map((e) => Breakpoint(start: e.start, end: e.end, name: e.name)).toList(),
              child: child!,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Page names of the root navigator, bottom first; the first one is the home shell.
  List<String?> stack() => router.routerDelegate.navigatorKey.currentState!.widget.pages.map((p) => p.name).toList();

  int noticePages() => stack().where((name) => name == ScreenPaths.notice).length;

  Future<LocalNoticeTapAction> tapNotification(WidgetTester tester, {bool loggedIn = true}) async {
    final (:top, :action) = openNoticePageForTap(router, loggedIn: loggedIn, hasPopup: popups.hasPopupRoute);
    await tester.pumpAndSettle();
    expect(top, isNotNull);
    return action;
  }

  Future<void> push(WidgetTester tester, String name, {Map<String, String> path = const {}, String? tid}) async {
    unawaited(
      router.pushNamed(name, pathParameters: path, queryParameters: {'tid': ?tid}),
    );
    await tester.pumpAndSettle();
  }

  group('notification tap', () {
    testWidgets('notice -> thread -> tap, many times: one notice page, the notice page on top', (tester) async {
      await pumpApp(tester);
      expect(await tapNotification(tester), LocalNoticeTapAction.openNoticePage);
      expect(stack().sublist(1), [ScreenPaths.notice]);

      for (var i = 0; i < 5; i++) {
        await push(tester, ScreenPaths.threadV1, tid: '$i');
        await push(tester, ScreenPaths.reply, path: {'target': '$i'});
        expect(routerTopLocation(router), '/reply/$i');

        expect(await tapNotification(tester), LocalNoticeTapAction.returnToNoticePage);
        expect(noticePages(), 1, reason: 'tap $i must not stack another notice page');
        expect(stack(), hasLength(2));
        expect(routerTopLocation(router), ScreenPaths.notice);
        expect(find.text('notice'), findsOneWidget);
        expect(router.routerDelegate.currentConfiguration.matches, hasLength(2));
      }

      // Normal back still works from the notice page reached again.
      router.pop();
      await tester.pumpAndSettle();
      expect(routerTopLocation(router), ScreenPaths.homepage);
      expect(find.text('home'), findsOneWidget);
    });

    testWidgets('two taps before the next frame: one notice page', (tester) async {
      await pumpApp(tester);
      openNoticePageForTap(router, loggedIn: true, hasPopup: popups.hasPopupRoute);
      openNoticePageForTap(router, loggedIn: true, hasPopup: popups.hasPopupRoute);
      await tester.pumpAndSettle();
      expect(noticePages(), 1);
    });

    testWidgets('notice page on top: nothing pushed', (tester) async {
      await pumpApp(tester);
      await tapNotification(tester);
      expect(await tapNotification(tester), LocalNoticeTapAction.alreadyOnNoticePage);
      expect(await tapNotification(tester), LocalNoticeTapAction.alreadyOnNoticePage);
      expect(noticePages(), 1);
      expect(stack(), hasLength(2));
    });

    testWidgets('no notice page open: pushed once over the thread', (tester) async {
      await pumpApp(tester);
      await push(tester, ScreenPaths.threadV1, tid: '1');
      expect(await tapNotification(tester), LocalNoticeTapAction.openNoticePage);
      expect(stack().last, ScreenPaths.notice);
      expect(stack(), hasLength(3), reason: 'the thread stays under the notice page');
    });

    testWidgets('not logged in: nothing happens', (tester) async {
      await pumpApp(tester);
      await tapNotification(tester);
      await push(tester, ScreenPaths.threadV1, tid: '1');
      expect(await tapNotification(tester, loggedIn: false), LocalNoticeTapAction.needLogin);
      expect(routerTopLocation(router), ScreenPaths.threadV1);
      expect(stack(), hasLength(3));
    });

    testWidgets('an unsent reply above the notice page is kept: notice page opened on top instead', (tester) async {
      await pumpApp(tester);
      await tapNotification(tester);
      await push(tester, ScreenPaths.threadV1, tid: '7');
      _DraftPageState.drafts['thread 7'] = true;

      expect(await tapNotification(tester), LocalNoticeTapAction.openNoticePage);
      expect(stack().sublist(1), [ScreenPaths.notice, ScreenPaths.threadV1, ScreenPaths.notice]);

      // Back from the new notice page finds the thread with its reply.
      router.pop();
      await tester.pumpAndSettle();
      expect(find.text('thread 7'), findsOneWidget);
    });

    testWidgets('a page that is not for reading above the notice page is kept', (tester) async {
      await pumpApp(tester);
      await tapNotification(tester);
      await push(tester, ScreenPaths.editPost, path: {'editType': '0', 'fid': '1'});
      expect(await tapNotification(tester), LocalNoticeTapAction.openNoticePage);
      expect(stack().sublist(1), [ScreenPaths.notice, ScreenPaths.editPost, ScreenPaths.notice]);
    });

    testWidgets('a reading page refusing to pop (PopScope) is kept, notice page opened on top', (tester) async {
      await pumpApp(tester);
      await tapNotification(tester);
      await push(tester, ScreenPaths.threadV1, tid: '1');
      await push(tester, ScreenPaths.profile);
      expect(await tapNotification(tester), LocalNoticeTapAction.openNoticePage);
      expect(stack().sublist(1), [ScreenPaths.notice, ScreenPaths.threadV1, ScreenPaths.profile, ScreenPaths.notice]);
    });

    testWidgets('an open dialog: pages under it are not closed', (tester) async {
      await pumpApp(tester);
      await tapNotification(tester);
      await push(tester, ScreenPaths.threadV1, tid: '1');
      unawaited(
        showDialog<void>(
          context: router.routerDelegate.navigatorKey.currentContext!,
          builder: (_) => const AlertDialog(title: Text('dialog')),
        ),
      );
      await tester.pumpAndSettle();
      expect(popups.hasPopupRoute, isTrue);

      expect(await tapNotification(tester), LocalNoticeTapAction.openNoticePage);
      expect(noticePages(), 2);
      expect(stack().sublist(1, 3), [ScreenPaths.notice, ScreenPaths.threadV1]);
    });
  });

  group('back to home', () {
    testWidgets('closes the notification pages and shows the homepage tab from another tab', (tester) async {
      await pumpApp(tester);
      router.goNamed(ScreenPaths.topic);
      await tester.pumpAndSettle();
      expect(routerTopLocation(router), ScreenPaths.topic);

      await tapNotification(tester);
      await push(tester, ScreenPaths.threadV1, tid: '1');
      await tapNotification(tester);
      expect(routerTopLocation(router), ScreenPaths.notice);

      await tester.tap(find.byTooltip(tr.noticePage.appBar.backToHome));
      await tester.pumpAndSettle();
      expect(stack(), hasLength(1));
      expect(routerTopLocation(router), ScreenPaths.homepage);
      expect(homeTabOfLocation(routerTopLocation(router)), HomeTab.home);
      expect(find.text('home'), findsOneWidget);
      expect(find.text(tr.noticePage.appBar.backToHomeStopped), findsNothing);
    });

    testWidgets('stops on a page that is not for reading and says why', (tester) async {
      await pumpApp(tester);
      await push(tester, ScreenPaths.editPost, path: {'editType': '0', 'fid': '1'});
      await tapNotification(tester);
      await push(tester, ScreenPaths.threadV1, tid: '1');

      expect(returnToHome(router), isFalse);
      await tester.pumpAndSettle();
      expect(routerTopLocation(router), '/editPost/0/1', reason: 'the edit page is kept and shown');
      expect(find.text('edit post'), findsOneWidget);
      expect(stack().sublist(1), [ScreenPaths.editPost]);
    });

    testWidgets('stops on a page with an unsent reply', (tester) async {
      await pumpApp(tester);
      await tapNotification(tester);
      await push(tester, ScreenPaths.threadV1, tid: '3');
      _DraftPageState.drafts['thread 3'] = true;
      await push(tester, ScreenPaths.reply, path: {'target': '3'});

      expect(returnToHome(router), isFalse);
      await tester.pumpAndSettle();
      expect(find.text('thread 3'), findsOneWidget);
      expect(stack().sublist(1), [ScreenPaths.notice, ScreenPaths.threadV1]);

      // Once sent (or cleared), home works.
      _DraftPageState.drafts['thread 3'] = false;
      expect(returnToHome(router), isTrue);
      await tester.pumpAndSettle();
      expect(routerTopLocation(router), ScreenPaths.homepage);
    });

    testWidgets('the button stops on a page with an unsent reply under the notice page and says why', (tester) async {
      await pumpApp(tester);
      await push(tester, ScreenPaths.threadV1, tid: '5');
      _DraftPageState.drafts['thread 5'] = true;
      await tapNotification(tester);
      expect(stack().sublist(1), [ScreenPaths.threadV1, ScreenPaths.notice]);

      // The button's own page is closed on the way.
      await tester.tap(find.byTooltip(tr.noticePage.appBar.backToHome));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(stack().sublist(1), [ScreenPaths.threadV1]);
      expect(find.text('thread 5'), findsOneWidget);
      expect(find.text(tr.noticePage.appBar.backToHomeStopped), findsOneWidget);
    });

    testWidgets('the button on a page refusing to pop stays and shows the hint', (tester) async {
      await pumpApp(tester);
      await push(tester, ScreenPaths.profile);
      await tester.tap(find.byTooltip(tr.noticePage.appBar.backToHome));
      await tester.pumpAndSettle();
      expect(find.text('guarded'), findsOneWidget);
      expect(find.text(tr.noticePage.appBar.backToHomeStopped), findsOneWidget);
    });
  });

  testWidgets('the navigation bar of the home page follows the router back to the homepage tab', (tester) async {
    tester.view
      ..physicalSize = const Size(400, 800)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpApp(tester, homePage: true);
    int selected() => tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex;
    expect(selected(), HomeTab.home.index);

    router.goNamed(ScreenPaths.topic);
    await tester.pumpAndSettle();
    expect(selected(), HomeTab.topic.index, reason: 'tab changed by the router, not by the bar');

    await tapNotification(tester);
    await push(tester, ScreenPaths.threadV1, tid: '1');
    await tapNotification(tester);
    await tester.tap(find.byTooltip(tr.noticePage.appBar.backToHome));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(stack(), hasLength(1));
    expect(routerTopLocation(router), ScreenPaths.homepage);
    expect(selected(), HomeTab.home.index);
    expect(find.text('home'), findsOneWidget);
  });

  test('home tab of a location', () {
    expect(homeTabOfLocation(ScreenPaths.homepage), HomeTab.home);
    expect(homeTabOfLocation(ScreenPaths.topic), HomeTab.topic);
    expect(homeTabOfLocation(ScreenPaths.settings.fullPath), HomeTab.settings);
    expect(homeTabOfLocation(ScreenPaths.settingsThreadAppearance.fullPath), HomeTab.settings);
    expect(homeTabOfLocation(ScreenPaths.rootSettings), isNull);
    expect(homeTabOfLocation(ScreenPaths.notice), isNull);
    expect(homeTabOfLocation(null), isNull);
  });
}
