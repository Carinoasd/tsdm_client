import 'dart:async';

import 'package:tsdm_client/features/background_sync/background_sync_service.dart';
import 'package:tsdm_client/utils/logger.dart';

/// What the service does after [BackgroundSyncController.apply] brought it to the state asked for.
enum BackgroundSyncApplyResult {
  /// The service runs.
  running,

  /// The settings do not want the service, it is stopped.
  stopped,

  /// The settings want the service but it could not be started (or a plugin call threw): the caller decides what to
  /// show and whether to roll the switch back.
  failed,

  /// A later request came in while this one waited or ran, so this result is stale; the later request reports.
  superseded,
}

/// Keeps the Android background message service in the state the settings ask for (#80).
///
/// The service runs when the switch is on and the auto sync interval is not "never"; it stops itself when either
/// changes, so every settings change goes through [apply], which also starts it again when the interval comes back
/// from "never". The plugin calls are injected so the decisions can be tested without a platform.
///
/// Requests are handled one after another and only the latest one counts. Stopping and starting take time (the
/// plugin is polled until the service is really gone or really up), and a request that ran meanwhile saw the
/// service in between: switched off and on again quickly, the "on" request found the service still running (it was
/// still stopping), only told it to read the settings again, and the switch ended up on with a stopped service.
final class BackgroundSyncController with LoggerMixin {
  /// Constructor with the plugin calls of `background_sync_service.dart` by default.
  BackgroundSyncController({
    Future<void> Function({required bool autoStartOnBoot})? configure,
    Future<bool> Function()? start,
    Future<bool> Function()? stop,
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
  final Future<bool> Function() _stop;
  final Future<bool> Function() _isRunning;
  final void Function() _notifySettingsChanged;

  /// The request handled last, the next one waits for it.
  Future<void> _previous = Future<void>.value();

  /// Id of the latest request; an older one is skipped when its turn comes and its result is not reported.
  var _latest = 0;

  /// Whether the service should run for these settings.
  static bool shouldRun({required bool enabled, required int intervalSeconds}) => enabled && intervalSeconds > 0;

  /// Bring the service to the state [enabled] and [intervalSeconds] ask for.
  ///
  /// Waits for the requests before it. When a newer request arrives meanwhile this one is skipped (or its outcome
  /// is dropped when it already ran) and reports [BackgroundSyncApplyResult.superseded]; the newest request is the
  /// one that leaves the service in the state the settings show. Nothing here throws.
  Future<BackgroundSyncApplyResult> apply({required bool enabled, required int intervalSeconds}) {
    final id = ++_latest;
    final result = _previous.then((_) async {
      if (id != _latest) {
        return BackgroundSyncApplyResult.superseded;
      }
      final outcome = await _apply(enabled: enabled, intervalSeconds: intervalSeconds);
      return id == _latest ? outcome : BackgroundSyncApplyResult.superseded;
    });
    _previous = result.then((_) {});
    return result;
  }

  Future<BackgroundSyncApplyResult> _apply({required bool enabled, required int intervalSeconds}) async {
    final wanted = shouldRun(enabled: enabled, intervalSeconds: intervalSeconds);
    try {
      // Boot start follows what is wanted now, so a switched-off service does not start just to stop itself.
      await _configure(autoStartOnBoot: wanted);
      if (!wanted) {
        if (!await _stop()) {
          warning('background sync service is still running after the stop request');
        }
        return BackgroundSyncApplyResult.stopped;
      }
      if (!await _isRunning()) {
        // A service that stopped itself (interval set to never, or a switch-off) is started again here.
        if (!await _start()) {
          error('background sync service did not start');
          return BackgroundSyncApplyResult.failed;
        }
      }
      // A running service reads the settings again and reschedules.
      _notifySettingsChanged();
      return BackgroundSyncApplyResult.running;
    } on Object catch (e, st) {
      handleRaw(e, st);
      return wanted ? BackgroundSyncApplyResult.failed : BackgroundSyncApplyResult.stopped;
    }
  }
}
