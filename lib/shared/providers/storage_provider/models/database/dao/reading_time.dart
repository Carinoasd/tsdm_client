part of 'dao.dart';

/// DAO for table [ReadingTime].
@DriftAccessor(tables: [ReadingTime])
final class ReadingTimeDao extends DatabaseAccessor<AppDatabase> with _$ReadingTimeDaoMixin {
  /// Constructor.
  ReadingTimeDao(super.attachedDatabase);

  /// Add [seconds] to what user [uid] read in forum [fid] on [day] (`yyyyMMdd`).
  Future<void> addSeconds({
    required int uid,
    required int day,
    required int fid,
    required String forumName,
    required int seconds,
  }) async {
    if (seconds <= 0) {
      return;
    }
    await into(readingTime).insert(
      ReadingTimeCompanion.insert(uid: uid, day: day, fid: fid, forumName: Value(forumName), seconds: Value(seconds)),
      onConflict: DoUpdate(
        (old) => ReadingTimeCompanion.custom(
          forumName: Variable(forumName),
          seconds: old.seconds + Variable<int>(seconds),
        ),
        target: [readingTime.uid, readingTime.day, readingTime.fid],
      ),
    );
  }

  /// The rows of user [uid] from day [from] to day [to], both included (`yyyyMMdd`).
  Future<List<ReadingTimeEntity>> selectRange({required int uid, required int from, required int to}) async =>
      (select(readingTime)..where((e) => e.uid.equals(uid) & e.day.isBetweenValues(from, to))).get();

  /// Delete every row of user [uid].
  Future<int> deleteByUid(int uid) async => (delete(readingTime)..where((e) => e.uid.equals(uid))).go();

  /// Delete all rows.
  Future<int> deleteAll() async => delete(readingTime).go();
}
