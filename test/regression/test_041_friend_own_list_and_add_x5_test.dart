import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/features/friend/utils/parse_add_friend.dart';
import 'package:tsdm_client/features/friend/utils/parse_friend.dart';
import 'package:tsdm_client/features/friend/widgets/add_friend_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

/// A tester with 52 friends saw "还没有好友": the owner's own list uses `<li id="friend_UID_li">` items, not the
/// `li.bbda` items of another member's list, and its `h4` starts with a "热度" link. Also the add-friend flow the
/// tester asked for. Fixtures were captured on 2026-09-06 with the two test accounts (uids 1000/1001, Alice/Bob).
String _data(String name) => File('test/data/$name').readAsStringSync();

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group("owner's own friends list", () {
    test('lists the friend with the name link, not the 热度 link, and the group icon from the h4', () {
      final page = parseFriendListPage(parseHtmlDocument(_data('friend_list_own_x5.html')));
      expect(page.items, hasLength(1));
      final friend = page.items.single;
      expect(friend.uid, '1001');
      expect(friend.username, 'Bob');
      expect(friend.groupIconUrl, endsWith('梦幻天使.gif'));
      expect(friend.credits, isNull);
      expect(page.totalCount, 1);
      expect(page.ownerName, 'Alice');
      expect(page.message, isNull);
    });

    test('the 在线成员 suggestions of an empty own list are still not friends', () {
      final page = parseFriendListPage(parseHtmlDocument(_data('friend_list_empty_x5.html')));
      expect(page.items, isEmpty);
    });

    test("another member's list still parses", () {
      final page = parseFriendListPage(parseHtmlDocument(_data('friend_list_x5.html')));
      expect(page.items, isNotEmpty);
      expect(page.items.first.username, 'Carol');
      expect(page.totalCount, 91);
    });
  });

  group('add friend', () {
    test('the form carries the formhash, the target, the groups and the preselected group', () {
      final result = parseAddFriendForm(_data('friend_add_form_x5.xml'));
      expect(result, isA<AddFriendForm>());
      final form = result as AddFriendForm;
      expect(form.formHash, 'XXXXXXXX');
      expect(form.targetName, 'Bob');
      expect(form.groups.map((g) => g.gid), ['0', '1', '2', '3', '4', '5', '6', '7']);
      expect(form.groups[1].name, '通过本站认识');
      expect(form.selectedGid, '1');
      expect(form.noteHint, contains('10'));
    });

    test('refusals come back instead of a form', () {
      expect((parseAddFriendForm(_data('friend_add_result_pending_x5.xml')) as AddFriendRefused).message, '正在等待验证');
      expect(
        (parseAddFriendForm(_data('friend_add_result_self_x5.xml')) as AddFriendRefused).message,
        '抱歉，您不能加自己为好友',
      );
      expect((parseAddFriendForm(_data('friend_add_result_friends_x5.xml')) as AddFriendRefused).message, '你们已成为好友');
    });

    test("a sent request and an approval are successes with the forum's message", () {
      final sent = parseAddFriendResult(_data('friend_add_result_sent_x5.xml'));
      expect(sent.success, isTrue);
      expect(sent.message, '好友请求已发送，请等待对方验证');
      final approved = parseAddFriendResult(_data('friend_accept_result_x5.xml'));
      expect(approved.success, isTrue);
      expect(approved.message, '您已和Alice成为好友');
      final refused = parseAddFriendResult(_data('friend_add_result_friends_x5.xml'));
      expect(refused.success, isFalse);
      expect(refused.message, '你们已成为好友');
    });

    test('urls', () {
      expect(
        FriendRepository.addFriendFormUrl('1001'),
        contains('ac=friend&op=add&uid=1001&handlekey=addfriendhk_1001&inajax=1'),
      );
      expect(FriendRepository.addFriendSubmitUrl('1001'), endsWith('ac=friend&op=add&uid=1001&inajax=1'));
    });

    testWidgets('the dialog returns the note and the chosen group', (tester) async {
      final form = parseAddFriendForm(_data('friend_add_form_x5.xml')) as AddFriendForm;
      AddFriendChoice? choice;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () async => choice = await showDialog<AddFriendChoice>(
                    context: context,
                    builder: (_) => AddFriendDialog(form: form, username: 'Bob'),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Bob'), findsWidgets);
      await tester.enterText(find.byType(TextField), '你好');
      await tester.tap(find.byType(FilledButton).last);
      await tester.pumpAndSettle();
      expect(choice, isNotNull);
      expect(choice!.note, '你好');
      expect(choice!.gid, '1');
    });
  });
}
