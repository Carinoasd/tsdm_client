import 'package:flutter/foundation.dart';

/// Most characters of a bookmark's note.
const floorBookmarkNoteMaxLength = 100;

/// Most characters of the excerpt of the floor a bookmark keeps.
const floorBookmarkExcerptLength = 60;

/// A floor of a thread an account marked to come back to, with an optional one line note.
///
/// Kept as the item of the `bookmarks` section of the cross-device sync document it is (see `SyncDocument`), under
/// [key] (`<tid>:<pid>`):
///
/// ```json
/// {"updated": ms, "tid": 1, "pid": 2, "floor": 27, "page": 2, "note": "…", "excerpt": "…", "title": "…"}
/// {"updated": ms, "deleted": true}
/// ```
///
/// `updated` is the device clock (milliseconds since the epoch) of the last change; a removed bookmark is kept as a
/// record of its deletion ([deleted]) so the other devices remove it too. Fields this version does not know stay in
/// [raw] and are written back.
@immutable
final class FloorBookmark {
  /// A live bookmark.
  factory FloorBookmark({
    required int tid,
    required int pid,
    required int updated,
    int? floor,
    int? page,
    String note = '',
    String excerpt = '',
    String threadTitle = '',
    Map<String, dynamic> unknown = const {},
  }) => FloorBookmark._(keyOf(tid: tid, pid: pid), {
    for (final MapEntry(:key, :value) in unknown.entries)
      if (!fields.contains(key)) key: value,
    'updated': updated,
    'tid': tid,
    'pid': pid,
    'floor': ?floor,
    'page': ?page,
    'note': note,
    'excerpt': excerpt,
    'title': threadTitle,
  });

  /// The bookmark of the item [raw] under [key], as read.
  const FloorBookmark._(this.key, this.raw);

  /// The record of the deletion of the bookmark under [key] at [updated].
  factory FloorBookmark.deletedAt(String key, int updated) =>
      FloorBookmark._(key, {'updated': updated, 'deleted': true});

  /// The bookmark of the item [item] under [key], null when either is not one this version reads (a key not
  /// `<tid>:<pid>`, a live item without them).
  static FloorBookmark? fromItem(String key, Map<String, dynamic> item) {
    final ids = idsOf(key);
    if (ids == null) {
      return null;
    }
    if (item['deleted'] == true || item['deleted'] == 1) {
      return FloorBookmark._(key, {...item});
    }
    final tid = item['tid'];
    final pid = item['pid'];
    if (tid is! num || pid is! num || tid.toInt() != ids.tid || pid.toInt() != ids.pid) {
      return null;
    }
    return FloorBookmark._(key, {...item});
  }

  /// The fields this version reads.
  static const fields = {'updated', 'deleted', 'tid', 'pid', 'floor', 'page', 'note', 'excerpt', 'title'};

  /// The key of the bookmark of floor [pid] of thread [tid].
  static String keyOf({required int tid, required int pid}) => '$tid:$pid';

  /// The thread and floor ids of [key], null when it is not `<tid>:<pid>`.
  static ({int tid, int pid})? idsOf(String key) {
    final parts = key.split(':');
    if (parts.length != 2) {
      return null;
    }
    final tid = int.tryParse(parts[0]);
    final pid = int.tryParse(parts[1]);
    if (tid == null || pid == null || tid <= 0 || pid <= 0 || '$tid:$pid' != key) {
      return null;
    }
    return (tid: tid, pid: pid);
  }

  /// `<tid>:<pid>`.
  final String key;

  /// The item as kept, unknown fields included.
  final Map<String, dynamic> raw;

  int? _int(String field) => switch (raw[field]) {
    final num n when n.isFinite => n.toInt(),
    _ => null,
  };

  String _text(String field) => switch (raw[field]) {
    final String s => s,
    _ => '',
  };

  /// Thread id.
  int get tid => idsOf(key)!.tid;

  /// Post id of the floor.
  int get pid => idsOf(key)!.pid;

  /// When it was last changed (milliseconds since the epoch).
  int get updated => _int('updated') ?? 0;

  /// Whether this is the record of a deletion.
  bool get deleted => raw['deleted'] == true || raw['deleted'] == 1;

  /// The floor number, null when not known.
  int? get floor => _int('floor');

  /// The page of the floor, the thread read oldest floor first; null when not known.
  int? get page => _int('page');

  /// The note, empty when none.
  String get note => _text('note');

  /// The start of the floor's text when it was marked.
  String get excerpt => _text('excerpt');

  /// The thread's title when it was marked.
  String get threadTitle => _text('title');

  @override
  bool operator ==(Object other) => other is FloorBookmark && other.key == key && mapEquals(other.raw, raw);

  @override
  int get hashCode => Object.hash(key, Object.hashAllUnordered(raw.entries.map((e) => Object.hash(e.key, e.value))));

  @override
  String toString() => 'FloorBookmark($key, $raw)';
}
