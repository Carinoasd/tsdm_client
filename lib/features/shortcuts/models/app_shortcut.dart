import 'package:collection/collection.dart';

/// A shortcut of a long press on the app icon (Android: `android/app/src/main/res/xml/shortcuts.xml`; iOS: the
/// `UIApplicationShortcutItems` of `ios/Runner/Info.plist`), or a tap on the home screen widget.
///
/// The id is the last segment of the `tsdm://shortcut/<id>` data of the shortcut's intent, handed over by the native
/// `ShortcutsHandler` (Android). On iOS the widget opens the same link and a quick action's type is that link, which
/// `HomeWidgetBridge` hands over whole ([fromLink]).
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

  /// The scheme of the shortcut links.
  static const linkScheme = 'tsdm';

  /// The host of the shortcut links.
  static const linkHost = 'shortcut';

  /// The shortcut with [id], null for an id the app does not know.
  static AppShortcut? fromId(String? id) => values.firstWhereOrNull((e) => e.id == id);

  /// The shortcut of [link], `tsdm://shortcut/<id>`; null for another link or an id the app does not know.
  static AppShortcut? fromLink(String? link) {
    final uri = link == null ? null : Uri.tryParse(link);
    if (uri == null || uri.scheme.toLowerCase() != linkScheme || uri.host.toLowerCase() != linkHost) {
      return null;
    }
    final segments = uri.pathSegments.where((e) => e.isNotEmpty).toList();
    return segments.length == 1 ? fromId(segments.single) : null;
  }

  /// The shortcut a native side handed over: an id (Android) or a link (iOS).
  static AppShortcut? fromIdOrLink(String? value) => fromId(value) ?? fromLink(value);

  /// The link opening this shortcut.
  String get link => '$linkScheme://$linkHost/$id';
}
