import 'package:tsdm_client/features/sync/models/sync_removals.dart';
import 'package:tsdm_client/features/thread_follow/models/followed_thread.dart';

/// The section of the sync document holding the threads the account follows: one item per thread, by its id.
///
/// ```json
/// "follows": {"<tid>": {"updated": ms, "title": "…"},
///             "<tid>": {"updated": ms, "deleted": true}}
/// ```
///
/// `updated` is when the thread was followed, or when it was unfollowed (a record of the removal, kept on the device as
/// [syncRemovalsOf] reads them). Item by item the later wins: a thread unfollowed on one device is unfollowed on the
/// others unless one followed it again after that. What a device's check of a thread knows (the replies seen and
/// found, when it was checked, whether it was announced) never goes with it: a thread that comes from another device
/// is checked here from the replies it has then ([FollowedThread.fromSync]).
const followedThreadsSection = 'follows';

/// The items of [followedThreadsSection] a device holds: its [threads], and the records of the threads it unfollowed
/// ([removed]) that it does not follow. A thread whose item in the forum's last document [base] is of the same time
/// keeps that item (its title then), so a title the check found since is no change to write.
Map<String, Map<String, dynamic>> followedThreadSyncItems(
  List<FollowedThread> threads,
  Map<int, int> removed,
  Map<String, Map<String, dynamic>> base,
) => syncItemsWithRemovals({
  for (final t in threads)
    t.tid: switch (base['${t.tid}']) {
      final was? when was['deleted'] != true && was['updated'] == t.followedAt.millisecondsSinceEpoch => was,
      _ => {'updated': t.followedAt.millisecondsSinceEpoch, 'title': t.title},
    },
}, removed);

/// What taking the [items] of [followedThreadsSection] in changes on a device following [threads] with the records
/// [removed]: the threads to follow (from the other device, [FollowedThread.fromSync]) and the threads to unfollow,
/// each with the time of the item. A thread followed here stays as it is whatever the item says but a later
/// removal; a removal of a thread not followed here changes nothing.
({List<FollowedThread> follow, Map<int, int> unfollow}) followedThreadSyncChanges(
  List<FollowedThread> threads,
  Map<int, int> removed,
  Map<String, Map<String, dynamic>> items,
) {
  final byTid = {for (final t in threads) t.tid: t};
  final follow = <FollowedThread>[];
  final unfollow = <int, int>{};
  for (final MapEntry(:key, value: item) in items.entries) {
    final tid = int.tryParse(key);
    final at = item['updated'];
    if (tid == null || tid <= 0 || at is! num) {
      continue;
    }
    final mine = byTid[tid];
    if (item['deleted'] == true || item['deleted'] == 1) {
      if (mine != null && mine.followedAt.millisecondsSinceEpoch <= at.toInt()) {
        unfollow[tid] = at.toInt();
      }
      continue;
    }
    final title = item['title'];
    if (mine != null || title is! String || (removed[tid] ?? -1) >= at.toInt()) {
      continue;
    }
    follow.add(
      FollowedThread(
        tid: tid,
        title: title,
        seenReplies: 0,
        knownReplies: 0,
        followedAt: DateTime.fromMillisecondsSinceEpoch(at.toInt()),
        fromSync: true,
      ),
    );
  }
  return (follow: follow, unfollow: unfollow);
}

/// [threads] with [follow] put in (by the time they were followed among the others, the latest first) and the threads
/// of [unfollow] taken out.
List<FollowedThread> followedThreadsWithSynced(
  List<FollowedThread> threads,
  List<FollowedThread> follow,
  Iterable<int> unfollow,
) {
  final list = [
    for (final t in threads)
      if (!unfollow.contains(t.tid)) t,
  ];
  for (final t in follow) {
    final at = list.indexWhere((e) => e.followedAt.isBefore(t.followedAt));
    list.insert(at < 0 ? list.length : at, t);
  }
  return list;
}
