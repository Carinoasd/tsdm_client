part of 'schema.dart';

/// Table for local notice.
///
/// Generated when interacting with other users: reply, mention, rate, ...
@DataClassName('NoticeEntity')
class Notice extends Table {
  /// Uid of the user who owns the notice.
  IntColumn get uid => integer()();

  /// Notice id.
  ///
  /// A field in server response, not the id of table.
  IntColumn get nid => integer()();

  /// Notice timestamp in seconds.
  IntColumn get timestamp => integer()();

  /// Notice body in html format.
  TextColumn get data => text()();

  /// User already read this notice or not.
  // ignore: unnecessary_nullable_return_type
  BoolColumn? get alreadyRead => boolean().nullable().withDefault(const Constant(true))();

  /// Notice type from the notice's own ignore link (`type=post`, `type=friend`, ...).
  ///
  /// Null when the link is absent or the notice was saved before v14: never guessed from the body.
  ///
  /// Added in v14.
  TextColumn get ignoreType => text().nullable()();

  /// Uid of the user who triggered the notice, from the notice's own ignore link (`authorid=`).
  ///
  /// Null when the link is absent or the notice was saved before v14: never guessed from links in the body.
  ///
  /// Added in v14.
  IntColumn get authorId => integer().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {uid, nid};
}
