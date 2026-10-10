import 'dart:async';

import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/method_channel.dart';

/// Signature of the call that asks the platform for a refresh rate.
typedef HighRefreshRateSetter = Future<double> Function({required bool enable});

/// Keeps the Android refresh rate in line with the [SettingsKeys.highRefreshRate] setting (GitHub #182).
///
/// Some vendor systems keep apps that do not ask for a display mode at 60Hz on 90/120Hz screens. This follows the
/// settings stream, so the current value applies at startup and every later toggle applies at once.
final class HighRefreshRateFollower with LoggerMixin {
  /// Constructor.
  HighRefreshRateFollower(Stream<SettingsMap> settings, {HighRefreshRateSetter setter = androidSetHighRefreshRate})
    : _setter = setter {
    _sub = settings.map((e) => e.highRefreshRate).distinct().listen(_apply);
  }

  final HighRefreshRateSetter _setter;
  late final StreamSubscription<bool> _sub;

  Future<void> _apply(bool enable) async {
    try {
      final rate = await _setter(enable: enable);
      debug('high refresh rate ${enable ? 'on' : 'off'}, preferred ${rate.toStringAsFixed(1)}Hz');
    } on Exception catch (e, st) {
      // An unsupported device only stays at the rate the system picks.
      warning('failed to set high refresh rate', e, st);
    }
  }

  /// Stop following the settings.
  Future<void> dispose() => _sub.cancel();
}
