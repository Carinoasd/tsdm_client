import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Whether the network in use now counts the data, as the pictures of the posts that load by themselves "on Wi-Fi
/// only" (`PostImageAutoLoad.wifiOnly`) ask it: the only place they ask.
///
/// Shaped as the app-wide `NetworkUsage` (`lib/utils/network_usage.dart`, coming with the thread list previews), which
/// takes over once it is in: [unmetered] is its `unmetered`, [refreshIfStale] its `refreshIfStale`. Until then the
/// desktop platforms are unmetered and the phones count as metered (unknown counts as metered): pictures wait for a
/// tap there.
abstract final class ImageNetwork {
  static final _unmetered = ValueNotifier<bool?>(null);

  /// The last answer: true on a network that does not count the data, null until the first one came.
  static ValueListenable<bool?> get unmetered => _unmetered;

  /// How the platform is asked (tests replace it).
  @visibleForTesting
  static Future<bool> Function() check = _platformUnmetered;

  static Future<void>? _checking;

  /// Ask again unless an answer is there or a check runs; [unmetered] tells the answer.
  static void refreshIfStale() {
    if (_checking != null || _unmetered.value != null) {
      return;
    }
    _checking = _refresh();
  }

  static Future<void> _refresh() async {
    try {
      _unmetered.value = await check();
    } on Exception catch (_) {
      _unmetered.value = false;
    } finally {
      _checking = null;
    }
  }

  /// Forget the answer (tests).
  @visibleForTesting
  static void reset() {
    _unmetered.value = null;
    _checking = null;
    check = _platformUnmetered;
  }
}

Future<bool> _platformUnmetered() async => isDesktop;
