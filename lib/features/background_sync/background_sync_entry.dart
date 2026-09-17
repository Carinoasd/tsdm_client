import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/background_sync/background_sync_events.dart';
import 'package:tsdm_client/features/background_sync/background_sync_tick.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/proxy_provider/proxy_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/connection/connection.dart' as conn;
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/log_redaction.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/redacting_talker.dart';

/// The isolate side of the Android background message service (#80): [backgroundSyncEntryPoint] and what it needs.
///
/// Kept apart from `background_sync_service.dart` (the app-facing start/stop API) because a library with a
/// `vm:entry-point` counts as executable for the analyzer, which then reports every member not reached from the
/// entry point.
/// Everything the service isolate needs, built once when it starts.
final class _BackgroundSyncRuntime {
  _BackgroundSyncRuntime._(this.db, this.storage, this.settings, this.proxy, this.repository, this.plugin);

  final AppDatabase db;
  final StorageProvider storage;
  final SettingsRepository settings;
  final ProxyProvider proxy;
  final NotificationSyncAllRepository repository;
  final FlutterLocalNotificationsPlugin plugin;

  /// Open the shared database and register what the shared repositories look up in `getIt` of this isolate.
  static Future<_BackgroundSyncRuntime> create() async {
    // Dart analyzer does not work on conditional export.
    // ignore: undefined_function
    final db = AppDatabase(conn.connect());
    final storage = StorageProvider(db, await preloadCookie(db), {});
    final settingsRepo = SettingsRepository(storage);
    await settingsRepo.init();
    // Filled before every fetch by `refreshNetwork`: the system proxy is only known after asking the platform.
    final proxy = ProxyProvider();
    getIt
      ..registerSingleton(proxy)
      ..registerSingleton(db)
      ..registerSingleton(storage)
      ..registerSingleton(settingsRepo)
      ..registerFactory(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton(NetErrorSaver());
    final repository = NotificationSyncAllRepository(
      storageProvider: storage,
      notificationRepository: NotificationRepository(storageProvider: storage),
      // The Kotlin http client lives in the activity's method channel: this isolate has no activity.
      clientFactory: (cookie) => NetClientProvider.buildNoCookie(
        dio: settingsRepo.buildDefaultDio(nativeHttp: false),
        cookie: cookie,
      ),
      gap: Duration.zero,
    );
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_launcher_foreground'),
      ),
    );
    return _BackgroundSyncRuntime._(db, storage, settingsRepo, proxy, repository, plugin);
  }

  /// Settings the client is built from, read again for this fetch: the snapshot from the service start is stale as
  /// soon as the app changed the proxy (or was started again), and the system proxy has to be asked for here.
  Future<void> refreshNetwork() => refreshBackgroundNetworkSettings(settings: settings, updateProxy: proxy.updateProxy);

  /// Load the app's language so the notification texts match the app.
  Future<void> applyLocale(String locale) async {
    if (locale.isEmpty) {
      await LocaleSettings.useDeviceLocale();
    } else {
      await LocaleSettings.setLocaleRaw(locale);
    }
  }

  Future<void> dispose() async {
    await repository.dispose();
    await db.close();
  }
}

/// Log lines of the service isolate go to their own file in the log directory, exported with the app's logs.
final class _BackgroundLogObserver implements TalkerObserver {
  _BackgroundLogObserver(this._sink);

  final IOSink _sink;

  void _write(TalkerData data) => _sink.write('${redactSensitive(data.generateTextMessage())}\n');

  @override
  void onError(TalkerError err) => _write(err);

  @override
  void onException(TalkerException err) => _write(err);

  @override
  void onLog(TalkerData log) => _write(log);
}

