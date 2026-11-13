part of 'schema.dart';

/// Table of the user's own image stickers ("表情包", GitHub #5): image urls saved on this device to insert into
/// posts with one tap. The device's, shared by every account; the addresses and names go with the cross-device sync
/// of each account synced on it (`custom_image_sync.dart`).
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

  /// When the image was saved, or last renamed (the cross-device sync takes the later of two names by it).
  DateTimeColumn get addedAt => dateTime()();
}
