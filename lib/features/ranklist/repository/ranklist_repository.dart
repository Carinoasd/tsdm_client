import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/ranklist/models/ranklist.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

/// Repository of the forum's rankings.
///
/// The forum's app API has no answer for the rankings (plugin 3.4.0), the web page is parsed.
class RanklistRepository {
  /// Constructor; [fetchHtml] replaces the network (tests).
  RanklistRepository({AsyncEither<String> Function(String url)? fetchHtml}) : _fetchHtml = fetchHtml ?? _fetchNetwork;

  final AsyncEither<String> Function(String url) _fetchHtml;

  static AsyncEither<String> _fetchNetwork(String url) =>
      getIt.get<NetClientProvider>().get(url).mapHttp((resp) => '${resp.data}');

  /// Fetch and parse the ranking page [url].
  ///
  /// A ranking the forum turned off (`排行榜功能关闭`, `此排行功能已关闭`) is its 提示信息 page: a
  /// [ServerRespondedErrorException] with the forum's words.
  AsyncEither<RanklistData> fetch(String url) =>
      _fetchHtml(url).flatMap((html) => parseRanklistAnswer(html).toTaskEither());
}

/// The ranking page in the forum's answer [html], or why there is none.
Either<AppException, RanklistData> parseRanklistAnswer(String html) {
  final document = parseHtmlDocument(html);
  final page = parseRanklistPage(document);
  if (page.isEmpty) {
    if (ranklistServerMessage(document) case final message?) {
      return left(ServerRespondedErrorException(message));
    }
  }
  return right(page);
}
