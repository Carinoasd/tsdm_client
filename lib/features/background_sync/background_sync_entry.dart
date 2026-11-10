import 'dart:async';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/background_sync/background_isolate.dart';
import 'package:tsdm_client/features/background_sync/background_sync_events.dart';
import 'package:tsdm_client/features/background_sync/background_sync_tick.dart';
import 'package:tsdm_client/features/forum_watch/repository/forum_watch_store.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_check.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_fetch.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_notice.dart';
import 'package:tsdm_client/features/local_notice/direct_reply_entry.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/settings/repositories/webdav_backup_repository.dart';
import 'package:tsdm_client/features/thread_follow/repository/followed_thread_store.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_check.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_fetch.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_notice.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/connection/native.dart' show databaseFile;
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// The isolate side of the Android background message service (#80): [backgroundSyncEntryPoint] and what it needs.
///
/// Kept apart from `background_sync_service.dart` (the app-facing start/stop API) because a library with a
/// `vm:entry-point` counts as executable for the analyzer, which then reports every member not reached from the
/// entry point.
/// Everything the service isolate needs, built once when it starts.
final class _BackgroundSyncRuntime {
  _BackgroundSyncRuntime._(this.base, this.repository, this.plugin)
    : followed = FollowedThreadStore(base.storage),
      watch = ForumWatchStore(base.storage);

  /// The database, the settings and the clients, shared with the isolate of the direct reply.
  final BackgroundIsolateBase base;
  final NotificationSyncAllRepository repository;
  final FlutterLocalNotificationsPlugin plugin;

  StorageProvider get storage => base.storage;

  /// The threads each account follows, checked by the service too (`followedThreadsTick`).
  final FollowedThreadStore followed;

  /// The forums and keywords each account watches, checked by the service too (`forumWatchTick`).
  final ForumWatchStore watch;

  /// The reading of the watched sources of account [uid], with a client built as the sync's clients are.
  Future<ForumWatchFetch> Function(String source) watchFetcherOf(int uid) =>
      forumWatchFetcherOf(uid, clientFactory: base.clientOf);

  /// The check of one followed thread of account [uid], with a client built as the sync's clients are.
  Future<FollowedThreadFetch> Function(int tid) followedFetcherOf(int uid) =>
      followedThreadFetcherOf(uid, clientFactory: base.clientOf);

  /// Open the shared database and register what the shared repositories look up in `getIt` of this isolate.
  static Future<_BackgroundSyncRuntime> create() async {
    final base = await BackgroundIsolateBase.open();
    final repository = NotificationSyncAllRepository(
      storageProvider: base.storage,
      notificationRepository: NotificationRepository(storageProvider: base.storage),
      clientFactory: base.clientOf,
      // One account per call: the tick spaces the accounts itself (`backgroundSyncAccountGap`).
      gap: Duration.zero,
    );
    final plugin = FlutterLocalNotificationsPlugin();
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_launcher_foreground'),
      ),
      // The notifications this service posts offer the direct reply: the plugin keeps the handle of the callback of
      // the current build, also when the service started at boot and the app was not opened since an update.
      onDidReceiveBackgroundNotificationResponse: onNotificationActionInBackground,
    );
    return _BackgroundSyncRuntime._(base, repository, plugin);
  }

  /// Settings the client is built from, read again for this fetch.
  Future<void> refreshNetwork() => base.refreshNetwork();

  /// Load the app's language so the notification texts match the app.
  Future<void> applyLocale(String locale) => base.applyLocale(locale);

  Future<void> dispose() async {
    await followed.dispose();
    await watch.dispose();
    await repository.dispose();
    await base.dispose();
  }
}

/// ` for uid 12**` in a log line about one account, nothing for the whole tick.
String _ofUid(int? uid) => uid == null ? '' : ' for uid ${"$uid".obscured(4)}';

