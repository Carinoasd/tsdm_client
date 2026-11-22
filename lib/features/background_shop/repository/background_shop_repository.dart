import 'dart:async';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/background_shop/models/background_shop.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// A write got no answer at all (a timeout, no network): the forum may still be carrying it out.
final class BackgroundShopNoAnswer implements Exception {
  /// Constructor.
  const BackgroundShopNoAnswer();
}

/// The forum asked to log in: the session of the account ended.
final class BackgroundShopLoginRequired implements Exception {
  /// Constructor.
  const BackgroundShopLoginRequired();
}

/// Reads the member's pages of the background shop (`bgmine`, `bgstore`, `bgslot`, `bgexchange` of the app API, plugin
/// 4.1.0) and sends the background plugin's own forms back to it, bound to the account logged in: an answer served to
/// another account is dropped and nothing is sent once the account changed ([IdentityChangedException]).
///
/// Every write is sent once ([postTsdmAppV4], [getTsdmAppV4Write]: no transport retry), and only when the user asked
/// for it; the two that are GETs carrying the form hash are never asked by anything else.
class BackgroundShopRepository {
  /// Transports are injected so the pages are tested without a forum.
  BackgroundShopRepository({
    required this.ask,
    required this.post,
    required this.get,
    this.onUnknown,
    int Function()? currentUid,
  }) : _currentUid = currentUid ?? currentLoginUid;

  /// Uses the account-bound [client].
  factory BackgroundShopRepository.network(NetClientProvider client) => BackgroundShopRepository(
    // Each action has its own interval on the plugin; an answer "too soon" is waited for ([TsdmAppApi.askWaiting]).
    ask: (action, query) => TsdmAppApi.askWaiting(client, action, query),
    post: (url, data) async => switch (await postTsdmAppV4(client, url, data).run()) {
      Right(:final value) => value,
      // The forum's HTTP 503 page of a stale form hash is an answer (not JSON); a timeout is none.
      Left() => throw const BackgroundShopNoAnswer(),
    },
    get: (url) async => switch (await getTsdmAppV4Write(client, url).run()) {
      Right(:final value) => value,
      Left() => throw const BackgroundShopNoAnswer(),
    },
    // The page of a background plugin switched off is not JSON either: what `status` says is asked again (the "me"
    // tab's entry follows it).
    onUnknown: () {
      TsdmAppApi.forgetStatus();
      unawaited(TsdmAppApi.ensureStatus(client));
    },
  );

  /// Ask an action of the app API with the query given; null when it can not answer.
  final Future<Map<String, dynamic>?> Function(String action, Map<String, String> query) ask;

  /// POST a form once with `tsdmapp=json&tsdmv=4`; the answer as it came; [BackgroundShopNoAnswer] for none.
  final Future<Object?> Function(String url, Map<String, String> data) post;

  /// Send a GET that writes once with `tsdmapp=json&tsdmv=4`; the answer as it came; [BackgroundShopNoAnswer] for
  /// none.
  final Future<Object?> Function(String url) get;

  /// Told when a write was answered with something that is not a write result ([BackgroundShopUnknown]); not for a
  /// write without an answer ([BackgroundShopNoAnswer]), which tells nothing of the plugin.
  final void Function()? onUnknown;

  final int Function() _currentUid;

  Future<BackgroundShopAnswer<T>> _load<T>(
    String action,
    Map<String, String> query,
    BackgroundShopAnswer<T>? Function(Map<String, dynamic>? json) parse,
  ) async {
    final uid = _currentUid();
    if (uid <= 0) throw const BackgroundShopLoginRequired();
    final json = await ask(action, query);
    if (json != null && json['ok'] == 0 && json['error'] == 'login') {
      if (_currentUid() != uid) throw IdentityChangedException();
      throw const BackgroundShopLoginRequired();
    }
    final answer = parse(json);
    if (answer == null) throw const FormatException('background shop answer not usable');
    final served = tsdmAppInt(json?['uid']);
    if (_currentUid() != uid || (served != 0 && served != uid)) throw IdentityChangedException();
    if (answer is BackgroundShopLoaded<T> && served != uid) throw IdentityChangedException();
    return answer;
  }

  /// My backgrounds.
  Future<BackgroundShopAnswer<BackgroundMine>> mine() => _load('bgmine', const {}, BackgroundMine.fromJson);

  /// Page [page] of the shop in [mode], filtered by [keyword] when not empty.
  Future<BackgroundShopAnswer<BackgroundStore>> store({
    BackgroundStoreMode mode = BackgroundStoreMode.shop,
    String keyword = '',
    int page = 1,
  }) => _load('bgstore', {
    if (mode == BackgroundStoreMode.special) 'mode': 'special',
    if (keyword.isNotEmpty) 'kw': keyword,
    if (page > 1) 'page': '$page',
  }, BackgroundStore.fromJson);

  /// Page [page] of the storeroom.
  Future<BackgroundShopAnswer<BackgroundSlots>> slots({int page = 1}) =>
      _load('bgslot', {if (page > 1) 'page': '$page'}, BackgroundSlots.fromJson);

  /// The exchange by medals.
  Future<BackgroundShopAnswer<BackgroundExchange>> exchange() =>
      _load('bgexchange', const {}, BackgroundExchange.fromJson);

  Future<BackgroundShopOutcome> _write(int uid, BackgroundShopWrite write, Future<Object?> Function() send) async {
    if (uid <= 0 || _currentUid() != uid) throw IdentityChangedException();
    final data = await send();
    final outcome = backgroundShopOutcomeOf(data, write, uid: uid);
    if (outcome == null || _currentUid() != uid) throw IdentityChangedException();
    if (outcome is BackgroundShopUnknown && !outcome.answered) {
      onUnknown?.call();
    }
    return outcome;
  }

  /// Save the display form [form] of a background (of the page served to [uid]) with [values] ([BackgroundStyleFields]).
  Future<BackgroundShopOutcome> saveStyle(int uid, BackgroundStyleForm form, Map<String, String> values) =>
      _write(uid, BackgroundShopWrite.style, () => post(form.url, form.body(values)));

  /// Buy [item] for [position] with [offer] for [months], with the form of the page served to [uid].
  Future<BackgroundShopOutcome> buy(
    int uid,
    BackgroundBuyForm form,
    BackgroundStoreItem item,
    BackgroundPosition position,
    BackgroundOffer offer,
    int months,
  ) => _write(uid, BackgroundShopWrite.buy, () => post(form.target(item, position), form.body(offer, months)));

  /// Put [slot] in use at [position], from page [page] of the storeroom served to [uid].
  Future<BackgroundShopOutcome> useSlot(
    int uid,
    BackgroundSlotForm form,
    BackgroundSlot slot,
    BackgroundPosition position,
    int page,
  ) => _write(uid, BackgroundShopWrite.slot, () => get(form.target(slot, position, page)));

  /// Exchange [campaign] for background [bgid], with the form of the page served to [uid].
  Future<BackgroundShopOutcome> exchangeFor(
    int uid,
    BackgroundExchangeForm form,
    BackgroundCampaign campaign,
    int bgid,
  ) => _write(uid, BackgroundShopWrite.exchange, () => get(form.target(campaign, bgid)));
}
