import 'dart:async';
import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/method_channel.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Whether the device is on a network that does not count the data (Wi-Fi, Ethernet), for the settings that load
/// images there only ("on Wi-Fi only": the thumbnails of the thread lists).
///
/// * Android: the system's own answer (`ConnectivityManager.isActiveNetworkMetered`): mobile data, a hotspot and a
///   Wi-Fi the user marked metered count, as does no network at all.
/// * iOS: on Wi-Fi when a Wi-Fi interface (`en…`) holds an address that is not link-local.
/// * The desktop platforms: never metered.
///
/// [unmetered] keeps the last answer for every widget that asks, and is asked again ([refreshIfStale]) when it is
/// older than [maxAge]; an answer that fails counts as metered.
abstract final class NetworkUsage {
  /// The last answer: true on a network that does not count the data, null until the first one came.
  static final ValueNotifier<bool?> unmetered = ValueNotifier(null);

  /// How long an answer holds before the next widget that asks checks again.
  static const maxAge = Duration(seconds: 20);

  /// How the platform is asked (tests replace it).
  @visibleForTesting
  static Future<bool> Function() check = _platformUnmetered;

  static DateTime? _checkedAt;

  static Future<void>? _checking;

  /// Ask the platform again unless the last answer is younger than [maxAge] or a check is running; [unmetered] tells
  /// the answer.
  static void refreshIfStale() {
    final checkedAt = _checkedAt;
    if (_checking != null || (checkedAt != null && DateTime.now().difference(checkedAt) < maxAge)) {
      return;
    }
    _checking = _refresh();
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

  /// Forget the last answer (tests).
  @visibleForTesting
  static void reset() {
    unmetered.value = null;
    _checkedAt = null;
    _checking = null;
    check = _platformUnmetered;
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