Future<IOSink> _initBackgroundLogger() async {
  final logDir = await getLogDir();
  if (!logDir.existsSync()) {
    await logDir.create(recursive: true);
  }
  final now = DateTime.now();
  final day = '${now.year}${"${now.month}".padLeft(2, "0")}${"${now.day}".padLeft(2, "0")}';
  final sink = File('${logDir.path}${Platform.pathSeparator}tsdm_client_bg_$day.log').openWrite(mode: FileMode.append);
  talker = RedactingTalker(
    logger: TalkerLogger(output: debugPrint),
    settings: TalkerSettings(colors: {TalkerKey.debug: AnsiPen()..xterm(60)}),
    observer: _BackgroundLogObserver(sink),
  );
  return sink;
}

/// Entry point of the service isolate.
@pragma('vm:entry-point')
Future<void> backgroundSyncEntryPoint(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  final logSink = await _initBackgroundLogger();
  talker.info('background sync: service started');

  final _BackgroundSyncRuntime runtime;
  try {
    runtime = await _BackgroundSyncRuntime.create();
  } on Object catch (e, st) {
    talker.handle(e, st, 'background sync: failed to start, stopping');
    await logSink.flush();
    await service.stopSelf();
    return;
  }

  Timer? timer;
  var period = Duration.zero;
  var ticking = false;
  var stopping = false;

  Future<void> stop(String why) async {
    if (stopping) {
      return;
    }
    stopping = true;
    talker.info('background sync: stop ($why)');
    timer?.cancel();
    await runtime.dispose();
    await logSink.flush();
    await service.stopSelf();
  }

  Future<void> tick() async {
    if (ticking || stopping) {
      return;
    }
    ticking = true;
    try {
      final outcome = await backgroundSyncTick(
        storage: runtime.storage,
        repository: runtime.repository,
        prepareNetwork: runtime.refreshNetwork,
      );
      if (stopping) {
        // The app asked for the stop while the fetch was in flight: whatever came back is stored, not announced.
        talker.debug('background sync: stopping, result of the last fetch not announced');
        return;
      }
      switch (outcome) {
        case BackgroundSyncDisabled():
          await stop('switched off');
        case BackgroundSyncSkipped(:final reason):
          talker.debug('background sync: skipped, $reason');
        case BackgroundSyncStale(:final reason):
          talker.info('background sync: not announced, $reason');
        case BackgroundSyncDone(:final uid, :final result):
          talker.debug('background sync: ${result.runtimeType} for uid ${"$uid".obscured(4)}');
          if (result case NotificationSyncResultSuccess(:final latest)) {
            if (latest != null) {
              await showLocalNotificationWith(plugin: runtime.plugin, translations: t, info: latest);
            }
            service.invoke(BackgroundSyncEvents.synced, {
              'uid': uid,
              'notice': result.unreadNotice,
              'personalMessage': result.unreadPersonalMessage,
              'broadcastMessage': result.unreadBroadcastMessage,
            });
          }
      }
    } on Object catch (e, st) {
      talker.handle(e, st, 'background sync: tick failed');
    } finally {
      ticking = false;
      await logSink.flush();
    }
  }

  /// Read the settings again: stop when the switch is off or auto sync is never, otherwise follow the interval.
  Future<void> reschedule() async {
    final settings = await readBackgroundSyncSettings(runtime.storage);
    if (!settings.enabled) {
      await stop('switched off');
      return;
    }
    if (settings.intervalSeconds <= 0) {
      await stop('auto sync is off');
      return;
    }
    await runtime.applyLocale(settings.locale);
    if (service is AndroidServiceInstance) {
      await service.setForegroundNotificationInfo(
        title: t.backgroundService.title,
        content: t.backgroundService.content,
      );
    }
    final next = Duration(seconds: settings.intervalSeconds);
    if (next != period) {
      talker.info('background sync: every ${next.inSeconds}s');
      period = next;
      timer?.cancel();
      timer = Timer.periodic(next, (_) => tick());
    }
  }

  service.on(BackgroundSyncEvents.stop).listen((_) => stop('asked by the app'));
  service.on(BackgroundSyncEvents.settingsChanged).listen((_) async {
    await reschedule();
    await tick();
  });
  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
  }
  await reschedule();
  await tick();
}
