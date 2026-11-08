import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/method_channel.dart';
import 'package:tsdm_client/utils/platform.dart';

/// The system unlock (fingerprint, face, Windows Hello) used by the app lock.
abstract interface class BiometricAuthenticator {
  /// Whether this device can unlock with it now: hardware present and something enrolled.
  Future<bool> isAvailable();

  /// Ask the system; true only when the user was recognized. Never throws.
  Future<bool> authenticate(String reason);
}

/// [BiometricAuthenticator] through `local_auth`: Android 9+, iOS, macOS and Windows; Linux has no implementation.
final class LocalBiometricAuthenticator with LoggerMixin implements BiometricAuthenticator {
  /// Constructor.
  LocalBiometricAuthenticator({LocalAuthentication? auth}) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> isAvailable() async {
    if (!(isAndroid || isIOS || isMacOS || isWindows)) {
      return false;
    }
    try {
      if (isWindows) {
        // Windows Hello: the plugin can not tell the kinds apart, any configured one counts.
        return await _auth.isDeviceSupported();
      }
      if (isAndroid && !await androidHasSystemBiometricPrompt()) {
        return false;
      }
      return await _auth.canCheckBiometrics && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } on Object catch (e) {
      warning('app lock: biometrics unavailable: $e');
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      // Windows Hello chooses the way itself (it rejects biometricOnly); elsewhere the app's PIN is the fallback, not
      // the device's.
      return await _auth.authenticate(localizedReason: reason, biometricOnly: !isWindows);
    } on LocalAuthException catch (e) {
      info('app lock: biometric unlock ended: ${e.code.name}');
      return false;
    } on PlatformException catch (e) {
      warning('app lock: biometric unlock failed: ${e.code}');
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
