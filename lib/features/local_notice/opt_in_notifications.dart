import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tsdm_client/features/local_notice/callback.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/platform.dart';

/// The platform as far as the system notifications of the auto sync are concerned.
///
/// Taken from `dart:io` ([noticePlatformOfHost]), which `debugDefaultTargetPlatformOverride` does not change: tests
/// give the platform to a [SystemNotificationGate] of their own instead.
enum NoticePlatform {
  /// Posts notifications, always.
  android,

  /// Posts notifications, always.
  windows,

  /// Posts notifications once the user turned them on (`SettingsKeys.systemNotificationsOptIn`).
  iOS,

  /// Posts notifications once the user turned them on (`SettingsKeys.systemNotificationsOptIn`).
  macOS,

  /// Posts notifications once the user turned them on (`SettingsKeys.systemNotificationsOptIn`).
  linux,

  /// Never posts notifications.
  other
  ;

  /// Android and Windows: the platforms that always posted the notifications of the auto sync. Everything tied to the
  /// notifications that is built once (the in-app sync of the other accounts, the bridge of the background results,
  /// the setting to announce every account) stays on these only.
  bool get alwaysPosts => this == android || this == windows;

  /// iOS, macOS and Linux: notifications posted only after the user turned them on in the settings.
  bool get optIn => this == iOS || this == macOS || this == linux;

  /// iOS and macOS: the system asks the user for the permission.
  bool get darwin => this == iOS || this == macOS;
}

/// The [NoticePlatform] of the device the app runs on.
NoticePlatform get noticePlatformOfHost {
  if (isAndroid) return NoticePlatform.android;
  if (isWindows) return NoticePlatform.windows;
  if (isIOS) return NoticePlatform.iOS;
  if (isMacOS) return NoticePlatform.macOS;
  if (isLinux) return NoticePlatform.linux;
  return NoticePlatform.other;
}

/// What turning the notifications on came to.
enum OptInNoticeResult {
  /// Initialized and allowed: notifications are posted from now on.
  granted,

  /// The user (or the system settings) did not allow notifications (iOS, macOS).
  denied,

  /// The plugin could not be initialized, or no notification service answered (Linux without a notification daemon).
  unavailable,
}

/// The calls the opt-in platforms need from the notification plugin, apart so that tests can fake them.
abstract interface class OptInNoticePlugin {
  /// Initialize the plugin without asking anything: no permission dialog. True when it can be used.
  Future<bool> initialize();

  /// Ask the permission (iOS, macOS: the system dialog, shown once by the system; Linux: whether a notification
  /// service answers). True when notifications can be shown.
  Future<bool> requestPermission();

  /// Whether notifications can be shown now, never asking the user: the permission granted before is still granted
  /// (iOS, macOS), a notification service answers (Linux).
  Future<bool> permitted();
}

/// How long the Linux notification service is given to answer: on a desktop without one the D-Bus call may hang.
const _linuxProbeTimeout = Duration(seconds: 3);

/// [OptInNoticePlugin] of the app's plugin [flnp] on [platform].
final class FlnpOptInNoticePlugin implements OptInNoticePlugin {
  /// Constructor.
  FlnpOptInNoticePlugin({required this.platform, FlutterLocalNotificationsPlugin? plugin}) : _plugin = plugin ?? flnp;

  /// The platform, one of [NoticePlatform.optIn].
  final NoticePlatform platform;

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<bool> initialize() async {
    // Nothing is asked here: the permission is asked by [requestPermission], when the user turns the switch on.
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      defaultPresentBadge: false,
    );
    final initialized = await _plugin.initialize(
      settings: InitializationSettings(
        iOS: darwin,
        macOS: darwin,
        linux: LinuxInitializationSettings(
          // The action a click on the notification triggers, so the click reaches the app.
          defaultActionName:
              LocaleSettings.currentLocale.translations.settingsPage.behaviorSection.systemNotifications.open,
        ),
      ),
      onDidReceiveNotificationResponse: onLocalNotificationOpened,
    );
    return initialized ?? false;
  }

  @override
  Future<bool> requestPermission() async => switch (platform) {
    NoticePlatform.iOS =>
      await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
            alert: true,
            sound: true,
          ) ??
          false,
    NoticePlatform.macOS =>
      await _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()?.requestPermissions(
            alert: true,
            sound: true,
          ) ??
          false,
    NoticePlatform.linux => _linuxServiceAnswers(),
    _ => false,
  };

  @override
  Future<bool> permitted() async => switch (platform) {
    NoticePlatform.iOS =>
      (await _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.checkPermissions())
              ?.isEnabled ??
          false,
    NoticePlatform.macOS =>
      (await _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()?.checkPermissions())
              ?.isEnabled ??
          false,
    NoticePlatform.linux => _linuxServiceAnswers(),
    _ => false,
  };

  Future<bool> _linuxServiceAnswers() async {
    final linux = _plugin.resolvePlatformSpecificImplementation<LinuxFlutterLocalNotificationsPlugin>();
    if (linux == null) {
      return false;
    }
    await linux.getCapabilities().timeout(_linuxProbeTimeout);
    return true;
  }
}

/// Whether the system notifications of the auto sync are posted on this device.
///
/// Android and Windows: always, as before. iOS, macOS and Linux: only once the user turned them on
/// (`SettingsKeys.systemNotificationsOptIn`, off by default) and the plugin was initialized and allowed during this
/// run ([ready]). Until then the plugin is not initialized at all on these platforms: no permission is asked, nothing
/// is posted, exactly as before they could post anything.
final class SystemNotificationGate {
  /// Constructor.
  ///
  /// [enabled] reads the setting; by default the one of the settings repository.
  SystemNotificationGate({required this.platform, bool Function()? enabled}) : _enabled = enabled ?? _settingOn;

