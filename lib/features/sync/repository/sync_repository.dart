import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/sync/models/sync_document.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/features/sync/repository/sync_local_store.dart';
import 'package:tsdm_client/utils/logger.dart';

/// How a sync run ended (for the log and the tests).
enum SyncOutcome {
  /// The setting is off: nothing was asked.
  disabled,

  /// The forum's plugin does not keep documents (or said so within the hour): nothing was asked.
  unsupported,

  /// The forum says the session is not logged in: nothing was changed.
  notLoggedIn,

  /// The request failed, or the forum refused the write: this device's changes wait for the next run.
  failed,

  /// Read and merged, nothing to write: the forum holds what this device has.
  upToDate,

  /// Written: the forum holds what this device has now.
  pushed,
}

/// Keeps the reading progress, the quick phrases and the block list of an account the same on every device it logs in
/// on, through the forum's `sync` action (plugin 3.4.0, one document per account, see [SyncDocument]).
///
/// [pull] reads the forum's document, merges it with this device's ([SyncDocument.merge]: per item, the later change
/// wins), applies the result here and writes it back when this device had something newer. [schedulePush] waits a
/// while after a local change ([debounce]) and writes once; [pushNow] writes at once. A write is refused when another
/// device wrote since this one read (409): the forum's document is merged and the write tried once more.
///
/// A forum whose plugin has no `sync` (or whose table is not created yet) switches the sync off silently for
/// [unsupportedFor]. Nothing here ever shows a message: a failure is logged and the next run tries again.
final class SyncRepository with LoggerMixin {
  /// Constructor.
  ///
  /// [enabled] is read before every run (the setting); [now] is the device clock (the tests replace it).
  SyncRepository({
    required SyncApi api,
    required SyncLocalStore store,
    required bool Function() enabled,
    DateTime Function()? now,
    this.debounce = const Duration(seconds: 30),
    this.unsupportedFor = const Duration(hours: 1),
  }) : _api = api,
       _store = store,
       _enabled = enabled,
       _now = now ?? DateTime.now;

  final SyncApi _api;
  final SyncLocalStore _store;
  final bool Function() _enabled;
  final DateTime Function() _now;

  /// How long a local change waits before it is written, so a burst of changes is written once.
  final Duration debounce;

  /// How long the sync stays off after the forum said it does not keep documents.
  final Duration unsupportedFor;

  DateTime? _unsupportedUntil;
  Timer? _pushTimer;
  int? _pushUid;
  Future<void> _queue = Future.value();
  String? _appliedPhrases;
  bool _disposed = false;

  /// The time of the last [pull] that reached the forum, null when none did yet.
  DateTime? lastPulledAt;

  /// The account of the last [pull] that reached the forum.
  int? lastPulledUid;

  /// Whether the forum said (within [unsupportedFor]) that it does not keep documents.
  bool get unsupported => _unsupportedUntil != null && _now().isBefore(_unsupportedUntil!);

  /// Whether a write is waiting for [debounce] to pass.
  bool get pushScheduled => _pushTimer?.isActive ?? false;

  /// Forget that the forum does not keep documents (the user asked to check again, or the tests).
  void resetUnsupported() => _unsupportedUntil = null;

  DateTime? _pullAskedAt;
  int? _pullAskedUid;

  /// Read the forum's document of account [uid], merge, apply, write back what this device had newer.
  ///
  /// With [dedupe], a pull of the same account asked within that long before (done or still queued) is not asked
  /// again: the start and the replayed login status ask for the same account a moment apart.
  Future<SyncOutcome> pull(int uid, {Duration? dedupe}) {
    final now = _now();
    if (dedupe != null && _pullAskedUid == uid && _pullAskedAt != null && now.difference(_pullAskedAt!) < dedupe) {
      return Future.value(SyncOutcome.upToDate);
    }
    _pullAskedAt = now;
    _pullAskedUid = uid;
    return _run(() => _pull(uid));
  }

