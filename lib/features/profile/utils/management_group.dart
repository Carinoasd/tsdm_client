import 'dart:async';

import 'package:flutter/foundation.dart';

/// Whether an account is of a management group (管理组), kept per account for ten minutes.
///
/// The admin entries of other members' profiles are for these accounts only; every other account must not send
/// further requests for them, so the answer is read from the account's own profile once and shared.
abstract final class ManagementGroupCache {
  static const _keep = Duration(minutes: 10);

  static final _known = <int, ({bool value, DateTime at})>{};
  static final _asking = <int, Future<bool?>>{};

  /// The kept answer for [uid], null when none is kept or it is stale.
  static bool? cached(int uid) {
    final known = _known[uid];
    if (known == null || DateTime.now().difference(known.at) >= _keep) {
      return null;
    }
    return known.value;
  }

  /// Keep [value] for [uid] (the "me" page has read the profile already).
  static void remember(int uid, {required bool value}) => _known[uid] = (value: value, at: DateTime.now());

  /// Whether [uid] is of a management group; asks [load] (true when the profile shows a management group, null when
  /// it could not be read) unless an answer is kept. Calls for the same account while one is on its way share it.
  static Future<bool?> check(int uid, Future<bool?> Function() load) {
    final kept = cached(uid);
    if (kept != null) {
      return Future.value(kept);
    }
    return _asking[uid] ??= () async {
      try {
        final value = await load();
        if (value != null) {
          remember(uid, value: value);
        }
        return value;
      } on Exception {
        return null;
      } finally {
        unawaited(_asking.remove(uid));
      }
    }();
  }

  /// Forget everything kept.
  @visibleForTesting
  static void reset() {
    _known.clear();
    _asking.clear();
  }
}
