import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/page_stack.dart';
import 'package:tsdm_client/routes/popup_route_observer.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// GitHub #196: reading the notices one by one (notice page, a thread, the bell in the thread page's app bar, the next
/// thread...) pushed another notice page each time and piled them up. GitHub #117 only covered the tap on the system
/// notification; the bell of the app bars, the "notifications" item of their menu and of the profile page's menu still
/// pushed the page by themselves. They all go through [openNoticePageInApp] now.
///
/// The router is shaped like the app's (see regression 113): pages pushed on the root navigator, page name = path. It
/// has no home shell, so the notice page here is the one opened above other pages (`ScreenPaths.rootNotice`); the
/// notifications tab of the shell is covered by regression 113.

/// A reading page with the two controls of the app bars: the bell and the menu item.
class _ThreadPage extends StatefulWidget {
  const _ThreadPage(this.label, this.popups);

  final String label;
  final PopupRouteObserver popups;

  @override
  State<_ThreadPage> createState() => _ThreadPageState();
}

class _ThreadPageState extends State<_ThreadPage> {
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
  Widget build(BuildContext context) => Column(
    children: [
      Text(widget.label),
      IconButton(
        key: const Key('bell'),
        icon: const Icon(Icons.notifications_outlined),
        onPressed: () => openNoticePageInApp(context, popups: widget.popups),
      ),
      PopupMenuButton<int>(
        key: const Key('menu'),
        itemBuilder: (_) => const [PopupMenuItem(value: 1, child: Text('notifications'))],
        onSelected: (_) => openNoticePageInApp(context, popups: widget.popups),
      ),
    ],
  );
}

GoRoute _appRoute(String path, Widget Function(GoRouterState state) builder) => GoRoute(
  path: path,
  name: path,
  pageBuilder: (_, state) => MaterialPage<void>(
    name: path,
    child: Scaffold(body: builder(state)),
  ),
);

void main() {
  late GoRouter router;
  late PopupRouteObserver popups;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  setUp(_ThreadPageState.drafts.clear);

  Future<void> pumpApp(WidgetTester tester) async {
    popups = PopupRouteObserver();
    router = GoRouter(
      initialLocation: ScreenPaths.homepage,
      observers: [popups],
      routes: [
        _appRoute(ScreenPaths.homepage, (_) => const Text('home')),
        _appRoute(ScreenPaths.rootNotice, (_) => const Text('notice')),
        _appRoute(ScreenPaths.threadV1, (state) => _ThreadPage('thread ${state.uri.queryParameters['tid']}', popups)),
        // Not a reading page: may hold what the user typed, never closed by the app.
        _appRoute(ScreenPaths.search, (_) => const Text('search')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
  }

  List<String?> stack() => router.routerDelegate.navigatorKey.currentState!.widget.pages.map((p) => p.name).toList();

  int noticePages() => stack().where((name) => name == ScreenPaths.rootNotice).length;

  Future<void> push(WidgetTester tester, String name, {String? tid}) async {
    unawaited(router.pushNamed(name, queryParameters: {'tid': ?tid}));
    await tester.pumpAndSettle();
  }

  Future<void> tapBell(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('bell')));
    await tester.pumpAndSettle();
  }

  testWidgets('notice -> thread -> bell, many times: one notice page, the notice page on top', (tester) async {
    await pumpApp(tester);
    await push(tester, ScreenPaths.rootNotice);
    for (var i = 0; i < 5; i++) {
      await push(tester, ScreenPaths.threadV1, tid: '$i');
      expect(find.text('thread $i'), findsOneWidget);
      await tapBell(tester);
      expect(noticePages(), 1, reason: 'bell $i must not stack another notice page');
      expect(stack(), [ScreenPaths.homepage, ScreenPaths.rootNotice]);
      expect(find.text('notice'), findsOneWidget);
    }
    // Back from the notice page reached again goes home, not through a pile of pages.
    router.pop();
    await tester.pumpAndSettle();
    expect(stack(), [ScreenPaths.homepage]);
  });

  testWidgets('the menu item: back to the open notice page (the menu closed before the item runs)', (tester) async {
    await pumpApp(tester);
    await push(tester, ScreenPaths.rootNotice);
    await push(tester, ScreenPaths.threadV1, tid: '1');
    await push(tester, ScreenPaths.threadV1, tid: '2');
    await tester.tap(find.byKey(const Key('menu')));
    await tester.pumpAndSettle();
    expect(popups.hasPopupRoute, isTrue);
    await tester.tap(find.text('notifications'));
    await tester.pumpAndSettle();
    expect(stack(), [ScreenPaths.homepage, ScreenPaths.rootNotice]);
    expect(popups.hasPopupRoute, isFalse);
  });

  testWidgets('no notice page open: the bell pushes one over the thread', (tester) async {
    await pumpApp(tester);
    await push(tester, ScreenPaths.threadV1, tid: '1');
    await tapBell(tester);
    expect(stack(), [ScreenPaths.homepage, ScreenPaths.threadV1, ScreenPaths.rootNotice]);
  });

  testWidgets('a thread with a reply being written stays: a notice page is pushed over it', (tester) async {
    await pumpApp(tester);
    await push(tester, ScreenPaths.rootNotice);
    await push(tester, ScreenPaths.threadV1, tid: '1');
    _ThreadPageState.drafts['thread 1'] = true;
    await tapBell(tester);
    expect(stack(), [ScreenPaths.homepage, ScreenPaths.rootNotice, ScreenPaths.threadV1, ScreenPaths.rootNotice]);
  });

  testWidgets('a page that may hold a form in between stays: a notice page is pushed', (tester) async {
    await pumpApp(tester);
    await push(tester, ScreenPaths.rootNotice);
    await push(tester, ScreenPaths.search);
    await push(tester, ScreenPaths.threadV1, tid: '1');
    await tapBell(tester);
    expect(stack(), [
      ScreenPaths.homepage,
      ScreenPaths.rootNotice,
      ScreenPaths.search,
      ScreenPaths.threadV1,
      ScreenPaths.rootNotice,
    ]);
  });

  test('no control pushes the notice page by itself: every way in goes through tap.dart', () {
    final pushes = RegExp(r'(push|go|pushReplacement|replace)Named\(\s*ScreenPaths\.(notice|rootNotice)\s*[,)]');
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.endsWith('local_notice/tap.dart')) {
        continue;
      }
      if (pushes.hasMatch(file.readAsStringSync())) {
        offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty, reason: 'open it with openNoticePageInApp (GitHub #196)');
  });
}
