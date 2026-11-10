import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_config.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_state.dart';
import 'package:tsdm_client/features/forum_watch/repository/forum_watch_store.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_fetch.dart';
import 'package:tsdm_client/features/notification/utils/push_rules.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Pause between two sources of a round.
const forumWatchGap = Duration(seconds: 2);

/// How long one source may take before it counts as failed.
const forumWatchFetchTimeout = Duration(seconds: 30);

/// The check intervals offered, in minutes (`SettingsKeys.forumWatchCheckMinutes`).
const forumWatchCheckChoices = [15, 30, 60];

/// How often the app and the background message service look whether a check is due: the interval itself is kept in
/// the settings table ([ForumWatchCheckSlot]), so whichever comes first checks and the other skips.
const forumWatchHeartbeat = Duration(minutes: 1);

/// The check interval set, one of [forumWatchCheckChoices] (the default for anything else).
Future<Duration> readForumWatchInterval(StorageProvider storage) async {
  final minutes =
      await storage.getInt(SettingsKeys.forumWatchCheckMinutes.name) ??
      SettingsKeys.forumWatchCheckMinutes.defaultValue;
  return Duration(
    minutes: forumWatchCheckChoices.contains(minutes) ? minutes : SettingsKeys.forumWatchCheckMinutes.defaultValue,
  );
}

/// Shares the check of an account's watched forums between the app and the Android background message service, as
/// `FollowedThreadCheckSlot` shares the check of the followed threads: the time of the last check is kept in the
/// shared database ([StorageProvider.forumWatchCheckedAtKey]), a check is due once an interval passed since.
abstract final class ForumWatchCheckSlot {
  /// Slack of the interval: the heartbeats of the two checkers do not tick on the minute.
  static const _slack = Duration(seconds: 30);

  /// Take the check of [uid] at [now] for an [interval]: its time (to [release] it), or null when the last check is
  /// less than an interval (less [_slack]) ago. A time in the future (the clock was turned back) does not block.
  static Future<int?> take(StorageProvider storage, int uid, Duration interval, {DateTime? now}) =>
      storage.exclusively(() async {
        final time = (now ?? DateTime.now()).millisecondsSinceEpoch;
        final key = StorageProvider.forumWatchCheckedAtKey(uid);
        final last = await storage.getInt(key);
        if (last != null && time >= last && time - last < (interval - _slack).inMilliseconds) {
          return null;
        }
        await storage.saveInt(key, time);
        return time;
      });

  /// Give back the check taken as [slot] when nothing was asked: the next heartbeat may check after all.
  static Future<void> release(StorageProvider storage, int uid, int slot) => storage.exclusively(() async {
    final key = StorageProvider.forumWatchCheckedAtKey(uid);
    if (await storage.getInt(key) == slot) {
      await storage.deleteKey(key);
    }
  });
}

/// The threads of one reading of a source that are news for the account, see [forumWatchHitsOf].
typedef ForumWatchReading = ({int? mark, List<WatchAlert> found});

/// What the reading [rows] of [source] brings, for an account watching [config] whose check knows [state], with the
/// block list [blocks], found at [now].
///
/// The threads above the mark of the source ([ForumWatchState.marks]; thread ids grow with every new thread) are new;
/// a source without a mark (never read, or read again after it was dropped) is not: its first reading only sets the
/// mark, the threads already there are never announced. The mark becomes the highest thread id of the reading. A
/// reading of a forum only counts the threads of that forum (the global sticky threads of the others are listed too).
///
/// A new thread is found when:
/// * it was not found before (by another source, or an earlier reading: [ForumWatchState.alerted]);
/// * its author is not blocked, its title holds no filter keyword and its forum is not filtered ([UserBlockList]);
/// * its title holds an alert keyword and the keywords are looked in the source ([ForumWatchConfig.keywordFids]; every
///   forum when they look in the list of the latest threads, [ForumWatchConfig.keywordsInLatest], where its threads
///   are listed too): found with its keywords; or else the source is a forum watched for new threads: found without.
ForumWatchReading forumWatchHitsOf({
  required String source,
  required List<WatchRow> rows,
  required ForumWatchConfig config,
  required ForumWatchState state,
  required UserBlockList blocks,
  required DateTime now,
}) {
  final fid = forumWatchFidOfSource(source);
  final own = [
    for (final r in rows)
      if (fid == null || r.fid == 0 || r.fid == fid) r,
  ];
  final previous = state.marks[source];
  var mark = previous;
  for (final r in own) {
    if (mark == null || r.tid > mark) {
      mark = r.tid;
    }
  }
  if (previous == null) {
    return (mark: mark, found: const []);
  }
  final watched = fid != null && config.watches(fid);
  // A forum's thread is in the list of the latest threads too: when the keywords look there, they look at it.
  final keywordsHere = config.keywordsInLatest || (fid != null && config.keywordFids.contains(fid));
  final found = <WatchAlert>[];
  final tids = <int>{};
  for (final r in own) {
    if (r.tid <= previous || state.alerted(r.tid) || !tids.add(r.tid)) {
      continue;
    }
    if (blocks.isBlocked(r.authorUid) || blocks.hidesThread(title: r.title, fid: r.fid == 0 ? fid : r.fid)) {
      continue;
    }
    final keywords = keywordsHere ? config.keywordsIn(r.title) : const <AlertKeyword>[];
    if (keywords.isEmpty && !watched) {
      continue;
    }
    found.add(
      WatchAlert(
        tid: r.tid,
        fid: r.fid == 0 ? (fid ?? 0) : r.fid,
        forumName: r.forumName.isNotEmpty ? r.forumName : config.nameOf(r.fid == 0 ? (fid ?? 0) : r.fid),
        title: r.title,
        author: r.author,
        at: now,
        keywords: [for (final k in keywords) k.text],
      ),
    );
  }
  return (mark: mark, found: found);
}

