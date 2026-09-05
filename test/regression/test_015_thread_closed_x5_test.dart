import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

/// Fast-post forms captured from Discuz! X5: the form is rendered even when the thread is closed, only the message
/// textarea is replaced by a hint.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('closed thread: form present, textarea replaced by the closed hint', () {
    final doc = parseHtmlDocument(File('test/data/fastpostform_closed_x5.html').readAsStringSync());
    expect(doc.querySelector('form#fastpostform'), isNotNull, reason: 'X5 keeps the form');
    expect(isThreadClosedForReply(doc), isTrue);
  });

  test('open thread: textarea present', () {
    final doc = parseHtmlDocument(File('test/data/fastpostform_open_x5.html').readAsStringSync());
    expect(isThreadClosedForReply(doc), isFalse);
  });

  test('guest view: login hint is not a closed thread', () {
    final doc = parseHtmlDocument(File('test/data/fastpostform_guest_x5.html').readAsStringSync());
    expect(isThreadClosedForReply(doc), isFalse);
  });

  test('no form at all (permission page) counts as closed', () {
    expect(isThreadClosedForReply(parseHtmlDocument('<div id="messagetext"><p>本版块只有特定用户可以访问</p></div>')), isTrue);
  });
}