  /// Write the document of account [uid] after [debounce], once for a burst of changes; a later call restarts the
  /// wait. A change of another account than the one scheduled drops the scheduled one.
  void schedulePush(int uid) {
    if (_disposed || !_enabled() || unsupported) {
      return;
    }
    _pushTimer?.cancel();
    _pushUid = uid;
    _pushTimer = Timer(debounce, () {
      if (_pushUid == uid) {
        unawaited(pushNow(uid));
      }
    });
  }

  /// Write the document of account [uid] now (a scheduled write of it is dropped); nothing is sent when the forum
  /// holds it already.
  Future<SyncOutcome> pushNow(int uid) {
    if (_pushUid == uid) {
      _pushTimer?.cancel();
    }
    return _run(() => _push(uid));
  }

  /// The quick phrases changed on this device to [raw] (the setting's value): note the time, unless it is the value
  /// the sync wrote itself, and schedule a write for account [uid].
  Future<void> onPhrasesChanged(int? uid, String raw) async {
    if (raw == _appliedPhrases) {
      return;
    }
    _appliedPhrases = null;
    await _store.savePhrasesUpdated(_now().millisecondsSinceEpoch);
    if (uid != null) {
      schedulePush(uid);
    }
  }

  /// Stop: nothing scheduled runs any more.
  Future<void> dispose() async {
    _disposed = true;
    _pushTimer?.cancel();
  }

  /// One run at a time: a pull and a scheduled push never interleave.
  Future<SyncOutcome> _run(Future<SyncOutcome> Function() action) {
    final completer = Completer<SyncOutcome>();
    _queue = _queue.then((_) async {
      if (_disposed) {
        completer.complete(SyncOutcome.failed);
        return;
      }
      try {
        completer.complete(await action());
      } on Object catch (e, st) {
        error('sync failed: $e', e, st);
        completer.complete(SyncOutcome.failed);
      }
    });
    return completer.future;
  }

  SyncOutcome? _gate() {
    if (!_enabled()) {
      return SyncOutcome.disabled;
    }
    if (unsupported) {
      return SyncOutcome.unsupported;
    }
    return null;
  }

  void _markUnsupported() {
    _unsupportedUntil = _now().add(unsupportedFor);
    info('sync: the forum does not keep documents, off for ${unsupportedFor.inMinutes} min');
  }

  Future<SyncOutcome> _pull(int uid) async {
    if (_gate() case final gated?) {
      return gated;
    }
    final answer = await _api.pull();
    switch (answer) {
      case SyncUnsupported():
        _markUnsupported();
        return SyncOutcome.unsupported;
      case SyncNotLoggedIn():
        debug('sync: not logged in, nothing pulled');
        return SyncOutcome.notLoggedIn;
      case SyncPullFailed(:final reason):
        debug('sync: pull failed: $reason');
        return SyncOutcome.failed;
      case SyncPulled(:final updated, :final data, :final formhash):
        lastPulledAt = _now();
        lastPulledUid = uid;
        return _mergeAndWriteBack(uid, remote: SyncDocument.parse(data), remoteUpdated: updated, formhash: formhash);
    }
  }

  Future<SyncOutcome> _push(int uid) async {
    if (_gate() case final gated?) {
      return gated;
    }
    final last = await _store.lastSynced(uid);
    final base = SyncDocument.parse(last?.document);
    final local = await _localDocument(uid, base);
    if (last != null && local.sameAs(base)) {
      return SyncOutcome.upToDate;
    }
    // The write needs the form hash of the session: a read gives it, and tells whether another device wrote
    // meanwhile without a refused write.
    final answer = await _api.pull();
    switch (answer) {
      case SyncUnsupported():
        _markUnsupported();
        return SyncOutcome.unsupported;
      case SyncNotLoggedIn():
        return SyncOutcome.notLoggedIn;
      case SyncPullFailed(:final reason):
        debug('sync: push failed, the read before it: $reason');
        return SyncOutcome.failed;
      case SyncPulled(:final updated, :final data, :final formhash):
        lastPulledAt = _now();
        lastPulledUid = uid;
        return _mergeAndWriteBack(uid, remote: SyncDocument.parse(data), remoteUpdated: updated, formhash: formhash);
    }
  }

