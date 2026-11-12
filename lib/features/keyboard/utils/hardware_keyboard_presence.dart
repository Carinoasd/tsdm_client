import 'dart:ui' show KeyEventDeviceType;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Whether a hardware keyboard is in use on a touch platform: an iPad (or an iPhone) with a keyboard attached.
///
/// Flutter has no API telling it. On iOS every key event comes from a hardware keyboard: the on-screen keyboard talks
/// to the text input (`UITextInput`) and sends no key events. So the first key pressed tells it ([seen]), and from then
/// on the keyboard shortcuts of the desktop app are in use.
///
/// Android is left out: its input methods send some keys (delete, enter) as key events of a keyboard source, and the
/// volume and back keys reach Flutter as key events too, so a key event there does not tell a hardware keyboard.
abstract final class HardwareKeyboardPresence {
  /// Whether a key of a hardware keyboard was pressed since the app started; never set on other platforms.
  static final ValueNotifier<bool> seen = ValueNotifier(false);

  /// Act as a touch platform (true) or as a desktop one (false) in tests, null for the platform the app runs on.
  @visibleForTesting
  static bool? touchPlatformOverride;

  /// Whether the app runs on a touch platform whose hardware keyboard is watched for (iOS).
  static bool get touchPlatform => touchPlatformOverride ?? isIOS;

  /// Whether the app runs on a desktop platform, where the keyboard shortcuts are always in use.
  static bool get desktopPlatform => switch (touchPlatformOverride) {
    null => isDesktop,
    final touch => !touch,
  };

  static bool _watching = false;

  /// Start watching for the keys of a hardware keyboard, once, on a touch platform.
  static void watch() {
    if (_watching || !touchPlatform) {
      return;
    }
    _watching = true;
    HardwareKeyboard.instance.addHandler(_onKeyEvent);
  }

  /// Seen before the focus gets the key: the shortcut of the very first key pressed works.
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
