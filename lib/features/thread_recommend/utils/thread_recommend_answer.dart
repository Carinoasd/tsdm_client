import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';

/// The key of a structured thread page answer under which the app keeps the forum's evaluation links of the thread
/// ("支持" and "踩", `a#recommend_add` and `a#recommend_subtract`) it cut from the answer's `document`
/// ([threadAnswerWithRecommend]). The plugin names no field so: it is the app's own, read by `threadPageFromApi`.
const threadRecommendHtmlKey = 'app_recommend_html';

/// The evaluation links of the first floor in the forum's page [html]: each `<a id="recommend_add">` and
/// `<a id="recommend_subtract">` up to its end (they hold no other link), joined; empty when there are none.
String threadRecommendLinksIn(String html) {
  if (!html.contains('recommend_')) {
    return '';
  }
  return _recommendLinkRe.allMatches(html).map((m) => m.group(0)).join();
}

final _recommendLinkRe = RegExp(r'<a\s[^>]*\bid="recommend_(?:add|subtract)"[^>]*>[\s\S]*?</a>');

/// The thread page answer [data] as the app reads and keeps it, for the first page asked by thread id with its
/// `document` (without `nodoc=1`, the only answer that has the evaluation of the thread, which the structured fields
/// of the forum's app API do not carry up to plugin 3.7.0).
///
/// A structured answer ([threadApiAnswerOf]) is that answer without `document` and `head`, as `nodoc=1` gives it,
/// with the evaluation links cut from the document under [threadRecommendHtmlKey] when there are any: nothing of the
/// page is parsed but those links, and the offline copy saved from the answer is no larger than a lean one. Any other
/// answer (a web page, an older plugin's, the thread cache a guest is served) is left as it came: the page parser
/// reads the links from the first floor.
Object? threadAnswerWithRecommend(Object? data) {
  final json = threadApiAnswerOf(data);
  if (json == null || json['document'] is! String) {
    return data;
  }
  final links = threadRecommendLinksIn(json['document'] as String);
  return {
    for (final e in json.entries)
      if (e.key != 'document' && e.key != 'head') e.key: e.value,
    if (links.isNotEmpty) threadRecommendHtmlKey: links,
  };
}
