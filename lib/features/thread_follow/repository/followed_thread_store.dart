import 'dart:async';
import 'dart:convert';

import 'package:tsdm_client/features/sync/models/sync_removals.dart';
import 'package:tsdm_client/features/thread_follow/models/followed_thread.dart';
import 'package:tsdm_client/features/thread_follow/models/followed_thread_sync.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// The threads each account follows ([FollowedThread]), kept on this device in the settings table: one JSON list per
/// account ([StorageProvider.followedThreadsKey]), removed with the account.
///
/// The app and the Android background message service (an isolate of its own on the same database) both write the
/// list: the app when the account follows, unfollows or reads a thread, the service when a check found new replies.
/// Every change is one read-modify-write of the stored list under the database's write lock
/// ([StorageProvider.exclusively]) and touches only the entry it is about, so a thread unfollowed while a check runs
/// does not come back and a read is not undone by the check that started before it ([update]).
final class FollowedThreadStore with LoggerMixin {
  /// Constructor.
  FollowedThreadStore(this._storage);

  /// The app's store (the list, its check and the cross-device sync share its change stream), null when none is
  /// registered (tests of other features).
  static FollowedThreadStore? get app =>
      getIt.isRegistered<FollowedThreadStore>() ? getIt.get<FollowedThreadStore>() : null;

  final StorageProvider _storage;

  final _changes = StreamController<int>.broadcast();

  /// Accounts whose list changed through this store, by uid; what another isolate wrote is only seen by [load].
  Stream<int> get changes => _changes.stream;

  /// The threads account [uid] follows, the one followed last first.
  Future<List<FollowedThread>> load(int uid) async => _decode(await _storage.getString(_key(uid)));

  /// The entry of thread [tid] of account [uid], null when it is not followed.
  Future<FollowedThread?> of(int uid, int tid) async {
    for (final e in await load(uid)) {
      if (e.tid == tid) {
        return e;
      }
    }
    return null;
  }

  /// Change the entry of thread [tid] of account [uid] to what [change] makes of the stored one (null: not followed).
  ///
  /// [change] returning null removes the entry; a new entry goes first in the list, or at [insertAt] when given (an
  /// entry put back where it was). Returns the entry as stored.
  Future<FollowedThread?> update(
    int uid,
    int tid,
    FollowedThread? Function(FollowedThread? current) change, {
    int? insertAt,
  }) async {
    final result = await _storage.exclusively(() async {
      final list = await load(uid);
      final index = list.indexWhere((e) => e.tid == tid);
      final current = index < 0 ? null : list[index];
      final next = change(current);
      if (next == current) {
        return (changed: false, entry: current);
      }
      if (next == null) {
        list.removeAt(index);
      } else if (index < 0) {
        list.insert((insertAt ?? 0).clamp(0, list.length), next);
      } else {
        list[index] = next;
      }
      await _write(uid, list);
      // Unfollowed, or followed again: the record the cross-device sync tells the other devices by.
      if (current == null || next == null) {
        final at = DateTime.now().millisecondsSinceEpoch;
        await _writeRemoved(
          uid,
          syncRemovalsWith(
            await removed(uid),
            tids: {if (next == null) tid: at},
            back: [if (next != null) tid],
            at: at,
          ),
        );
      }
      return (changed: true, entry: next);
    });
    if (result.changed && !_changes.isClosed) {
      _changes.add(uid);
    }
    return result.entry;
  }

  /// Follow thread [tid] titled [title] for account [uid], with its [replies] now (all seen) and the time of its newest
  /// floor [lastReplyAt]. Following a thread already followed reads it ([FollowedThread.read]).
  Future<FollowedThread?> follow(
    int uid, {
    required int tid,
    required String title,
    required int replies,
    DateTime? lastReplyAt,
    DateTime? now,
  }) => update(
    uid,
    tid,
    (current) =>
        current?.read(replies: replies, title: title, lastReplyAt: lastReplyAt) ??
        FollowedThread(
          tid: tid,
          title: title,
          seenReplies: replies,
          knownReplies: replies,
          followedAt: now ?? DateTime.now(),
          lastReplyAt: lastReplyAt,
        ),
  );

  /// Stop following thread [tid] for account [uid].
  Future<void> unfollow(int uid, int tid) => update(uid, tid, (_) => null);

  /// Account [uid] read thread [tid] with [replies] (null when the page did not tell): its new replies are cleared
  /// ([FollowedThread.read]). Nothing happens for a thread not followed.
  Future<FollowedThread?> markRead(int uid, int tid, {int? replies, String? title, DateTime? lastReplyAt}) =>
      update(uid, tid, (current) => current?.read(replies: replies, title: title, lastReplyAt: lastReplyAt));

  /// The records of the threads account [uid] unfollowed (thread id to the time, milliseconds), for the cross-device
  /// sync.
  Future<Map<int, int>> removed(int uid) async => syncRemovalsOf(await _storage.getString(_removedKey(uid)));

  /// Take the items of the sync's [followedThreadsSection] in for account [uid] ([followedThreadSyncChanges]): the
  /// threads followed on another device are followed here (checked from the replies they have then), the threads
  /// unfollowed there are unfollowed here. One read-modify-write under the database's write lock, like [update];
  /// nothing is written when nothing changes. Whether something changed.
  Future<bool> applySynced(int uid, Map<String, Map<String, dynamic>> items) async {
    final changed = await _storage.exclusively(() async {
      final list = await load(uid);
      final removedNow = await removed(uid);
      final (:follow, :unfollow) = followedThreadSyncChanges(list, removedNow, items);
      if (follow.isEmpty && unfollow.isEmpty) {
        return false;
      }
      await _write(uid, followedThreadsWithSynced(list, follow, unfollow.keys));
      await _writeRemoved(
        uid,
        syncRemovalsWith(
          removedNow,
          tids: unfollow,
          back: [for (final t in follow) t.tid],
          at: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      return true;
    });
    if (changed && !_changes.isClosed) {
      _changes.add(uid);
    }
    return changed;
  }

  /// Close the change stream.
  Future<void> dispose() => _changes.close();

  static String _key(int uid) => StorageProvider.followedThreadsKey(uid);

  static String _removedKey(int uid) => StorageProvider.followedThreadsRemovedKey(uid);

  Future<void> _writeRemoved(int uid, String? raw) async =>
      raw == null ? _storage.deleteKey(_removedKey(uid)) : _storage.saveString(_removedKey(uid), raw);

  Future<void> _write(int uid, List<FollowedThread> list) async {
    if (list.isEmpty) {
      await _storage.deleteKey(_key(uid));
      return;
    }
    await _storage.saveString(_key(uid), jsonEncode([for (final e in list) e.toJson()]));
  }

  List<FollowedThread> _decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return [];
    }
    try {
      final json = jsonDecode(raw);
      if (json is! List) {
        return [];
      }
      final seen = <int>{};
      return [
        for (final e in json.map(FollowedThread.fromJson))
          if (e != null && seen.add(e.tid)) e,
      ];
    } on FormatException catch (e) {
      warning('followed threads not readable, starting over: $e');
      return [];
    }
  }
}
