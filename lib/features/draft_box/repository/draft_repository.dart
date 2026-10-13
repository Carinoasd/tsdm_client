import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/draft_box/models/draft_data.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Read-only access bound to one account's network client.
class DraftRepository {
  /// Injectable transport for deterministic tests.
  DraftRepository(this.getPage);

  /// Production transport.
  ///
  /// Pages are asked in the JSON mode of the forum's app API (roadmap item 3): the draft list (`do=thread`) since
  /// plugin 1.6.0, the draft thread since 1.4.0. Both keep the `discuz_uid` the identity check reads; an older plugin
  /// answers the web page. A JSON answer without a page ([tsdmAppAnswerWithoutPage]: the plugin failed to build it, or
  /// an empty body) is a failed request, not a page without the account, which the check would take for an expired
  /// session.
  factory DraftRepository.network(NetClientProvider client) => DraftRepository(
    (url) async => switch (await client.get(withTsdmAppJson(url)).run()) {
      Right(:final value) when tsdmAppAnswerWithoutPage(value.data) => throw HttpRequestFailedException(
        value.statusCode,
      ),
      Right(:final value) => tsdmAppPageHtml(value.data),
      Left(:final value) => throw value,
    },
  );

  /// No POST is performed by this repository.
  final Future<String> Function(String url) getPage;

  Future<uh.Document> _fetch(String url, int uid) async {
    final document = parseHtmlDocument(await getPage(url));
    if (uid <= 0 || parseLoggedUidFromDocument(document) != uid) {
      throw const FormatException('Draft login expired');
    }
    return document;
  }

  /// Fetch a validated page of drafts.
  Future<DraftPage> load(int uid, {int page = 1}) async => parseDraftPage(
    await _fetch(draftBoxUrl(page: page), uid),
    page: page,
    uid: uid,
  );

  /// Resolve an existing draft through GET only.
  Future<DraftEditTarget> resolve(DraftEntry entry, int uid) async =>
      parseDraftTarget(await _fetch(entry.url, uid), entry);
}
