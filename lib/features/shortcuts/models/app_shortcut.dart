import 'package:collection/collection.dart';

/// A shortcut of a long press on the app icon (Android, `android/app/src/main/res/xml/shortcuts.xml`).
///
/// The id is the last segment of the `tsdm://shortcut/<id>` data of the shortcut's intent, handed over by the native
/// `ShortcutsHandler`.
enum AppShortcut {
  /// Check in for today.
  checkin('checkin'),

  /// The notifications and messages.
  notice('notice'),

  /// The favorites of the account in use.
  favorite('favorite'),

  /// Search the forum.
  search('search')
  ;

  const AppShortcut(this.id);

  /// The shortcut id, as in `shortcuts.xml`.
  final String id;

  /// The shortcut with [id], null for an id the app does not know.
  static AppShortcut? fromId(String? id) => values.firstWhereOrNull((e) => e.id == id);
}
