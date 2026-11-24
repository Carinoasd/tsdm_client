import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/background_shop/models/background_shop.dart';
import 'package:tsdm_client/features/background_shop/repository/background_shop_repository.dart';
import 'package:tsdm_client/features/post_background/models/post_background.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// The content background an account uses (`backgrounds.content` of `bgmine`) as the account card of the "me" tab
/// draws it.
@immutable
final class AccountBackground extends Equatable {
  /// Constructor.
  const AccountBackground({required this.imageUrl, this.repeat = PostBackgroundRepeat.none, this.alignX, this.alignY});

  /// The background of [inUse]; null when there is none, it is not shown (`display` 0) or its picture is not one the
  /// app loads ([postBackgroundImageUrl]).
  static AccountBackground? of(BackgroundInUse? inUse) {
    if (inUse == null || !inUse.display) {
      return null;
    }
    final url = postBackgroundImageUrl(inUse.imageUrl);
    if (url == null) {
      return null;
    }
    return AccountBackground(
      imageUrl: url,
      repeat: switch (inUse.style.repeat) {
        'both' => PostBackgroundRepeat.both,
        'x' => PostBackgroundRepeat.x,
        'y' => PostBackgroundRepeat.y,
        _ => PostBackgroundRepeat.none,
      },
      alignX: switch (inUse.style.alignX) {
        'left' => PostBackgroundAlignX.left,
        'center' => PostBackgroundAlignX.center,
        'right' => PostBackgroundAlignX.right,
        _ => null,
      },
      alignY: switch (inUse.style.alignY) {
        'top' => PostBackgroundAlignY.top,
        'center' => PostBackgroundAlignY.center,
        'bottom' => PostBackgroundAlignY.bottom,
        _ => null,
      },
    );
  }

  /// The picture, an absolute url the app loads.
  final String imageUrl;

  /// How the member has it repeat.
  final PostBackgroundRepeat repeat;

  /// Where the member has it across, null when not told.
  final PostBackgroundAlignX? alignX;

  /// Where the member has it down, null when not told.
  final PostBackgroundAlignY? alignY;

  @override
  List<Object?> get props => [imageUrl, repeat, alignX, alignY];
}

/// The content background of each account seen in this run ([AccountBackground]), by the uid `bgmine` was served to:
/// what the account card draws. Kept in memory only.
///
/// Asked ([ensure]) when the card shows an account and what is kept is missing, older than [fresh], or stale: a write
/// of the background shop marks it so ([markStale]). Every `bgmine` the shop reads fills it too ([remember]). A failed
/// ask is not repeated before [retryAfter].
abstract final class MyContentBackground {
  /// How long an answer is used without asking again.
  static const fresh = Duration(minutes: 10);

  /// How long after a failed ask it is not asked again.
  static const retryAfter = Duration(minutes: 2);

  /// Told on every change of what is kept.
  static final ValueNotifier<int> changes = ValueNotifier(0);

  static final _kept = <int, ({AccountBackground? background, DateTime at, bool stale})>{};
  static final _failedAt = <int, DateTime>{};
  static final _asking = <int>{};

  /// Counted up by each [markStale] and [clear] of an account: an answer asked before is not kept as fresh.
  static final _generations = <int, int>{};
  static int _generation = 0;

  /// The clock; replaced in tests.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// The repository [ensure] asks with; replaced in tests.
  @visibleForTesting
  static BackgroundShopRepository Function() repository = _networkRepository;

  static BackgroundShopRepository _networkRepository() =>
      BackgroundShopRepository.network(getIt.get<NetClientProvider>());

  /// The background of the account [uid], null when it has none or nothing is known.
  static AccountBackground? of(int uid) => _kept[uid]?.background;

  /// Keep what [mine] tells of the account it was served to.
  static void remember(BackgroundMine mine) => _keep(mine.uid, AccountBackground.of(mine.content));

  static void _keep(int uid, AccountBackground? background, {int? askedAt}) {
    if (uid <= 0) {
      return;
    }
    final before = _kept[uid];
    // Asked before a write (or [clear]): kept, still stale.
    final stale = askedAt != null && askedAt != (_generations[uid] ?? 0) + _generation;
    _kept[uid] = (background: background, at: now(), stale: stale);
    _failedAt.remove(uid);
    if (before == null || before.background != background) {
      changes.value++;
    }
  }

  /// A write of the background shop for [uid] was sent: asked again the next time the card shows it. What is kept is
  /// drawn until then.
  static void markStale(int uid) {
    _generations[uid] = (_generations[uid] ?? 0) + 1;
    final kept = _kept[uid];
    if (kept != null) {
      _kept[uid] = (background: kept.background, at: kept.at, stale: true);
    }
    _failedAt.remove(uid);
  }

  /// Ask `bgmine` for [uid] unless what is kept is fresh, it is on its way or failed lately. Only while [uid] is the
  /// account logged in ([currentLoginUid]): the answer of another account is never kept for it.
  static void ensure(int uid) {
    if (uid <= 0 || currentLoginUid() != uid || _asking.contains(uid)) {
      return;
    }
    final at = now();
    final kept = _kept[uid];
    if (kept != null && !kept.stale && at.difference(kept.at) < fresh) {
      return;
    }
    final failed = _failedAt[uid];
    if (failed != null && at.difference(failed) < retryAfter) {
      return;
    }
    _asking.add(uid);
    unawaited(_ask(uid));
  }

  static Future<void> _ask(int uid) async {
    final askedAt = (_generations[uid] ?? 0) + _generation;
    try {
      switch (await repository().mine()) {
        // [BackgroundShopRepository.mine] kept it ([remember]); stale again when a write came in between.
        case BackgroundShopLoaded():
          if (askedAt != (_generations[uid] ?? 0) + _generation) {
            final kept = _kept[uid];
            if (kept != null) {
              _kept[uid] = (background: kept.background, at: kept.at, stale: true);
            }
          }
        case BackgroundShopUnavailable():
          _keep(uid, null, askedAt: askedAt);
      }
    } on Object {
      // Another account now, logged out, no answer: nothing kept, asked again later.
      _failedAt[uid] = now();
    } finally {
      _asking.remove(uid);
    }
  }

  /// Forget everything (for tests): an answer on its way is kept stale.
  static void clear() {
    final had = _kept.isNotEmpty;
    _generation++;
    _kept.clear();
    _failedAt.clear();
    if (had) {
      changes.value++;
    }
  }
}
