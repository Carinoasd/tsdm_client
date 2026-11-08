import 'dart:async';

import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/method_channel.dart';

/// The icons the app can show on the launcher (Android and iOS).
///
/// The names are what [SettingsKeys.appIcon] stores and what the platform side knows.
enum AppIcon {
  /// The icon of the app.
  defaultIcon('default'),

  /// Light wing on a dark background.
  dark('dark'),

  /// Grey wing.
  mono('mono'),

  /// Pink wing.
  pink('pink')
  ;

  const AppIcon(this.storedName);

  /// Name in the settings and on the platform side.
  final String storedName;

  /// Preview image of the icon, in the settings.
  String get previewAsset => 'assets/images/app_icons/$storedName.png';

  /// The icon stored as [name]; the default icon for a name this version does not know (a backup of a newer version).
  static AppIcon fromStoredName(String name) =>
      AppIcon.values.firstWhere((e) => e.storedName == name, orElse: () => AppIcon.defaultIcon);
}

/// Signature of the call that switches the icon on the platform.
typedef AppIconSetter = Future<bool> Function(String name);

/// Keeps the launcher icon in line with the [SettingsKeys.appIcon] setting.
///
/// This follows the settings stream, so a value restored from a backup applies at startup too; the platform keeps the
/// icon it already shows without doing anything.
final class AppIconFollower with LoggerMixin {
  /// Constructor.
  AppIconFollower(Stream<SettingsMap> settings, {AppIconSetter setter = setPlatformAppIcon}) : _setter = setter {
    // One switch at a time, in the order of the changes: the iOS call finishes later than it starts.
    _sub = settings.map((e) => AppIcon.fromStoredName(e.appIcon)).distinct().asyncMap(_apply).listen(null);
  }

  final AppIconSetter _setter;
  late final StreamSubscription<void> _sub;

  Future<void> _apply(AppIcon icon) async {
    try {
      final done = await _setter(icon.storedName);
      debug('app icon ${icon.storedName}, applied: $done');
      // ignore: avoid_catches_without_on_clauses, a TypeError of a platform answer must not escape the settings stream.
    } catch (e, st) {
      // A device that cannot switch icons keeps the one it shows.
      warning('failed to set app icon ${icon.storedName}', e, st);
    }
  }

  /// Stop following the settings.
  Future<void> dispose() => _sub.cancel();
}
