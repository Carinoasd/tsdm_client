import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Repository of the latest thread feature.
class LatestThreadRepository {
  /// Fetch html document from [url].
  AsyncEither<uh.Document> fetchDocument(String url) {
    // The url is handed over as a route parameter; only forum urls are fetched, on the canonical https host.
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isForumOrRelative) {
      return AsyncEither.left(HttpRequestFailedException(null));
    }
    return getIt
        .get<NetClientProvider>()
        .get(url.canonicalForumUrl())
        .mapHttp((v) => parseHtmlDocument(v.data as String));
  }
}
