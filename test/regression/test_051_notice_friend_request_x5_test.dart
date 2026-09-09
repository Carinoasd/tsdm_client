import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

String _data(String name) => File('test/data/$name').readAsStringSync();

/// Regression: a friend request notice on Discuz! X5 has two `id` attributes
/// (`id="pendingFriend_UID" notice="NID" id="notice_NID"`); the html parser keeps the first, so the
/// `dl[id^="notice_"]` selector alone never found it and the app silently skipped every friend request.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('friend request notice on X5', () {
    test('is found through the notice attribute and keeps its id, time and unread flag', () {
      final doc = parseHtmlDocument(_data('notice_friend_request_x5.html'));
      final nodes = NotificationV2.noticeNodes(doc);
      expect(nodes, hasLength(1));
      expect(nodes.single.id, 'pendingFriend_1000');
      final v2 = Notice.toV2(nodes.single)!;
      expect(v2.id, 2436);
      expect(v2.alreadyRead, isFalse);
      expect(v2.data, contains('请求加您为好友'));
      expect(v2.data, contains('op=add'));
      expect(DateTime.fromMillisecondsSinceEpoch(v2.timestamp * 1000, isUtc: true).year, 2026);
    });

    test('an ordinary notice is not listed twice by the grouped selector', () {
      final doc = parseHtmlDocument(_data('notice_unread_x5.html'));
      expect(NotificationV2.noticeNodes(doc), hasLength(1));
    });

    test('fromDocuments keeps the friend request', () {
      final info = NotificationV2.fromDocuments(
        noticeDoc: parseHtmlDocument(_data('notice_friend_request_x5.html')),
        personalMessageDoc: parseHtmlDocument('<html></html>'),
        broadcastMessageDoc: parseHtmlDocument('<html></html>'),
        since: 0,
      );
      expect(info.noticeList.map((e) => e.id), [2436]);
    });
  });
}
