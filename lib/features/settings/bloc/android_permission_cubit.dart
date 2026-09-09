import 'package:bloc/bloc.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';

part 'android_permission_state.dart';

/// Seam over permission_handler so the cubit can be tested without the platform plugin.
abstract interface class AndroidPermissionGateway {
  /// Current status of [permission].
  Future<PermissionStatus> status(Permission permission);

  /// Ask the user for [permission]; returns the status afterwards.
  Future<PermissionStatus> request(Permission permission);

  /// Open the app info page in system settings.
  Future<bool> openSettings();
}

/// Default gateway backed by permission_handler.
final class _PermissionHandlerGateway implements AndroidPermissionGateway {
  const _PermissionHandlerGateway();

  @override
  Future<PermissionStatus> status(Permission permission) => permission.status;

  @override
  Future<PermissionStatus> request(Permission permission) => permission.request();

  @override
  Future<bool> openSettings() => openAppSettings();
}

/// Tracks and requests the Android permissions the auto sync push relies on (#13, #3).
///
/// Every method is a no-op when [enabled] is false, which defaults to running on Android.
final class AndroidPermissionCubit extends Cubit<AndroidPermissionState> with LoggerMixin {
  /// Constructor.
  AndroidPermissionCubit({bool? enabled, AndroidPermissionGateway? gateway})
    : _enabled = enabled ?? isAndroid,
      _gateway = gateway ?? const _PermissionHandlerGateway(),
      super(const AndroidPermissionState());

  final bool _enabled;
  final AndroidPermissionGateway _gateway;

  /// Whether the cubit talks to the platform at all.
  bool get enabled => _enabled;

  /// Re-read both statuses from the system.
  Future<void> refresh() async {
    if (!_enabled) {
      return;
    }
    try {
      final notification = await _gateway.status(Permission.notification);
      final ignoreBattery = await _gateway.status(Permission.ignoreBatteryOptimizations);
      debug('refresh: notification=$notification ignoreBattery=$ignoreBattery');
      emit(AndroidPermissionState(notification: notification, ignoreBattery: ignoreBattery));
    } on Exception catch (e, st) {
      handleRaw(e, st);
    }
  }

  /// Request the notification permission.
  ///
  /// When the permission is permanently denied Android shows no dialog any more, so this opens the app settings
  /// page instead, unless [openSettingsWhenPermanentlyDenied] is false (then it only refreshes the status).
  Future<void> requestNotification({bool openSettingsWhenPermanentlyDenied = true}) async {
    if (!_enabled) {
      return;
    }
    try {
      final current = state.notification ?? await _gateway.status(Permission.notification);
      if (current.isPermanentlyDenied) {
        if (openSettingsWhenPermanentlyDenied) {
          final opened = await _gateway.openSettings();
          info('notification permission permanently denied, open app settings: $opened');
        } else {
          info('notification permission permanently denied, not asking again');
        }
      } else {
        final result = await _gateway.request(Permission.notification);
        info('request notification permission: $result');
      }
    } on Exception catch (e, st) {
      handleRaw(e, st);
    }
    await refresh();
  }

  /// Ask the system to exempt this app from battery optimizations.
  ///
  /// Launches the system dialog only when `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is in the manifest.
  Future<void> requestIgnoreBattery() async {
    if (!_enabled) {
      return;
    }
    try {
      final result = await _gateway.request(Permission.ignoreBatteryOptimizations);
      info('request ignore battery optimizations: $result');
    } on Exception catch (e, st) {
      handleRaw(e, st);
    }
    await refresh();
  }
}
