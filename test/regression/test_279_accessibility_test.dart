/// Accessibility of the main pages, checked against the guidelines of `flutter_test`:
///
/// * [androidTapTargetGuideline], [iOSTapTargetGuideline]: anything that takes a tap is at least 48x48 (44x44);
/// * [labeledTapTargetGuideline]: anything that takes a tap has a label (a tooltip or a semantics label);
/// * [textContrastGuideline]: the text keeps the WCAG AA contrast against what is behind it, in the light and the
///   dark theme.
///
/// The pages: the homepage, a forum, a thread (floor cards and the reply bar), the notifications, the settings, the
/// login, the editor toolbar, the author card of a floor and the search (the other pages: test_990). Synthetic
/// accounts and pages only: no network, no login, nothing is sent. Each test closes what it opened before it ends
/// ([A11yHarness.finish]): closing it after the test waited forever on CI once (the search, 2026-11-13).
library;

import 'package:flutter/material.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/view/login_page.dart';
import 'package:tsdm_client/features/editor/widgets/toolbar.dart';
import 'package:tsdm_client/features/forum/view/forum_page.dart';
import 'package:tsdm_client/features/homepage/view/homepage_page.dart';
import 'package:tsdm_client/features/notification/view/notification_page.dart';
import 'package:tsdm_client/features/search/view/search_page.dart';
import 'package:tsdm_client/features/settings/view/settings_page.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/heroes.dart';

import 'a11y_harness.dart';
import 'a11y_pages.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