  /// Merge the forum's [remote] (written at [remoteUpdated]) with this device, apply, and write back what this device
  /// had newer; a refused write (another device wrote meanwhile) is merged and tried once more.
  Future<SyncOutcome> _mergeAndWriteBack(
    int uid, {
    required SyncDocument remote,
    required int remoteUpdated,
    required String formhash,
    bool retry = true,
  }) async {
    final last = await _store.lastSynced(uid);
    final base = SyncDocument.parse(last?.document);
    final local = await _localDocument(uid, base);
    final merged = SyncDocument.merge(local, remote);
    await _apply(uid, merged);
    await _store.saveLastSynced(uid, remote.encode(), remoteUpdated);
    if (merged.sameAs(remote)) {
      return SyncOutcome.upToDate;
    }
    final answer = await _api.push(data: merged.encode(), baseUpdated: remoteUpdated, formhash: formhash);
    switch (answer) {
      case SyncPushed(:final updated):
        await _store.saveLastSynced(uid, merged.encode(), updated);
        debug('sync: pushed ${merged.encodedLength} bytes, updated $updated');
        return SyncOutcome.pushed;
      case SyncConflict(:final updated, :final data):
        if (!retry) {
          info('sync: refused again (another device keeps writing), waiting for the next run');
          return SyncOutcome.failed;
        }
        debug('sync: another device wrote meanwhile, merging once more');
        return _mergeAndWriteBack(
          uid,
          remote: SyncDocument.parse(data),
          remoteUpdated: updated,
          formhash: formhash,
          retry: false,
        );
      case SyncTooLarge(:final maxBytes):
        warning('sync: the document (${merged.encodedLength} bytes) is over the forum limit of $maxBytes bytes');
        return SyncOutcome.failed;
      case SyncPushFailed(:final reason):
        debug('sync: push failed: $reason');
        return SyncOutcome.failed;
    }
  }

  /// This device's document of account [uid]: what it keeps, and the deletions since [base] (what the forum held last)
  /// as tombstones. Fields of [base] this version does not read are carried over.
  Future<SyncDocument> _localDocument(int uid, SyncDocument base) async {
    final now = _now().millisecondsSinceEpoch;
    final keepSince = now - syncTombstoneKeptFor.inMilliseconds;
    var doc = base;

    // Visits: the records, then the threads the forum knew that this device removed.
    final visits = {for (final v in await _store.visits(uid)) '${v.tid}': v.toItem()};
    final gone = <String, Map<String, dynamic>>{};
    for (final MapEntry(:key, value: item) in base.items('visits').entries) {
      if (visits.containsKey(key)) {
        continue;
      }
      final stone = SyncDocument.isDeleted(item) ? item : SyncDocument.tombstone(now);
      if (SyncDocument.updatedOf(stone) >= keepSince) {
        gone[key] = stone;
      }
    }
    doc = doc.withItems('visits', _capped(visits, gone));

    // Phrases: one item; a device that never noted a change stamps its phrases now (it has some) or 0 (none).
    final phrases = await _store.phrases();
    var phrasesUpdated = await _store.phrasesUpdated();
    if (phrasesUpdated == null) {
      phrasesUpdated = phrases.isEmpty ? 0 : now;
      await _store.savePhrasesUpdated(phrasesUpdated);
    }
    final basePhrases = base.single('phrases') ?? const <String, dynamic>{};
    // A device that never had phrases says nothing (the same as a forum without the section).
    doc = doc.withSingle(
      'phrases',
      phrases.isEmpty && phrasesUpdated == 0 && basePhrases.isEmpty
          ? null
          : {...basePhrases, 'updated': phrasesUpdated, 'items': phrases},
    );

    // Blocks: the list, then the users the forum knew blocked that this device unblocked.
    final blocks = {for (final b in await _store.blocks(uid)) '${b.uid}': b.toItem()};
    for (final MapEntry(:key, value: item) in base.items('blocks').entries) {
      if (blocks.containsKey(key)) {
        continue;
      }
      final stone = SyncDocument.isDeleted(item) ? item : SyncDocument.tombstone(now);
      if (SyncDocument.updatedOf(stone) >= keepSince) {
        blocks[key] = stone;
      }
    }
    doc = doc.withItems('blocks', blocks);

    // Size: the oldest visits go first, then the oldest tombstones.
    while (doc.encodedLength > syncDocumentMaxBytes) {
      final items = doc.items('visits');
      if (items.isEmpty) {
        break;
      }
      final live = items.entries.where((e) => !SyncDocument.isDeleted(e.value)).toList();
      final pool = (live.isNotEmpty ? live : items.entries.toList())
        ..sort((a, b) => SyncDocument.updatedOf(a.value).compareTo(SyncDocument.updatedOf(b.value)));
      doc = doc.withItems('visits', {...items}..remove(pool.first.key));
    }
    return doc;
  }

