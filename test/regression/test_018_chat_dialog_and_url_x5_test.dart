import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/chat/models/models.dart';
import 'package:tsdm_client/features/chat/utils/parse_chat.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

/// Discuz! X5 samples captured with test accounts on 2026-09-05 (ids and names replaced).
String _data(String name) => File('test/data/$name').readAsStringSync();

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('chat dialog on X5', () {
    test('messages carry the separator date only, so the card must not show a time', () {
      final xml = parseXmlDocument(_data('chat_dialog_x5.xml'));
      final doc = parseHtmlDocument(xml.documentElement!.nodes.first.text!);
      final info = parseChatDialog(doc)!;
      expect(info.username, 'Bob');
      expect(info.uid, '1000');
      expect(info.sendTarget.formHash, 'XXXXXXXX');
      final m = info.messageList.single;
      expect(m.author, 'Alice');
      expect(m.dateTime, DateTime(2026, 9, 5));
      expect(m.dateOnly, isTrue);
      expect(m.message, contains('私訊 #n1'));
    });

    test('a message with a full time is not date only', () {
      const m = ChatMessage(author: 'a', authorUid: null, authorAvatarUrl: null, message: 'x', dateTime: null);
      expect(m.dateOnly, isFalse);
      expect(
        ChatMessage.fromLi(
          parseHtmlDocument('<li class="cl"><h4 class="xg1">2026-09-05</h4></li>').querySelector('li')!,
        ),
        isNull,
      );
    });
  });

  group('url helpers keep absolute urls absolute', () {
    test('prependHost trims stray whitespace before deciding', () {
      expect(' https://example.com/img/5.jpg'.prependHost(), 'https://example.com/img/5.jpg');
      expect('\nhttps://example.com/img/5.jpg\n'.prependHost(), 'https://example.com/img/5.jpg');
      expect(' static/image/x.gif'.prependHost(), '$baseUrl/static/image/x.gif');
      expect('forum.php?mod=viewthread&tid=1'.prependHost(), '$baseUrl/forum.php?mod=viewthread&tid=1');
    });

    test('imageUrl trims the attribute value', () {
      final img = parseHtmlDocument('<img src=" https://example.com/img/5.jpg ">').querySelector('img')!;
      expect(img.imageUrl(), 'https://example.com/img/5.jpg');
      final rel = parseHtmlDocument('<img data-src="\n./data/attachment/x.jpg">').querySelector('img')!;
      expect(rel.imageUrl(), '$baseUrl/./data/attachment/x.jpg');
    });
  });
}
