import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tsdm_client/features/background_sync/background_sync_entry.dart';
import 'package:tsdm_client/features/background_sync/background_sync_events.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// Android background message service (#80).
///
/// A foreground service (the persistent "receiving messages" notification) whose isolate runs
/// `backgroundSyncTick` at the auto sync interval, so new notices and private messages are announced while the app is
/// in the background or was cleared. The isolate has no activity, so it opens the shared database itself, builds the
/// same repositories the app uses and talks to the app only through the `synced` event.
///
/// Channel of the persistent notification. Separate from the one that carries new messages: low importance, no sound.
const backgroundSyncChannelId = 'tsdm_foreground';

/// Id of the persistent notification.
const backgroundSyncNotificationId = 888;

/// Register the service with the plugin. Android only, call once at boot and again when [autoStartOnBoot] changes.
///
/// [autoStartOnBoot] makes the plugin's boot receiver start the service after a reboot; it follows the switch so a
/// disabled service does not start just to stop itself.
Future<void> initializeBackgroundSyncService({required bool autoStartOnBoot}) async {
  final tr = t.backgroundService;
  await FlutterLocalNotificationsPlugin()
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(
        AndroidNotificationChannel(
          backgroundSyncChannelId,
          tr.channelName,
          description: tr.channelDesc,
          importance: Importance.low,
        ),
      );
  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundSyncEntryPoint,
      autoStart: false,
      autoStartOnBoot: autoStartOnBoot,
      isForegroundMode: true,
      notificationChannelId: backgroundSyncChannelId,
      initialNotificationTitle: tr.title,
      initialNotificationContent: tr.content,
      foregroundServiceNotificationId: backgroundSyncNotificationId,
      // Android 15 stops a dataSync foreground service after six hours a day; specialUse has no such budget.
      foregroundServiceTypes: [AndroidForegroundType.specialUse],
    ),
    iosConfiguration: IosConfiguration(autoStart: false),
  );
}

/// Start the service and wait until the plugin reports it running. False when it did not come up in time.
Future<bool> startBackgroundSyncService() async {
  final service = FlutterBackgroundService();
  if (await service.isRunning()) {
    return true;
  }
  await service.startService();
  for (var i = 0; i < 15; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (await service.isRunning()) {
      return true;
    }
  }
  return false;
}

/// Ask the service to stop and wait until the plugin reports it gone. False when it was still up after the wait.
Future<bool> stopBackgroundSyncService() async {
  final service = FlutterBackgroundService();
  if (!await service.isRunning()) {
    return true;
  }
  service.invoke(BackgroundSyncEvents.stop);
  for (var i = 0; i < 25; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!await service.isRunning()) {
      return true;
    }
  }
  return false;
}

/// Whether the plugin reports the service running.
Future<bool> isBackgroundSyncServiceRunning() => FlutterBackgroundService().isRunning();

/// Tell a running service that the settings it reads have changed.
void notifyBackgroundSyncSettingsChanged() => FlutterBackgroundService().invoke(BackgroundSyncEvents.settingsChanged);
