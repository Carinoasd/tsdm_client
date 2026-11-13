// "Open" on the clipboard prompt opens the link as a link tapped on the page in view: on a list page showing two panes
// (a wide window) a thread goes to the detail pane, no page pushed; on a narrow window, with another page above the
// list page, on a page that is no list page, or with the list page in a branch out of view, it opens as a page of its
// own, as before.
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/open_in_app/clipboard_link_prompt.dart';
import 'package:tsdm_client/features/open_in_app/utils/forum_link_in_text.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/two_pane.dart';

const _token = '【天使动漫】某某标题 https://www.tsdm39.com/forum.php?mod=viewthread&tid=123 点击链接直接打开';
const _forumLink = 'https://www.tsdm39.com/forum.php?mod=forumdisplay&fid=8';

const _wide = Size(1200, 800);
const _narrow = Size(800, 1000);

final class _Harness {
  late GoRouter router;

  /// The list page shows its branch (false: as a branch of the home shell out of view).
  bool inView = true;

  /// Names of the pages of the root navigator, bottom first.
  List<String?> get stack => router.routerDelegate.navigatorKey.currentState!.widget.pages.map((p) => p.name).toList();

  /// The root navigator's context, what the prompt opens from when no list page is in view.
  BuildContext? root() => router.routerDelegate.navigatorKey.currentState?.overlay?.context;

  Future<void> pump(WidgetTester tester, {Size size = _wide, bool listPage = true}) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          name: '/',
          builder: (_, _) => const Scaffold(body: Text('home')),
        ),
        GoRoute(
          path: '/list',
          name: '/list',
          builder: (_, _) => TickerMode(
            enabled: inView,
            child: const TwoPaneLayout(list: Scaffold(body: Text('list'))),
          ),
        ),
        AppRoute(
          path: ScreenPaths.forum,
          builder: (s) => Scaffold(body: Text('forum ${s.pathParameters['fid']}')),
        ),
        AppRoute(
          path: ScreenPaths.threadV1,
          builder: (s) => Scaffold(body: Text('thread page ${s.uri.queryParameters['tid']}')),
        ),
        AppRoute(
          path: ScreenPaths.profile,
          builder: (_) => const Scaffold(body: Text('profile')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
    await tester.pumpAndSettle();
    if (listPage) {
      // The future of a push completes when the page is popped.
      unawaited(router.push('/list'));
      await tester.pumpAndSettle();
    }
  }

  /// The tabs of the detail pane of the list page.
  TwoPaneTabs tabs(WidgetTester tester) => TwoPaneScope.readOf(tester.element(find.text('list')))!.tabs;
}

/// The link of the token, as the clipboard prompt offers it.
ForumLinkInText get _thread => findForumLinkInText(_token)!;

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  late _Harness h;
  setUp(() => h = _Harness());

  testWidgets('wide: a thread goes to the detail pane of the list page in view, no page pushed', (tester) async {
    await h.pump(tester);
    expect(TwoPaneScope.readOf(twoPaneListContextInView()!)?.side, TwoPaneSide.list);
    final before = h.stack;

    openClipboardLink(_thread, elsewhere: () => fail('opened elsewhere'));
    // Opened in the pane at once: checked before the pane builds the thread page, which needs the whole app.
    expect(h.tabs(tester).active?.top?.query['tid'], '123');
    expect(h.stack, before);

    // As a thread tapped in the list: it takes the place of the thread the pane shows, in the tab shown.
    openClipboardLink(
      findForumLinkInText('https://www.tsdm39.com/forum.php?mod=viewthread&tid=456')!,
      elsewhere: () => fail('opened elsewhere'),
    );
    expect(h.tabs(tester).length, 1);
    expect(h.tabs(tester).active?.threads.map((t) => t.query['tid']), ['456']);
    expect(h.stack, before);

    // Nothing else of the pane is built here.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('wide: a link that is no thread opens as a page of its own, as from the list', (tester) async {
    await h.pump(tester);
    openClipboardLink(findForumLinkInText(_forumLink)!, elsewhere: () => fail('opened elsewhere'));
    await tester.pumpAndSettle();
    expect(find.text('forum 8'), findsOneWidget);
    expect(h.stack.last, ScreenPaths.forum);
  });

  testWidgets('narrow: the thread opens as a page of its own', (tester) async {
    await h.pump(tester, size: _narrow);
    openClipboardLink(_thread, elsewhere: () => fail('opened elsewhere'));
    await tester.pumpAndSettle();
    expect(find.text('thread page 123'), findsOneWidget);
    expect(h.stack.last, ScreenPaths.threadV1);
  });

  testWidgets('another page above the list page: opened from the root, as a page of its own', (tester) async {
    await h.pump(tester);
    unawaited(h.router.pushNamed(ScreenPaths.profile));
    await tester.pumpAndSettle();
    expect(twoPaneListContextInView(), isNull);
    openClipboardLink(_thread, elsewhere: h.root);
    await tester.pumpAndSettle();
    expect(find.text('thread page 123'), findsOneWidget);
    expect(h.stack.last, ScreenPaths.threadV1);
  });

  testWidgets('no list page, or one out of view: opened from the root', (tester) async {
    await h.pump(tester, listPage: false);
    expect(twoPaneListContextInView(), isNull);
    openClipboardLink(_thread, elsewhere: h.root);
    await tester.pumpAndSettle();
    expect(find.text('thread page 123'), findsOneWidget);

    h.inView = false;
    await h.pump(tester);
    expect(find.text('list', skipOffstage: false), findsOneWidget);
    expect(twoPaneListContextInView(), isNull);
  });
}
