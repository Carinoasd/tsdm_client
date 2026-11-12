import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// Whether an account may rate in batches in a forum, or read the batches, kept for ten minutes per account and forum:
/// `status` first (`batchrate: 1`, tsdmapp 3.9.0), then `action=batchrate` (with the forum) only when it says so.
///
/// Callers ask only for a moderator of the forum (the forum's and the thread's own check) or an account of a management
/// group (the panel), so an ordinary member never sends these requests.
abstract final class BatchRateAccess {
  static const _keep = Duration(minutes: 10);

  static final _status = <int, ({bool on, DateTime at})>{};
  static final _known = <String, ({BatchRateInfo info, DateTime at})>{};
  static final _asking = <String, Future<BatchRateInfo?>>{};

  static String _key(int uid, int? fid) => '$uid:${fid ?? ''}';

  /// The kept answer for [uid] in forum [fid] (none: the batches), null when none is kept or it is stale.
  static BatchRateInfo? cached(int uid, {int? fid}) {
    final known = _known[_key(uid, fid)];
    if (known == null || DateTime.now().difference(known.at) >= _keep) {
      return null;
    }
    return known.info;
  }

  /// What [uid] may do in forum [fid] (none: whether it may read the batches); null when `status` says batch rating is
  /// off for the account, or the forum could not tell (nothing is kept then).
  ///
  /// [status] asks `status` of the app API, [repository] asks `batchrate`; the account's client when null. Calls for
  /// the same account and forum while one is on its way share its answer. When [stillCurrent] says the account is no
  /// longer in use once the forum has answered, the answer is dropped and nothing is kept.
  static Future<BatchRateInfo?> check(
    int uid, {
    int? fid,
    Future<Map<String, dynamic>?> Function()? status,
    BatchRateRepository? repository,
    bool Function()? stillCurrent,
  }) {
    final kept = cached(uid, fid: fid);
    if (kept != null) {
      return Future.value(kept);
    }
    final key = _key(uid, fid);
    return _asking[key] ??= _ask(uid, fid, status, repository, stillCurrent).whenComplete(
      () => unawaited(_asking.remove(key)),
    );
  }

  static Future<BatchRateInfo?> _ask(
    int uid,
    int? fid,
    Future<Map<String, dynamic>?> Function()? status,
    BatchRateRepository? repository,
    bool Function()? stillCurrent,
  ) async {
    try {
      final known = _status[uid];
      bool on;
      if (known != null && DateTime.now().difference(known.at) < _keep) {
        on = known.on;
      } else {
        final askStatus = status ?? () => TsdmAppApi.askWaiting(getIt.get<NetClientProvider>(), 'status');
        final flags = await askStatus();
        if (flags == null || flags['ok'] != 1 || tsdmAppInt(flags['uid']) != uid) {
          return null;
        }
        on = flags['batchrate'] == 1;
        if (!(stillCurrent?.call() ?? true)) {
          return null;
        }
        _status[uid] = (on: on, at: DateTime.now());
      }
      if (!on) {
        return null;
      }
      final repo = repository ?? BatchRateRepository.network(getIt.get<NetClientProvider>());
      final info = await repo.info(fid: fid);
      if (info == null || !(stillCurrent?.call() ?? true) || info.uid != uid) {
        return null;
      }
      _known[_key(uid, fid)] = (info: info, at: DateTime.now());
      return info;
    } on Exception {
      return null;
    }
  }

  /// Forget the answers kept for [uid] in forum [fid] (none: the batches): the quota changed (a batch was made).
  static void forget(int uid, {int? fid}) => _known.remove(_key(uid, fid));

  /// Forget everything kept.
  @visibleForTesting
  static void reset() {
    _status.clear();
    _known.clear();
    _asking.clear();
  }
}
