/// Accessibility of the pages test_279 does not cover, against the same guidelines of `flutter_test` in the light and
/// the dark theme: tap targets of 48x48 (Android) and 44x44 (iOS), a label on everything tappable, the WCAG AA contrast
/// of the text.
///
/// The pages: the list of the forums, a floor's menu, the reply bar with its emoji panel, the messages and the
/// broadcasts of the notifications, the "me" tab, the settings (all of the list, the thread cards, the homepage
/// layout, about), the editor of a new thread, the moderator's panel and the downloads. Synthetic accounts and pages
/// only: no network, no login, nothing is sent.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_manager.dart';
import 'package:tsdm_client/features/attachment_download/view/attachment_downloads_page.dart';
import 'package:tsdm_client/features/chat/view/chat_history_page.dart';
import 'package:tsdm_client/features/chat/view/chat_page.dart';
import 'package:tsdm_client/features/editor/repository/recent_emoji_store.dart';
import 'package:tsdm_client/features/editor/widgets/emoji_panel.dart';
import 'package:tsdm_client/features/me/view/me_page.dart';
import 'package:tsdm_client/features/notification/view/notification_page.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/view/post_edit_page.dart';
import 'package:tsdm_client/features/settings/view/about_page.dart';
import 'package:tsdm_client/features/settings/view/home_layout_page.dart';
import 'package:tsdm_client/features/settings/view/settings_page.dart';
import 'package:tsdm_client/features/settings/view/thread_card_appearance.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/topics/view/topics_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';

import 'a11y_harness.dart';
import 'a11y_pages.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

