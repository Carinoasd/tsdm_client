import 'dart:async';
import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:flutter/widgets.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/method_channel.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Whether the device is on a network that counts the data (mobile data, a hotspot), for every feature that loads
/// large content there only on the user's choice ("on Wi-Fi only": the thumbnails of the thread lists, the images).
///
/// * Android: the system's own answer (`ConnectivityManager.isActiveNetworkMetered`): mobile data, a hotspot and a
///   Wi-Fi the user marked metered count, as does no network at all. The system also pushes every change of the
///   default network ([handlePlatformChange]).
/// * iOS: unmetered when a Wi-Fi interface (`en…`) holds an address that is not link-local; anything else, or no
///   answer, counts as metered.
/// * The desktop platforms: never metered.
///
/// [unmetered] keeps the last answer and can be listened to; it is asked again when it is older than [maxAge] (the
/// next [refreshIfStale] or [isMetered]), and always when the app comes back to the foreground. An answer that fails
/// counts as metered.
abstract final class NetworkUsage {
  /// The last answer: true on a network that does not count the data, null until the first one came. Listen to it
  /// for the changes.
  static final ValueNotifier<bool?> unmetered = ValueNotifier(null);

  /// How long an answer holds before it is asked again.
  static const maxAge = Duration(seconds: 5);

  /// How the platform is asked (tests replace it).
  @visibleForTesting
  static Future<bool> Function() check = _platformUnmetered;

  static DateTime? _checkedAt;

  static Future<void>? _checking;

  static _ForegroundObserver? _observer;

  /// Whether the network counts the data now: the last answer while younger than [maxAge], else asked again first.
  /// Unknown counts as metered.
  static Future<bool> isMetered() async {
    refreshIfStale();
    await _checking;
    return !(unmetered.value ?? false);
  }

  /// Ask the platform again unless the last answer is younger than [maxAge] (or [force]) or a check is running;
  /// [unmetered] tells the answer.
  static void refreshIfStale({bool force = false}) {
    _watch();
    final checkedAt = _checkedAt;
    if (_checking != null || (!force && checkedAt != null && DateTime.now().difference(checkedAt) < maxAge)) {
      return;
    }
    _checking = _refresh();
  }

  /// The platform told a change itself (Android's network callback): [metered] is the new answer.
  static void handlePlatformChange({required bool metered}) {
    unmetered.value = !metered;
    _checkedAt = DateTime.now();
  }

  static Future<void> _refresh() async {
    try {
      unmetered.value = await check();
    } on Exception catch (e) {
      talker.debug('network usage: the platform did not tell, taken as metered: $e');
      unmetered.value = false;
    } finally {
      _checkedAt = DateTime.now();
      _checking = null;
    }
  }

  /// Start following the changes, once: the app back in the foreground asks again, Android pushes its changes.
  static void _watch() {
    if (_observer != null) {
      return;
    }
    _observer = _ForegroundObserver();
    WidgetsBinding.instance.addObserver(_observer!);
    if (isAndroid) {
      androidOnNetworkMeteredChanged(handlePlatformChange);
    }
  }

  /// Forget the last answer and stop following the changes (tests).
  @visibleForTesting
  static void reset() {
    unmetered.value = null;
    _checkedAt = null;
    _checking = null;
    check = _platformUnmetered;
    if (_observer != null) {
      WidgetsBinding.instance.removeObserver(_observer!);
      _observer = null;
    }
  }
}

/// Asks again when the app comes back to the foreground: the network may have changed meanwhile.
final class _ForegroundObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      NetworkUsage.refreshIfStale(force: true);
    }
  }
}

Future<bool> _platformUnmetered() async {
  if (isAndroid) {
    return !(await androidActiveNetworkMetered());
  }
  if (isIOS) {
    final interfaces = await NetworkInterface.list();
    return interfaces.any((e) => e.name.startsWith('en') && e.addresses.any((a) => !a.isLinkLocal && !a.isLoopback));
  }
  return true;
}
