part of 'schema.dart';

/// Table of the threads every account replied to from this device, or was seen to have a floor in.
///
/// A local mark only (issue #21): the forum is never asked. One row per account and thread.
@DataClassName('RepliedThreadEntity')
class RepliedThread extends Table {
  /// User id, part of [primaryKey].
  IntColumn get uid => integer()();

  /// Thread id, part of [primaryKey].
  IntColumn get tid => integer()();

  /// Direct parent forum id.
  IntColumn get fid => integer()();

  /// When the mark was recorded.
  DateTimeColumn get time => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {uid, tid};
}
