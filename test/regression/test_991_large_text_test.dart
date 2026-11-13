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
import 'package:tsdm_client/instance.dart';

import 'a11y_harness.dart';
import 'a11y_pages.dart';

/// A page of the test: how it is built, what its forum answers, how it is brought to what is checked.
typedef _Page = ({
  String name,
  Widget Function() build,
  A11yAnswer answer,
  Future<void> Function(WidgetTester tester)? open,
});

_Page _page(
  String name,
  Widget Function() build, {
  A11yAnswer answer = a11yMainForum,
  Future<void> Function(WidgetTester tester)? open,
}) => (name: name, build: build, answer: answer, open: open);

const _thread = ThreadPage(
  threadID: '$a11yTid',
  findPostID: null,
  pageNumber: '1',
  overrideReverseOrder: false,
  overrideWithExactOrder: null,
);

final _pages = <_Page>[
  _page('homepage', () => const HomepagePage()),
  _page('forum list', () => const TopicsPage(), answer: a11yMoreForum),
  _page('forum page', () => const ForumPage(fid: '13', title: 'COS・攝影')),
  _page('thread page', () => _thread),
  _page(
    'reply bar',
    () => _thread,
    answer: a11yMoreForum,
    open: (tester) async {
      await a11ySettleUntil(tester, () => find.byKey(const ValueKey('reply-bar-field')).evaluate().isNotEmpty, 'bar');
      await tester.tap(find.byKey(const ValueKey('reply-bar-field')));
    },
  ),
  _page('notification page', () => const NotificationPage()),
  for (final (tab, index) in [('messages', 1), ('broadcasts', 2)])
    _page(
      'notification page, $tab',
      () => const NotificationPage(),
      open: (tester) => tester.tap(find.byType(Tab).at(index)),
    ),
  _page(
    'conversation window',
    () => const ChatPage(username: 'Bob', uid: '1001'),
    answer: a11yMoreForum,
  ),
  _page('conversation history', () => const ChatHistoryPage(uid: '1001'), answer: a11yMoreForum),
  _page(
    'search page',
    () => const SearchPage(),
    open: (tester) async {
      await tester.enterText(find.byType(TextFormField).first, '000000');
      await tester.tap(find.byIcon(Icons.search_outlined));
    },
  ),
  _page('me tab', () => const MePage()),
  _page('settings', () => const SettingsPage()),
  _page('settings, thread cards', () => const SettingsThreadCardAppearancePage()),
  _page('settings, homepage layout', () => const SettingsHomeLayoutPage()),
  _page('about', () => const AboutPage()),
  _page(
    'login page',
    () => RepositoryProvider<AuthenticationRepository>(
      create: (_) => A11yLoginRepository(),
      dispose: (repo) => repo.dispose(),
      child: const LoginPage(),
    ),
  ),
  _page(
    'editor of a new thread',
    () => const PostEditPage(editType: PostEditType.newThread, fid: '2', tid: null, pid: null),
    answer: a11yMoreForum,
  ),
  _page('moderator panel', a11yModeratorPanel),
  _page('downloads', () => const AttachmentDownloadsPage()),
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
            await a11ySettle(tester);
          }
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
