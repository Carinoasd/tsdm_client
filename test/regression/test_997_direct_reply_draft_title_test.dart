/// The draft kept from a reply typed in a notification that was not sent is listed by the title of its thread (the name
/// of the peer of a conversation) as the notification named it: the account of the notification may never have opened
/// the thread on this device, which then knows no title of its own and listed "主题 `tid`".
///
/// Synthetic accounts and texts only: nothing reaches a forum.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/local_notice/direct_reply.dart';
import 'package:tsdm_client/features/local_notice/direct_reply_drafts.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

const _tid = 9202864;
const _pid = 9700002;

/// Account B (2000), announced with every logged-in account, never opened the thread.
const _b = LocalNoticeAccount(uid: 2000, username: 'B', named: true);

NotificationAutoSyncInfoNotice _reply({String? threadTitle = '合成主题 乙', String type = 'post'}) =>
    NotificationAutoSyncInfoNotice(
      msg: 'A 回复了您的帖子',
      notice: 1,
      personalMessage: 0,
      broadcastMessage: 0,
      timestamp: 1700000000,
      nid: 5,
      author: 'A',
      noticeType: type,
      fromIdType: type == 'post' ? 'post' : null,
      threadTitle: threadTitle,
      tid: _tid,
      pid: _pid,
    );

const _pm = NotificationAutoSyncInfoPm(
  user: 'Carol',
  msg: '在吗',
  notice: 0,
  personalMessage: 1,
  broadcastMessage: 0,
  timestamp: 1700000000,
  peerUid: 3000,
);

/// The reply typed in the notification posted with [payload] (the extras its action carries).
DirectReplyRequest _typed(String payload, String text) {
  final uid = LocalNoticeKeys.parseOpenNotification(payload)!.uid!;
  final target = LocalNoticeKeys.parseTarget(payload)!;
  return DirectReplyRequest.of(
    NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotificationAction,
      id: directReplyNoticeIdOf(directReplyTargetKey(uid, target)!),
      actionId: directReplyActionId,
      input: text,
      payload: payload,
    ),
  )!;
}

