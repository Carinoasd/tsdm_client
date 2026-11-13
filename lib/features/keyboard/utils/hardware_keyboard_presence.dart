import 'dart:async';
import 'dart:ui' show KeyEventDeviceType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/method_channel.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Whether a hardware keyboard is in use on a touch platform: an iPad (or an iPhone) or an Android tablet (or phone)
/// with a keyboard attached.
///
/// Flutter has no API telling it, so each platform tells it its own way:
///
/// * iOS: every key event comes from a hardware keyboard, the on-screen keyboard talks to the text input
///   (`UITextInput`) and sends no key events. So the first key pressed tells it, and it stays in use since.
/// * Android: a key event tells nothing. The input methods send some keys (delete, enter) as key events of a keyboard
///   source, and the volume and back keys reach Flutter as key events too. The activity tells it instead, from its
///   configuration (`Configuration.keyboard`, `hardKeyboardHidden`): when it starts, and each time a keyboard is
///   attached or removed. Taken out again, the shortcuts are off again.
///
/// While [seen] is true, the keyboard shortcuts of the desktop app are in use.
abstract final class HardwareKeyboardPresence {
  /// Whether a hardware keyboard is in use; never set on other platforms.
  static final ValueNotifier<bool> seen = ValueNotifier(false);

  /// Act as a touch platform (true) or as a desktop one (false) in tests, null for the platform the app runs on.
  @visibleForTesting
  static bool? touchPlatformOverride;

  /// Act as Android (true, the activity tells of the keyboard) or as iOS (false, the keys tell) in tests, null for
  /// the platform the app runs on.
  @visibleForTesting
  static bool? androidOverride;

  /// Whether the app runs on a touch platform whose hardware keyboard is watched for (iOS, Android).
  static bool get touchPlatform => touchPlatformOverride ?? (isIOS || isAndroid);

  /// Whether the activity tells of the keyboard (Android) rather than its keys (iOS).
  static bool get toldBySystem => androidOverride ?? isAndroid;

  /// Whether the app runs on a desktop platform, where the keyboard shortcuts are always in use.
  static bool get desktopPlatform => switch (touchPlatformOverride) {
    null => isDesktop,
    final touch => !touch,
  };

  static bool _watching = false;

  /// Start watching for a hardware keyboard, once, on a touch platform.
  ///
  /// On Android [present] and [listen] are the main channel calls by default, replaced in tests.
  static void watch({
    Future<bool> Function()? present,
    void Function(void Function({required bool present}) onChanged)? listen,
  }) {
    if (_watching || !touchPlatform) {
      return;
    }
    _watching = true;
    if (!toldBySystem) {
      HardwareKeyboard.instance.addHandler(_onKeyEvent);
      return;
    }
    (listen ?? androidOnHardwareKeyboardChanged)(systemTold);
    unawaited(
      (present ?? androidHasHardwareKeyboard)().then(
        (value) => systemTold(present: value),
        onError: (Object e) => talker.warning('hardware keyboard not asked: $e'),
      ),
    );
  }

  /// Android told whether a hardware keyboard is in use.
  static void systemTold({required bool present}) {
    if (!_watching || !toldBySystem || seen.value == present) {
      return;
    }
    talker.info('hardware keyboard ${present ? 'attached' : 'removed'}');
    seen.value = present;
  }

  /// iOS: seen before the focus gets the key, so the shortcut of the very first key pressed works.
  static bool _onKeyEvent(KeyEvent event) {
    if (!seen.value && event is KeyDownEvent && event.deviceType == KeyEventDeviceType.keyboard) {
      seen.value = true;
    }
    // Only watching, the key goes on.
    return false;
  }

  /// Forget the keyboard and stop watching, for tests.
  @visibleForTesting
  static void reset() {
    if (_watching) {
      HardwareKeyboard.instance.removeHandler(_onKeyEvent);
    }
    _watching = false;
    seen.value = false;
  }
}
