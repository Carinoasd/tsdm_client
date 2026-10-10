import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/title_shop/models/title_shop.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

/// The served page belongs to another account or to a guest.
final class TitleShopIdentityException implements Exception {
  /// Constructor.
  const TitleShopIdentityException({required this.guest});

  /// The page was served to a guest: the session expired.
  final bool guest;
}

/// Title shop access bound to one network client's account. Never retries a purchase POST.
class TitleShopRepository {
  /// Injected transports allow purchases to be tested without a live account.
  TitleShopRepository({required this.getPage, required this.postForm, this.askApi});

  /// Uses the account-bound client; the purchase is a single attempt that follows no redirect.
  factory TitleShopRepository.network(NetClientProvider client) => TitleShopRepository(
    // JSON mode of the forum's app API when the forum has it (see TsdmAppApi); the web page otherwise.
    getPage: (url) async => switch (await client.get(withTsdmAppJson(url)).run()) {
      Right(:final value) => tsdmAppPageHtml(value.data),
      Left(:final value) => throw value,
    },
    postForm: (url, body) async => switch (await client.postForm(url, data: body, singleAttempt: true).run()) {
      Right(:final value) => value.data as String,
      Left(:final value) => throw value,
    },
    askApi: (query) => TsdmAppApi.askWaiting(client, 'titleshop', query),
  );

  /// The forum's app API (`titleshop`), asked first when set; null answers fall back to [getPage].
  final Future<Map<String, dynamic>?> Function(Map<String, String> query)? askApi;

  /// Reads shop pages only.
  final Future<String> Function(String url) getPage;

  /// Sends one explicitly confirmed purchase.
  final Future<String> Function(String url, Map<String, String> body) postForm;

  /// Fetch a validated shop page served to [uid].
  Future<TitleShopCatalog> fetchPage(String url, int uid) async {
    final safe = titleShopPageUrl(url);
    if (safe == null || uid <= 0) throw const FormatException('Title shop page refused');
    if (askApi case final ask?) {
      final page = Uri.parse(safe).queryParameters['page'];
      final json = await ask({'page': ?page});
      if (titleShopFromApi(json) case final catalog?) {
        final served = (json!['uid'] as num?)?.toInt() ?? 0;
        if (served != uid) throw TitleShopIdentityException(guest: served == 0);
        return catalog;
      }
      if (json != null && json['ok'] == 0 && json['error'] == 'login') {
        throw const TitleShopIdentityException(guest: true);
      }
    }
    final document = parseHtmlDocument(await getPage(safe));
    final served = parseLoggedUidFromDocument(document);
    if (served != uid) throw TitleShopIdentityException(guest: served == null);
    return parseTitleShop(document);
  }

  /// Post [form] once. A response, even HTTP 200, is not proof of a purchase; the caller verifies by GET.
  Future<({bool error, String? message})> buy(TitleBuyForm form) async =>
      parseTitleBuyResponse(parseHtmlDocument(await postForm(form.url, form.body())));
}