/// Entry point of the service isolate.
@pragma('vm:entry-point')
Future<void> backgroundSyncEntryPoint(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  final logSink = await initBackgroundLogger();
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

  // The automatic WebDAV backup runs on the ticks too, so it is not limited to the times the app is open.
  final webdav = WebdavBackupRepository(store: await WebdavBackupStore.forApp(), databaseFile: () => databaseFile);

  Timer? timer;
  Timer? followTimer;
  var period = Duration.zero;
  var ticking = false;
  var followChecking = false;
  Completer<void>? followDone;
  var watchChecking = false;
  Completer<void>? watchDone;
  var stopping = false;

  Future<void> stop(String why) async {
    if (stopping) {
      return;
    }
    stopping = true;
    talker.info('background sync: stop ($why)');
    timer?.cancel();
    followTimer?.cancel();
    // A check of the followed threads stops at its next thread (`keepGoing`): its writes land before the database
    // closes.
    await followDone?.future.timeout(const Duration(seconds: 40), onTimeout: () {});
    // The same for a check of the watched forums: it stops at its next source.
    await watchDone?.future.timeout(const Duration(seconds: 40), onTimeout: () {});
    await runtime.dispose();
    await logSink.flush();
    await service.stopSelf();
  }

  /// Act on what a tick (or a fetch given up by one, answered later) brought, one account at a time.
  ///
  /// A notification carries its account ([LocalNoticeAccount]): a tap opens the notice page as that account. With
  /// every account announced it names the account and is that account's own, see [BackgroundSyncDone.named]. An
  /// expired login of any account was recorded for that account by the sync itself; nothing else is done here, the
  /// account in use is never logged out by the service.
  Future<void> report(BackgroundSyncOutcome outcome) async {
    if (stopping) {
      // The app asked for the stop while the fetch was in flight: whatever came back is stored, not announced.
      talker.debug('background sync: stopping, result of the last fetch not announced');
      return;
    }
    try {
      switch (outcome) {
        case BackgroundSyncDisabled():
          await stop('switched off');
        case BackgroundSyncSkipped(:final reason, :final uid):
          talker.debug('background sync: skipped${_ofUid(uid)}, $reason');
        case BackgroundSyncStale(:final reason, :final uid):
          talker.info('background sync: not announced${_ofUid(uid)}, $reason');
        case BackgroundSyncDone(:final uid, :final username, :final named, :final result):
          talker.debug('background sync: ${result.runtimeType} for uid ${"$uid".obscured(4)}');
          if (result case NotificationSyncResultSuccess(:final latest)) {
            if (latest != null) {
              await showLocalNotificationWith(
                plugin: runtime.plugin,
                translations: t,
                info: latest,
                account: LocalNoticeAccount(uid: uid, username: username, named: named),
                hideContent:
                    await runtime.storage.getBool(SettingsKeys.notificationHideContent.name) ??
                    SettingsKeys.notificationHideContent.defaultValue,
              );
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
      talker.handle(e, st, 'background sync: reporting failed');
    } finally {
      await logSink.flush();
    }
  }

  Future<void> tick() async {
    if (stopping) {
      return;
    }
    if (ticking) {
      talker.debug('background sync: the previous tick is still running, skipped');
      return;
    }
    ticking = true;
    try {
      // Each account is announced as soon as it is done; the account in use only, unless every account is asked for.
      await backgroundSyncAccountsTick(
        storage: runtime.storage,
        repository: runtime.repository,
        prepareNetwork: runtime.refreshNetwork,
        onLate: (late) => unawaited(report(late)),
        onOutcome: report,
      );
      // Not waited for: an upload must not hold the next notification tick back. It never throws.
      unawaited(webdav.runIfDue());
    } on Object catch (e, st) {
      talker.handle(e, st, 'background sync: tick failed');
    } finally {
      ticking = false;
      await logSink.flush();
    }
  }

  /// Check the followed threads of the account in use when a check is due (shared with the app's own check through
  /// the settings table); one check at a time, apart from the notification tick.
  Future<void> followTick() async {
    if (stopping || followChecking) {
      return;
    }
    followChecking = true;
    followDone = Completer<void>();
    try {
      final uid = (await readBackgroundSyncSettings(runtime.storage)).loginUid;
      await followedThreadsTick(
        storage: runtime.storage,
        store: runtime.followed,
        uid: uid,
        fetch: runtime.followedFetcherOf(uid),
        prepare: runtime.refreshNetwork,
        keepGoing: () => !stopping,
        onCleared: (tid) => unawaited(
          runtime.plugin
              .cancel(id: followedThreadNoticeId(tid))
              .catchError((Object e) => talker.warning('background sync: taking back notification failed: $e')),
        ),
        announce: (thread) async {
          if (stopping) {
            return false;
          }
          await showFollowedThreadNotification(
            plugin: runtime.plugin,
            translations: t,
            thread: thread,
            uid: uid,
            hideContent:
                await runtime.storage.getBool(SettingsKeys.notificationHideContent.name) ??
                SettingsKeys.notificationHideContent.defaultValue,
          );
          return true;
        },
      );
    } on Object catch (e, st) {
      talker.handle(e, st, 'background sync: followed threads check failed');
    } finally {
      followChecking = false;
      followDone?.complete();
      followDone = null;
      await logSink.flush();
    }
  }

  /// Check the forums and keywords the account in use watches when a check is due (shared with the app's own check
  /// through the settings table); one check at a time, apart from the other ticks.
  Future<void> watchTick() async {
    if (stopping || watchChecking) {
      return;
    }
    watchChecking = true;
    watchDone = Completer<void>();
    try {
      final uid = (await readBackgroundSyncSettings(runtime.storage)).loginUid;
      await forumWatchTick(
        storage: runtime.storage,
        store: runtime.watch,
        uid: uid,
        fetch: runtime.watchFetcherOf(uid),
        prepare: runtime.refreshNetwork,
        keepGoing: () => !stopping,
        announce: (batch) async {
          if (stopping) {
            return false;
          }
          await showForumWatchNotification(
            plugin: runtime.plugin,
            translations: t,
            batch: batch,
            uid: uid,
            hideContent:
                await runtime.storage.getBool(SettingsKeys.notificationHideContent.name) ??
                SettingsKeys.notificationHideContent.defaultValue,
          );
          return true;
        },
      );
    } on Object catch (e, st) {
      talker.handle(e, st, 'background sync: forum watch check failed');
    } finally {
      watchChecking = false;
      watchDone?.complete();
      watchDone = null;
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
  if (!stopping) {
    // The watched forums share the heartbeat of the followed threads (`forumWatchHeartbeat` is the same minute).
    followTimer = Timer.periodic(followedThreadHeartbeat, (_) {
      unawaited(followTick());
      unawaited(watchTick());
    });
  }
  await tick();
  unawaited(followTick());
  unawaited(watchTick());
}
