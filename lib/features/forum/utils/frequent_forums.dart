import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// Most recently visited forums kept per account.
const frequentForumsRecentMax = 8;

/// Most pinned forums kept per account.
const frequentForumsPinnedMax = 30;

/// Account key of the visitor that is not logged in.
const frequentForumsGuestUid = 0;

/// How far apart the ranks of two pinned forums next to each other start ([FrequentForum.rank]): a forum moved between
/// two takes the rank in the middle, so only the moved one changes.
const int frequentForumRankStep = 1 << 20;

/// Most records of unpinned forums kept per account (and in the sync document), the latest ones.
const frequentForumsUnpinnedMax = 30;

/// How long the record of an unpinned forum is kept, so the cross-device sync unpins it on the other devices too.
const frequentForumsUnpinnedKeptFor = Duration(days: 180);

/// A forum of the frequent forums bar.
///
/// Two of them are equal when they show the same (forum and name); [updated] and [rank] are how a pinned one is
/// kept and synced.
@immutable
final class FrequentForum {
  /// Constructor.
  const FrequentForum({required this.fid, required this.name, this.updated = 0, this.rank = 0});

  /// Forum id.
  final int fid;

  /// Forum name, as shown when it was pinned or visited last.
  final String name;

  /// When a pinned forum was pinned, moved or renamed last (milliseconds since the epoch); 0 for one pinned before the
  /// time was kept, and for a recent one.
  final int updated;

  /// Where a pinned forum stands among the others: the lower first, ties by [fid]. Synced with the forum, so the
  /// order is the same on every device.
  final int rank;

  @override
  bool operator ==(Object other) => other is FrequentForum && other.fid == fid && other.name == name;

  @override
  int get hashCode => Object.hash(fid, name);

  FrequentForum _with({String? name, int? updated, int? rank}) =>
      FrequentForum(fid: fid, name: name ?? this.name, updated: updated ?? this.updated, rank: rank ?? this.rank);

  Map<String, Object> _toJson({bool pinned = false}) => {
    'fid': fid,
    'name': name,
    if (pinned) ...{'at': updated, 'rank': rank},
  };
}

/// The pinned and recent forums of one account.
@immutable
final class FrequentForumsOfAccount {
  /// Constructor.
  const FrequentForumsOfAccount({this.pinned = const [], this.recent = const [], this.unpinned = const {}});

  /// Pinned forums, in the order the user arranged (by [FrequentForum.rank]).
  final List<FrequentForum> pinned;

  /// Recently visited forums, the latest first, none of them pinned.
  final List<FrequentForum> recent;

  /// The forums unpinned on this device, by forum id: when (milliseconds since the epoch). Kept for the cross-device
  /// sync ([frequentForumsUnpinnedKeptFor], [frequentForumsUnpinnedMax]); never one that is pinned.
  final Map<int, int> unpinned;

  /// Nothing to show.
  bool get isEmpty => pinned.isEmpty && recent.isEmpty;

  /// Whether forum [fid] is pinned.
  bool isPinned(int fid) => pinned.any((e) => e.fid == fid);
}

/// The time of a change made at [now] to something last changed at [before]: later than [before] even when the clock
/// went back, so the change wins on the other devices too.
int _after(int now, int before) => now > before ? now : before + 1;

int _nowOr(int? now) => now ?? DateTime.now().millisecondsSinceEpoch;

/// The whole number [value] stands for (a JSON number), null when it is not one.
int? _intOf(Object? value) => value is num && value.isFinite ? value.toInt() : null;

int _byRank(FrequentForum a, FrequentForum b) {
  final byRank = a.rank.compareTo(b.rank);
  return byRank != 0 ? byRank : a.fid.compareTo(b.fid);
}

/// [pinned] with the ranks of their places, [frequentForumRankStep] apart.
List<FrequentForum> _ranked(List<FrequentForum> pinned, {int Function(FrequentForum e)? updated}) => [
  for (final (i, e) in pinned.indexed) e._with(rank: i * frequentForumRankStep, updated: updated?.call(e)),
];