  /// [live] visits capped to the latest [syncVisitsMax], [gone] to the latest [syncVisitTombstonesMax].
  static Map<String, Map<String, dynamic>> _capped(
    Map<String, Map<String, dynamic>> live,
    Map<String, Map<String, dynamic>> gone,
  ) {
    List<MapEntry<String, Map<String, dynamic>>> latest(Map<String, Map<String, dynamic>> items, int max) {
      final entries = items.entries.toList()
        ..sort((a, b) => SyncDocument.updatedOf(b.value).compareTo(SyncDocument.updatedOf(a.value)));
      return entries.take(max).toList();
    }

    return {
      for (final e in latest(live, syncVisitsMax)) e.key: e.value,
      for (final e in latest(gone, syncVisitTombstonesMax)) e.key: e.value,
    };
  }

  /// Make this device hold what [merged] says, where it differs.
  Future<void> _apply(int uid, SyncDocument merged) async {
    final localVisits = {for (final v in await _store.visits(uid)) v.tid: v};
    for (final MapEntry(:key, value: item) in merged.items('visits').entries) {
      final tid = int.tryParse(key);
      if (tid == null) {
        continue;
      }
      final local = localVisits[tid];
      if (SyncDocument.isDeleted(item)) {
        if (local != null && local.updated <= SyncDocument.updatedOf(item)) {
          await _store.deleteVisit(uid, tid);
        }
        continue;
      }
      final visit = SyncVisit.fromItem(tid, item);
      if (visit == null) {
        continue;
      }
      if (local == null || local.updated < visit.updated || (local.updated == visit.updated && local != visit)) {
        await _store.saveVisit(uid, visit);
      }
    }

    final phrases = merged.single('phrases');
    if (phrases != null) {
      final items = [
        for (final e in phrases['items'] is List ? phrases['items'] as List : const [])
          if (e is String) e,
      ];
      final updated = SyncDocument.updatedOf(phrases);
      final localUpdated = await _store.phrasesUpdated() ?? 0;
      final local = await _store.phrases();
      if (updated > localUpdated || (updated == localUpdated && !listEquals(items, local))) {
        // The setting's value the store writes (`encodeQuickPhrases`): the change the settings stream reports is this one.
        _appliedPhrases = items.isEmpty ? '' : jsonEncode(items);
        await _store.savePhrasesUpdated(updated);
        await _store.savePhrases(items);
      }
    }

    final blocks = <SyncBlock>[];
    for (final MapEntry(:key, value: item) in merged.items('blocks').entries) {
      final blockedUid = int.tryParse(key);
      if (blockedUid == null || SyncDocument.isDeleted(item)) {
        continue;
      }
      blocks.add(SyncBlock.fromItem(blockedUid, item));
    }
    final localBlocks = await _store.blocks(uid);
    if (merged.items('blocks').isNotEmpty && !setEquals(blocks.toSet(), localBlocks.toSet())) {
      await _store.saveBlocks(uid, blocks);
    }
  }
}