  /// The platform.
  final NoticePlatform platform;

  final bool Function() _enabled;

  static bool _settingOn() =>
      getIt.isRegistered<SettingsRepository>() &&
      getIt.get<SettingsRepository>().currentSettings.systemNotificationsOptIn;

  /// Whether the plugin was initialized and the notifications allowed during this run, opt-in platforms only.
  bool get ready => _ready;
  bool _ready = false;

  /// Whether notifications are posted now: always on [NoticePlatform.alwaysPosts], on the opt-in platforms when
  /// turned on and [ready].
  bool get posts => platform.alwaysPosts || (platform.optIn && _ready && _enabled());

  /// Whether the switch of the settings shows on: turned on and [ready], so a setting left on (by a backup restored,
  /// or a permission taken back in the system settings) never shows on while nothing could be posted.
  bool switchOn({required bool enabled}) => platform.optIn && _ready && enabled;

  /// At boot, with the setting [enabled]: initialize the plugin without asking anything and check that the
  /// notifications are still allowed. When they are not (taken back in the system settings, no notification service
  /// any more) the setting is turned off with [turnOff], so it does not stay on while nothing can be posted.
  ///
  /// Does nothing at all off the opt-in platforms or with the setting off: the plugin is not initialized. Failures are
  /// logged and swallowed, the boot must not stop on an optional feature.
  Future<void> boot({
    required bool enabled,
    required OptInNoticePlugin plugin,
    Future<void> Function()? turnOff,
  }) async {
    if (!platform.optIn || !enabled) {
      return;
    }
    var ok = false;
    try {
      ok = await plugin.initialize() && await plugin.permitted();
    } on Object catch (e, st) {
      talker.handle(e, st, 'opt-in notifications boot failed');
    }
    _ready = ok;
    talker.info('opt-in notifications at boot: ${platform.name} ready=$ok');
    if (!ok) {
      try {
        await turnOff?.call();
      } on Object catch (e, st) {
        talker.handle(e, st, 'turning opt-in notifications off failed');
      }
    }
  }

  /// The user turned the switch on: initialize the plugin and ask the permission now, the first time it is asked.
  ///
  /// [OptInNoticeResult.granted] makes [ready] true; the caller saves the setting after it. Anything else leaves the
  /// notifications off. Off the opt-in platforms: [OptInNoticeResult.unavailable], nothing asked.
  Future<OptInNoticeResult> enable(OptInNoticePlugin plugin) async {
    if (!platform.optIn) {
      return OptInNoticeResult.unavailable;
    }
    try {
      if (!await plugin.initialize()) {
        _ready = false;
        return OptInNoticeResult.unavailable;
      }
    } on Object catch (e, st) {
      talker.handle(e, st, 'opt-in notifications init failed');
      _ready = false;
      return OptInNoticeResult.unavailable;
    }
    bool allowed;
    try {
      allowed = await plugin.requestPermission();
    } on Object catch (e, st) {
      talker.handle(e, st, 'opt-in notifications permission failed');
      _ready = false;
      // Linux: no notification service answered. iOS, macOS: the request itself failed.
      return platform.darwin ? OptInNoticeResult.denied : OptInNoticeResult.unavailable;
    }
    _ready = allowed;
    talker.info('opt-in notifications turned on: ${platform.name} allowed=$allowed');
    if (allowed) {
      return OptInNoticeResult.granted;
    }
    return platform.darwin ? OptInNoticeResult.denied : OptInNoticeResult.unavailable;
  }
}

/// The gate of the app, for the platform it runs on.
///
/// Replaced by tests only.
SystemNotificationGate systemNotificationGate = SystemNotificationGate(platform: noticePlatformOfHost);

/// Turn the system notifications of an opt-in platform on with [gate] and [plugin], saving the setting with [save]
/// only when they are allowed: the switch flips back by itself otherwise, as it shows the setting.
Future<OptInNoticeResult> turnOnSystemNotifications({
  required SystemNotificationGate gate,
  required OptInNoticePlugin plugin,
  required Future<void> Function({required bool on}) save,
}) async {
  final result = await gate.enable(plugin);
  await save(on: result == OptInNoticeResult.granted);
  return result;
}

/// [turnOnSystemNotifications] with the gate, plugin and settings of the app.
Future<OptInNoticeResult> turnOnAppSystemNotifications() => turnOnSystemNotifications(
  gate: systemNotificationGate,
  plugin: FlnpOptInNoticePlugin(platform: systemNotificationGate.platform),
  save: ({required on}) => getIt.get<SettingsRepository>().setValue(SettingsKeys.systemNotificationsOptIn, on),
);

/// [SystemNotificationGate.boot] of the app, called once at boot after the settings are loaded.
Future<void> bootAppSystemNotifications() => systemNotificationGate.boot(
  enabled:
      getIt.isRegistered<SettingsRepository>() &&
      getIt.get<SettingsRepository>().currentSettings.systemNotificationsOptIn,
  plugin: FlnpOptInNoticePlugin(platform: systemNotificationGate.platform),
  turnOff: () => getIt.get<SettingsRepository>().setValue(SettingsKeys.systemNotificationsOptIn, false),
);
