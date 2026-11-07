import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

/// The structured search answer in [data]: a JSON answer of the forum's app API that carries the search results as
/// fields (plugin 2.4.0, `type: search`, `schema` 6 or later), or the forum's own message of such a plugin (the
/// search too frequent, expired, switched off, no permission, please log in: `ok` 0, `error: message`, with `login`
/// telling the two apart). Null when the answer has to be read from its `document` as before: a web page, an older
/// plugin's answer (no `schema`, no `login`), a failed build, and the search form page, which the plugin answers
/// without a `schema` (there is no result to give).
///
/// The results are then built by [searchResultFromApi]; the `document` of the answer, when there is one, is never
/// parsed.
Map<String, dynamic>? searchApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 6;
  if (json['ok'] == 1) {
    return structured && json['type'] == 'search' ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// The results of a structured search answer [json] (`ok` 1, [searchApiAnswerOf]).
///
/// The same [SearchResult] the web page gives through [SearchResult.fromDocument], from the fields instead of the
/// html: `page` / `pages` are the pagination the forum printed, `count` the total of the search (as the page's
/// "找到 … 相关内容 N 个"), `threads` the rows of the page as [SearchedThread.fromApi] builds them (a row without a
/// thread or a subject dropped, as the page parser drops a malformed row, [tsdmAppIsThreadRow]). A search without a
/// result is a page of its own (`count` 0, `threads` empty): the forum prints the results page then, not a message.
/// `fulltext` tells whether the full text was searched ([SearchResult.fullText]).
SearchResult searchResultFromApi(Map<String, dynamic> json) {
  final page = tsdmAppInt(json['page']);
  final pages = tsdmAppInt(json['pages']);
  final timeOffset = tsdmAppTimeOffset(json);
  return SearchResult(
    currentPage: page > 0 ? page : 1,
    totalPages: pages > 0 ? pages : (page > 0 ? page : 1),
    count: json['count'] is num ? tsdmAppInt(json['count']) : null,
    data: tsdmAppList(
      json['threads'],
    ).where(tsdmAppIsThreadRow).map((e) => SearchedThread.fromApi(e, timeOffset: timeOffset)).toList(),
    fullText: json['fulltext'] is num ? tsdmAppInt(json['fulltext']) == 1 : null,
  );
}

/// The search id of a structured search answer [json] (`ok` 1), which the other pages of the same search are asked
/// with (`search.php?mod=forum&searchid=…`), as the web path reads it from the pagination links; null when the
/// answer names none.
String? searchIdOfApi(Map<String, dynamic> json) {
  final id = tsdmAppInt(json['searchid']);
  return id > 0 ? '$id' : null;
}

/// The url of page [page] of the search a structured answer [json] (`ok` 1) is a page of: the forum's own paging
/// link (`searchid`, the order of the answer, `searchsubmit=yes`, `page`), as the web page prints it in its
/// pagination. Null when the answer names no search id.
String? searchResultPageUrl(Map<String, dynamic> json, int page) {
  final id = searchIdOfApi(json);
  if (id == null) {
    return null;
  }
  final orderBy = tsdmAppText(json['orderby']);
  final ascDesc = tsdmAppText(json['ascdesc']);
  return '$baseUrl/search.php?mod=forum&searchid=$id'
      '&orderby=${orderBy.isEmpty ? 'lastpost' : orderBy}'
      '&ascdesc=${ascDesc.isEmpty ? 'desc' : ascDesc}'
      '&searchsubmit=yes&page=$page';
}
