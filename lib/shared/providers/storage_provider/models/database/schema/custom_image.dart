part of 'schema.dart';

/// Table of the user's own image stickers ("表情包", GitHub #5): image urls saved on this device to insert into
/// posts with one tap. Device-local and shared by every account.
@DataClassName('CustomImageEntity')
class CustomImage extends Table {
  /// Row id.
  IntColumn get id => integer().autoIncrement()();

  /// Optional display name.
  TextColumn get name => text().withDefault(const Constant(''))();

  /// Image url (http/https).
  TextColumn get url => text().unique()();

  /// Manual order, lower first; equal values fall back to [addedAt].
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  /// When the image was saved.
  DateTimeColumn get addedAt => dateTime()();
}
