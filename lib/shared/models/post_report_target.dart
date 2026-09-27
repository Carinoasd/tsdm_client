part of 'models.dart';

/// Ids of the thread page a post was read from, taken from the page itself and not from any post link (#127).
///
/// A report link of a floor is only trusted when its thread and forum ids equal these, so a link can never validate
/// itself.
final class PostReportPageContext {
  /// Constructor.
  const PostReportPageContext({required this.tid, required this.fid, required this.viewerUid});

  /// Thread id of the page.
  final int tid;

  /// Forum id of the page.
  final int fid;

  /// Uid of the account the page was served to.
  final int viewerUid;
}

/// A floor the forum offered to report to the account [viewerUid] on the thread page it was read from (#127).
///
/// Only built from the report link the forum rendered in the operation row of that floor, never made up: own posts,
/// guest pages and floors without the link have none.
@MappableClass()
final class PostReportTarget with PostReportTargetMappable {
  /// Constructor.
  const PostReportTarget({required this.pid, required this.tid, required this.fid, required this.viewerUid});

  /// Post id, `rid` of the report.
  final int pid;

  /// Thread id.
  final int tid;

  /// Forum id.
  final int fid;

  /// The account the link was offered to. Another account may not use it.
  final int viewerUid;

  /// Handle key of the forum's report window, e.g. `miscreport123`.
  String get handleKey => 'miscreport$pid';

  /// The report entry exactly as the forum links it.
  Uri get reportUrl => Uri.parse('$baseUrl/misc.php?mod=report&rtype=post&rid=$pid&tid=$tid&fid=$fid');

  /// The full thread page at this floor, for the browser fallback. Never the ajax report fragment.
  Uri get floorUrl => Uri.parse('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=$tid&pid=$pid');
}

final _positiveIdRe = RegExp(r'^[1-9][0-9]{0,11}$');

/// Parse a positive decimal id written without sign, spaces or leading zeros.
int? parsePositiveForumId(String? value) => value != null && _positiveIdRe.hasMatch(value) ? int.tryParse(value) : null;

/// Whether [uri] is the forum script [file] (`misc.php`, `forum.php`...): relative (`misc.php`, `/misc.php`) or on
/// the forum's own hosts over http(s) on the default port, without user info or fragment.
bool isForumScriptUri(Uri uri, String file) {
  if (uri.hasFragment || uri.userInfo.isNotEmpty) {
    return false;
  }
  if (uri.hasScheme) {
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      return false;
    }
    if (uri.host != baseHost && uri.host != baseHostAlt) {
      return false;
    }
    if (uri.hasPort) {
      return false;
    }
    return uri.path == '/$file';
  }
  if (uri.hasAuthority) {
    return false;
  }
  return uri.path == file || uri.path == '/$file';
}

/// Query of [uri] when every key appears once, null when malformed or repeated.
Map<String, String>? uniqueQueryParameters(Uri uri) {
  try {
    final all = uri.queryParametersAll;
    if (all.values.any((e) => e.length != 1)) {
      return null;
    }
    return {for (final e in all.entries) e.key: e.value.single};
  } on FormatException {
    return null;
  }
}

/// The canonical report url of [raw] when it is exactly the forum's report entry of post [pid] in thread [tid] of
/// forum [fid], null otherwise.
///
/// Exactly `misc.php` with the keys `mod=report`, `rtype=post`, `rid`, `tid` and `fid`, each once: any other key
/// (a mutation flag, a handle key...) refuses the link.
Uri? canonicalPostReportUrl(String raw, {required int pid, required int tid, required int fid}) {
  if (raw.isEmpty || raw.length > 512) {
    return null;
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || !isForumScriptUri(uri, 'misc.php')) {
    return null;
  }
  final query = uniqueQueryParameters(uri);
  if (query == null || query.length != 5) {
    return null;
  }
  if (query['mod'] != 'report' ||
      query['rtype'] != 'post' ||
      query['rid'] != '$pid' ||
      query['tid'] != '$tid' ||
      query['fid'] != '$fid') {
    return null;
  }
  return PostReportTarget(pid: pid, tid: tid, fid: fid, viewerUid: 0).reportUrl;
}

