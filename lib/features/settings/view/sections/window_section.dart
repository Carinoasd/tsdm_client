part of '../settings_page.dart';

/// Desktop: the window, the tray and the boss key.
class _WindowSection extends StatefulWidget {
  const _WindowSection();

  @override
  State<_WindowSection> createState() => _WindowSectionState();
}

class _WindowSectionState extends State<_WindowSection> {
  /// The platform for the tray switches of this group.
  static final TrayPlatform _trayPlatform = TrayPlatform.host;

  /// Set while the tray icon is being put up or removed.
  bool _switchingTray = false;

  /// macOS, Linux: put the tray icon up or remove it. Not possible: the switch stays off and a short message says why.
  Future<void> _toggleTrayIcon(BuildContext context, {required bool enable}) async {
    final settings = getIt.get<SettingsRepository>();
    final tr = context.t.settingsPage.windowSection;
    setState(() => _switchingTray = true);
    TrayStartResult? result;
    try {
      if (enable) {
        result = await TrayHelper.instance.start();
        await settings.setValue(SettingsKeys.desktopTrayIcon, !turnsTraySwitchOff(_trayPlatform, result));
      } else {
        await settings.setValue(SettingsKeys.desktopTrayIcon, false);
        // What the switches show is what there is: closing into the menu bar goes off with its icon.
        await settings.setValue(SettingsKeys.closeToTray, false);
        await TrayHelper.instance.dispose();
      }
    } finally {
      if (mounted) setState(() => _switchingTray = false);
    }
    if (!context.mounted) return;
    switch (result) {
      case TrayStartResult.unavailable:
        showSnackBar(context: context, message: tr.trayUnavailable);
      case TrayStartResult.failed:
        showSnackBar(context: context, message: tr.trayFailed);
      case TrayStartResult.started || null:
        break;
    }
  }

  /// Windows, macOS: close the window into the tray. Turned on only while the icon is up: on Windows its start may
  /// have failed at launch, the window would then be hidden with no way back.
  Future<void> _toggleCloseToTray(BuildContext context, {required bool enable}) async {
    if (enable && !TrayHelper.instance.running.value) {
      showSnackBar(context: context, message: context.t.settingsPage.windowSection.trayFailed);
      return;
    }
    await getIt.get<SettingsRepository>().setValue(SettingsKeys.closeToTray, enable);
  }

  @override
  Widget build(BuildContext context) => SettingsSelect(
    select: (m) => (
      bossKey: m.bossKey,
      bossKeyCombo: m.bossKeyCombo,
      closeToTray: m.closeToTray,
      desktopTrayIcon: m.desktopTrayIcon,
      windowInCenter: m.windowInCenter,
      windowRememberPosition: m.windowRememberPosition,
      windowRememberSize: m.windowRememberSize,
    ),
    builder: (context, s) {
      final tr = context.t.settingsPage.windowSection;
      final windowRememberSize = s.windowRememberSize;
      final windowRememberPosition = s.windowRememberPosition;
      final windowInCenter = s.windowInCenter;
      final desktopTrayIcon = s.desktopTrayIcon;
      final closeToTray = s.closeToTray;

      return AppTileGroup(
        title: tr.title,
        icon: Icons.desktop_windows_outlined,
        footer: AppNoticeBanner(message: tr.disableHint, selectable: true),
        children: [
          SectionListTile(
            leading: const Icon(Icons.keyboard_alt_outlined),
            title: Text(tr.keyboardShortcuts),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.pushNamed(ScreenPaths.keyboardShortcuts),
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.settings_overscan_outlined),
            title: Text(tr.windowRememberSize.title),
            subtitle: Text(tr.windowRememberSize.detail),
            value: windowRememberSize,
            onChanged: (v) =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.windowRememberSize, v)),
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.open_with_outlined),
            title: Text(tr.windowRememberPosition.title),
            subtitle: Text(tr.windowRememberPosition.detail),
            value: windowRememberPosition,
            onChanged: (v) =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.windowRememberPosition, v)),
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.filter_center_focus_outlined),
            title: Text(tr.windowInCenter.title),
            subtitle: Text(tr.windowInCenter.detail),
            value: windowInCenter,
            onChanged: (v) => context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.windowInCenter, v)),
          ),
          if (_trayPlatform.hasTrayIconSwitch)
            SectionSwitchListTile(
              secondary: const Icon(Icons.push_pin_outlined),
              title: Text(_trayPlatform == TrayPlatform.macOS ? tr.menuBarIcon : tr.trayIcon),
              value: desktopTrayIcon,
              onChanged: _switchingTray ? null : (v) => _toggleTrayIcon(context, enable: v),
            ),
          if (_trayPlatform.hasCloseToTraySwitch)
            // Shown on only while it applies: the tray may have failed to start (Windows) or be off (macOS).
            ValueListenableBuilder<bool>(
              valueListenable: TrayHelper.instance.running,
              builder: (context, trayRunning, _) => SectionSwitchListTile(
                secondary: const Icon(Icons.close_fullscreen_outlined),
                title: Text(_trayPlatform == TrayPlatform.macOS ? tr.closeToMenuBar : tr.closeToTray),
                value: closeToTray && trayRunning,
                // macOS: only with the menu bar icon, the window would have no way back.
                onChanged: _switchingTray || (_trayPlatform.hasTrayIconSwitch && !desktopTrayIcon)
                    ? null
                    : (v) => _toggleCloseToTray(context, enable: v),
              ),
            ),
          BossKeySwitchTile(enabled: s.bossKey),
          BossKeyShortcutTile(combo: s.bossKeyCombo),
        ],
      );
    },
  );
}
