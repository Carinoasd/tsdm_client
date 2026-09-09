import 'package:flutter/widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:window_manager/window_manager.dart';

/// Update window title according to current using locale.
///
/// Only available on desktop platforms.
Future<void> desktopUpdateWindowTitle() async {
  if (isDesktop && !cmdArgs.noWindowConfigs) {
    await windowManager.setTitle(LocaleSettings.currentLocale.translations.appName);
    talker.debug('set window title with current locale');
  }
}

/// Restore normal bounds before maximizing, so restoring down keeps those bounds.
Future<void> desktopRestoreWindowBounds(SettingsMap settings) async {
  if (settings.windowRememberSize && settings.windowSize != Size.zero) {
    await windowManager.setSize(settings.windowSize);
  }
  if (settings.windowInCenter) {
    await windowManager.center();
  } else if (settings.windowRememberPosition) {
    await windowManager.setPosition(settings.windowPosition);
  }
  if (settings.windowRememberSize && settings.windowMaximized) {
    await windowManager.maximize();
  }
}
