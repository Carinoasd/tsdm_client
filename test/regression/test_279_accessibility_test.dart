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
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
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
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

import 'a11y_harness.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

const _tid = 1264975;

// ---------------------------------------------------------------------------------------------------------------------
// The forum.

/// A table wider than a phone, in the first floor: the button opening it in a page of its own is on the page.
final _wideTable = '<table><tr>${'<td>a wide table cell</td>' * 8}</tr></table>';

/// A floor of the synthetic thread (test_270), with a reply link so the floor has its own action row.
String _floor(int floor) {
  final pid = 9700000 + floor;
  return '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1000" class="xi2">Bob</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor text<br />${'line<br />' * 3}
${floor == 1 ? _wideTable : ''}
</div></div></div>
<div class="pob"><em><a class="fastre" href="forum.php?mod=post&amp;action=reply&amp;fid=8&amp;tid=$_tid&amp;repquote=$pid">回复</a></em></div>
</td>
</tr></tbody></table></div>''';
}

/// A thread of 3 pages, 10 floors each: page [page].
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

/// The author link of a thread row of the homepage.
const _carol = '<a href="home.php?mod=space&amp;uid=1003" target="_blank"><em>Carol</em></a>';

/// `forum.php` of Alice: the status bar and the pinned thread groups (test_226), owner marks as in test_171.
String _forumHome() {
  String threads(List<(String, int)> rows) => [
    for (final (title, tid) in rows)
      '<div class="Kahrpba_threads"><a href="forum.php?mod=viewthread&amp;tid=$tid">$title</a>$_carol</div>',
  ].join('\n');
  String button(int id, String title) => '<button type="button" id="Kahrpba_$id"><em>$title</em></button>';
  return '''
<html><head>
<script type="text/javascript">var STYLEID = '42', discuz_uid = '1000', cookiepre = 'Ystv_2132_';</script>
</head><body>
<div id="hd"><div class="wp"><div class="hdc cl"><div id="um">
<div class="avt y"><a href="home.php?mod=space&amp;uid=1000"><img data-src="./data/avatar/000/00/10/00_avatar_middle.jpg" class="_avt user_avatar"></a></div>
<p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong></p>
</div></div></div></div>
<form><input type="hidden" name="formhash" value="XXXXXXXX" /></form>
<div id="chart" class="bm bw0 cl"><p class="chart z">今日: <em>1234</em> | 昨日: <em>5678</em> | 帖子: <em>9012345</em></p></div>
<table id="Kahrpba"><tr>
<td id="Kahrpba_nav">
${button(1, '最新活动')}${button(2, '见习天使')}${button(3, '动漫新闻')}${button(4, '最新主题')}
${button(6, '今日话题')}${button(7, '动漫讨论')}${button(5, '发帖排行')}
</td>
<td id="Kahrpba_show">
<div id="Kahrpba_c_1">${threads([('【活动】十月签到挑战赛开始报名', 2001), ('【活动】秋季同人绘画征集', 2002), ('【公告】活动专区兑换商店开放', 2003)])}</div>
<div id="Kahrpba_c_2"><div class="Kahrpba_threads"><a href="home.php?mod=space&amp;uid=1101">欢迎Momo加入~</a></div></div>
<div id="Kahrpba_c_3">${threads([('【新闻】十月新番播出时间表整理', 2004), ('【新闻】某长篇漫画宣布动画化', 2005)])}</div>
<div id="Kahrpba_c_4">${threads([('求推荐几部轻松的日常番', 2006), ('分享一下我的手办收藏', 2007)])}</div>
<div id="Kahrpba_c_5"><div class="Kahrpba_threads"><a href="home.php?mod=space&amp;uid=1003">Carol</a><a href="home.php?mod=space&amp;uid=1003" target="_blank"><em>今日共发128贴</em></a></div></div>
<div id="Kahrpba_c_6">${threads([('你最喜欢的片头曲是哪首？', 2008)])}</div>
<div id="Kahrpba_c_7">${threads([('第 3 集的伏笔是不是太明显了', 2009)])}</div>
</td></tr></table>
</body></html>''';
}

const _profile = '''
<html><body>
<div id="um"><p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong></p></div>
<div id="uhd"><div class="icn avt"><a href="home.php?mod=space&amp;uid=1000"><img data-src="./data/avatar/000/00/10/00_avatar_middle.jpg"></a></div></div>
</body></html>''';

/// The forum: the homepage, the profile, a forum (JSON of the app plugin), a thread and a search; an empty page
/// otherwise.
(String, bool)? _answer(Uri uri, String method) {
  final q = uri.queryParameters;
  return switch (uri.pathSegments.lastOrNull) {
    'forum.php' when q['mod'] == null => (_forumHome(), false),
    'forum.php' when q['mod'] == 'forumdisplay' => (a11yData('tsdmapp/preview_v2_forum.json'), true),
    'forum.php' when q['mod'] == 'viewthread' => (_threadPage(int.tryParse(q['page'] ?? '') ?? 1), false),
    'home.php' when q['mod'] == 'space' => (_profile, false),
    'search.php' => (a11yData('tsdmapp/preview_v6_search.json'), true),
    _ => null,
  };
}

/// The login: the form hash comes at once, a login is refused.
final class _LoginRepository extends AuthenticationRepository {
  @override
  AsyncEither<LoginHash> fetchHash() =>
      AsyncEither(() async => right(const LoginHash(formHash: 'hash', loginHash: 'login')));

  @override
  AsyncVoidEither loginWithPassword(UserCredential credential) =>
      AsyncVoidEither(() async => left(LoginInvalidCredentialException()));
}

/// The floor of the fixture `locked_purchase_x5.html` as a post with a plain body (test_267).
Post _fixturePost() {
  final doc = parseHtmlDocument(a11yData('locked_purchase_x5.html'));
  final original = doc.querySelector('div#post_77983102')!;
  final floor = original.clone(true) as uh.Element;
  original.parent!.append(floor);
  final post = Post.fromPostNode(floor, 1)!;
  return post.copyWith(data: '<p>floor body</p>', locked: const [], signature: null, pokemon: null, checkin: null);
}

void main() {
  final h = A11yHarness(fallback: _answer)..install();

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

  /// The name of the author of a floor opens the author card like the 48 wide avatar before it does: the equivalent
  /// control is there, the name stays the height of its line.
  Finder floorAuthorName(String name) => find.widgetWithText(GestureDetector, name);

  /// The buttons the bbcode editor package builds (the style toggles, undo, redo, lists, alignment ...): the package
  /// puts their tooltip on a node of its own around the button instead of on the button, so the button node has no
  /// label; the tooltip is still read. The package is a submodule, not changed here; the app's own buttons are checked.
  Finder packageToolbarButtons() => find.descendant(
    of: find.byType(BBCodeEditorToolbar),
    matching: find.byWidgetPredicate((w) => w is IconButton && w.tooltip == null),
  );

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
          threadID: '$_tid',
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
      final login = _LoginRepository();
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
      final post = _fixturePost();
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
