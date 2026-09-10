import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:responsive_framework/responsive_framework.dart';
import 'package:system_theme/system_theme.dart';
import 'package:tsdm_client/app.dart';
import 'package:tsdm_client/cmd.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/color.dart';
import 'package:tsdm_client/features/local_notice/callback.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/proxy_provider/proxy_provider.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/window_configs.dart';
import 'package:tsdm_client/utils/window_events.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main(List<String> args) async => runZonedGuarded(() async => _boot(args), _ensureHandled);

Future<void> _boot(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  await initLogger();

  // Widget errors never reach the zone handler: the framework catches them itself and, in a release build, shows a
  // plain grey box in place of the failing subtree with nothing in the exported log. Record them so a report of
  // "a grey block flashed" carries the widget and the stack (GitHub #55).
  final presentError = FlutterError.onError;
  FlutterError.onError = (details) {
    // `context` is the "building <widget>" part, the one thing that says where the grey box was.
    final where = details.context?.toDescription();
    talker.handle(
      details.exception,
      details.stack,
      'FlutterError in ${details.library ?? 'widgets'}${where == null ? '' : ': $where'}',
    );
    presentError?.call(details);
  };

  parseCmdArgs(args);

  talker.debug('------------------- start app -------------------');
  listenAndroidWindowEvents();
  await initProviders();

  final settings = getIt.get<SettingsRepository>().currentSettings;

  final settingsLocale = settings.locale;
  final locale = AppLocale.values.firstWhereOrNull((v) => v.languageTag == settingsLocale);
  if (locale == null) {
    await LocaleSettings.useDeviceLocale();
  } else {
    await LocaleSettings.setLocale(locale);
  }

  if (isDesktop) {
    await windowManager.ensureInitialized();
    if (!cmdArgs.noWindowConfigs) {
      await desktopUpdateWindowTitle();
      await desktopRestoreWindowBounds(settings);
    }
  }

  // System color.
  // Use this color when following system color settings turned on.
  //
  // A not empty value represents currently is using system color and the color
  // value is inside it.
  final useSystemTheme = settings.accentColorFollowSystem;

  final color = switch (useSystemTheme) {
    true => await SystemTheme.accentColor.load().then((_) => SystemTheme.accentColor.accent.valueA),
    false => settings.accentColor,
  };
  final themeModeIndex = settings.themeMode;

  final autoCheckin = settings.autoCheckin;
  final autoSyncNoticeSeconds = settings.autoSyncNoticeSeconds;

  // Initialize flutter_local_notification.
  flnp = FlutterLocalNotificationsPlugin();
  if (isAndroid) {
    await flnp.initialize(
      // Drawable ic_launcher_foreground_no_transform is shrunk when building in CI.
      // The default one is compat but ok.
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_launcher_foreground'),
      ),
      onDidReceiveNotificationResponse: onLocalNotificationOpened,
    );
    // The first channel had default importance and Android never lets the app raise it: drop it so the
    // high-importance replacement is the only one left in the system notification settings (#13).
    await deleteLegacyLocalNoticeChannel();
    // A tap on the notification while the app was not running: park the payload for the home page (#14).
    await rememberNotificationLaunch();
    if (autoSyncNoticeSeconds > 0) {
      // Android 13+ runtime permission; `null` means the platform plugin was not resolved.
      final granted = await flnp
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      talker.info('boot notification permission granted=$granted');
    }
  }

  // Load font family.
  final fontFamily = settings.fontFamily;

  // Check update when app startup.
  final checkUpdate = settings.enableUpdateCheckOnStartup;

  // Only record system proxy settings if required to do so.
  if (settings.useDetectedProxyWhenStartup) {
    await getIt.get<ProxyProvider>().updateProxy();
  }

  runApp(
    TranslationProvider(
      child: ResponsiveBreakpoints.builder(
        breakpoints: WindowSize.values.map((e) => Breakpoint(start: e.start, end: e.end, name: e.name)).toList(),
        child: App(
          color,
          themeModeIndex,
          autoCheckin: autoCheckin,
          autoSyncNoticeSeconds: autoSyncNoticeSeconds,
          fontFamily: fontFamily,
          checkUpdate: checkUpdate,
        ),
      ),
    ),
  );
}

void _ensureHandled(Object exception, StackTrace? stackTrace) => talker.handle(exception, stackTrace);