void main() {
  final h = A11yHarness(fallback: a11yMoreForum)..install();

  /// The routes a page may open: stubs.
  final stubs = [
    for (final path in ['/stub'])
      GoRoute(
        path: path,
        builder: (_, _) => const Scaffold(body: Text('stub')),
      ),
  ];

  const thread = ThreadPage(
    threadID: '$a11yTid',
    findPostID: null,
    pageNumber: '1',
    overrideReverseOrder: false,
    overrideWithExactOrder: null,
  );

  for (final dark in [false, true]) {
    final mode = dark ? 'dark' : 'light';

    a11yTest('forum list, $mode', (tester) async {
      await h.pump(tester, const TopicsPage(), dark: dark, routes: stubs);
      await a11ySettleUntil(tester, () => find.byType(Card).evaluate().isNotEmpty, 'the forums on the page');
      await h.audit(tester);
      await h.finish(tester);
    });

    a11yTest('floor menu, $mode', (tester) async {
      await h.pump(tester, thread, dark: dark);
      await a11ySettleUntil(tester, () => find.textContaining('floor 1 text').evaluate().isNotEmpty, 'the floors');
      await tester.tap(find.byWidgetPredicate((w) => w is PopupMenuButton).first);
      // The entries fade in one after another: a fixed time for that, not a wait for the animation to stop.
      await a11ySettle(tester, rounds: 12);
      expect(find.byWidgetPredicate((w) => w is PopupMenuItem), findsWidgets, reason: 'the menu is open');
      await h.audit(tester);
      await h.finish(tester);
    });

    a11yTest('reply bar and its emoji panel, $mode', (tester) async {
      EmojiPanel.debugGroups = a11yEmojiGroups;
      addTearDown(() => EmojiPanel.debugGroups = null);
      getIt.registerSingleton<RecentEmojiStore>(RecentEmojiStore.memory());
      await h.pump(tester, thread, dark: dark);
      await a11ySettleUntil(tester, () => find.textContaining('floor 1 text').evaluate().isNotEmpty, 'the floors');
      await tester.tap(find.byKey(const ValueKey('reply-bar-field')));
      await a11ySettle(tester);
      await h.audit(tester, tapTargetExempt: [floorAuthorName('Bob')], labelExempt: [packageToolbarButtons()]);
      await tester.tap(find.byKey(const ValueKey('reply-bar-emoji')));
      await a11ySettle(tester, rounds: 6);
      expect(find.byType(EmojiPanel), findsOneWidget, reason: 'the panel is open');
      await h.audit(tester, tapTargetExempt: [floorAuthorName('Bob')], labelExempt: [packageToolbarButtons()]);
      await h.finish(tester);
    });

    for (final (tab, index) in [('messages', 1), ('broadcasts', 2)]) {
      a11yTest('notification page, $tab, $mode', (tester) async {
        await h.pump(tester, const NotificationPage(), dark: dark);
        await tester.tap(find.byType(Tab).at(index));
        await a11ySettle(tester, rounds: 6);
        await h.audit(tester);
        await h.finish(tester);
      });
    }

    a11yTest('conversation window, $mode', (tester) async {
      await h.pump(
        tester,
        const ChatPage(username: 'Bob', uid: '1001'),
        dark: dark,
      );
      await a11ySettle(tester, rounds: 4);
      expect(find.byType(ReplyBar), findsOneWidget, reason: 'the conversation is on the page');
      await h.audit(tester);
      await h.finish(tester);
    });

    a11yTest('conversation history, $mode', (tester) async {
      await h.pump(tester, const ChatHistoryPage(uid: '1001'), dark: dark);
      await a11ySettle(tester, rounds: 4);
      expect(find.byType(ReplyBar), findsOneWidget, reason: 'the conversation is on the page');
      await h.audit(tester);
      await h.finish(tester);
    });

    a11yTest('me tab, $mode', (tester) async {
      await h.pump(tester, const MePage(), dark: dark, size: const Size(390, 2000));
      expect(find.byKey(const ValueKey('me-favorites')), findsOneWidget, reason: 'the pages of the account');
      await h.audit(tester);
      await h.finish(tester);
    });

    a11yTest('settings, the whole list, $mode', (tester) async {
      await h.pump(tester, const SettingsPage(), dark: dark, size: const Size(480, 6000));
      expect(find.text(tr.settingsPage.othersSection.recordReadingTime), findsOneWidget, reason: 'the last section');
      await h.audit(tester);
      await h.finish(tester);
    });

    a11yTest('settings, thread cards, $mode', (tester) async {
      await h.pump(tester, const SettingsThreadCardAppearancePage(), dark: dark);
      expect(find.byKey(const ValueKey('settings-thread-card-excerpt')), findsOneWidget);
      await h.audit(tester);
      await h.finish(tester);
    });

    a11yTest('settings, homepage layout, $mode', (tester) async {
      await h.pump(tester, const SettingsHomeLayoutPage(), dark: dark);
      expect(find.byKey(const ValueKey('home-layout-list')), findsOneWidget);
      await h.audit(tester);
      await h.finish(tester);
    });

    a11yTest('about, $mode', (tester) async {
      await h.pump(tester, const AboutPage(), dark: dark, size: const Size(390, 1400));
      await h.audit(tester);
      await h.finish(tester);
    });

    a11yTest('editor of a new thread, $mode', (tester) async {
      await h.pump(
        tester,
        const PostEditPage(editType: PostEditType.newThread, fid: '2', tid: null, pid: null),
        dark: dark,
      );
      await a11ySettle(tester, rounds: 4);
      expect(find.byType(TextField), findsWidgets, reason: 'the form of the thread');
      // The page is read from its title on, the title field one node among the others: it used to take the whole
      // page (nothing above the field was a semantics boundary), read first and as the page itself.
      final handle = tester.ensureSemantics();
      try {
        await tester.pump();
        final order = a11yReadingOrder(tester);
        expect(order.first, tr.postEditPage.newThreadTitle, reason: 'the title of the page first');
        expect(order.indexOf(tr.postEditPage.title), greaterThan(0));
      } finally {
        handle.dispose();
      }
      await h.audit(tester, labelExempt: [packageToolbarButtons()]);
      await h.finish(tester);
    });

    a11yTest('moderator panel, $mode', (tester) async {
      await h.pump(tester, a11yModeratorPanel(), dark: dark, size: const Size(390, 2400));
      expect(find.byKey(const ValueKey('modcp-report')), findsOneWidget, reason: 'all the entries');
      await h.audit(tester);
      await h.finish(tester);
    });

    a11yTest('downloads, $mode', (tester) async {
      final dir = Directory.systemTemp.createTempSync('tsdm_a11y_downloads_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/done.zip').writeAsBytesSync([1, 2, 3, 4]);
      getIt.registerSingleton<AttachmentDownloadManager>(a11yDownloads(dir));
      await h.pump(tester, const AttachmentDownloadsPage(), dark: dark);
      await a11ySettleUntil(tester, () => find.text('done.zip').evaluate().isNotEmpty, 'the downloads');
      await h.audit(tester);
      await h.finish(tester);
    });
  }
}
