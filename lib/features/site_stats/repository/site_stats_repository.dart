import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/site_stats/models/site_stats.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

/// Repository of the forum's statistics (`misc.php?mod=stat`).
///
/// The forum's app API has no answer for them (plugin 3.7.0 answers the web page), the web page is parsed.
class SiteStatsRepository {
  /// Constructor; [fetchText] replaces the network (tests).
  SiteStatsRepository({AsyncEither<String> Function(String url)? fetchText}) : _fetchText = fetchText ?? _fetchNetwork;

  final AsyncEither<String> Function(String url) _fetchText;

  /// The first page of the statistics: 基本概况.
  static const String basicUrl = '$baseUrl/misc.php?mod=stat';

  /// Whether [url] is a page of the statistics on the forum: only those are asked (with the account's session) for a
  /// url the page was given.
  static bool isStatsUrl(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.scheme == 'https' &&
        (uri.host == baseHost || uri.host == baseHostAlt) &&
        uri.path == '/misc.php' &&
        uri.queryParameters['mod'] == 'stat';
  }

  static AsyncEither<String> _fetchNetwork(String url) =>
      getIt.get<NetClientProvider>().get(url).mapHttp((resp) => '${resp.data}');

  /// Fetch and parse the statistics page [url], with its trend when the page loads one from the forum.
  ///
  /// A group that may not see the statistics (only the administrators may, by default) gets the forum's message
  /// instead ("抱歉，您所在的用户组(游客)无法进行此操作"): a [ServerRespondedErrorException] with its words. An answer
  /// that is neither is an empty page (no title, no tables). A trend that fails to load leaves the page without it.
  AsyncEither<SiteStatsData> fetch(String url) => _fetchText(url).flatMap((html) {
    final document = parseHtmlDocument(html);
    final page = parseSiteStatsPage(document);
    if (page == null) {
      // Neither a statistics page nor the forum's message: nothing to show.
      return switch (siteStatsServerMessage(document)) {
        final message? => TaskEither.left(ServerRespondedErrorException(message)),
        null => TaskEither.right(const SiteStatsData(title: '')),
      };
    }
    final chartUrl = page.chartUrl;
    // The page names where its trend is; only a statistics page of the forum is asked with the session.
    if (chartUrl == null || !isStatsUrl(chartUrl)) {
      return TaskEither.right(page);
    }
    return TaskEither(
      () async => right(
        (await _fetchText(
          chartUrl,
        ).run()).match((_) => page.withChart(null), (xml) => page.withChart(parseSiteStatsChart(xml))),
      ),
    );
  });
}
