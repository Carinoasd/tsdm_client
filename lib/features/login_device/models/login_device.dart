import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

/// A device an account logged in on with the app, as the forum's app API keeps it (plugin 3.6.0, `type: devices`,
/// `schema: 20`, a row of `devices[]` or the `device` of a write).
@immutable
final class LoginDevice {
  /// Constructor.
  const LoginDevice({
    required this.id,
    required this.platform,
    required this.appVersion,
    required this.name,
    required this.lastSeen,
    required this.revoked,
    required this.current,
  });

  /// The device of the answer object [json], null when it names no id.
  static LoginDevice? fromJson(Map<String, dynamic> json) {
    final id = tsdmAppText(json['device']).toLowerCase();
    if (id.isEmpty) {
      return null;
    }
    return LoginDevice(
      id: id,
      platform: tsdmAppText(json['platform']),
      appVersion: tsdmAppText(json['app_version']),
      name: tsdmAppText(json['name']),
      lastSeen: tsdmAppTime(json['last_seen']),
      revoked: json['revoked'] == 1,
      current: json['current'] == 1,
    );
  }

  /// The id (a UUID, lower case).
  final String id;

  /// `android`, `ios`, `windows`, `macos` or `linux`.
  final String platform;

  /// The app's version on the device (`1.52.1+164`).
  final String appVersion;

  /// The device's name, may be empty.
  final String name;

  /// The last request of the device the forum noted (to 5 minutes), the real instant; null when the answer has none.
  final DateTime? lastSeen;

  /// Logged out of the account from another device.
  final bool revoked;

  /// The device of the request, this one.
  final bool current;

  @override
  bool operator ==(Object other) =>
      other is LoginDevice &&
      other.id == id &&
      other.platform == platform &&
      other.appVersion == appVersion &&
      other.name == name &&
      other.lastSeen == lastSeen &&
      other.revoked == revoked &&
      other.current == current;

  @override
  int get hashCode => Object.hash(id, platform, appVersion, name, lastSeen, revoked, current);

  @override
  String toString() => 'LoginDevice($platform $appVersion, revoked: $revoked, current: $current)';
}

/// The devices of the account the `device` action answered for: [devices] as the forum lists them (the latest
/// activity first), [formHash] for the writes.
@immutable
final class LoginDeviceList {
  /// Constructor.
  const LoginDeviceList({required this.uid, required this.devices, required this.formHash});

  /// The account.
  final int uid;

  /// The devices.
  final List<LoginDevice> devices;

  /// The form hash of the session.
  final String formHash;
}
