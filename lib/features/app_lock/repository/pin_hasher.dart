import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:tsdm_client/features/app_lock/models/app_lock_config.dart';

/// Shortest PIN accepted.
const appLockPinMinLength = 4;

/// Longest PIN accepted.
const appLockPinMaxLength = 6;

/// Whether [pin] is 4 to 6 ASCII digits.
bool isValidAppLockPin(String pin) => RegExp('^[0-9]{$appLockPinMinLength,$appLockPinMaxLength}\$').hasMatch(pin);

/// Hashes and checks app lock PINs with PBKDF2-HMAC-SHA256.
final class PinHasher {
  /// Constructor; tests use few [iterations], and widget tests (whose clock is fake) [offUiIsolate] false.
  const PinHasher({this.iterations = defaultIterations, this.offUiIsolate = true});

  /// Rounds of a new hash: a few hundred milliseconds on a phone, run off the UI isolate.
  static const defaultIterations = 100000;

  static const _saltLength = 16;
  static const _bits = 256;

  /// Rounds of a new hash.
  final int iterations;

  /// Derive the keys in another isolate.
  final bool offUiIsolate;

  /// Hash [pin] with a new random salt.
  Future<PinHash> hash(String pin) async {
    final random = Random.secure();
    final salt = List<int>.generate(_saltLength, (_) => random.nextInt(256));
    return PinHash(
      iterations: iterations,
      salt: salt,
      hash: await _derive(pin, salt, iterations, offUiIsolate: offUiIsolate),
    );
  }

  /// Whether [pin] is the one [stored] was made from, compared in constant time.
  Future<bool> verify(String pin, PinHash stored) async {
    final derived = await _derive(pin, stored.salt, stored.iterations, offUiIsolate: offUiIsolate);
    if (derived.length != stored.hash.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < derived.length; i++) {
      diff |= derived[i] ^ stored.hash[i];
    }
    return diff == 0;
  }

  static Future<List<int>> _derive(String pin, List<int> salt, int iterations, {required bool offUiIsolate}) {
    final nonce = List<int>.unmodifiable(salt);
    Future<List<int>> derive() async {
      final key = await Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: _bits,
      ).deriveKeyFromPassword(password: pin, nonce: nonce);
      return key.extractBytes();
    }

    return offUiIsolate ? Isolate.run(derive) : derive();
  }
}

/// Wrong PINs in a row accepted before the PIN pad waits.
const appLockFreeAttempts = 5;

/// How long no PIN is checked after the [failedAttempts]-th wrong one in a row, null when the next may come at once.
///
/// 30 seconds after the 5th, doubled after each further one, at most 30 minutes.
Duration? appLockLockoutFor(int failedAttempts) {
  if (failedAttempts < appLockFreeAttempts) {
    return null;
  }
  final doublings = min(failedAttempts - appLockFreeAttempts, 6);
  final seconds = 30 * (1 << doublings);
  return Duration(seconds: min(seconds, 30 * 60));
}
