/// Followed threads: a thread followed on this device is checked for new replies and announced once until it is read.
///
/// * The check reads a thread's replies (the floors after the first, `thread.replies`) and its newest floor from the
///   structured answer of the forum's app API, or from the web page without the plugin; the forum's message, a guest's
///   page or a page served to another account is no reading.
/// * The list is kept per account in the settings table; a change touches only its own entry, so a thread unfollowed
///   while a check runs stays unfollowed.
/// * A round asks at most 30 threads, the ones checked longest ago first; a failure is not announced; a thread with new
///   replies is announced once until it is read; the category switch and the quiet hours hold the announcement back
///   until they allow it; a 429 or a page of another account stops the round.
/// * The check is shared between the app and the background service through the time of the last check.
/// * The notification opens the last floor of the thread as the account that follows it.
///
/// The answers are the test forum's (plugin 3.4.0, `schema: 18`): `followed_v18_before.json` (the thread without
/// replies), `followed_v18_after.json` (three replies by another account later) and `followed_thread_after_x5.html`
/// (the same page without the plugin), scrubbed.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/utils/push_rules.dart';
import 'package:tsdm_client/features/thread_follow/cubit/followed_threads_cubit.dart';
import 'package:tsdm_client/features/thread_follow/models/followed_thread.dart';
import 'package:tsdm_client/features/thread_follow/repository/followed_thread_store.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_check.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_fetch.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_notice.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

String _data(String name) => File('test/data/$name').readAsStringSync();

const _uid = 31;
const _tid = 9202774;

FollowedThread _thread(int tid, {int seen = 0, int known = 0, DateTime? checked, bool notified = false}) =>
    FollowedThread(
      tid: tid,
      title: 'thread $tid',
      seenReplies: seen,
      knownReplies: known,
      followedAt: DateTime(2026, 11),
      checkedAt: checked,
      notified: notified,
    );