/// Whether the alerts of [category] ([NoticeCategory.forumNewThread], [NoticeCategory.keywordAlert]) are announced at
/// [now]: the category is on and it is not the quiet hours (the same rules as the notices, [NotificationPushRules]).
///
/// As for a notice, what is found while they are not is not announced afterwards either: it is kept with the alerts
/// (and shown on the page of the alerts), never posted later.
Future<bool> forumWatchAnnounced(StorageProvider storage, NoticeCategory category, DateTime now) async {
  final rules = await NotificationPushRules.read(storage);
  return rules.enabled.contains(category) && !rules.isQuiet(now);
}

/// What one notification announces: the threads found with a keyword ([keyword] true), or the new threads of forum
/// [fid] found without one.
@immutable
final class ForumWatchBatch {
  /// Constructor.
  const ForumWatchBatch({required this.alerts, this.keyword = false, this.fid = 0, this.forumName = ''});

  /// The threads, the first found first.
  final List<WatchAlert> alerts;

  /// Whether these are the threads found with a keyword ([NoticeCategory.keywordAlert]); otherwise the new threads of
  /// forum [fid] ([NoticeCategory.forumNewThread]).
  final bool keyword;

  /// The forum of the new threads, 0 for the keywords.
  final int fid;

  /// The name of the forum of the new threads.
  final String forumName;

  /// The category the notification is posted in.
  NoticeCategory get category => keyword ? NoticeCategory.keywordAlert : NoticeCategory.forumNewThread;
}

/// The notifications of the threads [found] in a round: one for every thread found with a keyword, one per forum for
/// the new threads found without; in the order found.
List<ForumWatchBatch> forumWatchBatchesOf(List<WatchAlert> found) {
  final keyword = [
    for (final a in found)
      if (a.keywords.isNotEmpty) a,
  ];
  final byForum = <int, List<WatchAlert>>{};
  for (final a in found) {
    if (a.keywords.isEmpty) {
      (byForum[a.fid] ??= []).add(a);
    }
  }
  return [
    if (keyword.isNotEmpty) ForumWatchBatch(alerts: keyword, keyword: true),
    for (final MapEntry(key: fid, value: alerts) in byForum.entries)
      ForumWatchBatch(
        alerts: alerts,
        fid: fid,
        forumName: alerts.map((a) => a.forumName).firstWhere((n) => n.isNotEmpty, orElse: () => ''),
      ),
  ];
}

/// What a round of [checkForumWatch] did.
typedef ForumWatchRound = ({
  int asked,
  int failed,
  List<WatchAlert> found,
  List<ForumWatchBatch> announced,
  bool stopped,
});

