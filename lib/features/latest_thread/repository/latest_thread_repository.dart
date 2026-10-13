import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;

/// Repository of the latest thread feature.
class LatestThreadRepository {
  /// Fetch html document from [url].
  ///
  /// The pages are asked in the JSON mode of the forum's app API (roadmap item 3): the forum search of "查看新帖"
  /// (`srchfrom`, its redirect to the results carried by the plugin) since plugin 1.3.0, the guide lists since 1.6.0.
  /// An older plugin, or a forum without it, answers the web page, which parses the same.
  AsyncEither<uh.Document> fetchDocument(String url) {
    // The url is handed over as a route parameter; only forum urls are fetched, on the canonical https host.
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isForumOrRelative) {
      return AsyncEither.left(HttpRequestFailedException(null));
    }
    return getIt
        .get<NetClientProvider>()
        .get(withTsdmAppJson(url.canonicalForumUrl()))
        .mapHttp((v) => tsdmAppPageDocument(v.data));
  }
}
