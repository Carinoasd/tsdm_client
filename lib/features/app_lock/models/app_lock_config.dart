import 'dart:convert';

import 'package:flutter/foundation.dart';

/// How the app is unlocked once the app lock is on.
enum AppLockMethod {
  /// No app lock.
  off,

  /// The PIN set in the app.
  pin,

  /// The fingerprint or face of the system (Windows Hello on Windows), the PIN when it fails or is not available.
  biometric,
}

/// How long the app may stay in the background before it locks again.
enum AppLockTiming {
  /// Each time the app leaves the screen.
  immediately(Duration.zero),

  /// After one minute away.
  oneMinute(Duration(minutes: 1)),

  /// After five minutes away.
  fiveMinutes(Duration(minutes: 5))
  ;

  const AppLockTiming(this.delay);

  /// Time away after which the app locks.
  final Duration delay;
}

/// A PIN as stored: PBKDF2-HMAC-SHA256 of it with a random salt, never the PIN itself.
@immutable
final class PinHash {
  /// Constructor.
  const PinHash({required this.iterations, required this.salt, required this.hash});

  /// From [toJson]; null when anything is missing or malformed.
  static PinHash? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final iterations = json['iterations'];
    final salt = json['salt'];
    final hash = json['hash'];
    if (iterations is! int || iterations <= 0 || salt is! String || hash is! String) {
      return null;
    }
    try {
      return PinHash(iterations: iterations, salt: base64Decode(salt), hash: base64Decode(hash));
    } on FormatException {
      return null;
    }
  }

  /// PBKDF2 rounds.
  final int iterations;

  /// Random salt.
  final List<int> salt;

  /// The derived key.
  final List<int> hash;

  /// For the file.
  Map<String, Object?> toJson() => {
    'kdf': 'pbkdf2-hmac-sha256',
    'iterations': iterations,
    'salt': base64Encode(salt),
    'hash': base64Encode(hash),
  };
}

/// The app lock settings of this device, kept outside the settings table so neither backups nor the cross-device
/// sync carry them.
@immutable
final class AppLockConfig {
  /// Constructor.
  const AppLockConfig({
    this.method = AppLockMethod.off,
    this.pin,
    this.timing = AppLockTiming.immediately,
    this.requireForAccountSwitch = false,
    this.failedAttempts = 0,
    this.lockedOutUntil,
  });

  /// From [toJson]. A file naming a lock without a readable PIN is taken as no lock: there would be no way in.
  factory AppLockConfig.fromJson(Map<String, Object?> json) {
    final pin = PinHash.fromJson(json['pin']);
    final method = AppLockMethod.values.asNameMap()[json['method']] ?? AppLockMethod.off;
    final until = json['lockedOutUntil'];
    return AppLockConfig(
      method: pin == null ? AppLockMethod.off : method,
      pin: pin,
      timing: AppLockTiming.values.asNameMap()[json['timing']] ?? AppLockTiming.immediately,
      requireForAccountSwitch: json['requireForAccountSwitch'] == true,
      failedAttempts: switch (json['failedAttempts']) {
        final int v when v > 0 => v,
        _ => 0,
      },
      lockedOutUntil: until is int ? DateTime.fromMillisecondsSinceEpoch(until) : null,
    );
  }

  /// Version of the file.
  static const formatVersion = 1;

  /// How the app is unlocked.
  final AppLockMethod method;

  /// The PIN, set whenever [method] is not [AppLockMethod.off].
  final PinHash? pin;

  /// When the app locks again after leaving the screen.
  final AppLockTiming timing;

  /// Ask to unlock again before switching to another account.
  final bool requireForAccountSwitch;

  /// Wrong PINs entered in a row.
  final int failedAttempts;

  /// No PIN is checked before this time (too many wrong ones).
  final DateTime? lockedOutUntil;

  /// Whether the app lock is on.
  bool get enabled => method != AppLockMethod.off && pin != null;

  /// A copy with the given fields replaced; [clearLockout] resets [lockedOutUntil].
  AppLockConfig copyWith({
    AppLockMethod? method,
    PinHash? pin,
    AppLockTiming? timing,
    bool? requireForAccountSwitch,
    int? failedAttempts,
    DateTime? lockedOutUntil,
    bool clearLockout = false,
  }) => AppLockConfig(
    method: method ?? this.method,
    pin: pin ?? this.pin,
    timing: timing ?? this.timing,
    requireForAccountSwitch: requireForAccountSwitch ?? this.requireForAccountSwitch,
    failedAttempts: failedAttempts ?? this.failedAttempts,
    lockedOutUntil: clearLockout ? null : (lockedOutUntil ?? this.lockedOutUntil),
  );

  /// For the file.
  Map<String, Object?> toJson() => {
    'v': formatVersion,
    'method': method.name,
    if (pin != null) 'pin': pin!.toJson(),
    'timing': timing.name,
    'requireForAccountSwitch': requireForAccountSwitch,
    'failedAttempts': failedAttempts,
    if (lockedOutUntil != null) 'lockedOutUntil': lockedOutUntil!.millisecondsSinceEpoch,
  };
}
