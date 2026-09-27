import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// Thread id of the canonical link of a thread page, `<link href="...forum.php?mod=viewthread&tid=N" rel="canonical">`.
int? _canonicalTid(uh.Document document) {
  final links = document.querySelectorAll('head > link[rel="canonical"]');
  if (links.length != 1) {
    return null;
  }
  final uri = Uri.tryParse(links.single.attributes['href'] ?? '');
  if (uri == null || !isForumScriptUri(uri, 'forum.php')) {
    return null;
  }
  final query = uniqueQueryParameters(uri);
  if (query == null || query['mod'] != 'viewthread') {
    return null;
  }
  return parsePositiveForumId(query['tid']);
}

/// Forum id of a thread page: the search box's `srhfid` and the fast reply form's action, which must agree.
int? _pageFid(uh.Document document) {
  final found = <int?>[];
  final srh = document.querySelectorAll('input[name="srhfid"]');
  for (final e in srh) {
    found.add(parsePositiveForumId(e.attributes['value']));
  }
  final action = document.querySelector('form#fastpostform')?.attributes['action'];
  if (action != null) {
    final uri = Uri.tryParse(action.replaceAll('&amp;', '&'));
    final query = uri == null ? null : uniqueQueryParameters(uri);
    found.add(parsePositiveForumId(query?['fid']));
  }
  if (found.isEmpty || found.any((e) => e == null) || found.toSet().length != 1) {
    return null;
  }
  return found.first;
}

/// Ids of the thread page [document] for report links (#127), null unless the viewer, the thread and the forum are
/// all known from the page itself.
///
/// [expectedTid] is the thread the caller asked for (e.g. `ptid` of a notice link); a page of another thread gives
/// null.
PostReportPageContext? postReportPageContextOf(uh.Document document, {String? expectedTid}) {
  final viewerUid = parseLoggedUidFromDocument(document);
  final tid = _canonicalTid(document);
  final fid = _pageFid(document);
  if (viewerUid == null || viewerUid <= 0 || tid == null || fid == null) {
    return null;
  }
  if (expectedTid != null && expectedTid != '$tid') {
    return null;
  }
  return PostReportPageContext(tid: tid, fid: fid, viewerUid: viewerUid);
}
