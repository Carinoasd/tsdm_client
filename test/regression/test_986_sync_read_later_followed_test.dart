/// The cross-device sync of the read later list and of the followed threads:
///
/// * the `read_later` and `follows` sections: item by item the later wins; a thread taken off (unfollowed) leaves a
///   record of when, noted where it is taken off, so the removal reaches the other devices unless one put it back
///   later; a section switched off is neither read nor written, and switched on again deletes nothing;
/// * each within its budget: the oldest threads stay on their device, no removal for the others;
/// * a followed thread from another device starts from the replies it has then: its first check announces nothing;
///   what a device's check knows never goes to the forum, a title the check found is no change to write;
/// * documents without the sections and with fields and sections this version does not know;
/// * the size of a typical document before and after.
///
/// Synthetic data, no real account or forum.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/read_later/models/read_later_sync.dart';
import 'package:tsdm_client/features/sync/models/sync_document.dart';
import 'package:tsdm_client/features/sync/models/sync_removals.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/features/sync/repository/sync_local_store.dart';
import 'package:tsdm_client/features/sync/repository/sync_repository.dart';
import 'package:tsdm_client/features/thread_follow/models/followed_thread.dart';
import 'package:tsdm_client/features/thread_follow/models/followed_thread_sync.dart';
import 'package:tsdm_client/features/thread_follow/repository/followed_thread_store.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_check.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_fetch.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const _uid = 31;

/// The device clock of the tests (milliseconds, whole seconds).
const _t = 1700000000000;

final class _Forum {
  int updated = 0;
  String? data;

  Map<String, dynamic> get doc => data == null ? const {} : jsonDecode(data!) as Map<String, dynamic>;

  Map<String, Map<String, dynamic>> items(String section) => SyncDocument.parse(data).items(section);

  void write(Map<String, dynamic> doc) {
    updated++;
    data = jsonEncode(doc);
  }
}

final class _Api implements SyncApi {
  _Api(this.forum);

  final _Forum forum;
  int pulls = 0;
  int conflicts = 0;
  Future<void> Function()? afterPull;

  @override
  Future<SyncPullAnswer> pull(int uid) async {
    pulls++;
    final answer = SyncPulled(updated: forum.updated, data: forum.data, formhash: 'f1f2f3f4', uid: _uid);
    final hook = afterPull;
    afterPull = null;
    await hook?.call();
    return answer;
  }

  @override
  Future<SyncPushAnswer> push(
    int uid, {
    required String data,
    required int baseUpdated,
    required String formhash,
  }) async {
    if (baseUpdated != forum.updated) {
      conflicts++;
      return SyncConflict(updated: forum.updated, data: forum.data);
    }
    forum
      ..updated += 1
      ..data = data;
    return SyncPushed(forum.updated);
  }
}

final class _Device {
  _Device(_Forum forum, this.now) : api = _Api(forum), store = MemorySyncLocalStore() {
    store.clock = () => now().millisecondsSinceEpoch;
    repo = SyncRepository(
      api: api,
      store: store,
      enabled: () => true,
      categoryEnabled: (c) => !off.contains(c),
      now: now,
    );
  }

  final DateTime Function() now;
  final _Api api;
  final MemorySyncLocalStore store;
  final off = <SyncCategory>{};
  late final SyncRepository repo;

  int get ms => now().millisecondsSinceEpoch;

  Future<SyncOutcome> sync() => repo.pull(_uid);

  void readLater(int tid, {String? title}) =>
      store.addReadLater(_uid, ReadLaterSyncEntry(tid: tid, title: title ?? '帖子$tid', addedAt: ms, forum: '版块'));

  void takeOff(int tid) => store.removeReadLater(_uid, tid, ms);

  List<int> get readLaterTids => (store.readLaterByUid[_uid]?.keys.toList() ?? <int>[])..sort();

