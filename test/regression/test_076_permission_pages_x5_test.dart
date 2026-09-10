import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/widgets/card/error_card.dart';
import 'package:universal_html/parsing.dart';

String _data(String name) => File('test/data/$name').readAsStringSync();

/// GitHub #46: what the forum answers when a link points at something the account may not read, and what the app
/// makes of it. All four pages are real Discuz! X5 answers (anonymized: uid 1000/1001, Alice/Bob, formhash X).
///
/// Thread and forum links are in-app routes, so a permission answer is shown by the page (`NeedLoginPage` for the
/// login box, the server's own sentence in an `ErrorCard` otherwise); nothing here reaches the external browser.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('thread and forum links are routed in-app', () {
    expect(
      'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1263647'.parseUrlToRoute()?.screenPath,
      ScreenPaths.threadV1,
    );
    expect(
      'https://www.tsdm39.com/forum.php?mod=redirect&goto=findpost&pid=999999999'.parseUrlToRoute()?.screenPath,
      ScreenPaths.threadV1,
    );
    expect(
      'https://www.tsdm39.com/forum.php?mod=forumdisplay&fid=200'.parseUrlToRoute()?.screenPath,
      ScreenPaths.forum,
    );
  });

  test('read permission as a guest: the login box marks the page as needing login', () {
    final info = parseThreadDocument(parseHtmlDocument(_data('thread_readperm_guest_x5.html')), 1);
    expect(info.postList, isEmpty);
    expect(info.needLogin, isTrue);
  });

  test('a thread of a restricted board as a member: permission denied with the server sentence', () {
    final info = parseThreadDocument(parseHtmlDocument(_data('thread_restricted_board_member_x5.html')), 1);
    expect(info.postList, isEmpty);
    expect(info.needLogin, isFalse);
    expect(info.havePermission, isFalse);
    expect(info.permissionDeniedMessage?.text?.trim(), '本版块只有特定用户可以访问');
  });

  test('a missing post: the server sentence, not a permission error of the account', () {
    final info = parseThreadDocument(parseHtmlDocument(_data('thread_findpost_missing_x5.html')), 1);
    expect(info.postList, isEmpty);
    expect(info.needLogin, isFalse);
    expect(info.havePermission, isFalse);
    expect(info.permissionDeniedMessage?.text?.trim(), '抱歉，指定的主题不存在或已被删除或正在被审核');
  });

  test('a restricted board as a member: the forum page carries the server sentence', () {
    final data = parseForumPage(parseHtmlDocument(_data('forum_restricted_board_member_x5.html')), '200');
    expect(data.needLogin, isFalse);
    expect(data.havePermission, isFalse);
    expect(data.permissionDeniedMessage?.text?.trim(), '本版块只有特定用户可以访问');
  });

  testWidgets('the server sentence is what the error card shows', (tester) async {
    getIt.registerSingleton<NetErrorSaver>(NetErrorSaver());
    addTearDown(getIt.reset);
    final info = parseThreadDocument(parseHtmlDocument(_data('thread_restricted_board_member_x5.html')), 1);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(builder: (context) => ErrorCard(child: munchElement(context, info.permissionDeniedMessage!))),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('本版块只有特定用户可以访问'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
