/// The text of a reply typed in a notification that was not sent reaches the drafts while the editor of its floor (or
/// conversation) is open: that editor offers it at once ("有未送出的草稿 — 恢复／舍弃"), as it offers a draft found when
/// it opened, never in place of what the user is typing there.
///
/// Synthetic accounts and texts only: nothing reaches a forum.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/local_draft/utils/draft_autosaver.dart';
import 'package:tsdm_client/features/local_notice/direct_reply_drafts.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/instance.dart';

const _uid = 1000;
const _tid = 9600001;
const _pid = 9700002;
const _floor = LocalNoticeTarget(nid: 5, tid: _tid, pid: _pid);

final _floorKey = LocalDraftKey.floorReply('$_tid', '$_pid');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late LocalDraftStore store;
  late DateTime now;
  late DirectReplyDraftInbox inbox;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tsdm_996_');
    store = LocalDraftStore.memory();
    now = DateTime(2026, 11, 13, 10);
    inbox = DirectReplyDraftInbox(directory: () async => dir, now: () => now, random: Random(996));
  });

  tearDown(() async {
    await store.dispose();
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  /// The failing isolate keeps [text] for [target] of [uid], then the app's isolate moves it in (as told by the port).
  Future<void> failThenCollect(String text, {LocalNoticeTarget target = _floor, int uid = _uid}) async {
    expect(await inbox.put(uid: uid, target: target, text: text), isNotNull);
    await collectDirectReplyDrafts(inbox: inbox, store: store, accounts: () async => {_uid, 2000});
    await pumpEventQueue();
  }

  /// An editor open on [key] of [uid] holding [text] (nothing when empty), as the reply bar's: what it offers is for
  /// the thread's floors too when [key] is the reply to the thread.
  ({DraftAutosaver saver, void Function(String) type}) editor({
    int uid = _uid,
    LocalDraftKey? key,
    String text = '',
    Duration interval = const Duration(hours: 1),
  }) {
    final target = key ?? _floorKey;
    var current = text;
    final saver = DraftAutosaver(
      read: () => (
        uid: uid,
        key: target,
        draft: current.isEmpty ? null : LocalDraft(key: target, body: current, updatedAt: now),
      ),
      store: store,
      interval: interval,
      now: () => now,
    )..attach();
    addTearDown(saver.dispose);
    return (saver: saver, type: (t) => current = t);
  }

  Future<void> open(DraftAutosaver saver, {int uid = _uid, LocalDraftKey? key}) {
    final target = key ?? _floorKey;
    return saver.offerStored(
      uid,
      (k) => target.kind == LocalDraftKind.threadReply ? k.tid == target.tid : k == target,
    );
  }

  test('the editor of the floor is open, empty: the failed text is offered at once', () async {
    final e = editor();
    await open(e.saver);
    expect(e.saver.offer.value, isNull);

    await failThenCollect('没送出的回复');
    final offered = e.saver.offer.value;
    expect(offered, isNotNull, reason: 'offered without closing and opening the editor again');
    expect(offered!.uid, _uid);
    expect(offered.draft.key, _floorKey);
    expect(offered.draft.body, '没送出的回复');

    // Restored as any offered draft.
    expect(e.saver.takeOffer()?.body, '没送出的回复');
  });

  test('the reply to the thread is open: a failed reply to one of its floors is offered too', () async {
    final threadKey = LocalDraftKey.threadReply('$_tid');
    final e = editor(key: threadKey);
    await open(e.saver, key: threadKey);
    await failThenCollect('楼层的回复');
    expect(e.saver.offer.value?.draft.key, _floorKey);
  });

  test('the user is typing there: the text stays, the failed one is offered beside it, nothing lost', () async {
    final e = editor(text: '正在打的字');
    await open(e.saver);
    // Written by the editor an hour after the failure, which reaches the app only now.
    final failedAt = now;
    now = now.add(const Duration(hours: 1));
    e.saver.flush();
    await store.pendingWrites;
    now = failedAt;

    await failThenCollect('没送出的回复');
    expect((await store.load(_uid, _floorKey))?.body, '正在打的字', reason: 'never written over');
    final offered = e.saver.offer.value!;
    expect(offered.draft.body, '没送出的回复');
    expect(offered.draft.key.isBackup, isTrue, reason: 'kept aside: the newer text holds the target');
    expect(offered.draft.key.target, _floorKey);

    // Discarded: the aside goes, the typed text stays.
    e.saver.discardOffer();
    await store.pendingWrites;
    final left = await store.list(_uid);
    expect(left.map((d) => d.body), ['正在打的字']);
  });

  test('the editor held an older text: the failed one takes the target, typing on keeps both', () async {
    final e = editor(text: '早先的字');
    await open(e.saver);
    now = now.subtract(const Duration(hours: 1));
    e.saver.flush();
    await store.pendingWrites;
    now = now.add(const Duration(hours: 1));

    await failThenCollect('没送出的回复');
    expect(e.saver.offer.value?.draft.key, _floorKey);
    expect(e.saver.offer.value?.draft.body, '没送出的回复');

    // The user goes on typing: the offered one is moved aside, still offered, never written over.
    e.type('早先的字，再加一句');
    e.saver.flush();
    await store.pendingWrites;
    final bodies = (await store.list(_uid)).map((d) => d.body).toSet();
    expect(bodies, containsAll(['早先的字，再加一句', '没送出的回复']));
    expect(e.saver.offer.value?.draft.body, '没送出的回复');
    expect(e.saver.offer.value?.draft.key.isBackup, isTrue);
  });

  test('another floor, another conversation, another account: nothing offered', () async {
    final e = editor();
    await open(e.saver);
    await failThenCollect(
      '别的楼',
      target: const LocalNoticeTarget(nid: 5, tid: _tid, pid: _pid + 1),
    );
    await failThenCollect('私信', target: const LocalNoticeTarget(peerUid: 3000));
    await failThenCollect('另一个账号', uid: 2000);
    expect(e.saver.offer.value, isNull);
  });

  test('the editor holds that very text already: nothing offered', () async {
    final e = editor(text: '一样的字');
    await open(e.saver);
    await failThenCollect('一样的字');
    expect(e.saver.offer.value, isNull);
  });

  test('an editor closed meanwhile is not told', () async {
    final e = editor();
    await open(e.saver);
    e.saver.dispose();
    await failThenCollect('没送出的回复');
    expect((await store.load(_uid, _floorKey))?.body, '没送出的回复');
  });

  test('arrived while the editor looks for its draft: the arrived one is offered, not the older one found', () async {
    store.save(_uid, LocalDraft(key: _floorKey, body: '旧的', updatedAt: now.subtract(const Duration(days: 1))));
    await store.pendingWrites;
    final e = editor();
    var offered = 0;
    final looking = e.saver.offerStored(_uid, (k) => k == _floorKey, onOffered: () => offered++);
    // The failure lands aside of the older draft and is announced while the editor reads the store.
    final aside = _floorKey.backupAt(now.millisecondsSinceEpoch);
    store
      ..save(_uid, LocalDraft(key: aside, body: '没送出的回复', updatedAt: now))
      ..announceArrived(_uid, aside);
    await looking;
    await pumpEventQueue();
    expect(e.saver.offer.value?.draft.body, '没送出的回复');
    expect(offered, greaterThan(0), reason: 'the callback of the editor runs for it too');
  });

  test('an editor that never looked for a draft offers nothing', () async {
    final e = editor();
    await failThenCollect('没送出的回复');
    expect(e.saver.offer.value, isNull);
  });
}
