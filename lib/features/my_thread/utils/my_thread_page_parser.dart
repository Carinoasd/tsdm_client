import 'package:collection/collection.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/my_thread/models/models.dart';
import 'package:tsdm_client/features/my_thread/utils/my_thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/html.dart' as uh;

/// The rows and the next page url of a "my threads" list page [answer] fetched from [url]: the thread list, or the
/// reply list when [reply] (one row per reply).
///
/// The structured answer of the forum's app API is built from its fields (`myThreadsFromApi`, which lists one row per
/// reply already), the web page (or an older plugin's answer) is parsed as before ([parseMyThreadList],
/// [parseMyReplyList]). Shared by the account's own list and the list of another member: the forum prints both with
/// the same template (`home.php?mod=space[&uid=N]&do=thread&view=me`).
(List<MyThread>, String? nextPageUrl) myThreadPageOf(TsdmAppPageAnswer answer, String url, {required bool reply}) =>
    switch (answer) {
      TsdmAppWebPage(:final document) => reply ? parseMyReplyList(document) : parseMyThreadList(document),
      TsdmAppStructuredPage(:final json) => myThreadsFromApi(json, url),
    };

/// Parse thread list and next page url.
///
/// X5: `<div class="tl"><form id="delform"><table><tr class="th">header</tr><tr>thread</tr>...</table></form></div>`
/// followed by `<div class="pgs cl mtm"><div class="pg"><a class="nxt">下一页</a></div></div>`.
(List<MyThread>, String? nextPageurl) parseMyThreadList(uh.Document document) {
  final data = _threadRows(document)
      // Skip the header row.
      .where((e) => !e.classes.contains('th'))
      .map(MyThread.fromTr)
      .whereType<MyThread>()
      .toList();

  return (data, _nextPageUrl(document));
}

/// Parse reply list and next page url.
///
/// Each `<tr class="bw0_all">` thread row is followed by one or more reply rows, every reply becomes an item.
(List<MyThread>, String? nextPageUrl) parseMyReplyList(uh.Document document) {
  final data = _threadRows(
    document,
  ).where((e) => e.classes.contains('bw0_all')).map(MyThread.buildReplyListFromTr).flattened.toList();
  return (data, _nextPageUrl(document));
}

List<uh.Element> _threadRows(uh.Document document) {
  var rows = document.querySelectorAll('div.bm.bw0 > div.tl > form > table > tbody > tr');
  if (rows.isEmpty) {
    // X5.
    rows = document.querySelectorAll('div.tl > form#delform > table > tbody > tr');
  }
  return rows.toList();
}

String? _nextPageUrl(uh.Document document) =>
    (document.querySelector('div.pgs.cl.mtm > div.pg > a.nxt') ?? document.querySelector('div.pgs > div.pg > a.nxt'))
        ?.firstHref()
        ?.prependHost();
