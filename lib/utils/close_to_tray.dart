import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/desktop_tray_policy.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/tray_helper.dart';
import 'package:window_manager/window_manager.dart';

Future<void> _windowSetPreventClose({required bool prevent}) => windowManager.setPreventClose(prevent);

/// Windows and macOS: closing the window hides it into the tray (`SettingsKeys.closeToTray`).
///
/// The close button is only taken over (`setPreventClose(true)`) while the switch is on **and** the tray icon is up
/// ([interceptsClose]); with the switch off nothing is ever sent to the native side, the window closes and the app
/// quits exactly as before. Whatever was applied last, the click itself is decided again with the state of the moment
/// ([closeActionOf]): a window is never hidden without an icon to bring it back.
///
/// Logging off or shutting Windows down is not a click on the close button (`WM_QUERYENDSESSION`, not `WM_CLOSE`):
/// nothing here holds it. Quitting from the tray menu goes through [TrayHelper.quit].
class CloseToTray with WindowListener, LoggerMixin {
  CloseToTray._(this._platform, this._tray, this._setPreventClose, this._hide);

  /// Drives a fake tray and window in tests.
  @visibleForTesting
  CloseToTray.forTesting({
    required TrayPlatform platform,
    required TrayHelper tray,
    required Future<void> Function({required bool prevent}) setPreventClose,
    required Future<void> Function() hide,
  }) : this._(platform, tray, setPreventClose, hide);

  /// The app's.
  static final CloseToTray instance = CloseToTray._(
    TrayPlatform.host,
    TrayHelper.instance,
    _windowSetPreventClose,
    windowManager.hide,
  );

  final TrayPlatform _platform;
  final TrayHelper _tray;
  final Future<void> Function({required bool prevent}) _setPreventClose;
  final Future<void> Function() _hide;

  StreamSubscription<SettingsMap>? _settingsSubscription;
  bool _started = false;

  /// What the native side holds now: `true` only after `setPreventClose(true)` succeeded.
  bool _intercepting = false;

  /// The value being applied, so a burst of changes sends each value once, in order.
  Future<void> _applying = Future<void>.value();

  /// Whether the close button is taken over now.
  @visibleForTesting
  bool get intercepting => _intercepting;

  /// Follow the switch and the tray icon. Nothing happens on platforms without the switch.
  void start() {
    if (_started || !_platform.hasCloseToTraySwitch) {
      return;
    }
    _started = true;
    windowManager.addListener(this);
    _settingsSubscription = getIt.get<SettingsRepository>().settings.listen((_) => unawaited(apply()));
    _tray.running.addListener(_onTrayChanged);
    unawaited(apply());
  }

  void _onTrayChanged() => unawaited(apply());

  bool get _closeToTraySetting => getIt.get<SettingsRepository>().currentSettings.closeToTray;

  /// Bring the native side in line with the switch and the tray.
  Future<void> apply() => _applying = _applying.then((_) => _apply());

  Future<void> _apply() async {
    if (!_started) {
      return;
    }
    final want = interceptsClose(_platform, closeToTraySetting: _closeToTraySetting, trayRunning: _tray.running.value);
    if (want == _intercepting) {
      return;
    }
    try {
      await _setPreventClose(prevent: want);
      _intercepting = want;
      info('close to tray: ${want ? 'on' : 'off'}');
    } on Object catch (e, st) {
      // Left as it was: a failed `true` keeps the native close, a failed `false` is still handled by [onWindowClose].
      talker.handle(e, st, 'set prevent close failed');
    }
  }

  @override
  void onWindowClose() => unawaited(handleClose());

  /// A click on the close button.
  @visibleForTesting
  Future<void> handleClose() async {
    final action = closeActionOf(
      _platform,
      intercepting: _intercepting,
      closeToTraySetting: _closeToTraySetting,
      trayRunning: _tray.running.value,
    );
    debug('window close: ${action.name}');
    switch (action) {
      case WindowCloseAction.native:
        return;
      case WindowCloseAction.hide:
        try {
          await _hide();
        } on Object catch (e, st) {
          // A window that cannot be hidden is closed instead: the click must not do nothing.
          talker.handle(e, st, 'hide window failed');
          await _tray.quit();
        }
      case WindowCloseAction.quit:
        await _tray.quit();
    }
  }

  /// Stop following (tests).
  @visibleForTesting
  Future<void> dispose() async {
    if (!_started) {
      return;
    }
    _started = false;
    windowManager.removeListener(this);
    _tray.running.removeListener(_onTrayChanged);
    await _settingsSubscription?.cancel();
    _settingsSubscription = null;
    await _applying;
  }
}
