import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// The settings one background sync reads fresh from the database.
///
/// The service runs in its own isolate: nothing in memory tells it about a change made in the app, so every tick
/// reads what it needs from the settings table instead of caching a copy.
typedef BackgroundSyncSettings = ({bool enabled, int intervalSeconds, int loginUid, String locale});

/// Read [BackgroundSyncSettings] from [storage].
Future<BackgroundSyncSettings> readBackgroundSyncSettings(StorageProvider storage) async => (
  enabled:
      await storage.getBool(SettingsKeys.enableBackgroundMessageService.name) ??
      SettingsKeys.enableBackgroundMessageService.defaultValue,
  intervalSeconds:
      await storage.getInt(SettingsKeys.autoSyncNoticeSeconds.name) ?? SettingsKeys.autoSyncNoticeSeconds.defaultValue,
  loginUid: await storage.getInt(SettingsKeys.loginUid.name) ?? SettingsKeys.loginUid.defaultValue,
  locale: await storage.getString(SettingsKeys.locale.name) ?? SettingsKeys.locale.defaultValue,
);

/// What one tick of the background message service ended with.
sealed class BackgroundSyncOutcome {
  const BackgroundSyncOutcome();
}

/// The switch is off: the service has no reason to stay alive.
final class BackgroundSyncDisabled extends BackgroundSyncOutcome {
  /// Constructor.
  const BackgroundSyncDisabled();
}

/// Nothing was fetched this time; [reason] says why.
final class BackgroundSyncSkipped extends BackgroundSyncOutcome {
  /// Constructor.
  const BackgroundSyncSkipped(this.reason);

  /// Why the tick fetched nothing.
  final String reason;
}

/// The current account was synced; [result] is what the shared sync produced for it.
final class BackgroundSyncDone extends BackgroundSyncOutcome {
  /// Constructor.
  const BackgroundSyncDone({required this.uid, required this.result});

  /// The account that was synced.
  final int uid;

  /// Outcome of the sync of that account.
  final NotificationSyncResult result;

  /// What a push notification should announce, null when nothing was new.
  NotificationAutoSyncInfo? get latest => switch (result) {
    NotificationSyncResultSuccess(:final latest) => latest,
    _ => null,
  };
}

/// One tick of the Android background message service (#80).
///
/// Reads the settings, then fetches and stores the current account's notifications through [repository], the very
/// path the "sync all accounts" action uses: same client (cookies, antitheft, proxy, user agent), same storage, same
/// read-state reconciliation and the same notion of what is new. Because the rows land in the shared database, the
/// in-app sync that runs next finds nothing new and does not announce them a second time, and vice versa.
///
/// The service is meant to follow the in-app auto sync: with the interval set to never, or nobody logged in, the tick
/// fetches nothing.
Future<BackgroundSyncOutcome> backgroundSyncTick({
  required StorageProvider storage,
  required NotificationSyncAllRepository repository,
}) async {
  final settings = await readBackgroundSyncSettings(storage);
  if (!settings.enabled) {
    return const BackgroundSyncDisabled();
  }
  if (settings.intervalSeconds <= 0) {
    return const BackgroundSyncSkipped('auto sync is off');
  }
  if (settings.loginUid <= 0) {
    return const BackgroundSyncSkipped('not logged in');
  }
  // The app may have logged in, out or switched accounts since the last tick.
  await storage.refreshCookieCache();
  final user = UserLoginInfo(username: null, uid: settings.loginUid);
  final info = await repository.syncAll(accounts: [user]).run();
  return switch (info) {
    Left(:final value) => BackgroundSyncSkipped('sync failed: $value'),
    Right(:final value) => BackgroundSyncDone(
      uid: settings.loginUid,
      result: value.finished.firstOrNull?.$2 ?? const NotificationSyncResultFailed('no result'),
    ),
  };
}
