import 'dart:async';

import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/notification/utils/push_rules.dart';
import 'package:tsdm_client/features/thread_follow/models/followed_thread.dart';
import 'package:tsdm_client/features/thread_follow/repository/followed_thread_store.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_fetch.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Most threads asked in one round: the ones checked longest ago go first, the others wait for the next round.
const followedThreadRoundLimit = 30;

/// Pause between two threads of a round.
const followedThreadGap = Duration(seconds: 1);

/// How long one thread may take before it counts as failed.
const followedThreadFetchTimeout = Duration(seconds: 30);

/// The check intervals offered, in minutes (`SettingsKeys.followedThreadCheckMinutes`).
const followedThreadCheckChoices = [15, 30, 60];

/// How often the app and the background message service look whether a check is due: the interval itself is kept in
/// the settings table ([FollowedThreadCheckSlot]), so whichever comes first checks and the other skips.
const followedThreadHeartbeat = Duration(minutes: 1);

/// The check interval set, one of [followedThreadCheckChoices] (the default for anything else).
Future<Duration> readFollowedThreadInterval(StorageProvider storage) async {
  final minutes =
      await storage.getInt(SettingsKeys.followedThreadCheckMinutes.name) ??
      SettingsKeys.followedThreadCheckMinutes.defaultValue;
  return Duration(
    minutes: followedThreadCheckChoices.contains(minutes)
        ? minutes
        : SettingsKeys.followedThreadCheckMinutes.defaultValue,
  );
}

/// Shares the check of an account's followed threads between the app and the Android background message service, as
/// `NotificationPollSlot` shares the notification poll: the time of the last check is kept in the shared database
/// ([StorageProvider.followedThreadsCheckedAtKey]), a check is due once an interval passed since.
abstract final class FollowedThreadCheckSlot {
  /// Slack of the interval: the heartbeats of the two checkers do not tick on the minute.
  static const _slack = Duration(seconds: 30);

  /// Take the check of [uid] at [now] for an [interval]: its time (to [release] it), or null when the last check is
  /// less than an interval (less [_slack]) ago. A time in the future (the clock was turned back) does not block.
  static Future<int?> take(StorageProvider storage, int uid, Duration interval, {DateTime? now}) =>
      storage.exclusively(() async {
        final time = (now ?? DateTime.now()).millisecondsSinceEpoch;
        final key = StorageProvider.followedThreadsCheckedAtKey(uid);
        final last = await storage.getInt(key);
        if (last != null && time >= last && time - last < (interval - _slack).inMilliseconds) {
          return null;
        }
        await storage.saveInt(key, time);
        return time;
      });

  /// Give back the check taken as [slot] when nothing was asked: the next heartbeat may check after all.
  static Future<void> release(StorageProvider storage, int uid, int slot) async {
    final key = StorageProvider.followedThreadsCheckedAtKey(uid);
    if (await storage.getInt(key) == slot) {
      await storage.deleteKey(key);
    }
  }
}

/// Whether the new replies of followed threads are announced at [now]: the category is on and it is not the quiet
/// hours (the same rules as the notices, [NotificationPushRules]).
///
/// Unlike a notice, a thread not announced because of the rules stays unannounced ([FollowedThread.notified] false):
/// the first round after the quiet hours announces it, when it is still not read.
Future<bool> followedThreadsAnnounced(StorageProvider storage, DateTime now) async {
  final rules = await NotificationPushRules.read(storage);
  return rules.enabled.contains(NoticeCategory.followedThread) && !rules.isQuiet(now);
}

/// What a round of [checkFollowedThreads] did.
typedef FollowedThreadRound = ({int asked, int failed, List<FollowedThread> announced, bool stopped});