FollowedThreadFetch _replies(int n, {int? viewer = _uid}) =>
    FollowedThreadFetched(replies: n, title: null, lastReplyAt: DateTime(2026, 11, 8, 12), viewerUid: viewer);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('reading a followed thread', () {
    test('the structured answer: replies, title, newest floor, the account served', () {
      final before = followedThreadStateOf(jsonDecode(_data('tsdmapp/followed_v18_before.json')));
      final after = followedThreadStateOf(_data('tsdmapp/followed_v18_after.json'));
      expect(before, isA<FollowedThreadFetched>());
      expect(after, isA<FollowedThreadFetched>());
      before as FollowedThreadFetched;
      after as FollowedThreadFetched;
      expect(before.replies, 0);
      expect(after.replies, 3);
      expect(after.title, '追踪帖子测试：新番讨论');
      expect(after.viewerUid, _uid);
      // The newest floor is the third reply, newer than the first floor (the only one before).
      expect(after.lastReplyAt, isNotNull);
      expect(after.lastReplyAt!.isAfter(before.lastReplyAt!), isTrue);
      expect(after.lastReplyAt!.difference(before.lastReplyAt!), const Duration(seconds: 1794147725 - 1794147685));
    });

    test('the web page without the plugin', () {
      final page = followedThreadStateOf(_data('followed_thread_after_x5.html'));
      expect(page, isA<FollowedThreadFetched>());
      page as FollowedThreadFetched;
      expect(page.replies, 3);
      expect(page.viewerUid, _uid);
      expect(page.lastReplyAt, isNotNull);
    });

    test("the forum's message is no reading", () {
      final message = {'ok': 0, 'api': 1, 'schema': 18, 'error': 'message', 'login': 0, 'message': '抱歉，指定的主题不存在'};
      expect(followedThreadStateOf(message), isA<FollowedThreadFetchFailed>());
    });

    test('the url asks the newest floors first in the JSON mode', () {
      final url = followedThreadCheckUrl(5, base: 'https://forum.test');
      expect(url, startsWith('https://forum.test/forum.php?mod=viewthread&tid=5&ordertype=1&'));
      expect(url, contains('tsdmapp=json'));
      expect(url, contains('nodoc=1'));
    });
  });

  group('the entry', () {
    test('round trip, new replies, read', () {
      final e = _thread(7, seen: 2, known: 5, checked: DateTime(2026, 11, 8), notified: true);
      expect(FollowedThread.fromJson(jsonDecode(jsonEncode(e.toJson()))), e);
      expect(e.newReplies, 3);
      final read = e.read(replies: 6);
      expect(read.newReplies, 0);
      expect(read.seenReplies, 6);
      expect(read.notified, isFalse);
      expect(FollowedThread.fromJson({'tid': 0}), isNull);
      expect(FollowedThread.fromJson('x'), isNull);
    });
  });

  group('store, slot and round', () {
    late AppDatabase db;
    late StorageProvider storage;
    late FollowedThreadStore store;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      store = FollowedThreadStore(storage);
    });

    tearDown(() async {
      await store.dispose();
      await db.close();
    });

    Future<void> seed(List<FollowedThread> threads) async {
      for (final t in threads.reversed) {
        await store.update(_uid, t.tid, (_) => t);
      }
    }

    test('follow, read, unfollow; per account; garbage reads as nothing', () async {
      await store.follow(_uid, tid: 1, title: 'a', replies: 4);
      await store.follow(_uid, tid: 2, title: 'b', replies: 0);
      expect((await store.load(_uid)).map((e) => e.tid), [2, 1]);
      expect(await store.load(32), isEmpty);
      await store.update(_uid, 1, (e) => e!.copyWith(knownReplies: 9));
      expect((await store.of(_uid, 1))!.newReplies, 5);
      await store.markRead(_uid, 1, replies: 9);
      expect((await store.of(_uid, 1))!.newReplies, 0);
      expect(await store.markRead(_uid, 3, replies: 1), isNull);
      await store.unfollow(_uid, 2);
      expect((await store.load(_uid)).map((e) => e.tid), [1]);
      await storage.saveString(StorageProvider.followedThreadsKey(_uid), 'not json');
      expect(await store.load(_uid), isEmpty);
    });

    test('the slot: due once an interval passed, released when nothing was asked', () async {
      final t0 = DateTime(2026, 11, 8, 10);
      const interval = Duration(minutes: 30);
      final slot = await FollowedThreadCheckSlot.take(storage, _uid, interval, now: t0);
      expect(slot, isNotNull);
      expect(
        await FollowedThreadCheckSlot.take(storage, _uid, interval, now: t0.add(const Duration(minutes: 10))),
        isNull,
      );
      expect(
        await FollowedThreadCheckSlot.take(
          storage,
          _uid,
          interval,
          now: t0.add(const Duration(minutes: 29, seconds: 40)),
        ),
        isNotNull,
      );
      final again = await FollowedThreadCheckSlot.take(storage, 32, interval, now: t0);
      await FollowedThreadCheckSlot.release(storage, 32, again!);
      expect(await FollowedThreadCheckSlot.take(storage, 32, interval, now: t0), isNotNull);
      // The interval set, the default for anything not offered.
      expect(await readFollowedThreadInterval(storage), const Duration(minutes: 30));
      await storage.saveInt(SettingsKeys.followedThreadCheckMinutes.name, 15);
      expect(await readFollowedThreadInterval(storage), const Duration(minutes: 15));
      await storage.saveInt(SettingsKeys.followedThreadCheckMinutes.name, 7);
      expect(await readFollowedThreadInterval(storage), const Duration(minutes: 30));
    });

    Future<FollowedThreadRound> round(
      Future<FollowedThreadFetch> Function(int tid) fetch, {
      List<FollowedThread>? announced,
      bool allowed = true,
      DateTime? now,
    }) => checkFollowedThreads(
      store: store,
      uid: _uid,
      fetch: fetch,
      announcing: () async => allowed,
      announce: (t) async {
        announced?.add(t);
        return true;
      },
      clock: () => now ?? DateTime(2026, 11, 8, 12),
      gap: Duration.zero,
    );

    test('at most 30 threads, the ones checked longest ago first', () async {
      final base = DateTime(2026, 11, 8);
      await seed([
        for (var i = 1; i <= 35; i++) _thread(i, checked: i <= 5 ? null : base.add(Duration(minutes: 40 - i))),
      ]);
      final asked = <int>[];
      final r = await round((tid) async {
        asked.add(tid);
        return _replies(0);
      });
      expect(r.asked, 30);
      expect(asked.take(5).toSet(), {1, 2, 3, 4, 5});
      // Then the oldest checks: tid 35 was checked earliest.
      expect(asked[5], 35);
      expect(asked, isNot(contains(6)));
      // Next round: the five left out are first now.
      asked.clear();
      await round((tid) async {
        asked.add(tid);
        return _replies(0);
      }, now: DateTime(2026, 11, 8, 13));
      expect(asked.take(5).toSet(), {6, 7, 8, 9, 10});
    });

    test('new replies are announced once until read; a failure is not announced', () async {
      await seed([_thread(1, seen: 2, known: 2), _thread(2)]);
      final announced = <FollowedThread>[];
      final r = await round(
        (tid) async => tid == 1 ? _replies(5) : const FollowedThreadFetchFailed('down'),
        announced: announced,
      );
      expect(r.failed, 1);
      expect(announced.single.tid, 1);
      expect(announced.single.newReplies, 3);
      expect((await store.of(_uid, 1))!.notified, isTrue);
      // More replies, not read yet: not announced again.
      announced.clear();
      await round((tid) async => tid == 1 ? _replies(7) : _replies(0), announced: announced);
      expect(announced, isEmpty);
      expect((await store.of(_uid, 1))!.newReplies, 5);
      // Read: the next replies are announced again.
      await store.markRead(_uid, 1, replies: 7);
      await round((tid) async => tid == 1 ? _replies(8) : _replies(0), announced: announced);
      expect(announced.single.newReplies, 1);
    });

    test('held back while the rules do not allow it, announced once they do', () async {
      await seed([_thread(1, seen: 1, known: 1)]);
      final announced = <FollowedThread>[];
      await round((_) async => _replies(3), announced: announced, allowed: false);
      expect(announced, isEmpty);
      expect((await store.of(_uid, 1))!.notified, isFalse);
      await round((_) async => _replies(3), announced: announced);
      expect(announced.single.newReplies, 2);
    });

    test('fewer replies than were read (floors deleted): the next ones count from there', () async {
      await seed([_thread(1, seen: 10, known: 10)]);
      final announced = <FollowedThread>[];
      await round((_) async => _replies(7), announced: announced);
      expect(announced, isEmpty);
      expect((await store.of(_uid, 1))!.seenReplies, 7);
      await round((_) async => _replies(9), announced: announced);
      expect(announced.single.newReplies, 2);
    });

    test('a notification not posted is taken back and posted next round', () async {
      await seed([_thread(1, seen: 1, known: 1)]);
      final r = await checkFollowedThreads(
        store: store,
        uid: _uid,
        fetch: (_) async => _replies(3),
        announcing: () async => true,
        announce: (_) async => false,
        gap: Duration.zero,
      );
      expect(r.announced, isEmpty);
      expect((await store.of(_uid, 1))!.notified, isFalse);
      final thrown = await checkFollowedThreads(
        store: store,
        uid: _uid,
        fetch: (_) async => _replies(3),
        announcing: () async => true,
        announce: (_) async => throw StateError('plugin'),
        gap: Duration.zero,
      );
      expect(thrown.announced, isEmpty);
      expect((await store.of(_uid, 1))!.notified, isFalse);
      final announced = <FollowedThread>[];
      await round((_) async => _replies(3), announced: announced);
      expect(announced.single.newReplies, 2);
    });

    test('deleted floors leaving nothing new clear the announcement', () async {
      await seed([_thread(1, seen: 10, known: 12, notified: true)]);
      final cleared = <int>[];
      await checkFollowedThreads(
        store: store,
        uid: _uid,
        fetch: (_) async => _replies(9),
        announcing: () async => true,
        announce: (_) async => true,
        onCleared: cleared.add,
        gap: Duration.zero,
      );
      expect(cleared, [1]);
      final e = (await store.of(_uid, 1))!;
      expect((e.newReplies, e.notified), (0, false));
      final announced = <FollowedThread>[];
      await round((_) async => _replies(10), announced: announced);
      expect(announced.single.newReplies, 1);
    });

    test('the cubit: a read without news writes nothing, a read of news takes the notification back', () async {
      await seed([_thread(1, seen: 3, known: 3), _thread(2, seen: 1, known: 4, notified: true)]);
      final taken = <int>[];
      final cubit = FollowedThreadsCubit(store: store, storage: storage, uid: _uid, onRead: taken.add);
      await cubit.stream.firstWhere((s) => s.loaded);
      var writes = 0;
      final sub = store.changes.listen((_) => writes++);
      await cubit.markRead(uid: _uid, tid: 1, replies: 3, title: 'thread 1');
      await cubit.markRead(uid: _uid, tid: 9, replies: 3);
      expect(writes, 0);
      await cubit.markRead(uid: _uid, tid: 2, replies: 4);
      await Future<void>.delayed(Duration.zero);
      expect(taken, [2]);
      expect((await store.of(_uid, 2))!.notified, isFalse);
      // Announced by the background service behind the cubit's back: the read still clears it.
      await FollowedThreadStore(storage).update(_uid, 1, (e) => e!.copyWith(knownReplies: 5, notified: true));
      expect(cubit.state.of(1)!.notified, isFalse);
      await cubit.markRead(uid: _uid, tid: 1, replies: 5);
      expect(taken, [2, 1]);
      expect((await store.of(_uid, 1))!.notified, isFalse);
      await sub.cancel();
      await cubit.close();
    });

    test('put back where it was', () async {
      await seed([_thread(1), _thread(2), _thread(3)]);
      final second = (await store.of(_uid, 2))!;
      await store.unfollow(_uid, 2);
      await store.update(_uid, 2, (c) => c ?? second, insertAt: 1);
      expect((await store.load(_uid)).map((e) => e.tid), [1, 2, 3]);
    });

    test('the category and the quiet hours', () async {
      final noon = DateTime(2026, 11, 8, 12);
      expect(await followedThreadsAnnounced(storage, noon), isTrue);
      await storage.saveBool(SettingsKeys.notifyFollowedThread.name, value: false);
      expect(await followedThreadsAnnounced(storage, noon), isFalse);
      await storage.saveBool(SettingsKeys.notifyFollowedThread.name, value: true);
      await storage.saveBool(SettingsKeys.notifyQuietHours.name, value: true);
      expect(await followedThreadsAnnounced(storage, DateTime(2026, 11, 8, 23, 30)), isFalse);
      expect(await followedThreadsAnnounced(storage, noon), isTrue);
    });

    test('a 429 or a page of another account (or a guest) stops the round', () async {
      await seed([_thread(1), _thread(2), _thread(3)]);
      var asked = 0;
      var r = await round((tid) async {
        asked++;
        return const FollowedThreadFetchFailed('429', rateLimited: true);
      });
      expect((asked, r.stopped), (1, true));
      asked = 0;
      final announced = <FollowedThread>[];
      r = await round((tid) async {
        asked++;
        return _replies(9, viewer: null);
      }, announced: announced);
      expect((asked, r.stopped), (1, true));
      expect(announced, isEmpty);
      expect((await store.of(_uid, 1))!.knownReplies, 0);
    });

    test('a thread unfollowed or read while the round runs stays so', () async {
      await seed([_thread(1, seen: 1, known: 1), _thread(2, seen: 1, known: 1)]);
      final announced = <FollowedThread>[];
      await round((tid) async {
        if (tid == 1) {
          // Unfollowed in the app while its page was on the way.
          await store.unfollow(_uid, 1);
        } else {
          await store.markRead(_uid, 2, replies: 4);
        }
        return _replies(4);
      }, announced: announced);
      expect(await store.of(_uid, 1), isNull);
      expect((await store.of(_uid, 2))!.newReplies, 0);
      expect(announced, isEmpty);
    });

    test('the tick: nothing followed, nothing asked; then once per interval', () async {
      var asked = 0;
      Future<FollowedThreadFetch> fetch(int tid) async {
        asked++;
        return _replies(1);
      }

      final t0 = DateTime(2026, 11, 8, 12);
      expect(
        await followedThreadsTick(storage: storage, store: store, uid: _uid, fetch: fetch, announce: (_) async => true),
        isNull,
      );
      await seed([_thread(1)]);
      final first = await followedThreadsTick(
        storage: storage,
        store: store,
        uid: _uid,
        fetch: fetch,
        announce: (_) async => true,
        clock: () => t0,
        gap: Duration.zero,
      );
      expect(first!.announced.single.tid, 1);
      expect(
        await followedThreadsTick(
          storage: storage,
          store: store,
          uid: _uid,
          fetch: fetch,
          announce: (_) async => true,
          clock: () => t0.add(const Duration(minutes: 5)),
        ),
        isNull,
      );
      expect(asked, 1);
    });

    test('the threads go with the account', () async {
      await store.follow(_uid, tid: 1, title: 'a', replies: 0);
      await FollowedThreadCheckSlot.take(storage, _uid, const Duration(minutes: 30));
      await storage.deleteUserLoginInfo(_uid);
      expect(await store.load(_uid), isEmpty);
      expect(await storage.getInt(StorageProvider.followedThreadsCheckedAtKey(_uid)), isNull);
    });
  });

  group('the notification', () {
    test('names the thread and the new replies, opens its last floor as the account', () async {
      final tr = await AppLocale.zhCn.build();
      final thread = _thread(_tid, seen: 1, known: 3);
      final content = followedThreadNoticeContentOf(tr, thread, uid: _uid);
      expect(content.body, '《thread $_tid》有 2 条新回复');
      expect(content.title, tr.localNotification.channels.followedThread);
      expect(LocalNoticeKeys.parseOpenNotification(content.payload), (uid: _uid));
      expect(LocalNoticeKeys.parseTarget(content.payload), const LocalNoticeTarget(tid: _tid, lastPost: true));
      final hidden = followedThreadNoticeContentOf(tr, thread, uid: _uid, hideContent: true);
      expect(hidden.body, isNot(contains('thread')));
      expect(hidden.body, contains('2'));
    });

    test('its id is apart from the auto sync and the service', () {
      for (final tid in [1, _tid, 0x0FFFFFFF]) {
        final id = followedThreadNoticeId(tid);
        expect(isLocalNoticeId(id), isFalse);
        expect(id, isNot(888));
        expect(id, isNot(localNoticeIdOf(tid)));
      }
    });

    test('the category has its own channel and switch', () async {
      expect(NoticeCategory.followedThread.settingsKey, SettingsKeys.notifyFollowedThread);
      for (final tr in [await AppLocale.zhCn.build(), await AppLocale.zhTw.build(), await AppLocale.en.build()]) {
        expect(noticeChannelName(tr, NoticeCategory.followedThread), isNotEmpty);
        expect(tr.followedThreads.notice.body(title: 'x', n: 2), contains('2'));
      }
    });
  });
}