/// Read the sources account [uid] watches ([ForumWatchConfig.sources]: the forums, at most [forumWatchForumMax], then
/// the list of the latest threads) one after another, [gap] between two, each through [fetch] given up after
/// [timeout], and store what was found ([forumWatchHitsOf]) under the store's lock, on what the account watches then:
/// a forum unwatched meanwhile is not read nor marked any more.
///
/// [blocks] gives the block list of the account, read once before the first request; when it can not be read nothing
/// is asked (a thread of a blocked author must never be announced). The threads found are announced at the end of the
/// round ([forumWatchBatchesOf]) through [announce] when [announcing] allows their category then.
///
/// A failure is not announced and keeps the mark of its source: the next round reads it again. The round stops when
/// the forum asks to slow down (429), when a page was served to another account or to a guest (the session expired,
/// or the account was switched: nothing of it is stored), and when [keepGoing] says no.
Future<ForumWatchRound> checkForumWatch({
  required ForumWatchStore store,
  required int uid,
  required Future<ForumWatchFetch> Function(String source) fetch,
  required Future<UserBlockList> Function() blocks,
  required Future<bool> Function(NoticeCategory category) announcing,
  required Future<bool> Function(ForumWatchBatch batch) announce,
  bool Function()? keepGoing,
  DateTime Function() clock = DateTime.now,
  Duration gap = forumWatchGap,
  Duration timeout = forumWatchFetchTimeout,
}) async {
  final sources = (await store.loadConfig(uid)).sources;
  final found = <WatchAlert>[];
  var asked = 0;
  var failed = 0;
  var stopped = false;
  final UserBlockList blockList;
  try {
    blockList = await blocks();
  } on Object catch (e) {
    talker.warning('forum watch: block list not readable, nothing checked: $e');
    return (asked: 0, failed: 0, found: const <WatchAlert>[], announced: const <ForumWatchBatch>[], stopped: true);
  }
  for (final source in sources) {
    if (keepGoing != null && !keepGoing()) {
      stopped = true;
      break;
    }
    if (asked > 0 && gap > Duration.zero) {
      await Future<void>.delayed(gap);
    }
    asked++;
    final ForumWatchFetch result;
    try {
      result = await fetch(
        source,
      ).timeout(timeout, onTimeout: () => ForumWatchFetchFailed('no answer within ${timeout.inSeconds}s'));
    } on Object catch (e) {
      failed++;
      talker.warning('forum watch $source: reading threw: $e');
      continue;
    }
    if (keepGoing != null && !keepGoing()) {
      stopped = true;
      break;
    }
    switch (result) {
      case ForumWatchFetchFailed(:final reason, :final rateLimited):
        failed++;
        talker.debug('forum watch $source: not read, $reason');
        stopped = rateLimited;
      case ForumWatchFetched(:final viewerUid) when viewerUid != uid:
        failed++;
        stopped = true;
        talker.info(
          'forum watch of uid ${"$uid".obscured(4)}: page served to '
          '${viewerUid == null ? "a guest" : "another account"}, round stopped',
        );
      case ForumWatchFetched(:final rows):
        final now = clock();
        var hits = const <WatchAlert>[];
        await store.updateState(uid, (config, state) {
          if (!config.sources.contains(source)) {
            // Unwatched meanwhile.
            return null;
          }
          final reading = forumWatchHitsOf(
            source: source,
            rows: rows,
            config: config,
            state: state,
            blocks: blockList,
            now: now,
          );
          hits = reading.found;
          return state.withMark(source, reading.mark).withAlerts(reading.found);
        });
        found.addAll(hits);
    }
    if (stopped) {
      break;
    }
  }
  final announced = <ForumWatchBatch>[];
  for (final batch in forumWatchBatchesOf(found)) {
    if (keepGoing != null && !keepGoing()) {
      break;
    }
    try {
      if (await announcing(batch.category) && await announce(batch)) {
        announced.add(batch);
      }
    } on Object catch (e, st) {
      talker.handle(e, st, 'forum watch: announcing failed');
    }
  }
  return (asked: asked, failed: failed, found: found, announced: announced, stopped: stopped);
}

/// One check of what account [uid] watches when it is due ([ForumWatchCheckSlot]): nothing when the account watches
/// nothing or the last check is less than an interval ago. [prepare] runs right before the first request (the network
/// settings of the background service); when it throws nothing is asked. [blocks] reads the block list of the account
/// ([UserBlockRepository.load] by default). See [checkForumWatch].
Future<ForumWatchRound?> forumWatchTick({
  required StorageProvider storage,
  required ForumWatchStore store,
  required int uid,
  required Future<ForumWatchFetch> Function(String source) fetch,
  required Future<bool> Function(ForumWatchBatch batch) announce,
  Future<UserBlockList> Function()? blocks,
  Future<void> Function()? prepare,
  bool Function()? keepGoing,
  DateTime Function() clock = DateTime.now,
  Duration gap = forumWatchGap,
}) async {
  if (uid <= 0 || (await store.loadConfig(uid)).sources.isEmpty) {
    return null;
  }
  final slot = await ForumWatchCheckSlot.take(storage, uid, await readForumWatchInterval(storage), now: clock());
  if (slot == null) {
    return null;
  }
  try {
    await prepare?.call();
  } on Object catch (e) {
    talker.warning('forum watch: network settings unavailable, not checked: $e');
    await ForumWatchCheckSlot.release(storage, uid, slot);
    return null;
  }
  final round = await checkForumWatch(
    store: store,
    uid: uid,
    fetch: fetch,
    blocks: blocks ?? () => UserBlockRepository(storage).load(uid),
    announcing: (category) => forumWatchAnnounced(storage, category, clock()),
    announce: announce,
    keepGoing: keepGoing,
    clock: clock,
    gap: gap,
  );
  if (round.asked == 0 && round.stopped) {
    // Nothing asked (the block list unreadable, the account switched, the service stopping): the next heartbeat may
    // check after all.
    await ForumWatchCheckSlot.release(storage, uid, slot);
  }
  talker.debug(
    'forum watch of uid ${"$uid".obscured(4)}: ${round.asked} asked, ${round.failed} failed, '
    '${round.found.length} found, ${round.announced.length} announced${round.stopped ? ", stopped" : ""}',
  );
  return round;
}
