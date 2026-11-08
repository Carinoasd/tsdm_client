import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/floor_bookmark/models/floor_bookmark.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/sync/models/sync_document.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/features/sync/repository/sync_local_store.dart';
import 'package:tsdm_client/shared/models/models.dart';
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

  /// The account in use changed while the run was on its way (or the forum answered for another account): nothing
  /// was changed or written.
  accountChanged,

  /// The forum's document was written by a newer app version: left alone, nothing applied or written.
  newerSchema,
}

/// What a device may leave out of the sync, each on its own switch (the reading progress, the quick phrases and the
/// block list always go with the sync).
enum SyncCategory {
  /// The fast rate templates (`rate_templates`).
  rateTemplates,

  /// The reading and display settings (`settings`).
  settings,

  /// The local drafts of the account (`drafts`).
  drafts,

  /// The floor bookmarks of the account (`bookmarks`).
  bookmarks,
}

/// Keeps the reading progress, the quick phrases, the block list, the fast rate templates, the reading settings, the
/// local drafts and the floor bookmarks of an account the same on every device it logs in on, through the forum's
/// `sync` action (plugin 3.4.0, one document per account, see [SyncDocument]).
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
    int? Function()? currentUid,
    bool Function(SyncCategory category)? categoryEnabled,
    DateTime Function()? now,
    this.debounce = const Duration(seconds: 30),
    this.unsupportedFor = const Duration(hours: 1),
  }) : _api = api,
       _store = store,
       _enabled = enabled,
       _currentUid = currentUid,
       _categoryEnabled = categoryEnabled,
       _now = now ?? DateTime.now;

  final SyncApi _api;
  final SyncLocalStore _store;
  final bool Function() _enabled;

  /// The account in use now, asked before anything is applied or written: a run of another account (the account was
  /// switched while it waited or was on its way) changes nothing. Null when there is no such account (tests).
  final int? Function()? _currentUid;

  /// Whether a category goes with the sync on this device (all of them when null). One left out is neither read nor
  /// written here: the forum's section stays as it is.
  final bool Function(SyncCategory category)? _categoryEnabled;
  final DateTime Function() _now;

  /// How long a local change waits before it is written, so a burst of changes is written once.
  final Duration debounce;

  /// How long the sync stays off after the forum said it does not keep documents.
  final Duration unsupportedFor;

  DateTime? _unsupportedUntil;

  /// Most bytes a document may take: [syncDocumentMaxBytes], less when the forum refused one as too large.
  int _documentMaxBytes = syncDocumentMaxBytes;
  Timer? _pushTimer;
  int? _pushUid;
  Future<void> _queue = Future.value();
  String? _appliedPhrases;
  String? _appliedRateTemplates;
  String? _appliedSettings;

  /// The drafts this device held when its document was last built: a draft deleted since (while the run was on its
  /// way) is not written back by the apply.
  Set<String>? _draftKeysRead;
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
    return _run(() => _pull(uid)).then((outcome) {
      // A pull that did not reach the forum does not count as asked: the next occasion asks again.
      if (const {
            SyncOutcome.failed,
            SyncOutcome.notLoggedIn,
            SyncOutcome.accountChanged,
            SyncOutcome.disabled,
          }.contains(outcome) &&
          _pullAskedAt == now) {
        _pullAskedAt = null;
      }
      return outcome;
    });
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

  /// Drop a scheduled write (the account in use changed: its write must not run for the account that is in use now).
  void cancelScheduled() {
    _pushTimer?.cancel();
    _pushUid = null;
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

  /// The fast rate templates changed on this device to [snapshot] ([encodeRateTemplates]): note the time, unless it is
  /// what the sync wrote itself, and schedule a write for account [uid].
  Future<void> onRateTemplatesChanged(int? uid, String snapshot) async {
    if (snapshot == _appliedRateTemplates) {
      return;
    }
    _appliedRateTemplates = null;
    await _store.saveRateTemplatesUpdated(_now().millisecondsSinceEpoch);
    if (uid != null) {
      schedulePush(uid);
    }
  }

  /// The synced settings changed on this device to [snapshot] ([encodeSettingsValues]): note the time, unless it is
  /// what the sync wrote itself, and schedule a write for account [uid].
  Future<void> onSettingsChanged(int? uid, String snapshot) async {
    if (snapshot == _appliedSettings) {
      return;
    }
    _appliedSettings = null;
    await _store.saveSettingsUpdated(_now().millisecondsSinceEpoch);
    if (uid != null) {
      schedulePush(uid);
    }
  }

  /// The text the sync compares the fast rate [templates] by.
  static String encodeRateTemplates(List<FastRateTemplateModel> templates) =>
      jsonEncode([for (final t in templates) rateTemplateToItem(t)]);

  /// The text the sync compares the synced settings [values] by.
  static String encodeSettingsValues(Map<String, Object> values) => jsonEncode(values);

  bool _on(SyncCategory category) => _categoryEnabled?.call(category) ?? true;

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

  /// Whether account [uid] is still the one in use (and the one the forum answered for, [answeredUid]).
  bool _stillCurrent(int uid, [int? answeredUid]) {
    if (answeredUid != null && answeredUid != uid) {
      info('sync: the forum answered for account $answeredUid, not $uid: nothing done');
      return false;
    }
    final current = _currentUid?.call();
    if (_currentUid != null && current != uid) {
      info('sync: the account in use is now $current, not $uid: nothing done');
      return false;
    }
    return true;
  }

  Future<SyncOutcome> _pull(int uid) async {
    if (_gate() case final gated?) {
      return gated;
    }
    if (!_stillCurrent(uid)) {
      return SyncOutcome.accountChanged;
    }
    return _readThenMerge(uid, await _api.pull(uid));
  }

  Future<SyncOutcome> _push(int uid) async {
    if (_gate() case final gated?) {
      return gated;
    }
    if (!_stillCurrent(uid)) {
      return SyncOutcome.accountChanged;
    }
    final last = await _store.lastSynced(uid);
    final base = SyncDocument.parse(last?.document);
    final local = await _localDocument(uid, base);
    if (last != null && local.sameAs(base)) {
      return SyncOutcome.upToDate;
    }
    // The write needs the form hash of the session: a read gives it, and tells whether another device wrote
    // meanwhile without a refused write.
    return _readThenMerge(uid, await _api.pull(uid));
  }

  /// What a read [answer] of account [uid] leads to.
  Future<SyncOutcome> _readThenMerge(int uid, SyncPullAnswer answer) async {
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
      case SyncPulled(uid: final answeredUid, :final updated, :final data, :final formhash):
        if (!_stillCurrent(uid, answeredUid)) {
          return SyncOutcome.accountChanged;
        }
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
    if (remote.newerThanKnown) {
      info('sync: the forum holds a schema ${remote.schema} document, newer than this version reads: left alone');
      return SyncOutcome.newerSchema;
    }
    await _unitePhrasesOnFirstSync(remote);
    await _uniteRateTemplatesOnFirstSync(remote);
    await _stampSettingsOnFirstSync(remote);
    final last = await _store.lastSynced(uid);
    final base = SyncDocument.parse(last?.document);
    final local = await _localDocument(uid, base);
    // The merge is a union: the caps hold for it as for this device's own document (two devices with different
    // histories would otherwise give a document over the forum's limit for ever).
    final merged = _fit(SyncDocument.merge(local, remote));
    if (!_stillCurrent(uid)) {
      return SyncOutcome.accountChanged;
    }
    await _apply(uid, merged);
    await _store.saveLastSynced(uid, remote.encode(), remoteUpdated);
    if (merged.sameAs(remote)) {
      return SyncOutcome.upToDate;
    }
    if (!_stillCurrent(uid)) {
      return SyncOutcome.accountChanged;
    }
    final answer = await _api.push(uid, data: merged.encode(), baseUpdated: remoteUpdated, formhash: formhash);
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
        if (maxBytes <= 0) {
          return SyncOutcome.failed;
        }
        // The forum keeps less than this version thought: fit to its limit from now on (the drafts within a quarter of
        // it), and write again after the debounce. Not at once: the plugin keeps
        // its interval lock after a 413 (unlike a 409), so a write right away is answered 429 (busy).
        final limit = math.max(0, maxBytes - 2048);
        if (limit < _documentMaxBytes) {
          _documentMaxBytes = limit;
          schedulePush(uid);
        }
        return SyncOutcome.failed;
      case SyncPushFailed(:final reason):
        debug('sync: push failed: $reason');
        return SyncOutcome.failed;
    }
  }

  /// The first sync of a device (its quick phrases never stamped): a device that had phrases before the sync existed
  /// while the forum has some too gets the two lists united (this device's first, the forum's that it lacks after),
  /// so neither device's phrases are lost; the phrases are then stamped as this device's change of now (0 when it has
  /// none: nothing to say), and the union is written back. Only here is the stamp first written: [_localDocument]
  /// computes it without keeping it, so a first sync that starts as a write still unites.
  Future<void> _unitePhrasesOnFirstSync(SyncDocument remote) async {
    if (await _store.phrasesUpdated() != null) {
      return;
    }
    var mine = await _store.phrases();
    final theirs = remote.single('phrases');
    if (mine.isNotEmpty && theirs != null) {
      final items = [
        for (final e in theirs['items'] is List ? theirs['items'] as List : const [])
          if (e is String && e.trim().isNotEmpty) e,
      ];
      final union = [...mine, ...items.where((e) => !mine.contains(e))].take(syncPhrasesMax).toList();
      if (!listEquals(union, mine)) {
        info('sync: first sync, ${union.length - mine.length} quick phrases of the forum added to this device');
        await _store.savePhrases(union);
        mine = union;
      }
    }
    await _store.savePhrasesUpdated(mine.isEmpty ? 0 : _now().millisecondsSinceEpoch);
  }

  /// The first sync of the fast rate templates on a device (never stamped): like the quick phrases, this device's
  /// templates and the forum's that it lacks (by name) are united, then stamped as of now (0 when there are none).
  Future<void> _uniteRateTemplatesOnFirstSync(SyncDocument remote) async {
    if (!_on(SyncCategory.rateTemplates) || await _store.rateTemplatesUpdated() != null) {
      return;
    }
    var mine = await _store.rateTemplates();
    final theirs = remote.single('rate_templates');
    if (mine.isNotEmpty && theirs != null) {
      final names = {for (final t in mine) t.name};
      final union = [
        ...mine,
        ...rateTemplatesOf(theirs).where((t) => !names.contains(t.name)),
      ].take(syncRateTemplatesMax).toList();
      if (union.length != mine.length) {
        info('sync: first sync, ${union.length - mine.length} rate templates of the forum added to this device');
        _appliedRateTemplates = encodeRateTemplates(union);
        await _store.saveRateTemplates(union);
        mine = union;
      }
    }
    await _store.saveRateTemplatesUpdated(mine.isEmpty ? 0 : _now().millisecondsSinceEpoch);
  }

  /// The first sync of the settings on a device (never stamped). A device with only the defaults takes the forum's
  /// settings (it counts as changed at 0), or says nothing when the forum has none: a fresh device never undoes
  /// another's. A device with settings of its own keeps them: the forum's fill in only the settings still at their
  /// default here, and the result is stamped as of now (then written), so neither device's choices are lost.
  Future<void> _stampSettingsOnFirstSync(SyncDocument remote) async {
    if (!_on(SyncCategory.settings) || await _store.settingsUpdated() != null) {
      return;
    }
    final mine = await _store.settingsValues();
    final defaults = syncedSettingsDefaults();
    final theirs = remote.single('settings');
    if (mapEquals(mine, defaults)) {
      if (theirs != null) {
        await _store.saveSettingsUpdated(0);
      }
      return;
    }
    if (theirs != null) {
      final fill = {
        for (final MapEntry(:key, :value) in settingsValuesOf(theirs).entries)
          if (mine.containsKey(key) && mine[key] == defaults[key]) key: value,
      };
      final next = syncedSettingsApplied(mine, fill);
      if (!mapEquals(next, mine)) {
        info('sync: first sync, settings of the forum taken where this device has the defaults');
        await _store.saveSettingsUpdated(_now().millisecondsSinceEpoch);
        _appliedSettings = encodeSettingsValues(next);
        await _store.applySettingsValues(fill);
        return;
      }
    }
    await _store.saveSettingsUpdated(_now().millisecondsSinceEpoch);
  }

  /// The fast rate templates of the `rate_templates` [item]: the ones this version reads, the first of each name, at
  /// most [syncRateTemplatesMax].
  static List<FastRateTemplateModel> rateTemplatesOf(Map<String, dynamic> item) {
    final names = <String>{};
    final templates = <FastRateTemplateModel>[];
    for (final e in item['items'] is List ? item['items'] as List : const []) {
      final template = rateTemplateFromItem(e);
      if (template != null && names.add(template.name) && templates.length < syncRateTemplatesMax) {
        templates.add(template);
      }
    }
    return templates;
  }

  /// The values of the `settings` [item].
  static Map<String, dynamic> settingsValuesOf(Map<String, dynamic> item) =>
      item['values'] is Map<String, dynamic> ? item['values'] as Map<String, dynamic> : const {};

  /// Whether the draft of [key] goes with the sync: every kind but the private messages, kept on their device only
  /// (the document lies in the forum's table as plain text).
  static bool syncsDraft(String key) => !key.startsWith('${LocalDraftKind.message.prefix}:');

  static List<LocalDraft>? _synced(List<LocalDraft>? drafts) =>
      drafts?.where((d) => d.key.kind != LocalDraftKind.message).toList();

  static int _bytesOf(Object? json) => utf8.encode(jsonEncode(json)).length;

  /// The document item of [draft] ([draftToItem]), with the fields of the forum's item [base] this version does not
  /// read; without its editor document when over [syncDraftMaxBytes], null when still over.
  static Map<String, dynamic>? _draftItem(LocalDraft draft, Map<String, dynamic>? base) {
    final item = <String, dynamic>{
      if (base != null && !SyncDocument.isDeleted(base))
        for (final MapEntry(:key, :value) in base.entries)
          if (!syncDraftFields.contains(key)) key: value,
      ...draftToItem(draft),
    };
    if (_bytesOf(item) <= syncDraftMaxBytes) {
      return item;
    }
    item.remove('delta');
    return _bytesOf(item) <= syncDraftMaxBytes ? item : null;
  }

  /// This device's document of account [uid]: what it keeps, and the deletions since [base] (what the forum held last)
  /// as tombstones. Fields of [base] this version does not read are carried over, and so are items of [base] this
  /// version could not read (they were never applied here: not deleted here either).
  Future<SyncDocument> _localDocument(int uid, SyncDocument base) async {
    final now = _now().millisecondsSinceEpoch;
    var doc = base;

    // Visits: the records, then the threads the forum knew that this device removed.
    final visits = {for (final v in await _store.visits(uid)) '${v.tid}': v.toItem()};
    for (final MapEntry(:key, value: item) in base.items('visits').entries) {
      if (visits.containsKey(key)) {
        continue;
      }
      final tid = int.tryParse(key);
      final readable = tid != null && SyncVisit.fromItem(tid, item) != null;
      visits[key] = SyncDocument.isDeleted(item) || !readable ? item : SyncDocument.tombstone(now);
    }
    doc = doc.withItems('visits', visits);

    // Phrases: one item; a device that never noted a change counts its phrases as of now (it has some) or 0 (none)
    // without keeping the stamp (the first sync does, see _unitePhrasesOnFirstSync).
    final phrases = await _store.phrases();
    final phrasesUpdated = await _store.phrasesUpdated() ?? (phrases.isEmpty ? 0 : now);
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
      if (!blocks.containsKey(key)) {
        blocks[key] = SyncDocument.isDeleted(item) ? item : SyncDocument.tombstone(now);
      }
    }
    doc = doc.withItems('blocks', blocks);

    // Rate templates: one item, like the phrases. A category left out keeps the forum's section as it is.
    if (_on(SyncCategory.rateTemplates)) {
      final templates = await _store.rateTemplates();
      final updated = await _store.rateTemplatesUpdated() ?? (templates.isEmpty ? 0 : now);
      final baseItem = base.single('rate_templates') ?? const <String, dynamic>{};
      doc = doc.withSingle(
        'rate_templates',
        templates.isEmpty && updated == 0 && baseItem.isEmpty
            ? null
            : {
                ...baseItem,
                'updated': updated,
                'items': [for (final t in templates.take(syncRateTemplatesMax)) rateTemplateToItem(t)],
              },
      );
    }

    // Settings: one item; values of settings this version does not carry are kept. A device that never stamped them
    // says nothing (see _stampSettingsOnFirstSync).
    if (_on(SyncCategory.settings)) {
      final updated = await _store.settingsUpdated();
      if (updated != null) {
        final baseItem = base.single('settings') ?? const <String, dynamic>{};
        doc = doc.withSingle('settings', {
          ...baseItem,
          'updated': updated,
          'values': {...settingsValuesOf(baseItem), ...await _store.settingsValues()},
        });
      }
    }

    // Drafts: those this device holds (an older copy of the forum's in place of one too large to send), then the
    // deletions: a draft this device held at its last sync of them ([SyncLocalStore.draftsSeen]) and holds no more.
    // A draft of the forum this device never held is not deleted here, whatever the forum's document says.
    _draftKeysRead = null;
    if (_on(SyncCategory.drafts)) {
      final drafts = _synced(await _store.drafts(uid));
      if (drafts != null) {
        final seen = await _store.draftsSeen(uid) ?? const <String>{};
        final baseDrafts = base.items('drafts');
        final items = <String, Map<String, dynamic>>{};
        for (final draft in drafts) {
          final key = draft.key.value;
          if (_draftItem(draft, baseDrafts[key]) ?? baseDrafts[key] case final item?) {
            items[key] = item;
          }
        }
        final held = {for (final d in drafts) d.key.value};
        _draftKeysRead = held;
        for (final key in {...baseDrafts.keys, ...seen}) {
          if (held.contains(key) || !syncsDraft(key)) {
            continue;
          }
          final item = baseDrafts[key];
          if (item != null && SyncDocument.isDeleted(item)) {
            items[key] = item;
          } else if (seen.contains(key)) {
            items[key] = SyncDocument.tombstone(now);
          } else if (item != null) {
            items[key] = item;
          }
        }
        doc = doc.withItems('drafts', items);
      }
    }

    // Bookmarks: those this device keeps, the records of the ones removed here included (a removal is always recorded,
    // see FloorBookmarkStore), over the forum's. A bookmark of the forum this device does not hold was never taken here
    // (the category was off, or it came after the last sync): it stays as the forum has it, no deletion.
    if (_on(SyncCategory.bookmarks)) {
      final bookmarks = await _store.bookmarks(uid);
      if (bookmarks != null) {
        doc = doc.withItems('bookmarks', {...base.items('bookmarks'), for (final b in bookmarks) b.key: b.raw});
      }
    }
    return _fit(doc);
  }

  /// [doc] within the caps: the latest [syncVisitsMax] visits and [syncVisitTombstonesMax] records of removed visits,
  /// the latest [syncDraftsMax] drafts and [syncDraftTombstonesMax] records of deleted drafts within
  /// [syncDraftsMaxBytes] (a quarter of the document at most), the latest [syncBookmarksMax] floor bookmarks and
  /// [syncBookmarkTombstonesMax] records of removed ones within [syncBookmarksMaxBytes] (two fifths at most, the
  /// oldest of either dropped first), deletion
  /// records older than [syncTombstoneKeptFor] dropped, and at most [syncDocumentMaxBytes] or the forum's limit when it
  /// said a smaller one (the oldest visits dropped first, then the oldest deletion records of visits, then the drafts,
  /// then the bookmarks). Dropping is by time alone, so every device drops the same items of the same document; a
  /// dropped item is not a deletion.
  SyncDocument _fit(SyncDocument doc) {
    final keepSince = _now().millisecondsSinceEpoch - syncTombstoneKeptFor.inMilliseconds;
    List<MapEntry<String, Map<String, dynamic>>> latest(
      Iterable<MapEntry<String, Map<String, dynamic>>> items,
      int max,
    ) {
      final entries = items.toList()
        ..sort((a, b) => SyncDocument.updatedOf(b.value).compareTo(SyncDocument.updatedOf(a.value)));
      return entries.take(max).toList();
    }

    final visits = doc.items('visits').entries;
    final live = latest(visits.where((e) => !SyncDocument.isDeleted(e.value)), syncVisitsMax);
    final gone = latest(
      visits.where((e) => SyncDocument.isDeleted(e.value) && SyncDocument.updatedOf(e.value) >= keepSince),
      syncVisitTombstonesMax,
    );
    final blocks = {
      for (final e in doc.items('blocks').entries)
        if (!SyncDocument.isDeleted(e.value) || SyncDocument.updatedOf(e.value) >= keepSince) e.key: e.value,
    };
    // Private messages never go to the forum's table, whoever wrote them there.
    final draftItems = doc.items('drafts').entries.where((e) => syncsDraft(e.key));
    final liveDrafts = latest(draftItems.where((e) => !SyncDocument.isDeleted(e.value)), syncDraftsMax);
    final goneDrafts = latest(
      draftItems.where((e) => SyncDocument.isDeleted(e.value) && SyncDocument.updatedOf(e.value) >= keepSince),
      syncDraftTombstonesMax,
    );
    Map<String, Map<String, dynamic>> drafts() => {
      for (final e in liveDrafts) e.key: e.value,
      for (final e in goneDrafts) e.key: e.value,
    };
    final draftsMax = math.min(syncDraftsMaxBytes, _documentMaxBytes ~/ 4);
    while ((liveDrafts.isNotEmpty || goneDrafts.isNotEmpty) && _bytesOf(drafts()) > draftsMax) {
      if (liveDrafts.isNotEmpty) {
        liveDrafts.removeLast();
      } else {
        goneDrafts.removeLast();
      }
    }
    // Bookmarks within their caps and budget, like the drafts.
    final bookmarkItems = doc.items('bookmarks').entries;
    final liveBookmarks = latest(bookmarkItems.where((e) => !SyncDocument.isDeleted(e.value)), syncBookmarksMax);
    final goneBookmarks = latest(
      bookmarkItems.where((e) => SyncDocument.isDeleted(e.value) && SyncDocument.updatedOf(e.value) >= keepSince),
      syncBookmarkTombstonesMax,
    );
    Map<String, Map<String, dynamic>> bookmarks() => {
      for (final e in liveBookmarks) e.key: e.value,
      for (final e in goneBookmarks) e.key: e.value,
    };
    // Over the budget, the oldest item goes first, a bookmark or the record of a removal alike.
    final bookmarksMax = math.min(syncBookmarksMaxBytes, _documentMaxBytes * 2 ~/ 5);
    while ((liveBookmarks.isNotEmpty || goneBookmarks.isNotEmpty) && _bytesOf(bookmarks()) > bookmarksMax) {
      if (goneBookmarks.isEmpty ||
          (liveBookmarks.isNotEmpty &&
              SyncDocument.updatedOf(liveBookmarks.last.value) <= SyncDocument.updatedOf(goneBookmarks.last.value))) {
        liveBookmarks.removeLast();
      } else {
        goneBookmarks.removeLast();
      }
    }
    var fitted = doc
        .withItems('visits', {for (final e in live) e.key: e.value, for (final e in gone) e.key: e.value})
        .withItems('blocks', blocks)
        .withItems('drafts', drafts())
        .withItems('bookmarks', bookmarks());
    // Size: the oldest visits go first, then the oldest deletion records, then the drafts, then the bookmarks.
    while (fitted.encodedLength > _documentMaxBytes) {
      if (live.isNotEmpty) {
        live.removeLast();
      } else if (gone.isNotEmpty) {
        gone.removeLast();
      } else if (liveDrafts.isNotEmpty) {
        liveDrafts.removeLast();
      } else if (goneDrafts.isNotEmpty) {
        goneDrafts.removeLast();
      } else if (liveBookmarks.isNotEmpty) {
        liveBookmarks.removeLast();
      } else if (goneBookmarks.isNotEmpty) {
        goneBookmarks.removeLast();
      } else {
        break;
      }
      fitted = fitted
          .withItems('visits', {for (final e in live) e.key: e.value, for (final e in gone) e.key: e.value})
          .withItems('drafts', drafts())
          .withItems('bookmarks', bookmarks());
    }
    return fitted;
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
        final localAt = local == null
            ? 0
            : (local.updated > local.progressUpdated ? local.updated : local.progressUpdated);
        if (local != null && localAt <= SyncDocument.updatedOf(item)) {
          await _store.deleteVisit(uid, tid);
        }
        continue;
      }
      final visit = SyncVisit.fromItem(tid, item);
      if (visit == null) {
        continue;
      }
      // Each half where the merge is later than this device's; the same time on both leaves this device's own.
      if (local == null || local.updated < visit.updated) {
        await _store.saveVisit(uid, visit);
      }
      // The same progress time (0: kept before it was timed): a progress fills in where this device has none.
      if (local == null ||
          local.progressUpdated < visit.progressUpdated ||
          (local.progressUpdated == visit.progressUpdated && !local.hasProgress && visit.hasProgress)) {
        await _store.saveProgress(uid, visit);
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
      if (updated > localUpdated) {
        await _store.savePhrasesUpdated(updated);
        if (!listEquals(items, local)) {
          // The setting's value the store writes (`encodeQuickPhrases`): the change the settings stream reports next
          // is this one, not the user's.
          _appliedPhrases = items.isEmpty ? '' : jsonEncode(items);
          await _store.savePhrases(items);
        }
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

    // The stamps are written before the values: the change the streams report next is the sync's, not the user's.
    if (_on(SyncCategory.rateTemplates)) {
      final item = merged.single('rate_templates');
      if (item != null && SyncDocument.updatedOf(item) > (await _store.rateTemplatesUpdated() ?? 0)) {
        await _store.saveRateTemplatesUpdated(SyncDocument.updatedOf(item));
        final templates = rateTemplatesOf(item);
        final encoded = encodeRateTemplates(templates);
        if (encoded != encodeRateTemplates(await _store.rateTemplates())) {
          _appliedRateTemplates = encoded;
          await _store.saveRateTemplates(templates);
        }
      }
    }

    if (_on(SyncCategory.settings)) {
      final item = merged.single('settings');
      final localUpdated = await _store.settingsUpdated();
      if (item != null && localUpdated != null && SyncDocument.updatedOf(item) > localUpdated) {
        await _store.saveSettingsUpdated(SyncDocument.updatedOf(item));
        final values = settingsValuesOf(item);
        final current = await _store.settingsValues();
        final next = syncedSettingsApplied(current, values);
        if (!mapEquals(next, current)) {
          _appliedSettings = encodeSettingsValues(next);
          await _store.applySettingsValues(values);
        }
      }
    }

    // Drafts item by item, each where the merge is later than this device's (the same time leaves this device's own:
    // it may carry the editor document the forum's copy went without); a draft not in the document stays.
    if (_on(SyncCategory.drafts)) {
      final local = _synced(await _store.drafts(uid));
      if (local != null) {
        final byKey = {for (final d in local) d.key.value: d};
        final save = <LocalDraft>[];
        final delete = <LocalDraftKey>[];
        final items = merged.items('drafts');
        final skipped = <String>{};
        for (final MapEntry(:key, value: item) in items.entries) {
          final mine = byKey[key];
          final at = SyncDocument.updatedOf(item);
          if (SyncDocument.isDeleted(item)) {
            if (mine != null && mine.updatedAt.millisecondsSinceEpoch <= at) {
              delete.add(mine.key);
            }
            continue;
          }
          if (mine != null && mine.updatedAt.millisecondsSinceEpoch >= at) {
            continue;
          }
          if (mine == null && (_draftKeysRead?.contains(key) ?? false)) {
            // Deleted here while the run was on its way: still seen, so the next run sends the deletion.
            skipped.add(key);
            continue;
          }
          if (draftFromItem(key, item) case final draft?) {
            save.add(draft);
          }
        }
        await _store.applyDrafts(uid, save: save, delete: delete);
        final held = {...byKey.keys, for (final d in save) d.key.value}..removeAll([for (final k in delete) k.value]);
        await _store.saveDraftsSeen(uid, {
          ...held,
          ...skipped,
          for (final MapEntry(:key, :value) in items.entries)
            if (SyncDocument.isDeleted(value)) key,
        });
      }
    }

    // Bookmarks item by item, each where the merge is later than this device's (the same time leaves this device's
    // own); a removal of a bookmark this device does not hold changes nothing, a bookmark not in the document stays.
    if (_on(SyncCategory.bookmarks)) {
      final local = await _store.bookmarks(uid);
      if (local != null) {
        final byKey = {for (final b in local) b.key: b};
        final save = <FloorBookmark>[];
        for (final MapEntry(:key, value: item) in merged.items('bookmarks').entries) {
          final bookmark = FloorBookmark.fromItem(key, item);
          final mine = byKey[key];
          if (bookmark == null ||
              (mine != null && mine.updated >= bookmark.updated) ||
              (mine == null && bookmark.deleted)) {
            continue;
          }
          save.add(bookmark);
        }
        if (save.isNotEmpty) {
          await _store.applyBookmarks(uid, save);
        }
      }
    }
  }
}
