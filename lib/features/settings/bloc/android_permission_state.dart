part of 'android_permission_cubit.dart';

/// Statuses of the Android permissions shown in settings.
///
/// A null status means "not read yet" (or not running on Android).
@immutable
final class AndroidPermissionState {
  /// Constructor.
  const AndroidPermissionState({this.notification, this.ignoreBattery});

  /// `POST_NOTIFICATIONS` (Android 13+) or "notifications enabled" on older versions.
  final PermissionStatus? notification;

  /// Whether the app is exempted from battery optimizations.
  final PermissionStatus? ignoreBattery;

  @override
  bool operator ==(Object other) =>
      other is AndroidPermissionState && other.notification == notification && other.ignoreBattery == ignoreBattery;

  @override
  int get hashCode => Object.hash(notification, ignoreBattery);

  @override
  String toString() => 'AndroidPermissionState(notification: $notification, ignoreBattery: $ignoreBattery)';
}
