import 'package:tsdm_client/features/reading_time/models/reading_time_summary.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Where the reading time is kept.
abstract interface class ReadingTimeStore {
  /// Add [seconds] read in forum [fid] on [day] by user [uid].
  Future<void> add({
    required int uid,
    required DateTime day,
    required int fid,
    required String forumName,
    required int seconds,
  });

  /// The rows of user [uid] from day [from] to day [to], both included.
  Future<List<ReadingTimeRow>> fetch({required int uid, required DateTime from, required DateTime to});

  /// Forget the reading time of every account.
  Future<void> clear();
}

/// The reading time kept in the database (schema 19).
final class StorageReadingTimeStore implements ReadingTimeStore {
  /// Constructor.
  const StorageReadingTimeStore(this._storage);

  final StorageProvider _storage;

  @override
  Future<void> add({
    required int uid,
    required DateTime day,
    required int fid,
    required String forumName,
    required int seconds,
  }) => _storage.addReadingTime(uid: uid, day: readingDayKey(day), fid: fid, forumName: forumName, seconds: seconds);

  @override
  Future<List<ReadingTimeRow>> fetch({required int uid, required DateTime from, required DateTime to}) async {
    final rows = await _storage.fetchReadingTime(uid: uid, from: readingDayKey(from), to: readingDayKey(to));
    return [
      for (final r in rows) ReadingTimeRow(day: r.day, fid: r.fid, forumName: r.forumName, seconds: r.seconds),
    ];
  }

  @override
  Future<void> clear() => _storage.deleteAllReadingTime();
}

/// A [ReadingTimeStore] in memory (tests).
final class MemoryReadingTimeStore implements ReadingTimeStore {
  /// The rows by `uid:day:fid`.
  final rows = <String, ({int uid, ReadingTimeRow row})>{};

  @override
  Future<void> add({
    required int uid,
    required DateTime day,
    required int fid,
    required String forumName,
    required int seconds,
  }) async {
    final key = readingDayKey(day);
    final id = '$uid:$key:$fid';
    final old = rows[id]?.row.seconds ?? 0;
    rows[id] = (uid: uid, row: ReadingTimeRow(day: key, fid: fid, forumName: forumName, seconds: old + seconds));
  }

  @override
  Future<List<ReadingTimeRow>> fetch({required int uid, required DateTime from, required DateTime to}) async => [
    for (final e in rows.values)
      if (e.uid == uid && e.row.day >= readingDayKey(from) && e.row.day <= readingDayKey(to)) e.row,
  ];

  @override
  Future<void> clear() async => rows.clear();
}
