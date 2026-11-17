import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// Most forums whose pinned threads section is remembered ([SettingsKeys.pinnedThreadsFold]): those saved last (a
/// section is saved when what it shows changes or it is expanded or collapsed, not at every visit).
const pinnedFoldForumsMax = 100;

/// Most pinned threads remembered as seen in one forum.
const pinnedFoldSeenMax = 200;

/// The pinned threads section of a forum's thread list, folded to one row with the setting
/// [SettingsKeys.collapsePinnedThreads].
@immutable
final class PinnedFold {
  /// Constructor.
  const PinnedFold({this.open = false, this.seen});

  /// The user left the section expanded.
  final bool open;

  /// The pinned threads (tids) of the forum's first page seen last without a filter, null before any was seen.
  final Set<int>? seen;

  /// This one with [open].
  PinnedFold withOpen({required bool open}) => PinnedFold(open: open, seen: seen);

  @override
  bool operator ==(Object other) => other is PinnedFold && other.open == open && setEquals(other.seen, seen);

  @override
  int get hashCode => Object.hash(open, seen == null ? null : Object.hashAllUnordered(seen!));

  Map<String, Object> _toJson() => {
    if (open) 'open': 1,
    if (seen case final seen?) 'seen': seen.toList(),
  };
}

/// The pinned threads sections saved in [raw] ([SettingsKeys.pinnedThreadsFold]), by forum id, the oldest first.
///
/// A JSON object by fid: `{"25": {"open": 1, "seen": [9199039, 9199070]}}`; `open` is left out when collapsed, `seen`
/// before any pinned thread was seen. Anything else (an empty value, damaged JSON, entries that are not one) reads as
/// nothing for that part; the lists are cut to their limits.
Map<int, PinnedFold> decodePinnedFolds(String raw) {
  final result = <int, PinnedFold>{};
  if (raw.isEmpty) {
    return result;
  }
  try {
    final json = jsonDecode(raw);
    if (json is! Map) {
      return result;
    }
    for (final MapEntry(:key, :value) in json.entries) {
      final fid = int.tryParse('$key');
      if (fid == null || fid <= 0 || value is! Map) {
        continue;
      }
      final seen = switch (value['seen']) {
        final List<dynamic> tids => tids.whereType<int>().where((e) => e > 0).take(pinnedFoldSeenMax).toSet(),
        _ => null,
      };
      result[fid] = PinnedFold(open: value['open'] == 1, seen: seen);
    }
  } on FormatException {
    return {};
  }
  while (result.length > pinnedFoldForumsMax) {
    result.remove(result.keys.first);
  }
  return result;
}

/// [folds] as saved in [SettingsKeys.pinnedThreadsFold] ([decodePinnedFolds]).
String encodePinnedFolds(Map<int, PinnedFold> folds) =>
    jsonEncode({for (final MapEntry(:key, :value) in folds.entries) '$key': value._toJson()});

/// [folds] with [fold] as the latest one of forum [fid], the oldest ones dropped past [pinnedFoldForumsMax].
Map<int, PinnedFold> pinnedFoldsWith(Map<int, PinnedFold> folds, int fid, PinnedFold fold) {
  final result = {...folds}
    ..remove(fid)
    ..[fid] = fold;
  while (result.length > pinnedFoldForumsMax) {
    result.remove(result.keys.first);
  }
  return result;
}

/// What seeing the pinned threads [tids] above a forum's list tells, the forum's section saved as [saved] (null when
/// none is): whether one of them is `fresh` (not seen before: the section is shown expanded this time), and the section
/// to save instead (`save`, null when nothing changed).
///
/// The first page without a filter shows every pinned thread of the forum: they are the ones seen from now on. A
/// filtered one (another order included) only shows the forum's own pinned threads matching the filter: one not seen
/// before is fresh and seen from now on, the others stay seen. The first time a forum's pinned threads are seen (no
/// filter) none is fresh, the section stays as it is; nothing is learnt from a filtered first time, nor from a list
/// without pinned threads (another page than the first).
({bool fresh, PinnedFold? save}) pinnedFoldSeen(PinnedFold? saved, Iterable<int> tids, {required bool filtered}) {
  final shown = tids.take(pinnedFoldSeenMax).toSet();
  if (shown.isEmpty) {
    return (fresh: false, save: null);
  }
  final seen = saved?.seen;
  if (seen == null) {
    return filtered
        ? (fresh: false, save: null)
        : (fresh: false, save: PinnedFold(open: saved?.open ?? false, seen: shown));
  }
  final fresh = shown.difference(seen);
  if (filtered) {
    return fresh.isEmpty
        ? (fresh: false, save: null)
        : (fresh: true, save: PinnedFold(open: saved!.open, seen: {...fresh, ...seen}.take(pinnedFoldSeenMax).toSet()));
  }
  return setEquals(shown, seen)
      ? (fresh: false, save: null)
      : (fresh: fresh.isNotEmpty, save: PinnedFold(open: saved!.open, seen: shown));
}

/// The pinned threads section of forum [fid] saved on this device, null when none is.
PinnedFold? savedPinnedFold(int fid) =>
    decodePinnedFolds(getIt.get<SettingsRepository>().currentSettings.pinnedThreadsFold)[fid];

/// The save of [_savePinnedFold] going on, null when none is: the next one waits for it and reads what it saved.
Future<void>? _saving;

/// Save the pinned threads section of forum [fid] on this device, [change] made to the one saved. It is not synced:
/// what was seen and left open is the device's own.
Future<void> _savePinnedFold(int fid, PinnedFold Function(PinnedFold saved) change) {
  final previous = _saving;
  final Future<void> saving = () async {
    await previous;
    try {
      final settings = getIt.get<SettingsRepository>();
      final folds = decodePinnedFolds(settings.currentSettings.pinnedThreadsFold);
      final fold = change(folds[fid] ?? const PinnedFold());
      if (folds[fid] == fold) {
        return;
      }
      await settings.setValue(SettingsKeys.pinnedThreadsFold, encodePinnedFolds(pinnedFoldsWith(folds, fid, fold)));
    } on Object catch (e) {
      talker.error('failed to save the pinned threads section of forum $fid: $e');
    }
  }();
  _saving = saving;
  // Done: the next save does not wait for it (kept, it would also hold the zone it ran in).
  return saving.whenComplete(() {
    if (identical(_saving, saving)) {
      _saving = null;
    }
  });
}

/// Save the pinned threads [seen] in forum [fid] ([pinnedFoldSeen]), keeping whether the section was left open.
Future<void> savePinnedFoldSeen(int fid, Set<int>? seen) =>
    _savePinnedFold(fid, (saved) => PinnedFold(open: saved.open, seen: seen));

/// Save that the user left the pinned threads section of forum [fid] expanded ([open]) or collapsed, keeping what was
/// seen.
Future<void> savePinnedFoldOpen(int fid, {required bool open}) =>
    _savePinnedFold(fid, (saved) => saved.withOpen(open: open));
