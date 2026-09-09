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

  /// Whether Android would still show a dialog for [permission]; false off Android.
  ///
  /// False after a request that came back denied means the system did not and will not prompt.
  Future<bool> shouldShowRationale(Permission permission);
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

  @override
  Future<bool> shouldShowRationale(Permission permission) => permission.shouldShowRequestRationale;
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

  /// Set once a notification request came back denied without the system showing (or ever showing) a dialog.
  ///
  /// permission_handler only reports `permanentlyDenied` when it saw the two denials itself; Android < 13, users who
  /// denied twice through the boot prompt, and notifications switched off in system settings all read plain `denied`
  /// forever. Treat those as permanently denied so the row and the tap lead to the app settings page instead of a
  /// no-op (#13).
  bool _notificationWillNotPrompt = false;

  /// Whether the cubit talks to the platform at all.
  bool get enabled => _enabled;

  /// Re-read both statuses from the system.
  Future<void> refresh() async {
    if (!_enabled || isClosed) {
      return;
    }
    try {
      final notification = await _gateway.status(Permission.notification);
      final ignoreBattery = await _gateway.status(Permission.ignoreBatteryOptimizations);
      if (isClosed) {
        // The settings page was popped while the platform calls were in flight.
        return;
      }
      debug('refresh: notification=$notification ignoreBattery=$ignoreBattery');
      emit(AndroidPermissionState(notification: _stickyNotification(notification), ignoreBattery: ignoreBattery));
    } on Exception catch (e, st) {
      handleRaw(e, st);
    }
  }

  /// Map a plain `denied` to `permanentlyDenied` once we know the system will not prompt.
  PermissionStatus _stickyNotification(PermissionStatus status) {
    if (status.isGranted || status.isLimited || status.isProvisional) {
      _notificationWillNotPrompt = false;
      return status;
    }
    return _notificationWillNotPrompt ? PermissionStatus.permanentlyDenied : status;
  }

  /// Request the notification permission.
  ///
  /// When the permission is permanently denied Android shows no dialog any more, so this opens the app settings
  /// page instead, unless [openSettingsWhenPermanentlyDenied] is false (then it only refreshes the status).
  ///
  /// A request that comes back denied while the system would not show a dialog (Android < 13, both denials made
  /// through the boot prompt, notifications switched off in system settings) is treated as permanently denied from
  /// then on: the state flips to [PermissionStatus.permanentlyDenied] and the same settings shortcut applies.
  Future<void> requestNotification({bool openSettingsWhenPermanentlyDenied = true}) async {
    if (!_enabled || isClosed) {
      return;
    }
    try {
      final current = state.notification ?? await _gateway.status(Permission.notification);
      if (current.isPermanentlyDenied) {
        await _openSettingsForNotification(openSettingsWhenPermanentlyDenied);
      } else {
        final result = await _gateway.request(Permission.notification);
        info('request notification permission: $result');
        if (result.isDenied || result.isRestricted) {
          final rationale = await _gateway.shouldShowRationale(Permission.notification);
          if (!rationale) {
            // No dialog was shown and none will be: only the app settings page can turn notifications on.
            info('notification permission denied without a dialog, treat as permanently denied');
            _notificationWillNotPrompt = true;
            if (isClosed) {
              return;
            }
            emit(
              AndroidPermissionState(
                notification: PermissionStatus.permanentlyDenied,
                ignoreBattery: state.ignoreBattery,
              ),
            );
            await _openSettingsForNotification(openSettingsWhenPermanentlyDenied);
          }
        }
      }
    } on Exception catch (e, st) {
      handleRaw(e, st);
    }
    await refresh();
  }

  Future<void> _openSettingsForNotification(bool openSettings) async {
    if (openSettings) {
      final opened = await _gateway.openSettings();
      info('notification permission permanently denied, open app settings: $opened');
    } else {
      info('notification permission permanently denied, not asking again');
    }
  }

  /// Ask the system to exempt this app from battery optimizations.
  ///
  /// Launches the system dialog only when `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is in the manifest.
  Future<void> requestIgnoreBattery() async {
    if (!_enabled || isClosed) {
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
