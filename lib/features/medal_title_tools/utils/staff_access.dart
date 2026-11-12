import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/medal_title_tools/repository/medal_title_tools_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// What an account may do with the medal and title tools.
typedef StaffTools = ({bool grant, bool issue});

/// Whether an account may send medals and issue titles, asked once per account and kept for ten minutes.
///
/// The answers carry the whole medal list and the latest sendings, too much to read each time a page that links the
/// tools opens. Callers outside the medal centre must ask only accounts of a management group, so an ordinary member
/// never sends these requests.
abstract final class StaffToolsAccess {
  /// How long an answer is kept.
  static const _keep = Duration(minutes: 10);

  static final _known = <int, ({StaffTools can, DateTime at})>{};
  static final _asking = <int, Future<StaffTools?>>{};

  /// The kept answer for [uid], null when none is kept or it is stale.
  static StaffTools? cached(int uid) {
    final known = _known[uid];
    if (known == null || DateTime.now().difference(known.at) >= _keep) {
      return null;
    }
    return known.can;
  }

  /// Whether [uid] may send medals and issue titles; null when the forum could not tell (nothing is kept then).
  ///
  /// Asks with [repository], the account's client otherwise. Calls for the same account while one is on its way share
  /// its answer.
  static Future<StaffTools?> check(int uid, {MedalTitleToolsRepository? repository}) {
    final kept = cached(uid);
    if (kept != null) {
      return Future.value(kept);
    }
    return _asking[uid] ??= _ask(uid, repository).whenComplete(() => unawaited(_asking.remove(uid)));
  }

  static Future<StaffTools?> _ask(int uid, MedalTitleToolsRepository? repository) async {
    final repo = repository ?? MedalTitleToolsRepository.network(getIt.get<NetClientProvider>());
    try {
      final grant = await repo.grant();
      final issue = await repo.issue();
      final can = (grant: grant?.canGrant ?? false, issue: issue?.canIssue ?? false);
      _known[uid] = (can: can, at: DateTime.now());
      return can;
    } on Exception {
      return null;
    }
  }

  /// Forget everything kept.
  @visibleForTesting
  static void reset() {
    _known.clear();
    _asking.clear();
  }
}
