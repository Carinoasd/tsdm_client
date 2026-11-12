import 'dart:io' as io;

/// The platform as far as the tray icon and the close button are concerned.
///
/// Taken from `dart:io` ([host]), which `debugDefaultTargetPlatformOverride` does not change: tests give the platform
/// to the functions below and to `TrayHelper.forTesting` instead.
enum TrayPlatform {
  /// Tray icon always shown (as since PR #61); closing the window may hide it with `SettingsKeys.closeToTray`.
  windows,

  /// Menu bar icon with `SettingsKeys.desktopTrayIcon`; closing the window may hide it with `SettingsKeys.closeToTray`.
  macOS,

  /// Tray icon with `SettingsKeys.desktopTrayIcon`, when the desktop has a tray. Closing the window always quits.
  linux,

  /// No tray.
  other
  ;

  /// The platform the app runs on.
  static final TrayPlatform host = io.Platform.isWindows
      ? windows
      : io.Platform.isMacOS
      ? macOS
      : io.Platform.isLinux
      ? linux
      : other;

  /// macOS and Linux: the tray icon has a switch in the settings, off by default.
  bool get hasTrayIconSwitch => this == macOS || this == linux;

  /// Windows and macOS: closing the window can hide it into the tray, off by default.
  bool get hasCloseToTraySwitch => this == windows || this == macOS;

  /// The native side of `tray_manager` takes a tooltip: Linux (appindicator) has none and throws.
  bool get supportsToolTip => this == windows || this == macOS;

  /// The menu is popped up by the app on a right click: on Linux the desktop opens it on any click by itself.
  bool get popsUpMenu => this == windows || this == macOS;

  /// Linux asks the desktop for a tray host first: `app_indicator_new` never fails, without a host the icon is just
  /// nowhere (GNOME without the AppIndicator extension).
  bool get probesTrayHost => this == linux;
}

/// Whether the tray icon is wanted on [platform] with the tray icon switch at [trayIconSetting].
///
/// Windows always had it, whatever the switch (which it does not show) holds.
bool trayWanted(TrayPlatform platform, {required bool trayIconSetting}) => switch (platform) {
  TrayPlatform.windows => true,
  TrayPlatform.macOS || TrayPlatform.linux => trayIconSetting,
  TrayPlatform.other => false,
};

/// Whether the close button of the window is taken over by the app (`windowManager.setPreventClose(true)`).
///
/// Only with the close-to-tray switch on [closeToTraySetting] and a tray icon actually up ([trayRunning]): hiding a
/// window with no icon to bring it back would leave a process nobody can reach. Otherwise the native side closes the
/// window as it always did.
bool interceptsClose(TrayPlatform platform, {required bool closeToTraySetting, required bool trayRunning}) =>
    platform.hasCloseToTraySwitch && closeToTraySetting && trayRunning;

/// What a click on the close button of the window does in the app.
enum WindowCloseAction {
  /// Nothing: the native side closes the window itself (not intercepted), as it always did.
  native,

  /// Hide the window, the app stays in the tray.
  hide,

  /// Quit through the shared shutdown flow: intercepted, but hiding is not possible (any more).
  quit,
}

/// What to do on a click on the close button.
///
/// [intercepting] is what was last applied to the native side, the decision itself is taken again with the state of
/// now: the switch may have been turned off or the tray removed since, while the native side still holds the close.
WindowCloseAction closeActionOf(
  TrayPlatform platform, {
  required bool intercepting,
  required bool closeToTraySetting,
  required bool trayRunning,
}) {
  if (!intercepting) {
    return WindowCloseAction.native;
  }
  return interceptsClose(platform, closeToTraySetting: closeToTraySetting, trayRunning: trayRunning)
      ? WindowCloseAction.hide
      : WindowCloseAction.quit;
}

/// Entries of the tray menu.
enum TrayMenuEntry {
  /// The current user, disabled.
  userInfo,

  /// Bring the window back.
  showWindow,

  /// Thread visit history.
  history,

  /// Favorites.
  favorite,

  /// Account management.
  manageAccount,

  /// Quit the app.
  exit,

  /// A separator.
  separator,
}

/// The tray menu on [platform].
///
/// Windows keeps the menu it always had while the window cannot be hidden ([closeToTraySetting] off): a click on the
/// icon brings the window back. macOS and Linux always list "show window": the menu may be the only way there (Linux
/// gives no click on the icon to the app).
List<TrayMenuEntry> trayMenuEntries(TrayPlatform platform, {required bool closeToTraySetting}) => [
  TrayMenuEntry.userInfo,
  TrayMenuEntry.separator,
  if (platform != TrayPlatform.windows || closeToTraySetting) TrayMenuEntry.showWindow,
  TrayMenuEntry.history,
  TrayMenuEntry.favorite,
  TrayMenuEntry.manageAccount,
  TrayMenuEntry.separator,
  TrayMenuEntry.exit,
];

/// The asset of the tray icon on macOS and Linux: `tray_manager` reads it from the bundle (macOS) or from
/// `data/flutter_assets` next to the executable (Linux). Windows takes an absolute `.ico` path instead.
const trayIconAsset = 'assets/images/tsdm_client.png';

/// Outcome of putting the tray icon up.
enum TrayStartResult {
  /// The icon is up.
  started,

  /// The desktop has no tray (Linux).
  unavailable,

  /// The native side failed.
  failed,
}

/// Whether the tray icon switch goes back off after [result]: the switch then says what the user gets, the app
/// stays as it was before the switch was turned on. Windows has no switch.
bool turnsTraySwitchOff(TrayPlatform platform, TrayStartResult result) =>
    platform.hasTrayIconSwitch && result != TrayStartResult.started;
