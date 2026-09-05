import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/features/friend/utils/parse_friend.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:universal_html/parsing.dart';

/// Discuz! X5 friends list samples captured with a test account on 2026-09-06 (uids -> 1000+, usernames -> placeholder
/// names, avatars -> example.com, hashes -> XXXXXXXX).
String _data(String name) => File('test/data/$name').readAsStringSync();

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('friends list page on X5', () {
    test('first page of a user with 91 friends', () {
      final page = parseFriendListPage(parseHtmlDocument(_data('friend_list_x5.html')));
      expect(page.needLogin, isFalse);
      expect(page.message, isNull);
      expect(page.ownerName, 'Bob');
      expect(page.totalCount, 91);
      expect(page.items, hasLength(24));
      expect(page.nextPageUrl, isNotNull);
      expect(page.nextPageUrl, startsWith(baseUrl));
      expect(page.nextPageUrl, contains('do=friend'));
      expect(page.nextPageUrl, contains('page=2'));

      final first = page.items.first;
      expect(first.uid, '1002');
      expect(first.username, 'Carol');
      expect(first.avatarUrl, 'https://example.com/avatar/2.png');
      expect(first.nameColor, isNull, reason: 'default colored name');
      expect(first.groupName, '永恒天使');
      expect(first.groupColor, isNull);
      expect(first.groupIconUrl, '$baseUrl/data/attachment/common/group/永恒天使.gif');
      expect(first.credits, '625876');

      for (final friend in page.items) {
        expect(friend.uid, isNotEmpty);
        expect(friend.username, isNotEmpty);
        expect(friend.avatarUrl, startsWith('https://'));
        expect(friend.credits, isNotNull, reason: '${friend.username} has no credits');
      }

      // A member of a colored user group: the name and the group name carry the color.
      final colored = page.items.where((e) => e.nameColor != null).toList();
      expect(colored, isNotEmpty);
      expect(colored.first.nameColor, 'Red');
      expect(colored.first.groupName, 'Friends☆');
      expect(colored.first.groupColor, 'Red');
    });

    test('last page has no next link', () {
      final page = parseFriendListPage(parseHtmlDocument(_data('friend_list_last_x5.html')));
      expect(page.items, hasLength(19));
      expect(page.totalCount, 91);
      expect(page.nextPageUrl, isNull);
    });

    test('own page without friends skips the online member suggestions', () {
      final page = parseFriendListPage(parseHtmlDocument(_data('friend_list_empty_x5.html')));
      expect(page.items, isEmpty, reason: 'li#friend_UID_li entries are 在线成员, not friends');
      expect(page.totalCount, 0);
      expect(page.ownerName, 'Alice');
      expect(page.message, isNull);
      expect(page.nextPageUrl, isNull);
    });

    test('private list answers a privacy notice', () {
      final page = parseFriendListPage(parseHtmlDocument(_data('friend_list_privacy_x5.html')));
      expect(page.items, isEmpty);
      expect(page.message, contains('隐私设置'));
      expect(page.needLogin, isFalse);
    });

    test('guest login notice', () {
      final page = parseFriendListPage(
        parseHtmlDocument(
          '<html><head><title>提示信息 - x</title></head><body><div id="messagetext" class="alert_info"> '
          '<p>请先登录后才能继续浏览</p></div><div id="messagelogin"></div></body></html>',
        ),
      );
      expect(page.items, isEmpty);
      expect(page.needLogin, isTrue);
    });
  });

  group('friends list urls', () {
    test('list url by uid or username', () {
      expect(FriendRepository.listUrl(uid: '1000'), '$baseUrl/home.php?mod=space&uid=1000&do=friend');
      expect(FriendRepository.listUrl(username: 'Bob Cat'), '$baseUrl/home.php?mod=space&username=Bob+Cat&do=friend');
    });

    test('friend page links route inside the app', () {
      final byUid = '$baseUrl/home.php?mod=space&uid=1000&do=friend&view=me&from=space'.parseUrlToRoute();
      expect(byUid?.screenPath, ScreenPaths.friend);
      expect(byUid?.queryParameters, {'uid': '1000'});

      final byName = 'home.php?mod=space&username=Bob&do=friend'.parseUrlToRoute();
      expect(byName?.screenPath, ScreenPaths.friend);
      expect(byName?.queryParameters, {'username': 'Bob'});

      final self = '$baseUrl/home.php?mod=space&do=friend'.parseUrlToRoute();
      expect(self?.screenPath, ScreenPaths.friend);
      expect(self?.queryParameters, isEmpty);

      // Other space urls still open the profile page.
      final profile = '$baseUrl/home.php?mod=space&uid=1000'.parseUrlToRoute();
      expect(profile?.screenPath, ScreenPaths.profile);

      // The favorites list, with or without uid, opens the favorites page.
      expect('$baseUrl/home.php?mod=space&do=favorite&type=thread'.parseUrlToRoute()?.screenPath, ScreenPaths.favorite);
      expect(
        '$baseUrl/home.php?mod=space&uid=1000&do=favorite&view=me&type=thread'.parseUrlToRoute()?.screenPath,
        ScreenPaths.favorite,
      );
    });
  });
}