/// [unpinned] without the records older than [frequentForumsUnpinnedKeptFor] at [now], the latest
/// [frequentForumsUnpinnedMax] of them.
Map<int, int> _unpinnedKept(Map<int, int> unpinned, int now) {
  final kept = unpinned.entries.where((e) => e.value >= now - frequentForumsUnpinnedKeptFor.inMilliseconds).toList()
    ..sort((a, b) {
      final byTime = b.value.compareTo(a.value);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
  return {for (final e in kept.take(frequentForumsUnpinnedMax)) e.key: e.value};
}

/// The frequent forums of every account saved in [raw] (`SettingsKeys.frequentForums`), by uid.
///
/// A JSON object by uid:
///
/// ```json
/// {"31": {"pinned": [{"fid": 1, "name": "…", "at": 1700000000000, "rank": 0}],
///         "recent": [{"fid": 2, "name": "…"}],
///         "unpinned": {"3": 1700000000000}}}
/// ```
///
/// Anything else (an empty value, damaged JSON, entries that are not forums) reads as nothing for that part;
/// duplicates are dropped and the lists are cut to their limits. Pinned forums saved before the ranks were kept (or
/// whose ranks do not rise along the list) get the ranks of their places, changed at 0.
Map<int, FrequentForumsOfAccount> decodeFrequentForums(String raw) {
  if (raw.isEmpty) {
    return const {};
  }
  try {
    final json = jsonDecode(raw);
    if (json is! Map) {
      return const {};
    }
    final result = <int, FrequentForumsOfAccount>{};
    for (final MapEntry(:key, :value) in json.entries) {
      final uid = int.tryParse('$key');
      if (uid == null || value is! Map) {
        continue;
      }
      var pinned = _decodeList(value['pinned'], frequentForumsPinnedMax, pinned: true);
      if (_unranked(value['pinned']) || !_inOrder(pinned)) {
        pinned = _ranked(pinned);
      }
      final pinnedIds = pinned.map((e) => e.fid).toSet();
      final recent = _decodeList(
        value['recent'],
        frequentForumsRecentMax + pinned.length,
      ).where((e) => !pinnedIds.contains(e.fid)).take(frequentForumsRecentMax).toList();
      final unpinned = <int, int>{};
      if (value['unpinned'] case final Map<dynamic, dynamic> gone) {
        for (final MapEntry(key: fid, value: at) in gone.entries) {
          final id = int.tryParse('$fid');
          if (id != null && id > 0 && at is int && !pinnedIds.contains(id)) {
            unpinned[id] = at;
          }
        }
      }
      result[uid] = FrequentForumsOfAccount(pinned: pinned, recent: recent, unpinned: unpinned);
    }
    return result;
  } on FormatException {
    return const {};
  }
}

/// Whether [pinned] are in the order of their ranks.
bool _inOrder(List<FrequentForum> pinned) {
  for (var i = 1; i < pinned.length; i++) {
    if (_byRank(pinned[i - 1], pinned[i]) >= 0) {
      return false;
    }
  }
  return true;
}

/// Whether an entry of the saved pinned list [json] has no rank (saved before the ranks were kept).
bool _unranked(Object? json) => json is List && json.any((e) => e is Map && e['fid'] is int && e['rank'] is! int);

List<FrequentForum> _decodeList(Object? json, int max, {bool pinned = false}) {
  if (json is! List) {
    return const [];
  }
  final seen = <int>{};
  final result = <FrequentForum>[];
  for (final e in json) {
    if (e is! Map) {
      continue;
    }
    final fid = e['fid'];
    final name = e['name'];
    if (fid is! int || fid <= 0 || name is! String || name.trim().isEmpty || !seen.add(fid)) {
      continue;
    }
    final at = e['at'];
    final rank = e['rank'];
    result.add(
      pinned
          ? FrequentForum(fid: fid, name: name, updated: at is int ? at : 0, rank: rank is int ? rank : 0)
          : FrequentForum(fid: fid, name: name),
    );
    if (result.length >= max) {
      break;
    }
  }
  return result;
}

/// [all] as the value to save, see [decodeFrequentForums]. Accounts with nothing are left out.
String encodeFrequentForums(Map<int, FrequentForumsOfAccount> all) {
  final json = <String, Object>{
    for (final MapEntry(:key, :value) in all.entries)
      if (!value.isEmpty || value.unpinned.isNotEmpty)
        '$key': {
          'pinned': [for (final e in value.pinned) e._toJson(pinned: true)],
          'recent': [for (final e in value.recent) e._toJson()],
          if (value.unpinned.isNotEmpty) 'unpinned': {for (final e in value.unpinned.entries) '${e.key}': e.value},
        },
  };
  return json.isEmpty ? '' : jsonEncode(json);
}

/// [account] after forum [forum] was visited at [now] (milliseconds, the device clock when not given): first of the
/// recent ones, once, the oldest dropped. A pinned forum is not listed again as a recent one, only its name is
/// refreshed (a change of the pinned forum when the name is another).
FrequentForumsOfAccount frequentForumsVisited(FrequentForumsOfAccount account, FrequentForum forum, {int? now}) {
  if (account.isPinned(forum.fid)) {
    return FrequentForumsOfAccount(
      pinned: [
        for (final e in account.pinned)
          e.fid == forum.fid && e.name != forum.name
              ? e._with(name: forum.name, updated: _after(_nowOr(now), e.updated))
              : e,
      ],
      recent: account.recent,
      unpinned: account.unpinned,
    );
  }
  return FrequentForumsOfAccount(
    pinned: account.pinned,
    recent: [
      FrequentForum(fid: forum.fid, name: forum.name),
      ...account.recent.where((e) => e.fid != forum.fid),
    ].take(frequentForumsRecentMax).toList(),
    unpinned: account.unpinned,
  );
}

/// [account] with [forum] pinned (last) or, when it is pinned already, unpinned, at [now] (milliseconds, the device
/// clock when not given). A pinned forum leaves the recent ones; an unpinned one goes back to the front of them and
/// leaves a record of when ([FrequentForumsOfAccount.unpinned]).
FrequentForumsOfAccount frequentForumsTogglePin(FrequentForumsOfAccount account, FrequentForum forum, {int? now}) {
  final at = _nowOr(now);
  final shown = FrequentForum(fid: forum.fid, name: forum.name);
  if (account.isPinned(forum.fid)) {
    final was = account.pinned.firstWhere((e) => e.fid == forum.fid);
    return FrequentForumsOfAccount(
      pinned: account.pinned.where((e) => e.fid != forum.fid).toList(),
      recent: [shown, ...account.recent].take(frequentForumsRecentMax).toList(),
      unpinned: _unpinnedKept({...account.unpinned, forum.fid: _after(at, was.updated)}, at),
    );
  }
  if (account.pinned.length >= frequentForumsPinnedMax) {
    return account;
  }
  return FrequentForumsOfAccount(
    pinned: [
      ...account.pinned,
      shown._with(
        // Later than the record of its last unpinning: pinned again wins on the other devices.
        updated: _after(at, account.unpinned[forum.fid] ?? 0),
        rank: account.pinned.isEmpty ? 0 : account.pinned.last.rank + frequentForumRankStep,
      ),
    ],
    recent: account.recent.where((e) => e.fid != forum.fid).toList(),
    unpinned: {
      for (final e in account.unpinned.entries)
        if (e.key != forum.fid) e.key: e.value,
    },
  );
}

/// [account] with the pinned forum at [oldIndex] moved to [newIndex] (the index in the list before the move, as a
/// `ReorderableListView` reports it) at [now] (milliseconds, the device clock when not given).
///
/// Only the moved forum changes: it takes a rank between its new neighbours. When they leave no room (after many moves
/// to the same place), every forum takes the rank of its place and counts as changed.
FrequentForumsOfAccount frequentForumsReorder(
  FrequentForumsOfAccount account,
  int oldIndex,
  int newIndex, {
  int? now,
}) {
  final pinned = [...account.pinned];
  if (oldIndex < 0 || oldIndex >= pinned.length) {
    return account;
  }
  final target = (newIndex > oldIndex ? newIndex - 1 : newIndex).clamp(0, pinned.length - 1);
  if (target == oldIndex) {
    return account;
  }
  final at = _nowOr(now);
  final moved = pinned.removeAt(oldIndex);
  final before = target > 0 ? pinned[target - 1].rank : null;
  final after = target < pinned.length ? pinned[target].rank : null;
  final rank = switch ((before, after)) {
    (null, final int after) => after - frequentForumRankStep,
    (final int before, null) => before + frequentForumRankStep,
    (final int before, final int after) => before + (after - before) ~/ 2,
    _ => moved.rank,
  };
  pinned.insert(target, moved._with(rank: rank, updated: _after(at, moved.updated)));
  final room = (before == null || before < rank) && (after == null || rank < after);
  return FrequentForumsOfAccount(
    pinned: room ? pinned : _ranked(pinned, updated: (e) => _after(at, e.updated)),
    recent: account.recent,
    unpinned: account.unpinned,
  );
}

/// The items of the `pinned_forums` section of the sync document [account] stands for, by forum id: the pinned forums
/// (`updated`, `name`, `rank`) and the records of the unpinned ones (`updated`, `deleted`).
Map<String, Map<String, dynamic>> frequentForumsSyncItems(FrequentForumsOfAccount account) => {
  for (final e in account.unpinned.entries) '${e.key}': {'updated': e.value, 'deleted': true},
  for (final e in account.pinned) '${e.fid}': {'updated': e.updated, 'name': e.name, 'rank': e.rank},
};

/// [account] with the [items] of the `pinned_forums` section of the sync document taken in at [now] (milliseconds),
/// null when nothing changes.
///
/// Per forum the later `updated` wins, the document's on the same time (the merge keeps the forum's item then): a
/// forum the document pins is pinned (or renamed, or moved) here, one it records as unpinned is unpinned here unless
/// it was pinned again later. A forum the document does not hold stays as it is; items this version does not read
/// (no name, no rank, not a forum id) are left alone. The pinned forums are then in the order of their ranks, the
/// latest [frequentForumsPinnedMax] of them (the others dropped without a record: not unpinned).
FrequentForumsOfAccount? frequentForumsWithSynced(
  FrequentForumsOfAccount account,
  Map<String, Map<String, dynamic>> items, {
  required int now,
}) {
  final pinned = {for (final e in account.pinned) e.fid: e};
  final unpinned = {...account.unpinned};
  var changed = false;
  for (final MapEntry(:key, value: item) in items.entries) {
    final fid = int.tryParse(key);
    final updated = _intOf(item['updated']);
    if (fid == null || fid <= 0 || '$fid' != key || updated == null) {
      continue;
    }
    final mine = pinned[fid];
    if (item['deleted'] == true || item['deleted'] == 1) {
      if (mine != null && mine.updated <= updated) {
        pinned.remove(fid);
        unpinned[fid] = updated;
        changed = true;
      }
      continue;
    }
    final name = item['name'];
    final rank = _intOf(item['rank']);
    if (name is! String || name.trim().isEmpty || rank == null) {
      continue;
    }
    final gone = unpinned[fid];
    if (mine == null ? gone != null && gone > updated : mine.updated > updated) {
      continue;
    }
    if (mine != null && mine.updated == updated && mine.name == name && mine.rank == rank) {
      continue;
    }
    pinned[fid] = FrequentForum(fid: fid, name: name, updated: updated, rank: rank);
    unpinned.remove(fid);
    changed = true;
  }
  if (!changed) {
    return null;
  }
  var next = pinned.values.toList();
  if (next.length > frequentForumsPinnedMax) {
    // The order of the sync document's own cap: the later first, ties by the item's key.
    next.sort((a, b) {
      final byTime = b.updated.compareTo(a.updated);
      return byTime != 0 ? byTime : '${a.fid}'.compareTo('${b.fid}');
    });
    next = next.take(frequentForumsPinnedMax).toList();
  }
  next.sort(_byRank);
  final fids = {for (final e in next) e.fid};
  return FrequentForumsOfAccount(
    pinned: next,
    recent: account.recent.where((e) => !fids.contains(e.fid)).toList(),
    unpinned: _unpinnedKept(unpinned, now),
  );
}

/// The frequent forums of the accounts, kept in the settings.
final class FrequentForumsStore {
  /// Constructor.
  const FrequentForumsStore(this._settings);

  final SettingsRepository _settings;

  /// The forums of account [uid] in [settings].
  static FrequentForumsOfAccount of(SettingsMap settings, int? uid) =>
      decodeFrequentForums(settings.frequentForums)[uid ?? frequentForumsGuestUid] ?? const FrequentForumsOfAccount();

  /// The forums of account [uid] now.
  FrequentForumsOfAccount current(int? uid) => of(_settings.currentSettings, uid);

  /// The text the cross-device sync compares the pinned forums of account [uid] in [settings] by.
  static String syncSnapshot(SettingsMap settings, int uid) => jsonEncode(frequentForumsSyncItems(of(settings, uid)));

  /// Take the [items] of the `pinned_forums` section of the sync document in for account [uid]
  /// ([frequentForumsWithSynced]); nothing is saved when nothing changes.
  Future<void> applySynced(int uid, Map<String, Map<String, dynamic>> items) => _update(
    uid,
    (a) => frequentForumsWithSynced(a, items, now: DateTime.now().millisecondsSinceEpoch) ?? a,
  );

  /// Forum [forum] was visited by account [uid].
  Future<void> visit(int? uid, FrequentForum forum) => _update(uid, (a) => frequentForumsVisited(a, forum));

  /// Pin or unpin [forum] for account [uid].
  Future<void> togglePin(int? uid, FrequentForum forum) => _update(uid, (a) => frequentForumsTogglePin(a, forum));

  /// Move a pinned forum of account [uid], see [frequentForumsReorder].
  Future<void> reorder(int? uid, int oldIndex, int newIndex) =>
      _update(uid, (a) => frequentForumsReorder(a, oldIndex, newIndex));

  /// The update of each settings repository still being saved: the next one waits for it, so it reads the settings
  /// the one before it saved.
  static final _pending = Expando<Future<void>>();

  Future<void> _update(int? uid, FrequentForumsOfAccount Function(FrequentForumsOfAccount) change) {
    final previous = _pending[_settings];
    final done = previous == null ? _apply(uid, change) : previous.then((_) => _apply(uid, change));
    // A failed update must not stop the ones after it.
    final tracked = done.catchError((Object _) {});
    _pending[_settings] = tracked;
    unawaited(
      tracked.whenComplete(() {
        if (identical(_pending[_settings], tracked)) {
          _pending[_settings] = null;
        }
      }),
    );
    return done;
  }

  Future<void> _apply(int? uid, FrequentForumsOfAccount Function(FrequentForumsOfAccount) change) async {
    final all = {...decodeFrequentForums(_settings.currentSettings.frequentForums)};
    final key = uid ?? frequentForumsGuestUid;
    final before = all[key] ?? const FrequentForumsOfAccount();
    all[key] = change(before);
    final value = encodeFrequentForums(all);
    if (value == encodeFrequentForums({...all, key: before})) {
      return;
    }
    await _settings.setValue(SettingsKeys.frequentForums, value);
  }
}
