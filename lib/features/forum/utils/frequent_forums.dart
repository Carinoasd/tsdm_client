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

/// A forum of the frequent forums bar.
@immutable
final class FrequentForum {
  /// Constructor.
  const FrequentForum({required this.fid, required this.name});

  /// Forum id.
  final int fid;

  /// Forum name, as shown when it was pinned or visited last.
  final String name;

  @override
  bool operator ==(Object other) => other is FrequentForum && other.fid == fid && other.name == name;

  @override
  int get hashCode => Object.hash(fid, name);

  Map<String, Object> _toJson() => {'fid': fid, 'name': name};
}

/// The pinned and recent forums of one account.
@immutable
final class FrequentForumsOfAccount {
  /// Constructor.
  const FrequentForumsOfAccount({this.pinned = const [], this.recent = const []});

  /// Pinned forums, in the order the user arranged.
  final List<FrequentForum> pinned;

  /// Recently visited forums, the latest first, none of them pinned.
  final List<FrequentForum> recent;

  /// Nothing to show.
  bool get isEmpty => pinned.isEmpty && recent.isEmpty;

  /// Whether forum [fid] is pinned.
  bool isPinned(int fid) => pinned.any((e) => e.fid == fid);
}

/// The frequent forums of every account saved in [raw] (`SettingsKeys.frequentForums`), by uid.
///
/// A JSON object `{"<uid>": {"pinned": [{"fid": 1, "name": "…"}], "recent": [...]}}`. Anything else (an empty value,
/// damaged JSON, entries that are not forums) reads as nothing for that part; duplicates are dropped and the lists are
/// cut to their limits.
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
      final pinned = _decodeList(value['pinned'], frequentForumsPinnedMax);
      final pinnedIds = pinned.map((e) => e.fid).toSet();
      final recent = _decodeList(
        value['recent'],
        frequentForumsRecentMax + pinned.length,
      ).where((e) => !pinnedIds.contains(e.fid)).take(frequentForumsRecentMax).toList();
      result[uid] = FrequentForumsOfAccount(pinned: pinned, recent: recent);
    }
    return result;
  } on FormatException {
    return const {};
  }
}

List<FrequentForum> _decodeList(Object? json, int max) {
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
    result.add(FrequentForum(fid: fid, name: name));
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
      if (!value.isEmpty)
        '$key': {
          'pinned': [for (final e in value.pinned) e._toJson()],
          'recent': [for (final e in value.recent) e._toJson()],
        },
  };
  return json.isEmpty ? '' : jsonEncode(json);
}

/// [account] after forum [forum] was visited: first of the recent ones, once, the oldest dropped. A pinned forum is
/// not listed again as a recent one, only its name is refreshed.
FrequentForumsOfAccount frequentForumsVisited(FrequentForumsOfAccount account, FrequentForum forum) {
  if (account.isPinned(forum.fid)) {
    return FrequentForumsOfAccount(
      pinned: [for (final e in account.pinned) e.fid == forum.fid ? forum : e],
      recent: account.recent,
    );
  }
  return FrequentForumsOfAccount(
    pinned: account.pinned,
    recent: [forum, ...account.recent.where((e) => e.fid != forum.fid)].take(frequentForumsRecentMax).toList(),
  );
}

/// [account] with [forum] pinned (last) or, when it is pinned already, unpinned. A pinned forum leaves the recent ones;
/// an unpinned one goes back to the front of them.
FrequentForumsOfAccount frequentForumsTogglePin(FrequentForumsOfAccount account, FrequentForum forum) {
  if (account.isPinned(forum.fid)) {
    return FrequentForumsOfAccount(
      pinned: account.pinned.where((e) => e.fid != forum.fid).toList(),
      recent: [forum, ...account.recent].take(frequentForumsRecentMax).toList(),
    );
  }
  if (account.pinned.length >= frequentForumsPinnedMax) {
    return account;
  }
  return FrequentForumsOfAccount(
    pinned: [...account.pinned, forum],
    recent: account.recent.where((e) => e.fid != forum.fid).toList(),
  );
}

/// [account] with the pinned forum at [oldIndex] moved to [newIndex] (the index in the list before the move, as a
/// `ReorderableListView` reports it).
FrequentForumsOfAccount frequentForumsReorder(FrequentForumsOfAccount account, int oldIndex, int newIndex) {
  final pinned = [...account.pinned];
  if (oldIndex < 0 || oldIndex >= pinned.length) {
    return account;
  }
  final target = (newIndex > oldIndex ? newIndex - 1 : newIndex).clamp(0, pinned.length - 1);
  pinned.insert(target, pinned.removeAt(oldIndex));
  return FrequentForumsOfAccount(pinned: pinned, recent: account.recent);
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

  /// Forum [forum] was visited by account [uid].
  Future<void> visit(int? uid, FrequentForum forum) => _update(uid, (a) => frequentForumsVisited(a, forum));

  /// Pin or unpin [forum] for account [uid].
  Future<void> togglePin(int? uid, FrequentForum forum) => _update(uid, (a) => frequentForumsTogglePin(a, forum));

  /// Move a pinned forum of account [uid], see [frequentForumsReorder].
  Future<void> reorder(int? uid, int oldIndex, int newIndex) =>
      _update(uid, (a) => frequentForumsReorder(a, oldIndex, newIndex));

  Future<void> _update(int? uid, FrequentForumsOfAccount Function(FrequentForumsOfAccount) change) async {
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
