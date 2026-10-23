import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/search/utils/search_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/list_preview.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Query parameters of a new forum search, see [SearchRepository] for the meaning of each one.
Map<String, String> buildSearchQuery({
  required String keyword,
  required String fid,
  required String uid,
  required String authorName,
  required int pageNumber,
}) => <String, String>{
  'mod': 'forum',
  'srchtxt': keyword,
  if (authorName.isNotEmpty) 'srchuname': authorName,
  if (uid.isNotEmpty && uid != '0') 'srchuid': uid,
  if (fid.isNotEmpty && fid != '0') 'srchfid[]': fid,
  'searchsubmit': 'yes',
  if (pageNumber > 1) 'page': '$pageNumber',
};

/// Seconds to wait before searching again, when the forum's refusal [message] says the search came too early: "抱歉，
/// 您在 20 秒内只能进行一次搜索" (the site's `searchctrl`, 20 seconds on TSDM) gives its seconds, "搜索过于频繁" and the
/// site's searches per minute limit ("每分钟系统最多响应搜索请求") 20 and 60. Null for any other message.
int? searchRateLimitSeconds(String message) {
  // The forum's language pack may be simplified or traditional Chinese.
  final seconds = RegExp(r'(\d+)\s*秒[内內]只能[进進]行一次搜[索尋]').firstMatch(message)?.group(1);
  if (seconds != null) {
    return int.tryParse(seconds);
  }
  if (RegExp('每分[钟鐘]').hasMatch(message) && RegExp('搜[索尋]').hasMatch(message)) {
    return 60;
  }
  if (RegExp('[过過]于频繁|[过過]於頻繁|只能[进進]行一次搜[索尋]').hasMatch(message)) {
    return 20;
  }
  return null;
}

/// Repository of searching.
///
/// Uses the Discuz built-in forum search `search.php?mod=forum` because the old plugin `Kahrpba:search` is gone.
///
/// ## How Discuz search works
///
/// * A new search is a GET request `search.php?mod=forum&srchtxt=KEYWORD&searchsubmit=yes` (form hash is NOT
///   required for GET), optionally with `srchuname=NAME` (author, the field the search form itself sends),
///   `srchuid=UID` (author) and `srchfid[]=FID` (forum). The keyword may be empty when an author or a forum is given,
///   the server then lists everything by that author or in that forum.
/// * The server caches the search result and assigns a `searchid`, other pages of the same search are fetched
///   through `search.php?mod=forum&searchid=ID&orderby=lastpost&ascdesc=desc&searchsubmit=yes&page=N`. The
///   `searchid` is parsed from the page links in the result page.
/// * Starting a new search too frequently is rejected by server ("搜索过于频繁"), so the search id is cached here and
///   reused when only page number changes.
///
/// The pages are asked in the JSON mode of the forum's app API (the redirect of a new search to its results carries
/// it). Plugin 2.4.0 answers the results as structured fields (`schema: 6`, [searchApiAnswerOf]): the results are
/// built from them ([searchResultFromApi]) and the search id read from the answer; the forum's refusal (too
/// frequent, expired, no permission) is its message. An older plugin's answer and the web page are parsed as before
/// ([SearchResult.fromDocument]). The results ask for the previews of their rows too when they are wanted
/// ([tsdmAppListPreviewParameters], plugin 3.1.0; the redirect of a new search carries the parameter as well).
class SearchRepository with LoggerMixin {
  static const _searchUrl = '$baseUrl/search.php';

  /// Parameters of the last search, used to reuse [_searchId].
  (String keyword, String fid, String uid, String authorName)? _lastParameters;

  /// Search id assigned by server for the last search.
  String? _searchId;

  /// An search action with given parameters:
  ///
  /// * [keyword]: Query keyword.
  /// * [fid]: Forum id, 0 represents any forum.
  /// * [uid]: Author user id, 0 represents any user.
  /// * [authorName]: Author user name, empty represents any user. Passed along with [uid] whenever known: a bare uid
  ///   found nothing for testers on the forum while the name is what the search form itself sends.
  /// * [pageNumber]: Page number of search result.
  AsyncEither<SearchResult> searchWithParameters({
    required String keyword,
    required String fid,
    required String uid,
    required int pageNumber,
    String authorName = '',
  }) => AsyncEither(() async {
    final parameters = (keyword, fid, uid, authorName);
    final Map<String, String> queryParameters;
    if (pageNumber > 1 && _searchId != null && _lastParameters == parameters) {
      // Other pages of the cached search.
      queryParameters = <String, String>{
        'mod': 'forum',
        'searchid': _searchId!,
        'orderby': 'lastpost',
        'ascdesc': 'desc',
        'searchsubmit': 'yes',
        'page': '$pageNumber',
      };
    } else {
      queryParameters = buildSearchQuery(
        keyword: keyword,
        fid: fid,
        uid: uid,
        authorName: authorName,
        pageNumber: pageNumber,
      );
    }

    final netClient = getIt.get<NetClientProvider>();
    // JSON mode of the forum's app API when the forum has it (see TsdmAppApi); the redirect to the results keeps it.
    final respEither = await netClient
        .get(
          _searchUrl,
          queryParameters: {...queryParameters, ...tsdmAppJsonQueryParameters, ...tsdmAppListPreviewParameters()},
        )
        .run();
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }
    final resp = respEither.unwrap();
    // An answer without a page is a failed request, not a search without results (see tsdmAppAnswerWithoutPage).
    if (resp.statusCode != HttpStatus.ok || tsdmAppAnswerWithoutPage(resp.data)) {
      return left(HttpRequestFailedException(resp.statusCode));
    }

    final api = searchApiAnswerOf(resp.data);
    if (api != null) {
      if (api['ok'] != 1) {
        // The forum's own refusal: "抱歉，您的搜索过于频繁", an expired search, no permission, please log in. A search
        // without a result is a results page of plugin 2.4.0 (count 0), never a message; the old rule is kept all
        // the same, a dead path here (its count is 0 where the message page gave none: nothing shows the difference).
        final message = api['message'] is String ? (api['message'] as String).trim() : '';
        if (!message.contains('没有找到')) {
          error('search failed: $message');
          return left(ServerRespondedErrorException(message));
        }
        return right(const SearchResult(currentPage: 1, totalPages: 1, count: 0, data: []));
      }
      final searchId = searchIdOfApi(api);
      if (searchId != null) {
        _searchId = searchId;
        _lastParameters = parameters;
      }
      return right(searchResultFromApi(api));
    }

    final document = tsdmAppPageDocument(resp.data);

    // Server side error, e.g. "抱歉，您的搜索过于频繁" or "没有找到匹配结果".
    final errorText = document.querySelector('div#messagetext > p')?.innerText.trim();
    if (errorText != null && !errorText.contains('没有找到')) {
      error('search failed: $errorText');
      return left(ServerRespondedErrorException(errorText));
    }

    final searchId = SearchResult.parseSearchId(document);
    if (searchId != null) {
      _searchId = searchId;
      _lastParameters = parameters;
    }
    return right(SearchResult.fromDocument(document));
  });
}
