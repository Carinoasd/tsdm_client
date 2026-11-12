import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/background_grant/models/background_grant.dart';
import 'package:tsdm_client/features/background_grant/repository/background_grant_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// What the forum's app API (plugin 3.9.0) offers an account of a management group beside the panel's own pages:
/// sending backgrounds (`bggrant`, the background plugin's own rule) and the panel's report page in the JSON mode
/// (`modcp_report`).
typedef PanelTools = ({bool background, bool modcpReport});

/// Whether an account may send backgrounds and the panel's report page is offered, asked once per account and kept for
/// ten minutes: `status` first, then `bggrant` only when `status` says the background plugin is on.
///
/// Callers ask only for accounts of a management group (the panel, the admin menu of a profile), so an ordinary member
/// never sends these requests.
abstract final class PanelToolsAccess {
  static const _keep = Duration(minutes: 10);

  /// How long the first page of the catalogue read for the answer is handed to the sending page.
  static const _fresh = Duration(seconds: 60);

  static final _known = <int, ({PanelTools can, DateTime at})>{};
  static final _asking = <int, Future<PanelTools?>>{};
  static final _pages = <int, ({BackgroundGrantInfo info, DateTime at})>{};
  static final _modcpPages = <int, ({Set<String> pages, DateTime at})>{};

  /// The panel's pages the forum answers as fields for [uid] (`status.modcp_pages`, plugin 3.9.0: `log`, `report`,
  /// `thread`, `forumaccess`, `home`), as last asked by [check]; null when none is kept or it is stale.
  static Set<String>? modcpPages(int uid) {
    final known = _modcpPages[uid];
    if (known == null || DateTime.now().difference(known.at) >= _keep) {
      return null;
    }
    return known.pages;
  }

  /// The kept answer for [uid], null when none is kept or it is stale.
  static PanelTools? cached(int uid) {
    final known = _known[uid];
    if (known == null || DateTime.now().difference(known.at) >= _keep) {
      return null;
    }
    return known.can;
  }

  /// The first page of the catalogue read for [uid]'s answer in the last minute, once: the sending page opened right
  /// after the entry was shown does not ask again (the plugin answers a second ask that soon "too soon").
  static BackgroundGrantInfo? takeFirstPage(int uid) {
    final kept = _pages.remove(uid);
    if (kept == null || DateTime.now().difference(kept.at) >= _fresh || kept.info.uid != uid) {
      return null;
    }
    return kept.info;
  }

  /// What [uid] is offered; null when the forum could not tell (nothing is kept then).
  ///
  /// [status] asks `status` of the app API, [backgrounds] reads `bggrant`; the account's client when null. Calls for
  /// the same account while one is on its way share its answer. When [stillCurrent] says the account is no longer in
  /// use once the forum has answered, the answer is dropped and nothing is kept.
  static Future<PanelTools?> check(
    int uid, {
    Future<Map<String, dynamic>?> Function()? status,
    BackgroundGrantRepository? backgrounds,
    bool Function()? stillCurrent,
  }) {
    final kept = cached(uid);
    if (kept != null) {
      return Future.value(kept);
    }
    return _asking[uid] ??= _ask(
      uid,
      status,
      backgrounds,
      stillCurrent,
    ).whenComplete(() => unawaited(_asking.remove(uid)));
  }

  static Future<PanelTools?> _ask(
    int uid,
    Future<Map<String, dynamic>?> Function()? status,
    BackgroundGrantRepository? backgrounds,
    bool Function()? stillCurrent,
  ) async {
    try {
      final askStatus = status ?? () => TsdmAppApi.askWaiting(getIt.get<NetClientProvider>(), 'status');
      final flags = await askStatus();
      if (flags == null || flags['ok'] != 1) {
        return null;
      }
      BackgroundGrantInfo? info;
      if (flags['bggrant'] == 1) {
        final repo = backgrounds ?? BackgroundGrantRepository.network(getIt.get<NetClientProvider>());
        info = await repo.load();
      }
      if (!(stillCurrent?.call() ?? true)) {
        return null;
      }
      final can = (background: info?.canGrant ?? false, modcpReport: flags['modcp_report'] == 1);
      _modcpPages[uid] = (
        pages: {
          for (final page in flags['modcp_pages'] is List ? flags['modcp_pages'] as List : const <Object?>[])
            if (page is String) page,
        },
        at: DateTime.now(),
      );
      // A catalogue that could not be read tells nothing about sending: shown without it this time, asked again later.
      if (flags['bggrant'] != 1 || info != null) {
        _known[uid] = (can: can, at: DateTime.now());
      }
      if (info != null && info.usable) {
        _pages[uid] = (info: info, at: DateTime.now());
      }
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
    _pages.clear();
    _modcpPages.clear();
  }
}
