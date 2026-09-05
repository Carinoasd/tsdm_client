import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:universal_html/parsing.dart';

/// Discuz! X5 samples captured with test accounts on 2026-09-05 (ids and names replaced).
String _data(String name) => File('test/data/$name').readAsStringSync();

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('notice read state on X5', () {
    test('an unread notice is marked by the bold body style, not by a class on the node', () {
      final node = NotificationV2.noticeNodes(parseHtmlDocument(_data('notice_unread_x5.html'))).single;
      expect(node.classes, ['cl'], reason: 'X5 leaves the dl without any extra class');
      expect(Notice.isUnreadNoticeNode(node), isTrue);
      final v2 = Notice.toV2(node)!;
      expect(v2.alreadyRead, isFalse);
      expect(v2.id, 1984);
      expect(DateTime.fromMillisecondsSinceEpoch(v2.timestamp * 1000), DateTime(2026, 9, 5, 17, 38));
      expect(v2.data, contains('回复了您的帖子'));
    });

    test('the same notice after the server flipped it is read', () {
      final node = NotificationV2.noticeNodes(parseHtmlDocument(_data('notice_read_x5.html'))).single;
      expect(Notice.isUnreadNoticeNode(node), isFalse);
      expect(Notice.toV2(node)!.alreadyRead, isTrue);
    });

    test('the X3 extra class still counts as unread', () {
      final node = parseHtmlDocument('''
<div class="nts"><dl class="cl newnotice" id="notice_1"><dt><span class="xg1 xw0">
<span title="2026-9-5 17:38">now</span></span></dt><dd class="ntc_body">x</dd></dl></div>
''').querySelector('dl')!;
      expect(Notice.isUnreadNoticeNode(node), isTrue);
    });

    test('fromDocuments keeps the unread flag of the fetched copy', () {
      final empty = parseHtmlDocument('<html><body></body></html>');
      final info = NotificationV2.fromDocuments(
        noticeDoc: parseHtmlDocument(_data('notice_unread_x5.html')),
        personalMessageDoc: empty,
        broadcastMessageDoc: empty,
      );
      expect(info.noticeList.single.alreadyRead, isFalse);
    });
  });

  group('reconcileNoticeReadState', () {
    NoticeV2 fetched(int id, int t, {required bool read}) =>
        NoticeV2(id: id, timestamp: t, data: 'd', alreadyRead: read);
    NoticeEntity stored(int id, int t, {bool? read}) =>
        NoticeEntity(uid: 1, nid: id, timestamp: t, data: 'd', alreadyRead: read);

    test('a notice seen for the first time keeps the server flag', () {
      final r = reconcileNoticeReadState(
        fetched: [fetched(1, 100, read: false), fetched(2, 100, read: true)],
        stored: [],
      );
      expect(r.map((e) => e.alreadyRead), [false, true]);
    });

    test('a stored notice keeps the local flag when the server copy is not newer', () {
      // Re-fetched after our first listing flipped it to read on the server: the app copy is still unread.
      final r = reconcileNoticeReadState(fetched: [fetched(1, 100, read: true)], stored: [stored(1, 100, read: false)]);
      expect(r.single.alreadyRead, isFalse);
      // Read in the app meanwhile: stays read even if the server still renders it unread.
      final r2 = reconcileNoticeReadState(
        fetched: [fetched(1, 100, read: false)],
        stored: [stored(1, 100, read: true)],
      );
      expect(r2.single.alreadyRead, isTrue);
    });

    test('a merged notice with a newer time becomes unread again', () {
      final r = reconcileNoticeReadState(fetched: [fetched(1, 200, read: true)], stored: [stored(1, 100, read: true)]);
      expect(r.single.alreadyRead, isFalse);
    });

    test('a stored copy without a flag counts as unread', () {
      final r = reconcileNoticeReadState(fetched: [fetched(1, 100, read: true)], stored: [stored(1, 100)]);
      expect(r.single.alreadyRead, isFalse);
    });
  });
}
