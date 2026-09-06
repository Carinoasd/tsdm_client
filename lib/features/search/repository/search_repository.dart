import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

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
  AsyncEither<uh.Document> searchWithParameters({
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
    final respEither = await netClient.get(_searchUrl, queryParameters: queryParameters).run();
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }
    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(resp.statusCode));
    }

    final document = parseHtmlDocument(resp.data as String);

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
    return right(document);
  });
}