void main() {
  late Translations tr;
  late Directory dir;
  late LocalDraftStore store;
  late DateTime now;
  late DirectReplyDraftInbox inbox;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    tr = await AppLocale.zhCn.build();
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tsdm_997_');
    store = LocalDraftStore.memory();
    now = DateTime(2026, 11, 13, 10);
    inbox = DirectReplyDraftInbox(directory: () async => dir, now: () => now, random: Random(997));
  });

  tearDown(() async {
    await store.dispose();
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  group('the notification names its target', () {
    test('a reply it can answer carries the title of the thread; a message the name of the peer', () {
      final reply = localNotificationContentOf(tr, _reply(), account: _b);
      expect(LocalNoticeKeys.parseTarget(reply.payload)?.title, '合成主题 乙');
      final pm = localNotificationContentOf(tr, _pm, account: _b);
      expect(LocalNoticeKeys.parseTarget(pm.payload)?.title, 'Carol');
    });

    test('none with the content hidden, none for a notice it can not answer, none without a title', () {
      final hidden = localNotificationContentOf(tr, _reply(), account: _b, hideContent: true);
      expect(LocalNoticeKeys.parseTarget(hidden.payload)?.title, isNull);
      final rate = localNotificationContentOf(tr, _reply(type: 'rate'), account: _b);
      expect(LocalNoticeKeys.parseTarget(rate.payload)?.title, isNull);
      final untitled = localNotificationContentOf(tr, _reply(threadTitle: null), account: _b);
      expect(LocalNoticeKeys.parseTarget(untitled.payload)?.title, isNull);
      final blank = localNotificationContentOf(tr, _reply(threadTitle: '  '), account: _b);
      expect(LocalNoticeKeys.parseTarget(blank.payload)?.title, isNull);
    });

    test('any title survives the payload; a long one is cut; it never changes where the reply goes', () {
      const odd = 'A&B #1 = 100% 「测试」?draft=x';
      final payload = LocalNoticeKeys.withTarget(
        LocalNoticeKeys.openNotificationOf(2000),
        const LocalNoticeTarget(nid: 5, tid: _tid, pid: _pid, title: odd),
      );
      final target = LocalNoticeKeys.parseTarget(payload)!;
      expect(target.title, odd);
      expect(target.draft, isNull, reason: 'the title is no draft');
      expect((target.tid, target.pid), (_tid, _pid));
      expect(directReplyTargetKey(2000, target), '2000:p:$_tid:$_pid', reason: 'the title is not part of the target');

      final long = '长' * 300;
      final cut = LocalNoticeKeys.parseTarget(
        LocalNoticeKeys.withTarget(LocalNoticeKeys.openNotification, LocalNoticeTarget(tid: 1, title: long)),
      )!;
      expect(cut.title, '长' * LocalNoticeTarget.titleLength);
    });

    test('the reply typed in it, and the notification telling it was not sent, keep the title', () {
      final content = localNotificationContentOf(tr, _reply(), account: _b);
      final request = _typed(content.payload, '没送出的回复');
      expect(request.uid, 2000);
      expect(request.target.title, '合成主题 乙');
      expect(LocalNoticeKeys.parseTarget(request.failedPayload)?.title, '合成主题 乙');
    });
  });

  group('the draft kept from it', () {
    test('the failure file carries the title, the draft is listed by it', () async {
      final content = localNotificationContentOf(tr, _reply(), account: _b);
      final request = _typed(content.payload, '没送出的回复');
      final id = await inbox.put(uid: request.uid, target: request.target, text: request.message);
      final json = jsonDecode(File('${dir.path}/$id.json').readAsStringSync()) as Map<String, dynamic>;
      expect(json['title'], '合成主题 乙');

      await collectDirectReplyDrafts(inbox: inbox, store: store, accounts: () async => {1000, 2000});
      final draft = (await store.load(2000, LocalDraftKey.floorReply('$_tid', '$_pid')))!;
      expect(draft.body, '没送出的回复');
      expect(draft.title, '合成主题 乙', reason: 'listed by the title, not "主题 $_tid"');
    });

    test('a private message: listed by the name of the peer', () async {
      final content = localNotificationContentOf(tr, _pm, account: _b);
      final request = _typed(content.payload, '在的');
      await inbox.put(uid: request.uid, target: request.target, text: request.message);
      await collectDirectReplyDrafts(inbox: inbox, store: store, accounts: () async => {2000});
      expect((await store.load(2000, LocalDraftKey.message('3000')))?.title, 'Carol');
    });

    test('kept at the tap of the notification (no file to move): the title comes with the text', () async {
      final content = localNotificationContentOf(tr, _reply(), account: _b);
      final request = _typed(content.payload, '点开时才保存');
      final tapped = LocalNoticeKeys.parseTarget(request.failedPayload)!;
      await keepDirectReplyDraftOfTap(2000, tapped, inbox: inbox, store: store, accounts: () async => {2000}, now: now);
      expect((await store.load(2000, LocalDraftKey.floorReply('$_tid', '$_pid')))?.title, '合成主题 乙');
    });

    test(
      'a file of an older version, a notification without a title: no title, the list falls back as before',
      () async {
        final id = await inbox.put(
          uid: 2000,
          target: const LocalNoticeTarget(nid: 5, tid: _tid, pid: _pid),
          text: '没有标题',
        );
        final json = jsonDecode(File('${dir.path}/$id.json').readAsStringSync()) as Map<String, dynamic>;
        expect(json.containsKey('title'), isFalse);
        await collectDirectReplyDrafts(inbox: inbox, store: store, accounts: () async => {2000});
        final draft = (await store.load(2000, LocalDraftKey.floorReply('$_tid', '$_pid')))!;
        expect(draft.body, '没有标题');
        expect(draft.title, isNull);
      },
    );
  });
}
