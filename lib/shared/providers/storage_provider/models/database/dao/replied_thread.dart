part of 'dao.dart';

/// DAO for table [RepliedThread].
@DriftAccessor(tables: [RepliedThread])
final class RepliedThreadDao extends DatabaseAccessor<AppDatabase> with _$RepliedThreadDaoMixin {
  /// Constructor.
  RepliedThreadDao(super.attachedDatabase);

  /// Insert or refresh the mark of user [uid] on thread [tid] in forum [fid].
  Future<int> record({required int uid, required int tid, required int fid, DateTime? time}) async {
    return into(repliedThread).insertOnConflictUpdate(
      RepliedThreadCompanion(uid: Value(uid), tid: Value(tid), fid: Value(fid), time: Value(time ?? DateTime.now())),
    );
  }

  SimpleSelectStatement<$RepliedThreadTable, RepliedThreadEntity> _selectOf(int uid, int? fid) =>
      select(repliedThread)..where((e) => fid == null ? e.uid.equals(uid) : e.uid.equals(uid) & e.fid.equals(fid));

  /// All marks of user [uid], only those in forum [fid] when given.
  Future<List<RepliedThreadEntity>> selectByUid(int uid, {int? fid}) async => _selectOf(uid, fid).get();

  /// Watch all marks of user [uid], only those in forum [fid] when given.
  Stream<List<RepliedThreadEntity>> watchByUid(int uid, {int? fid}) => _selectOf(uid, fid).watch();

  /// Delete every mark of user [uid].
  Future<int> deleteByUid(int uid) async => (delete(repliedThread)..where((e) => e.uid.equals(uid))).go();

  /// Delete all marks.
  Future<int> deleteAll() async => delete(repliedThread).go();
}