/// `showWindow('miscreportPID', 'URL', 'get', -1);return false;`, the only script form of the report link.
final _reportOnclickRe = RegExp(
  r"^\s*showWindow\(\s*'miscreport([0-9]+)'\s*,\s*'([^'\\\s]+)'\s*,\s*'get'\s*,\s*-1\s*\)\s*;\s*return\s+false\s*;?\s*$",
);

/// `javascript:;` and `javascript:void(0);`, links that only run their onclick.
final _scriptOnlyHrefRe = RegExp(r'^javascript:\s*(?:void\(0\)\s*)?;?$', caseSensitive: false);

bool _mentionsReport(String value) {
  final lower = value.toLowerCase();
  return lower.contains('mod=report') || lower.contains('miscreport');
}

/// Whether [e] sits in the operation row of the floor [table], not in the post body, a quote or the signature.
bool _inOperationRow(uh.Element e, uh.Element table) {
  var inPob = false;
  var node = e.parent;
  while (node != null && !identical(node, table)) {
    if (node.localName == 'table' || node.localName == 'blockquote') {
      return false;
    }
    final classes = node.classes;
    if (classes.contains('pcb') ||
        classes.contains('pct') ||
        classes.contains('t_f') ||
        classes.contains('sign') ||
        classes.contains('sign_inner') ||
        classes.contains('quote')) {
      return false;
    }
    if (node.localName == 'div' && classes.contains('pob')) {
      inPob = true;
    }
    node = node.parent;
  }
  return node != null && inPob;
}

/// The report target of the floor [postNode] (`div#post_PID`) when its operation row carries exactly one valid
/// report link for [postId] in the thread and forum of [context], null otherwise.
///
/// The link is read from `href` or from the literal `showWindow(...)` call in `onclick`, which is matched as text and
/// never run. Both, when present, must name the same report. Posts of [context]'s viewer ([authorUid]) never get a
/// target even if a link is there.
PostReportTarget? extractPostReportTarget(
  uh.Element postNode, {
  required String postId,
  required PostReportPageContext? context,
  required String? authorUid,
}) {
  final pid = parsePositiveForumId(postId);
  if (pid == null || context == null) {
    return null;
  }
  if (authorUid == null || authorUid == '${context.viewerUid}') {
    return null;
  }
  final table = postNode.children.firstWhereOrNull((e) => e.localName == 'table' && e.id == 'pid$pid');
  if (table == null) {
    return null;
  }
  final candidates = table
      .querySelectorAll('div.pob a')
      .where((a) => _inOperationRow(a, table))
      .where((a) => _mentionsReport(a.attributes['href'] ?? '') || _mentionsReport(a.attributes['onclick'] ?? ''))
      .toList();
  if (candidates.length != 1) {
    if (candidates.length > 1) {
      talker.warning('post $pid: ${candidates.length} report links in operation row, none used');
    }
    return null;
  }
  final a = candidates.single;
  final href = (a.attributes['href'] ?? '').trim();
  final onclick = (a.attributes['onclick'] ?? '').trim();

  Uri? fromHref;
  if (href.isNotEmpty && !_scriptOnlyHrefRe.hasMatch(href)) {
    if (href.toLowerCase().startsWith('javascript:')) {
      return null;
    }
    fromHref = canonicalPostReportUrl(href, pid: pid, tid: context.tid, fid: context.fid);
    if (fromHref == null) {
      return null;
    }
  }
  Uri? fromOnclick;
  if (onclick.isNotEmpty) {
    final m = _reportOnclickRe.firstMatch(onclick);
    if (m == null || m.group(1) != '$pid') {
      return null;
    }
    fromOnclick = canonicalPostReportUrl(m.group(2)!, pid: pid, tid: context.tid, fid: context.fid);
    if (fromOnclick == null) {
      return null;
    }
  }
  if (fromHref == null && fromOnclick == null) {
    return null;
  }
  if (fromHref != null && fromOnclick != null && fromHref != fromOnclick) {
    return null;
  }
  return PostReportTarget(pid: pid, tid: context.tid, fid: context.fid, viewerUid: context.viewerUid);
}