void main() {
  final h = A11yHarness(fallback: a11yMainForum)..install();

  Future<void> pump(WidgetTester tester, Widget home, {required bool dark, List<RouteBase> routes = const []}) =>
      h.pump(tester, home, dark: dark, routes: routes);

  Future<void> audit(
    WidgetTester tester, {
    List<Finder> tapTargetExempt = const [],
    List<Finder> labelExempt = const [],
    List<Finder> covered = const [],
  }) => h.audit(tester, tapTargetExempt: tapTargetExempt, labelExempt: labelExempt, covered: covered);

  /// The tap target of the [avatar]: the box of the gesture detector around it.
  Rect avatarTarget(WidgetTester tester, Finder avatar) =>
      tester.getRect(find.ancestor(of: avatar, matching: find.byType(GestureDetector)).first);

  /// The floating buttons of a list: the text of the last row on screen may run under them, where it is covered,
  /// not low in contrast (the guideline reads the pixels of the button over the text).
  Finder floatingButtons() => find.byType(FloatingActionButton);

  /// The button opening a table of a floor in a page of its own: 32 wide on purpose (test_271), a corner of the table
  /// that must not cover its cells; the table scrolls and zooms without it.
  Finder tableFullscreen() => find.byTooltip(tr.html.table.fullscreen);

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    a11yTest('homepage, $mode', (tester) async {
      final opened = <Uri>[];
      await pump(
        tester,
        const HomepagePage(),
        dark: dark,
        routes: [
          GoRoute(
            path: ScreenPaths.profile,
            name: ScreenPaths.profile,
            builder: (_, state) {
              opened.add(state.uri);
              return const Scaffold(body: Text('profile page'));
            },
          ),
        ],
      );
      await a11ySettle(tester);
      expect(find.text('【活动】十月签到挑战赛开始报名'), findsOneWidget, reason: 'the pinned threads are on the page');
      await audit(tester);
      // The whole 48 box of the avatar takes the tap: its end edge, past the circle, opens the user, not the thread
      // of the row (the tile's own tap).
      final avatar = avatarTarget(tester, find.byType(HeroUserAvatar).first);
      expect(avatar.width, 48);
      await tester.tapAt(Offset(avatar.right - 1, avatar.center.dy));
      await a11ySettle(tester);
      expect(opened.map((e) => e.queryParameters['username']), ['Carol']);
      expect(find.text('profile page'), findsOneWidget);
      await h.finish(tester);
    });

    a11yTest('forum page, $mode', (tester) async {
      await pump(
        tester,
        const ForumPage(fid: '13', title: 'COS・攝影'),
        dark: dark,
      );
      await a11ySettle(tester);
      expect(find.text('Alice'), findsWidgets, reason: 'the thread cards are on the page');
      await audit(tester, covered: [floatingButtons()]);
      // The 48 box of the avatar and its circle, name and date where they were with the 40 circle (16, 12 from the
      // corner of the card, the name 12 after the circle): the target grew around the circle, not the head.
      final card = tester.getRect(find.byType(Card).first);
      final circle = tester.getRect(find.descendant(of: find.byType(Card).first, matching: find.byType(CircleAvatar)));
      final box = avatarTarget(tester, find.byType(HeroUserAvatar).first);
      expect(box.size, const Size(48, 48));
      expect(circle.size, const Size(40, 40));
      expect(circle.topLeft - card.topLeft, const Offset(16, 12));
      final name = tester.getRect(find.descendant(of: find.byType(Card).first, matching: find.text('Alice')));
      expect(name.left - circle.right, 12);
      // The texts (name over date) centered on the circle, as with the 40 circle at the default size.
      final texts = tester.getRect(find.ancestor(of: find.text('Alice').first, matching: find.byType(Column)).first);
      expect(texts.height, lessThan(48), reason: 'the default size: the box decides the height of the head');
      expect(texts.center.dy, closeTo(circle.center.dy, 0.5));
      await h.finish(tester);
    });

    a11yTest('thread page, $mode', (tester) async {
      await pump(
        tester,
        const ThreadPage(
          threadID: '$a11yTid',
          findPostID: null,
          pageNumber: '1',
          overrideReverseOrder: false,
          overrideWithExactOrder: null,
        ),
        dark: dark,
      );
      await a11ySettle(tester);
      expect(find.textContaining('floor 1 text'), findsOneWidget, reason: 'the floors are on the page');
      expect(tableFullscreen(), findsOneWidget, reason: 'the table of the first floor is wider than the phone');
      await audit(tester, tapTargetExempt: [tableFullscreen(), floorAuthorName('Bob')]);
      await h.finish(tester);
    });

    a11yTest('notification page, $mode', (tester) async {
      await pump(tester, const NotificationPage(), dark: dark);
      await a11ySettle(tester);
      expect(find.text('unread notice one'), findsOneWidget, reason: 'the notices are on the page');
      await audit(tester);
      await h.finish(tester);
    });

    a11yTest('settings page, $mode', (tester) async {
      await pump(tester, const SettingsPage(), dark: dark);
      // The theme mode switch: on a phone the four segments are 43 wide, so the switch stays beside its title
      // (feedback 111, test_172); a wider window gets the 48 ones (the test below).
      await audit(tester, tapTargetExempt: [find.byType(SegmentedButton<int>)]);
      await h.finish(tester);
    });

    a11yTest('settings page on a wider window, $mode: the theme segments are 48', (tester) async {
      await pump(tester, const SettingsPage(), dark: dark);
      tester.view.physicalSize = const Size(480, 844);
      await a11ySettle(tester, rounds: 2);
      final light = find.byTooltip(tr.settingsPage.appearanceSection.themeMode.light);
      expect(tester.getSize(light).width, greaterThanOrEqualTo(48));
      await audit(tester);
      await h.finish(tester);
    });

    a11yTest('login page, $mode', (tester) async {
      final login = A11yLoginRepository();
      addTearDown(login.dispose);
      await pump(
        tester,
        RepositoryProvider<AuthenticationRepository>.value(value: login, child: const LoginPage()),
        dark: dark,
      );
      expect(find.text(tr.loginPage.password), findsOneWidget, reason: 'the form is on the page');
      await audit(tester);
      await h.finish(tester);
    });

    a11yTest('editor toolbar, $mode', (tester) async {
      final controller = buildBBCodeEditorController(initialText: 'abcd');
      addTearDown(controller.dispose);
      await pump(
        tester,
        Scaffold(body: EditorToolbar(bbcodeController: controller)),
        dark: dark,
      );
      expect(find.byKey(const ValueKey('editor-quick-phrases')), findsOneWidget, reason: "the app's own button");
      await audit(tester, labelExempt: [packageToolbarButtons()]);
      await h.finish(tester);
    });

    a11yTest('author card, $mode', (tester) async {
      final post = a11yFixturePost();
      await pump(
        tester,
        Scaffold(body: SingleChildScrollView(child: PostCard(post))),
        dark: dark,
      );
      await audit(tester, tapTargetExempt: [floorAuthorName(post.author.name)]);
      // The whole 48 box of the avatar takes the tap: a corner of it, outside the circle, opens the author card.
      final avatar = avatarTarget(tester, find.byType(HeroUserAvatar).first);
      expect(avatar.size, const Size(48, 48));
      await tester.tapAt(avatar.topLeft + const Offset(1, 1));
      await a11ySettle(tester, rounds: 12);
      expect(find.text(tr.postCard.profileDialog.tabName.info), findsOneWidget, reason: 'the dialog is open');
      await audit(tester);
      await h.finish(tester);
    });

    a11yTest('search page, $mode', (tester) async {
      await pump(tester, const SearchPage(), dark: dark);
      await audit(tester);
      await tester.enterText(find.byType(TextFormField).first, '000000');
      await tester.tap(find.byIcon(Icons.search_outlined));
      await a11ySettleUntil(tester, () => find.text('Alice').evaluate().isNotEmpty, 'the results on the page');
      // The pager and the cards fade in: a fixed time for that, not a wait for the animations to stop.
      await a11ySettle(tester, rounds: 6);
      await audit(tester);
      await h.finish(tester);
    });
  }
}
