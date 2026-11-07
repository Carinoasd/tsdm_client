import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/trade/models/trade_models.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

/// A page of the forum read for buying: the page (`page`, null when it is not one) or the forum's `message` instead
/// (closed, not found, log in).
typedef TradePage<T> = ({T? page, String? message});

/// Reads a goods page and its order form, places the order and pays it (the forum's guaranteed trade of a goods sold
/// for credit). The two writes are sent once each (no transport retry, no redirect followed); the password of the
/// payment is only in the body of its request, never kept nor logged.
final class TradeRepository {
  /// Constructor; tests inject their transports.
  const TradeRepository({required this.getPage, required this.postForm});

  /// The app's client. The pages are read as web pages: the plugin's JSON mode gives nothing of them. The forms are
  /// posted with the result parameter of the forum's app API ([NetClientProvider.postForm]).
  factory TradeRepository.network(NetClientProvider client) => TradeRepository(
    getPage: (url) async => switch (await client.get(url).run()) {
      Right(:final value) => tsdmAppAnswerText(value.data),
      Left(:final value) => throw value,
    },
    postForm: (url, body) async => switch (await client.postForm(url, data: body, singleAttempt: true).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
  );

  /// GET: the page's html; throws when the request failed.
  final Future<String> Function(String url) getPage;

  /// POST, once: the forum's answer; throws when the request failed.
  final Future<Object?> Function(String url, Map<String, String> body) postForm;

  /// The goods page of the goods [pid] of the thread [tid].
  Future<TradePage<TradeGoodsDetail>> fetchGoods({required int tid, required int pid}) async {
    final document = parseHtmlDocument(await getPage(tradeGoodsUrl(tid: tid, pid: pid)));
    final detail = TradeGoodsDetail.parse(document);
    return (page: detail, message: detail == null ? tradeMessageOf(document) : null);
  }

  /// The order form at [url] (the goods page's [TradeGoodsDetail.buyUrl]).
  Future<TradePage<TradeBuyForm>> fetchBuyForm(String url) async {
    final document = parseHtmlDocument(await getPage(url));
    final form = TradeBuyForm.parse(document);
    return (page: form, message: form == null ? tradeMessageOf(document) : null);
  }

  /// Place the order [body] ([TradeBuyForm.orderBody]) of [form].
  Future<TradeOutcome> order(TradeBuyForm form, Map<String, String> body) async {
    try {
      return tradeOrderOutcomeOf(await postForm(form.action, body));
    } on Exception catch (e) {
      talker.warning('trade order failed: ${form.action}: $e');
      return const TradeUnknown();
    }
  }

  /// Pay the order [orderId] with the account's login [password].
  Future<TradeOutcome> pay({required String orderId, required String formHash, required String password}) async {
    final url = tradeOrderUrl(orderId);
    try {
      return tradePayOutcomeOf(await postForm(url, tradePayBody(formHash: formHash, password: password)));
    } on Exception catch (e) {
      // The url only: the body carries the password.
      talker.warning('trade payment failed: $url: ${e.runtimeType}');
      return const TradeUnknown();
    }
  }
}
