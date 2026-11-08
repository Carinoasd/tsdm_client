part of 'dao.dart';

/// DAO for table [ReadLater].
@DriftAccessor(tables: [ReadLater])
final class ReadLaterDao extends DatabaseAccessor<AppDatabase> with _$ReadLaterDaoMixin {
  /// Constructor.
  ReadLaterDao(super.attachedDatabase);

  /// Put thread [tid] aside for user [uid]; an entry already there is replaced.
  Future<int> add({
    required int uid,
    required int tid,
    required String title,
    String? author,
    String? forumName,
    DateTime? time,
  }) async {
    return into(readLater).insertOnConflictUpdate(
      ReadLaterCompanion(
        uid: Value(uid),
        tid: Value(tid),
        threadTitle: Value(title),
        author: Value(author),
        forumName: Value(forumName),
        addedAt: Value(time ?? DateTime.now()),
      ),
    );
  }

  /// Take thread [tid] of user [uid] off the list.
  Future<int> remove(int uid, int tid) async =>
      (delete(readLater)..where((e) => e.uid.equals(uid) & e.tid.equals(tid))).go();

  SimpleSelectStatement<$ReadLaterTable, ReadLaterEntity> _orderedOf(int uid) => select(readLater)
    ..where((e) => e.uid.equals(uid))
    ..orderBy([
      (e) => OrderingTerm(expression: e.addedAt, mode: OrderingMode.desc),
      // The time is kept in seconds: threads put aside within one second keep the later thread id first.
      (e) => OrderingTerm(expression: e.tid, mode: OrderingMode.desc),
    ]);

  /// Watch the entries of user [uid], the latest put aside first.
  Stream<List<ReadLaterEntity>> watchByUid(int uid) => _orderedOf(uid).watch();

  /// The entries of user [uid], the latest put aside first.
  Future<List<ReadLaterEntity>> selectByUid(int uid) async => _orderedOf(uid).get();

  /// Delete every entry of user [uid].
  Future<int> deleteByUid(int uid) async => (delete(readLater)..where((e) => e.uid.equals(uid))).go();
}