/// Check the threads account [uid] follows for new replies, one after another, and store what was found.
///
/// At most [limit] threads, the ones checked longest ago first (never checked first of all), [gap] between two of
/// them, each asked through [fetch] (`fetchFollowedThread` with the account's client) and given up after [timeout].
///
/// A thread read is stored right away (its replies, title, newest floor and the time of the check) under the store's
/// lock, on the entry stored then: a thread unfollowed meanwhile stays unfollowed, a thread read meanwhile keeps what
/// was read. A thread with replies not read yet that was not announced since it was read is handed to [announce] when
/// [announcing] says so at that moment, and marked announced ([FollowedThread.notified]): once until it is read.
///
/// A failure is not announced and the thread is asked again next round. The round stops when the forum asks to slow
/// down (429), when a page was served to another account or to a guest (the session expired, or the account was
/// switched: nothing of it is stored), and when [keepGoing] says no (the account switched, the service stopped).
Future<FollowedThreadRound> checkFollowedThreads({
  required FollowedThreadStore store,
  required int uid,
  required Future<FollowedThreadFetch> Function(int tid) fetch,
  required Future<bool> Function() announcing,
  required Future<void> Function(FollowedThread thread) announce,
  bool Function()? keepGoing,
  DateTime Function() clock = DateTime.now,
  int limit = followedThreadRoundLimit,
  Duration gap = followedThreadGap,
  Duration timeout = followedThreadFetchTimeout,
}) async {
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  final threads = (await store.load(uid))..sort((a, b) => (a.checkedAt ?? epoch).compareTo(b.checkedAt ?? epoch));
  final due = threads.take(limit).toList();
  final announced = <FollowedThread>[];
  var asked = 0;
  var failed = 0;
  var stopped = false;
  for (final thread in due) {
    if (keepGoing != null && !keepGoing()) {
      stopped = true;
      break;
    }
    if (asked > 0 && gap > Duration.zero) {
      await Future<void>.delayed(gap);
    }
    asked++;
    final FollowedThreadFetch result;
    try {
      result = await fetch(
        thread.tid,
      ).timeout(timeout, onTimeout: () => FollowedThreadFetchFailed('no answer within ${timeout.inSeconds}s'));
    } on Object catch (e) {
      failed++;
      talker.warning('followed thread ${thread.tid}: check threw: $e');
      continue;
    }
    if (keepGoing != null && !keepGoing()) {
      stopped = true;
      break;
    }
    final now = clock();
    switch (result) {
      case FollowedThreadFetchFailed(:final reason, :final rateLimited):
        failed++;
        talker.debug('followed thread ${thread.tid}: not checked, $reason');
        if (rateLimited) {
          stopped = true;
        } else {
          await store.update(uid, thread.tid, (current) => current?.copyWith(checkedAt: now));
        }
      case FollowedThreadFetched(:final viewerUid) when viewerUid != uid:
        failed++;
        stopped = true;
        talker.info(
          'followed threads of uid ${"$uid".obscured(4)}: page served to '
          '${viewerUid == null ? "a guest" : "another account"}, round stopped',
        );
      case FollowedThreadFetched(:final replies, :final title, :final lastReplyAt):
        final allowed = await announcing();
        var toAnnounce = false;
        final stored = await store.update(uid, thread.tid, (current) {
          if (current == null) {
            return null;
          }
          final next = current.copyWith(
            title: title == null || title.isEmpty ? null : title,
            knownReplies: replies,
            lastReplyAt: lastReplyAt,
            checkedAt: now,
          );
          toAnnounce = allowed && next.newReplies > 0 && !next.notified;
          return toAnnounce ? next.copyWith(notified: true) : next;
        });
        if (toAnnounce && stored != null) {
          announced.add(stored);
          try {
            await announce(stored);
          } on Object catch (e, st) {
            talker.handle(e, st, 'followed thread ${thread.tid}: announcing failed');
          }
        }
    }
    if (stopped) {
      break;
    }
  }
  return (asked: asked, failed: failed, announced: announced, stopped: stopped);
}

/// One check of account [uid]'s followed threads when it is due ([FollowedThreadCheckSlot]): nothing when the account
/// follows nothing or the last check is less than an interval ago. [prepare] runs right before the first request (the
/// network settings of the background service); when it throws nothing is asked. See [checkFollowedThreads].
Future<FollowedThreadRound?> followedThreadsTick({
  required StorageProvider storage,
  required FollowedThreadStore store,
  required int uid,
  required Future<FollowedThreadFetch> Function(int tid) fetch,
  required Future<void> Function(FollowedThread thread) announce,
  Future<void> Function()? prepare,
  bool Function()? keepGoing,
  DateTime Function() clock = DateTime.now,
  Duration gap = followedThreadGap,
}) async {
  if (uid <= 0 || (await store.load(uid)).isEmpty) {
    return null;
  }
  final slot = await FollowedThreadCheckSlot.take(
    storage,
    uid,
    await readFollowedThreadInterval(storage),
    now: clock(),
  );
  if (slot == null) {
    return null;
  }
  try {
    await prepare?.call();
  } on Object catch (e) {
    talker.warning('followed threads: network settings unavailable, not checked: $e');
    await FollowedThreadCheckSlot.release(storage, uid, slot);
    return null;
  }
  final round = await checkFollowedThreads(
    store: store,
    uid: uid,
    fetch: fetch,
    announcing: () => followedThreadsAnnounced(storage, clock()),
    announce: announce,
    keepGoing: keepGoing,
    clock: clock,
    gap: gap,
  );
  talker.debug(
    'followed threads of uid ${"$uid".obscured(4)}: ${round.asked} asked, ${round.failed} failed, '
    '${round.announced.length} announced${round.stopped ? ", stopped" : ""}',
  );
  return round;
}
