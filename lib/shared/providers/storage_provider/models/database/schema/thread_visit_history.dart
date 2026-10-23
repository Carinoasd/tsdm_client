part of 'schema.dart';

/// Table for history of all users visited thread.
///
/// Including user info, thread info and visit time.
@DataClassName('ThreadVisitHistoryEntity')
class ThreadVisitHistory extends Table {
  /// User id, part of [primaryKey].
  IntColumn get uid => integer()();

  /// Thread id, part of [primaryKey].
  IntColumn get tid => integer()();

  /// Name of user.
  TextColumn get username => text()();

  /// Thread title
  TextColumn get threadTitle => text()();

  /// Direct parent forum id.
  IntColumn get fid => integer()();

  /// Direct parent forum name.
  TextColumn get forumName => text()();

  /// Visit time, timestamp.
  DateTimeColumn get visitTime => dateTime()();

  /// Where the reading stopped: the page (oldest floor first) of the floor at the top of the thread page. Null while
  /// not known (a visit kept before schema 17, a page newest first without the floors per page).
  IntColumn get lastPage => integer().nullable()();

  /// Where the reading stopped: the post id of that floor; null at the start of the thread.
  IntColumn get lastPid => integer().nullable()();

  /// Where the reading stopped: the number of that floor, 1 at the start of the thread.
  IntColumn get lastFloor => integer().nullable()();

  /// The thread's replies when it was read (as the thread lists count them): the lists tell the replies since.
  IntColumn get seenReplies => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {uid, tid};
}
