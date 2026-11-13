/// The main pages with the text of the system made larger, 1.5 and 2 times: nothing overflows (no "RenderFlex
/// overflowed" while they are laid out) and no text is cut where it can not be read (cut without an ellipsis, or
/// pushed past the edge of the screen with nothing to scroll it back). Wrapping to more lines and scrolling are fine.
///
/// The pages of test_279 and test_990, on a phone. Synthetic accounts and pages only: no network, no login, nothing
/// is sent.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_manager.dart';
import 'package:tsdm_client/features/attachment_download/view/attachment_downloads_page.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/view/login_page.dart';
import 'package:tsdm_client/features/chat/view/chat_history_page.dart';
import 'package:tsdm_client/features/chat/view/chat_page.dart';
import 'package:tsdm_client/features/chat/widgets/chat_message_card.dart';
import 'package:tsdm_client/features/forum/view/forum_page.dart';
import 'package:tsdm_client/features/homepage/view/homepage_page.dart';
import 'package:tsdm_client/features/me/view/me_page.dart';
import 'package:tsdm_client/features/notification/view/notification_page.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/view/post_edit_page.dart';
import 'package:tsdm_client/features/search/view/search_page.dart';
import 'package:tsdm_client/features/settings/view/about_page.dart';
import 'package:tsdm_client/features/settings/view/home_layout_page.dart';
import 'package:tsdm_client/features/settings/view/settings_page.dart';
import 'package:tsdm_client/features/settings/view/thread_card_appearance.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/topics/view/topics_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';

import 'a11y_harness.dart';
import 'a11y_pages.dart';

/// A page of the test: how it is built, what its forum answers, how it is brought to what is checked, and what is on
/// it once it is there (`ready`): checked on a page with its content, not on its loading indicator.
typedef _Page = ({
  String name,
  Widget Function() build,
  A11yAnswer answer,
  Future<void> Function(WidgetTester tester)? open,
  Finder Function() ready,
});

_Page _page(
  String name,
  Widget Function() build, {
  required Finder Function() ready,
  A11yAnswer answer = a11yMainForum,
  Future<void> Function(WidgetTester tester)? open,
}) => (name: name, build: build, answer: answer, open: open, ready: ready);

Finder _key(String key) => find.byKey(ValueKey(key));

Translations get tr => LocaleSettings.instance.currentTranslations;

const _thread = ThreadPage(
  threadID: '$a11yTid',
  findPostID: null,
  pageNumber: '1',
  overrideReverseOrder: false,
  overrideWithExactOrder: null,
);

final _pages = <_Page>[
  _page('homepage', () => const HomepagePage(), ready: () => find.text('【活动】十月签到挑战赛开始报名')),
  _page('forum list', () => const TopicsPage(), answer: a11yMoreForum, ready: () => find.byType(Card)),
  _page(
    'forum page',
    () => const ForumPage(fid: '13', title: 'COS・攝影'),
    ready: () => find.text('Alice'),
  ),
  _page('thread page', () => _thread, ready: () => find.textContaining('floor 1 text')),
  _page(
    'reply bar',
    () => _thread,
    answer: a11yMoreForum,
    ready: () => _key('reply-bar-send'),
    open: (tester) async {
      await a11ySettleUntil(tester, () => find.byKey(const ValueKey('reply-bar-field')).evaluate().isNotEmpty, 'bar');
      await tester.tap(find.byKey(const ValueKey('reply-bar-field')));
    },
  ),
  _page('notification page', () => const NotificationPage(), ready: () => find.text('unread notice one')),
  for (final (tab, index, text) in [
    ('messages', 1, 'a message from Bob'),
    ('broadcasts', 2, 'a broadcast of the forum'),
  ])
    _page(
      'notification page, $tab',
      () => const NotificationPage(),
      open: (tester) => tester.tap(find.byType(Tab).at(index)),
      ready: () => find.text(text),
    ),
  _page(
    'conversation window',
    () => const ChatPage(username: 'Bob', uid: '1001'),
    answer: a11yMoreForum,
    ready: () => find.byType(ChatMessageCard),
  ),
  _page(
    'conversation history',
    () => const ChatHistoryPage(uid: '1001'),
    answer: a11yMoreForum,
    ready: () => find.byType(ChatMessageCard),
  ),
  _page(
    'search page',
    () => const SearchPage(),
    open: (tester) async {
      await tester.enterText(find.byType(TextFormField).first, '000000');
      await tester.tap(find.byIcon(Icons.search_outlined));
    },
    ready: () => find.text('Alice'),
  ),
  _page('me tab', () => const MePage(), ready: () => _key('me-favorites')),
  _page('settings', () => const SettingsPage(), ready: () => find.byType(SectionListTile)),
  _page(
    'settings, thread cards',
    () => const SettingsThreadCardAppearancePage(),
    ready: () => find.byType(NormalThreadCard),
  ),
  _page('settings, homepage layout', () => const SettingsHomeLayoutPage(), ready: () => _key('home-layout-list')),
  _page('about', () => const AboutPage(), ready: () => find.byType(AppSurface)),
  _page(
    'login page',
    () => RepositoryProvider<AuthenticationRepository>(
      create: (_) => A11yLoginRepository(),
      dispose: (repo) => repo.dispose(),
      child: const LoginPage(),
    ),
    ready: () => find.text(tr.loginPage.password),
  ),
  _page(
    'editor of a new thread',
    () => const PostEditPage(editType: PostEditType.newThread, fid: '2', tid: null, pid: null),
    answer: a11yMoreForum,
    ready: () => find.byType(TextField),
  ),
  _page('moderator panel', a11yModeratorPanel, ready: () => _key('modcp-home-summary')),
  _page('downloads', () => const AttachmentDownloadsPage(), ready: () => find.text('done.zip')),
];

/// A phone as wide as usual and tall enough that the lists lay out most of their rows, not only the first screen
/// (the largest text only: what fits at 2x fits at 1.5x).
const _tallPhone = Size(390, 2400);

void main() {
  final h = A11yHarness()..install();

  for (final page in _pages) {
    for (final (scale, size) in [(1.5, a11yPhone), (2.0, a11yPhone), (2.0, _tallPhone)]) {
      final tall = size == _tallPhone ? ', tall' : '';
      a11yTest('${page.name}, text ${scale}x$tall', (tester) async {
        if (page.name == 'downloads') {
          final dir = Directory.systemTemp.createTempSync('tsdm_a11y_downloads_');
          addTearDown(() => dir.deleteSync(recursive: true));
          File('${dir.path}/done.zip').writeAsBytesSync([1, 2, 3, 4]);
          getIt.registerSingleton<AttachmentDownloadManager>(a11yDownloads(dir));
        }
        final errors = await a11yLayoutErrors(() async {
          await h.pump(tester, page.build(), dark: false, textScale: scale, answer: page.answer, size: size);
          if (page.open case final open?) {
            await open(tester);
          }
          await a11ySettleUntil(tester, () => page.ready().evaluate().isNotEmpty, 'the content of ${page.name}');
          // What fades in after it: a fixed time, not a wait for the animations to stop.
          await a11ySettle(tester, rounds: 4);
        });
        expect(
          errors.map((e) => e.exceptionAsString()),
          isEmpty,
          reason: 'nothing overflows at ${scale}x: ${errors.map((e) => e.toStringShort()).join('; ')}',
        );
        expect(a11yClippedTexts(tester), isEmpty, reason: 'no text is cut at ${scale}x');
        await h.finish(tester);
      });
    }
  }
}
