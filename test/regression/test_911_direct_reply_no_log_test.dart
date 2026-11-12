/// The failing isolate of a reply typed in a notification may be one whose log could not be set up: keeping the text
/// then fails quietly, never with an error. `talker` can be set only once per isolate and never unset, so this test has
/// a file of its own: in test 875 it had to run first, and failed under a randomized order.
///
/// Synthetic accounts and texts only: nothing reaches a forum.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/local_notice/direct_reply_drafts.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/instance.dart';

const _floor = LocalNoticeTarget(nid: 5, tid: 9600001, pid: 9700002);

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('tsdm_911_'));
  tearDown(() => dir.delete(recursive: true));

  test('no log set up and a directory that can not be written: no id, never an error', () async {
    expect(() => talker, throwsA(isA<Error>()), reason: 'nothing in this file sets the log up');
    final file = File('${dir.path}/not_a_dir')..writeAsStringSync('');
    final broken = DirectReplyDraftInbox(directory: () async => Directory(file.path));
    expect(await broken.put(uid: 1000, target: _floor, text: 'x'), isNull);
    tellAppOfDirectReplyDraft('1000-1-0000abcd');
    await broken.markHandled('1000-1-0000abcd');
  });
}