  void follow(int tid, {String? title}) {
    (store.followedByUid[_uid] ??= []).insert(
      0,
      FollowedThread(
        tid: tid,
        title: title ?? '帖子$tid',
        seenReplies: 5,
        knownReplies: 5,
        followedAt: now(),
      ),
    );
    store.followedRemovedByUid[_uid]?.remove(tid);
  }

  void unfollow(int tid) {
    store.followedByUid[_uid]?.removeWhere((t) => t.tid == tid);
    store.followedRemovedByUid[_uid] = syncRemovalsOf(
      syncRemovalsWith(store.followedRemovedByUid[_uid] ?? const {}, tids: {tid: ms}, at: ms),
    );
  }

  List<int> get followedTids => [for (final t in store.followedByUid[_uid] ?? const <FollowedThread>[]) t.tid];
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  late DateTime now;
  late _Forum forum;
  late _Device a;
  late _Device b;

  setUp(() {
    now = DateTime.fromMillisecondsSinceEpoch(_t);
    forum = _Forum();
    a = _Device(forum, () => now);
    b = _Device(forum, () => now);
  });

  void tick([int ms = 1000]) => now = now.add(Duration(milliseconds: ms));

  group('read later', () {
    test('each device puts a thread aside: both have both, with their time, title and forum', () async {
      a.readLater(1);
      tick();
      b.readLater(2, title: '另一台');
      await a.sync();
      await b.sync();
      await a.sync();
      expect(a.readLaterTids, [1, 2]);
      expect(b.readLaterTids, [1, 2]);
      expect(a.store.readLaterByUid[_uid]![2], b.store.readLaterByUid[_uid]![2]);
      expect(forum.items(readLaterSection)['2'], {'updated': _t + 1000, 'title': '另一台', 'forum': '版块'});
    });

    test(
      'a thread taken off on one device is taken off the other; put back later on the other, it comes back',
      () async {
        a
          ..readLater(1)
          ..readLater(2);
        await a.sync();
        await b.sync();
        expect(b.readLaterTids, [1, 2]);

        tick();
        a.takeOff(1);
        await a.sync();
        await b.sync();
        expect(b.readLaterTids, [2]);
        expect(b.store.readLaterRemovedByUid[_uid], {1: _t + 1000});

        // Put back on B after the removal: later, so it is back everywhere.
        tick();
        b.readLater(1);
        await b.sync();
        await a.sync();
        expect(a.readLaterTids, [1, 2]);
        expect(a.store.readLaterRemovedByUid[_uid] ?? const {}, isEmpty);
      },
    );

    test('put aside on one device before it was taken off on the other: the removal wins', () async {
      a.readLater(1);
      await a.sync();
      await b.sync();
      // B puts it aside again (offline), A takes it off later; B syncs last.
      tick();
      b.readLater(1, title: '新标题');
      tick();
      a.takeOff(1);
      await a.sync();
      await b.sync();
      await a.sync();
      expect(a.readLaterTids, isEmpty);
      expect(b.readLaterTids, isEmpty);
      expect(forum.items(readLaterSection)['1'], {'updated': _t + 2000, 'deleted': true});
    });

    test('both change at once: the refused write merges and both end with the same', () async {
      await a.sync();
      await b.sync();
      a.readLater(1);
      tick();
      b.readLater(2);
      a.api.afterPull = () async => b.sync();
      await a.sync();
      expect(a.api.conflicts, 1);
      await b.sync();
      expect(a.readLaterTids, [1, 2]);
      expect(b.readLaterTids, [1, 2]);
    });

    test('over the budget the oldest threads stay on their device and are no removal on the others', () async {
      for (var tid = 1; tid <= 120; tid++) {
        a.readLater(tid, title: '一个相当长的中文帖子标题，用来占满预算 $tid');
        tick();
      }
      await a.sync();
      final sent = forum.items(readLaterSection);
      expect(utf8.encode(jsonEncode(sent)).length, lessThanOrEqualTo(syncReadLaterMaxBytes));
      expect(sent.length, lessThan(120));
      expect(sent.keys, contains('120'), reason: 'the latest go');
      expect(sent.keys, isNot(contains('1')));
      expect(a.readLaterTids, hasLength(120), reason: 'nothing taken off here');
      await b.sync();
      expect(b.readLaterTids, hasLength(sent.length));
      await a.sync();
      expect(a.readLaterTids, hasLength(120));
    });

    test('switched off it is neither read nor written; switched on again nothing is taken off', () async {
      a.readLater(1);
      await a.sync();
      b.off.add(SyncCategory.readLater);
      await b.sync();
      expect(b.readLaterTids, isEmpty);
      tick();
      a.readLater(2);
      await a.sync();
      await b.sync();
      expect(b.readLaterTids, isEmpty);
      b.off.clear();
      tick();
      await b.sync();
      expect(b.readLaterTids, [1, 2]);
      await a.sync();
      expect(a.readLaterTids, [1, 2], reason: 'the threads B never held are no removal');
      expect(forum.items(readLaterSection).values.where(SyncDocument.isDeleted), isEmpty);
    });

    test('a time within the second it is stored in: taken once, no write back and forth', () async {
      forum.write({
        'schema': 1,
        readLaterSection: {
          '5': {'updated': _t + 1234, 'title': '毫秒', 'author': '作者', 'extra': 1},
        },
      });
      tick(5000);
      await b.sync();
      expect(b.store.readLaterByUid[_uid]![5]!.addedAt, _t + 1000);
      b.store.writes.clear();
      final pulls = b.api.pulls;
      expect(await b.sync(), SyncOutcome.upToDate);
      expect(b.store.writes, isEmpty);
      expect(b.api.pulls, pulls + 1);
      expect(forum.items(readLaterSection)['5']!['extra'], 1, reason: 'a field this version does not know is kept');
    });

    test('an older document without the section, and a newer one with sections this version does not know', () async {
      forum.write({
        'schema': 1,
        'phrases': {
          'updated': _t,
          'items': ['x'],
        },
        'later_things': {'k': 1},
      });
      a.readLater(1);
      await a.sync();
      expect(forum.items(readLaterSection).keys, ['1']);
      expect(forum.doc['later_things'], {'k': 1});
      forum.write({
        ...forum.doc,
        readLaterSection: {
          ...forum.doc[readLaterSection] as Map<String, dynamic>,
          '9': {'updated': _t + 500, 'title': 7},
          'x': {'updated': _t, 'title': 'not a thread'},
        },
      });
      await a.sync();
      expect(a.readLaterTids, [1], reason: 'items this version can not read are left out');
      expect(forum.items(readLaterSection).keys, containsAll(['1', '9', 'x']), reason: 'and carried as they are');
    });

    test('the app notes a thread taken off, drops the note when put back, notes every thread of a clear', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      addTearDown(db.close);
      await storage.addReadLater(uid: _uid, tid: 1, title: 'a', time: DateTime.fromMillisecondsSinceEpoch(_t));
      await storage.addReadLater(uid: _uid, tid: 2, title: 'b', time: DateTime.fromMillisecondsSinceEpoch(_t));
      await storage.removeReadLaterAt(_uid, 1, DateTime.fromMillisecondsSinceEpoch(_t + 5));
      expect(await storage.readLaterRemoved(_uid), {1: _t + 5});
      await storage.removeReadLater(_uid, 7);
      expect((await storage.readLaterRemoved(_uid)).keys, [1], reason: 'nothing taken off, nothing noted');
      await storage.addReadLater(uid: _uid, tid: 1, title: 'a');
      expect(await storage.readLaterRemoved(_uid), isEmpty);
      await storage.clearReadLater(_uid);
      expect((await storage.readLaterRemoved(_uid)).keys.toSet(), {1, 2});
      expect(await storage.readLaterRemoved(32), isEmpty, reason: 'per account');

      // The sync's store on the app's storage: the list and the notes, then what the forum says.
      final now = DateTime.now().add(const Duration(minutes: 1));
      final removed = await storage.readLaterRemoved(_uid);
      final changes = readLaterSyncChanges(const [], removed, {
        '1': {'updated': now.millisecondsSinceEpoch, 'title': 'a again'},
        '2': {'updated': _t, 'title': 'b, older than its removal'},
      });
      expect([for (final e in changes.save) e.tid], [1]);
    });

    test('the records of removals: half a year, the latest 200', () {
      var raw = syncRemovalsWith(const {}, tids: {for (var i = 1; i <= 250; i++) i: _t + i}, at: _t + 250);
      expect(syncRemovalsOf(raw), hasLength(syncRemovalsMax));
      expect(syncRemovalsOf(raw).keys, isNot(contains(1)));
      raw = syncRemovalsWith(
        syncRemovalsOf(raw),
        tids: {999: _t + const Duration(days: 181).inMilliseconds},
        at: _t + const Duration(days: 181).inMilliseconds,
      );
      expect(syncRemovalsOf(raw).keys, [999]);
      expect(syncRemovalsWith({1: _t}, back: [1], at: _t), isNull);
      expect(syncRemovalsOf('not json'), isEmpty);
    });
  });

  group('followed threads', () {
    test(
      'each device follows a thread: both follow both, the one from the other device marked to start over',
      () async {
        a.follow(1);
        tick();
        b.follow(2);
        await a.sync();
        await b.sync();
        await a.sync();
        expect(a.followedTids, [2, 1], reason: 'by the time they were followed, the latest first');
        expect(b.followedTids, [2, 1]);
        final arrived = a.store.followedByUid[_uid]!.first;
        expect((arrived.fromSync, arrived.seenReplies, arrived.knownReplies), (true, 0, 0));
        expect(forum.items(followedThreadsSection)['2'], {'updated': _t + 1000, 'title': '帖子2'});
      },
    );

    test('unfollowed on one device, unfollowed on the other; followed again later, back on both', () async {
      a.follow(1);
      await a.sync();
      await b.sync();
      tick();
      b.unfollow(1);
      await b.sync();
      await a.sync();
      expect(a.followedTids, isEmpty);
      tick();
      a.follow(1);
      await a.sync();
      await b.sync();
      expect(b.followedTids, [1]);
      expect(b.store.followedRemovedByUid[_uid] ?? const {}, isEmpty);
    });

    test('followed again on one device before it was unfollowed on the other: the unfollow wins', () async {
      a.follow(1);
      await a.sync();
      await b.sync();
      tick();
      b.unfollow(1);
      tick();
      a.unfollow(1);
      tick();
      a.follow(1);
      tick();
      b.follow(1);
      tick();
      b.unfollow(1);
      await a.sync();
      await b.sync();
      await a.sync();
      expect(a.followedTids, isEmpty);
      expect(b.followedTids, isEmpty);
    });

    test('both change at once: the refused write merges', () async {
      await a.sync();
      await b.sync();
      a.follow(1);
      tick();
      b.follow(2);
      a.api.afterPull = () async => b.sync();
      await a.sync();
      expect(a.api.conflicts, 1);
      await b.sync();
      expect(a.followedTids..sort(), [1, 2]);
      expect(b.followedTids..sort(), [1, 2]);
    });

    test('what the check knows never goes; a title it found is no change to write', () async {
      a.follow(1);
      await a.sync();
      final list = a.store.followedByUid[_uid]!;
      list[0] = list[0].copyWith(title: '新标题', knownReplies: 9, checkedAt: now, notified: true);
      final pulls = a.api.pulls;
      expect(await a.repo.pushNow(_uid), SyncOutcome.upToDate);
      expect(a.api.pulls, pulls, reason: 'nothing to write: not even read');
      expect(forum.items(followedThreadsSection)['1'], {'updated': _t, 'title': '帖子1'});
    });

    test('over the budget the oldest stay on their device; switched off then on nothing is unfollowed', () async {
      for (var tid = 1; tid <= 100; tid++) {
        a.follow(tid, title: '一个相当长的中文帖子标题，用来占满预算 $tid');
        tick();
      }
      await a.sync();
      final sent = forum.items(followedThreadsSection);
      expect(utf8.encode(jsonEncode(sent)).length, lessThanOrEqualTo(syncFollowedThreadsMaxBytes));
      expect(sent.keys, contains('100'));
      expect(sent.keys, isNot(contains('1')));
      b.off.add(SyncCategory.followedThreads);
      await b.sync();
      expect(b.followedTids, isEmpty);
      b.off.clear();
      await b.sync();
      expect(b.followedTids, hasLength(sent.length));
      await a.sync();
      expect(a.followedTids, hasLength(100));
      expect(forum.items(followedThreadsSection).values.where(SyncDocument.isDeleted), isEmpty);
    });

    test('an older document without the section, and fields and sections this version does not know', () async {
      forum.write({
        'schema': 1,
        'future': [1, 2],
      });
      a.follow(1);
      await a.sync();
      expect(forum.items(followedThreadsSection).keys, ['1']);
      forum.write({
        ...forum.doc,
        followedThreadsSection: {
          '1': {'updated': _t, 'title': '帖子1', 'muted': true},
          '2': {'updated': _t + 9, 'nope': 1},
        },
      });
      tick();
      a.follow(3);
      await a.sync();
      expect(a.followedTids, [3, 1]);
      expect(forum.items(followedThreadsSection)['1']!['muted'], isTrue);
      expect(forum.items(followedThreadsSection).keys, containsAll(['1', '2', '3']));
      expect(forum.doc['future'], [1, 2]);
    });

    group('on the app storage', () {
      late AppDatabase db;
      late StorageProvider storage;
      late FollowedThreadStore store;

      setUp(() {
        db = AppDatabase(NativeDatabase.memory());
        storage = StorageProvider(db, {}, {});
        store = FollowedThreadStore(storage);
      });

      tearDown(() async {
        await store.dispose();
        await db.close();
      });

      test('an unfollow is noted, a follow again drops the note; the sync applies item by item', () async {
        // The store notes with the clock of the device: times of now.
        final t0 = DateTime.now().millisecondsSinceEpoch - 60000;
        await store.follow(_uid, tid: 1, title: 'a', replies: 4, now: DateTime.fromMillisecondsSinceEpoch(t0));
        await store.follow(_uid, tid: 2, title: 'b', replies: 4, now: DateTime.fromMillisecondsSinceEpoch(t0 + 10));
        await store.unfollow(_uid, 1);
        expect((await store.removed(_uid)).keys, [1]);
        await store.follow(_uid, tid: 1, title: 'a', replies: 4);
        expect(await store.removed(_uid), isEmpty);
        await store.unfollow(_uid, 1);
        final noted = (await store.removed(_uid))[1]!;

        final changes = <int>[];
        final sub = store.changes.listen(changes.add);
        addTearDown(sub.cancel);
        expect(
          await store.applySynced(_uid, {
            '1': {'updated': noted - 1, 'title': 'older than the unfollow here'},
            '2': {'updated': t0 + 10, 'title': 'b, the same'},
            '3': {'updated': t0 + 5, 'title': 'c'},
          }),
          isTrue,
        );
        final list = await store.load(_uid);
        expect([for (final t in list) t.tid], [2, 3]);
        expect(list.last.fromSync, isTrue);
        expect(list.first.seenReplies, 4, reason: 'a thread followed here keeps what its check knows');
        expect(
          await store.applySynced(_uid, {
            '3': {'updated': t0 + 5, 'title': 'c'},
          }),
          isFalse,
        );
        expect(
          await store.applySynced(_uid, {
            '2': {'updated': t0 + 20, 'deleted': true},
          }),
          isTrue,
        );
        expect([for (final t in await store.load(_uid)) t.tid], [3]);
        expect((await store.removed(_uid))[2], t0 + 20);
        await Future<void>.delayed(Duration.zero);
        expect(changes, [_uid, _uid]);
      });

      test('the first check of a thread from another device announces nothing; the next ones do', () async {
        await store.applySynced(_uid, {
          '7': {'updated': DateTime.now().millisecondsSinceEpoch, 'title': 'from the other device'},
        });
        final announced = <FollowedThread>[];
        Future<FollowedThreadRound> round(int replies) => checkFollowedThreads(
          store: store,
          uid: _uid,
          // Typed as the check asks: the answer of a timeout is another kind of fetch.
          fetch: (_) async =>
              FollowedThreadFetched(replies: replies, title: null, viewerUid: _uid) as FollowedThreadFetch,
          announcing: () async => true,
          announce: (t) async {
            announced.add(t);
            return true;
          },
          gap: Duration.zero,
        );
        final first = await round(40);
        expect((first.asked, first.failed), (1, 0));
        expect(announced, isEmpty);
        final t = (await store.of(_uid, 7))!;
        expect((t.fromSync, t.seenReplies, t.knownReplies, t.newReplies), (false, 40, 40, 0));
        await round(43);
        expect(announced.single.newReplies, 3);
        expect(FollowedThread.fromJson(jsonDecode(jsonEncode(t.copyWith(fromSync: true).toJson())))!.fromSync, isTrue);
        expect(t.copyWith(fromSync: true).read(replies: 50).fromSync, isFalse);
      });
    });
  });

  test('the size of a typical document, before and after the new sections', () async {
    final device = _Device(forum, () => now);
    final s = device.store;
    for (var tid = 1; tid <= 150; tid++) {
      (s.visitsByUid[_uid] ??= {})[1000 + tid] = SyncVisit(
        tid: 1000 + tid,
        title: '常见长度的中文帖子标题 $tid',
        fid: 8,
        forumName: '动漫讨论',
        updated: _t + tid,
        progressUpdated: _t + tid,
        page: 2,
        pid: 50000 + tid,
        floor: 27,
        seenReplies: 40,
      );
    }
    s
      ..phraseList = ['谢谢楼主', '收藏了', '顶一下']
      ..settingsUpdatedAt = _t
      ..settingsMap = syncedSettingsDefaults()
      ..blocksByUid[_uid] = [for (var i = 1; i <= 5; i++) SyncBlock(uid: 100 + i, username: '用户$i', updated: _t)];
    device.off.addAll([SyncCategory.replyTemplates, SyncCategory.readLater, SyncCategory.followedThreads]);
    await device.sync();
    final before = utf8.encode(forum.data!).length;

    s.replyTemplateList = [
      for (var i = 1; i <= 5; i++) FastReplyTemplateModel(name: '模板$i', data: '感谢分享，资源已收下，辛苦了！' * 2),
    ];
    for (var tid = 1; tid <= 20; tid++) {
      device.readLater(5000 + tid, title: '想稍后再看的帖子标题 $tid');
    }
    for (var tid = 1; tid <= 15; tid++) {
      device.follow(7000 + tid, title: '追踪中的连载帖子标题 $tid');
    }
    device.off.clear();
    tick();
    await device.sync();
    final after = utf8.encode(forum.data!).length;
    // ignore: avoid_print, the size is part of the report of the change.
    print('typical document: $before bytes before, $after bytes after (+${after - before})');
    expect(after - before, lessThan(8 * 1024));
    expect(after, lessThan(syncDocumentMaxBytes));
  });
}
