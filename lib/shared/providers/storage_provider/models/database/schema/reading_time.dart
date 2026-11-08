part of 'schema.dart';

/// Table of the time every account spent reading threads, per day and forum.
///
/// Kept on this device only. One row per account, day and forum.
@DataClassName('ReadingTimeEntity')
class ReadingTime extends Table {
  /// User id, part of [primaryKey].
  IntColumn get uid => integer()();

  /// The local day as `yyyyMMdd` (20261108), part of [primaryKey].
  IntColumn get day => integer()();

  /// Direct parent forum id of the threads read, part of [primaryKey].
  IntColumn get fid => integer()();

  /// Name of the forum when the time was last added.
  TextColumn get forumName => text().withDefault(const Constant(''))();

  /// Seconds spent reading.
  IntColumn get seconds => integer().withDefault(const Constant(0))();

  @override
  Set<Column<Object>> get primaryKey => {uid, day, fid};
}
