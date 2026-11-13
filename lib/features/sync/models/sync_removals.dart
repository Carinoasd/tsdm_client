import 'dart:convert';

/// Most records of threads taken off a list (the read later list, the followed threads) an account keeps on a device
/// for the cross-device sync: the latest.
const syncRemovalsMax = 200;

/// How long such a record is kept (as long as the sync keeps the record of a deletion in its document).
const syncRemovalKeptFor = Duration(days: 180);

/// The records of threads taken off a list kept in the settings row [raw] (`{"<tid>": ms}`): thread id to the time
/// (milliseconds). Empty when there is none or it is not readable.
Map<int, int> syncRemovalsOf(String? raw) {
  if (raw == null || raw.isEmpty) {
    return {};
  }
  try {
    final json = jsonDecode(raw);
    if (json is! Map) {
      return {};
    }
    return {
      for (final MapEntry(:key, :value) in json.entries)
        if (value is num) ?int.tryParse('$key'): value.toInt(),
    };
  } on FormatException {
    return {};
  }
}

/// [removed] with the threads of [tids] taken off, each at its time (a later record of a thread kept), and the threads
/// of [back] taken back in (their records dropped); the records older than [syncRemovalKeptFor] before [at] (now) dropped and at most
/// [syncRemovalsMax] kept, the latest. The settings row to keep, null when there is no record left.
String? syncRemovalsWith(
  Map<int, int> removed, {
  required int at,
  Map<int, int> tids = const {},
  Iterable<int> back = const [],
}) {
  final next = {...removed}..removeWhere((tid, _) => back.contains(tid));
  for (final MapEntry(key: tid, value: time) in tids.entries) {
    if ((next[tid] ?? -1) < time) {
      next[tid] = time;
    }
  }
  final keepSince = at - syncRemovalKeptFor.inMilliseconds;
  final kept = next.entries.where((e) => e.value >= keepSince).toList()
    ..sort((a, b) => b.value != a.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key));
  if (kept.isEmpty) {
    return null;
  }
  return jsonEncode({for (final e in kept.take(syncRemovalsMax)) '${e.key}': e.value});
}

/// The items a device holds of a section of threads (`read_later`, `follows`): its [live] items by thread id, and
/// the records of the threads it took off ([removed]) that it does not hold, as deletions.
Map<String, Map<String, dynamic>> syncItemsWithRemovals(Map<int, Map<String, dynamic>> live, Map<int, int> removed) => {
  for (final MapEntry(:key, :value) in removed.entries)
    if (!live.containsKey(key)) '$key': {'updated': value, 'deleted': true},
  for (final MapEntry(:key, :value) in live.entries) '$key': value,
};
