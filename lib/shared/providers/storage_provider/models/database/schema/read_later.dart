part of 'schema.dart';

/// Table of the threads every account put aside to read later.
///
/// A local list only: the forum is never asked. One row per account and thread.
@DataClassName('ReadLaterEntity')
class ReadLater extends Table {
  /// User id, part of [primaryKey].
  IntColumn get uid => integer()();

  /// Thread id, part of [primaryKey].
  IntColumn get tid => integer()();

  /// Thread title when it was put aside.
  TextColumn get threadTitle => text()();

  /// Name of the thread's author, null when not known.
  TextColumn get author => text().nullable()();

  /// Name of the forum the thread is in, null when not known.
  TextColumn get forumName => text().nullable()();

  /// When the thread was put aside.
  DateTimeColumn get addedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {uid, tid};
}
