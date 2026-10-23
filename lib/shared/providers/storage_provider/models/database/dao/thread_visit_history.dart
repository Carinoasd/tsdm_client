part of 'dao.dart';

/// DAO for table [ThreadVisitHistory].
@DriftAccessor(tables: [ThreadVisitHistory])
final class ThreadVisitHistoryDao extends DatabaseAccessor<AppDatabase> with _$ThreadVisitHistoryDaoMixin {
  /// Constructor.
  ThreadVisitHistoryDao(super.attachedDatabase);

  /// Get all history, all users.
  Future<List<ThreadVisitHistoryEntity>> selectAll() async {
    return (select(
      threadVisitHistory,
    )..orderBy([(e) => OrderingTerm(expression: e.visitTime, mode: OrderingMode.desc)])).get();
  }

  /// Get all history with the user specified with [uid].
  ///
  /// Only [uid]'s user's visit history will be returned.
  Future<List<ThreadVisitHistoryEntity>> selectByUid(int uid) async {
    return (select(threadVisitHistory)
          ..where((e) => e.uid.equals(uid))
          ..orderBy([(e) => OrderingTerm(expression: e.visitTime, mode: OrderingMode.desc)]))
        .get();
  }

  /// Get all history on thread with [tid].
  ///
  /// Only [tid]'s thread's visit history will be returned.
  Future<List<ThreadVisitHistoryEntity>> selectByTid(int tid) async {
    return (select(threadVisitHistory)
          ..where((e) => e.tid.equals(tid))
          ..orderBy([(e) => OrderingTerm(expression: e.visitTime, mode: OrderingMode.desc)]))
        .get();
  }

  /// The threads user [uid] visited (by tid) with where the reading stopped, again whenever the table changes.
  Stream<Map<int, ({int? page, int? pid, int? floor, int? seenReplies})>> watchProgressByUid(int uid) {
    final t = threadVisitHistory;
    final query = selectOnly(t)
      ..addColumns([t.tid, t.lastPage, t.lastPid, t.lastFloor, t.seenReplies])
      ..where(t.uid.equals(uid));
    return query.watch().map(
      (rows) => {
        for (final row in rows)
          row.read(t.tid)!: (
            page: row.read(t.lastPage),
            pid: row.read(t.lastPid),
            floor: row.read(t.lastFloor),
            seenReplies: row.read(t.seenReplies),
          ),
      },
    );
  }

  /// Keep where user [uid] stopped reading thread [tid] on its visit record; nothing when the visit is not recorded.
  Future<int> updateProgress({
    required int uid,
    required int tid,
    required int? page,
    required int? pid,
    required int? floor,
    required int? seenReplies,
  }) => (update(threadVisitHistory)..where((e) => e.uid.equals(uid) & e.tid.equals(tid))).write(
    ThreadVisitHistoryCompanion(
      lastPage: Value(page),
      lastPid: Value(pid),
      lastFloor: Value(floor),
      seenReplies: Value(seenReplies),
    ),
  );

  /// Insert or update item [companion].
  ///
  /// All info are provided by the caller. Columns the companion leaves absent (the reading progress) keep their value.
  Future<int> upsertVisitHistory(ThreadVisitHistoryCompanion companion) async {
    return into(threadVisitHistory).insertOnConflictUpdate(companion);
  }

  /// Delete history by user's [uid] or thread's [tid].
  ///
  /// Can be used as:
  ///
  /// * [uid] != null && [tid] != null: Delete user visit a certain thread.
  /// * [uid] != null && [tid] == null: Delete user visit all thread.
  /// * [uid] == null && [tid] != null: Delete all history on a certain thread.
  ///
  /// Do nothing if both [uid] and [tid] are null.
  Future<int> deleteByUidOrTid({int? uid, int? tid}) async => switch ((uid, tid)) {
    (final int u, final int t) => (delete(threadVisitHistory)..where((e) => e.uid.equals(u) & e.tid.equals(t))).go(),
    (final int u, null) => (delete(threadVisitHistory)..where((e) => e.uid.equals(u))).go(),
    (null, final int t) => (delete(threadVisitHistory)..where((e) => e.tid.equals(t))).go(),
    (null, null) => 0,
  };

  /// Delete all items in table.
  ///
  /// Use with caution.
  Future<int> deleteAll() async {
    return delete(threadVisitHistory).go();
  }
}
