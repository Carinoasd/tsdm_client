import 'package:tsdm_client/features/background_sync/background_sync_service.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Keeps the Android background message service in the state the settings ask for (#80).
///
/// The service runs when the switch is on and the auto sync interval is not "never"; it stops itself when either
/// changes, so every settings change goes through [apply], which also starts it again when the interval comes back
/// from "never". The plugin calls are injected so the decisions can be tested without a platform.
final class BackgroundSyncController with LoggerMixin {
  /// Constructor with the plugin calls of `background_sync_service.dart` by default.
  BackgroundSyncController({
    Future<void> Function({required bool autoStartOnBoot})? configure,
    Future<bool> Function()? start,
    Future<void> Function()? stop,
    Future<bool> Function()? isRunning,
    void Function()? notifySettingsChanged,
  }) : _configure = configure ?? _configureWith,
       _start = start ?? startBackgroundSyncService,
       _stop = stop ?? stopBackgroundSyncService,
       _isRunning = isRunning ?? isBackgroundSyncServiceRunning,
       _notifySettingsChanged = notifySettingsChanged ?? notifyBackgroundSyncSettingsChanged;

  static Future<void> _configureWith({required bool autoStartOnBoot}) =>
      initializeBackgroundSyncService(autoStartOnBoot: autoStartOnBoot);

  final Future<void> Function({required bool autoStartOnBoot}) _configure;
  final Future<bool> Function() _start;
  final Future<void> Function() _stop;
  final Future<bool> Function() _isRunning;
  final void Function() _notifySettingsChanged;

  /// Whether the service should run for these settings.
  static bool shouldRun({required bool enabled, required int intervalSeconds}) => enabled && intervalSeconds > 0;

  /// Bring the service to the state [enabled] and [intervalSeconds] ask for.
  ///
  /// Returns whether the service runs afterwards. When it should run but could not be started, or a plugin call
  /// threw, the answer is false and the caller decides what to show and whether to roll the switch back; nothing
  /// here throws.
  Future<bool> apply({required bool enabled, required int intervalSeconds}) async {
    final wanted = shouldRun(enabled: enabled, intervalSeconds: intervalSeconds);
    try {
      // Boot start follows what is wanted now, so a switched-off service does not start just to stop itself.
      await _configure(autoStartOnBoot: wanted);
      if (!wanted) {
        await _stop();
        return false;
      }
      if (!await _isRunning()) {
        // A service that stopped itself (interval set to never, or a switch-off) is started again here.
        if (!await _start()) {
          error('background sync service did not start');
          return false;
        }
      }
      // A running service reads the settings again and reschedules.
      _notifySettingsChanged();
      return true;
    } on Object catch (e, st) {
      handleRaw(e, st);
      return false;
    }
  }
}
