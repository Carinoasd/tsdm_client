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

  /// Name of the user who triggered the notice: the `author` of the forum's app API, or the name of the author's link
  /// in the body on the notice page.
  ///
  /// Null when unknown, for system notices, or the notice was saved before v16.
  ///
  /// Added in v16.
  TextColumn get author => text().nullable()();

  /// The `from_id` of the forum's app API (a thread id for most post notices, the post id of a quote).
  ///
  /// Null when the notice was read from the notice page, which does not print it, or saved before v16.
  ///
  /// Added in v16.
  IntColumn get fromId => integer().nullable()();

  /// The `from_idtype` of the forum's app API (`post`, `quote`, `at`, `moderate_*`, `friendrequest`...).
  ///
  /// Null when the notice was read from the notice page, which does not print it, or saved before v16.
  ///
  /// Added in v16.
  TextColumn get fromIdType => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {uid, nid};
}
