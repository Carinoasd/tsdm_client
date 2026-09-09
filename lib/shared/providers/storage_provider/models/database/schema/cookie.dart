part of 'schema.dart';

/// Table for user cookies.
@DataClassName('CookieEntity')
class Cookie extends Table {
  /// User's name.
  TextColumn get username => text()();

  /// User id.
  IntColumn get uid => integer()();

  /// Cookie value.
  TextColumn get cookie => text()();

  /// Last checkin time.
  DateTimeColumn get lastCheckin => dateTime().nullable()();

  /// Timestamp of last notice fetch from server.
  ///
  /// This timestamp is in stored in milliseconds level while most of other
  /// timestamps are in seconds level. Because only this field is always used
  /// by client, not server.
  DateTimeColumn get lastFetchNotice => dateTime().nullable()();

  /// User Password.
  TextColumn get password => text().nullable()();

  /// Security Question id.
  IntColumn get questionId => integer().nullable()();

  /// Answer text of question id.
  TextColumn get answer => text().nullable()();

  /// When the app last learned that the forum session of this account is dead (issue #25).
  ///
  /// Set by whatever got the guest page with this account's cookie (auto check-in, the notification sync, the
  /// homepage), cleared when a login or an account switch verifies the session again. Null while nothing is known.
  DateTimeColumn get sessionExpiredAt => dateTime().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {uid};
}
