import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/post/utils/draft_marker.dart';
import 'package:universal_html/html.dart' as uh;

/// The current account's server-side drafts, not local editor backups.
String draftBoxUrl({int page = 1}) =>
    '$baseUrl/home.php?mod=space&do=thread&view=me&type=thread&filter=save&page=$page';

/// Reject duplicate parameters and foreign origins before interpreting a link.
Uri? draftForumUri(String? value) {
  if (value == null || value.isEmpty) return null;
  try {
    final uri = Uri.tryParse(baseUrl)?.resolve(value);
    if (uri == null ||
        uri.origin != Uri.parse(baseUrl).origin ||
        uri.userInfo.isNotEmpty ||
        uri.queryParametersAll.values.any((values) => values.length != 1)) {
      return null;
    }
    return uri;
  } on FormatException {
    return null;
  }
}

bool _positive(String? value) => value != null && RegExp(r'^[1-9]\d*$').hasMatch(value);

/// A minimal draft row; private content is fetched only when opening it.
final class DraftEntry {
  /// Constructor.
  const DraftEntry({required this.tid, required this.fid, required this.title, required this.forumName});

  /// Thread identifier.
  final String tid;

  /// Board identifier.
  final String fid;

  /// Private subject.
  final String title;

  /// Board name.
  final String forumName;

  /// Read-only thread endpoint. Never use the site's pubsave link.
  String get url => '$baseUrl/forum.php?mod=viewthread&tid=$tid';
}

/// One validated draft list page.
final class DraftPage {
  /// Constructor.
  const DraftPage(this.entries, this.nextPage);

  /// Draft rows.
  final List<DraftEntry> entries;

  /// Next page number, constrained to the same filter and identity.
  final int? nextPage;
}

/// Identifiers obtained from an editable, still-private thread.
typedef DraftEditTarget = ({String fid, String tid, String pid});

/// Parses only an explicitly selected server draft filter.
DraftPage parseDraftPage(uh.Document document, {required int page, required int uid}) {
  bool ownFilter(Uri? uri) =>
      uri != null &&
      uri.path == '/home.php' &&
      uri.queryParameters['mod'] == 'space' &&
      uri.queryParameters['do'] == 'thread' &&
      uri.queryParameters['view'] == 'me' &&
      uri.queryParameters['type'] == 'thread' &&
      uri.queryParameters['filter'] == 'save' &&
      (uri.queryParameters['uid'] == null || uri.queryParameters['uid'] == '$uid');
  final selected = document.querySelectorAll('a.a, .a > a').any((a) => ownFilter(draftForumUri(a.attributes['href'])));
  final table = document.querySelector('form#delform table');
  if (!selected || table == null) throw const FormatException('Draft list unavailable');
  final entries = <DraftEntry>[];
  for (final row in table.querySelectorAll('tr')) {
    if (row.classes.contains('th')) continue;
    final title = row.querySelector('th > a');
    if (title == null) continue;
    final thread = draftForumUri(title.attributes['href']);
    final forumLink = row.querySelector('td > a[href*="fid="]');
    final forum = draftForumUri(forumLink?.attributes['href']);
    if (thread?.path != '/forum.php' ||
        thread?.queryParameters['mod'] != 'viewthread' ||
        !_positive(thread?.queryParameters['tid']) ||
        forum?.path != '/forum.php' ||
        forum?.queryParameters['mod'] != 'forumdisplay' ||
        !_positive(forum?.queryParameters['fid']) ||
        title.innerText.trim().isEmpty) {
      throw const FormatException('Invalid draft row');
    }
    entries.add(
      DraftEntry(
        tid: thread!.queryParameters['tid']!,
        fid: forum!.queryParameters['fid']!,
        title: title.innerText.trim(),
        forumName: forumLink!.innerText.trim(),
      ),
    );
  }
  if (entries.isEmpty && table.querySelector('.emp') == null) {
    throw const FormatException('Unrecognized draft list');
  }
  int? next;
  final nextLink = document.querySelector('.pg a.nxt');
  if (nextLink != null) {
    final uri = draftForumUri(nextLink.attributes['href']);
    final number = int.tryParse(uri?.queryParameters['page'] ?? '');
    if (!ownFilter(uri) || number != page + 1) throw const FormatException('Invalid draft pagination');
    next = number;
  }
  return DraftPage(List.unmodifiable(entries), next);
}

/// Recheck draft state before entering the editor; a published/deleted draft is not editable here.
DraftEditTarget parseDraftTarget(uh.Document document, DraftEntry entry) {
  if (!isDraftThreadDocument(document)) throw const FormatException('Draft no longer available');
  final firstPost = document.querySelector('#postlist div[id^="post_"]');
  if (!isFirstThreadPost(firstPost, tid: entry.tid)) throw const FormatException('Draft first post missing');
  final canonical = document.querySelector('head link[rel="canonical"]')?.attributes['href'];
  if (canonical != null && draftForumUri(canonical)?.queryParameters['tid'] != entry.tid) {
    throw const FormatException('Draft thread changed');
  }
  final postId = firstPost?.id.replaceFirst('post_', '');
  if (!_positive(postId)) throw const FormatException('Draft post missing');
  for (final link in firstPost!.querySelectorAll('a[href]')) {
    final uri = draftForumUri(link.attributes['href']);
    final q = uri?.queryParameters;
    if (uri?.path == '/forum.php' &&
        q?['mod'] == 'post' &&
        q?['action'] == 'edit' &&
        q?['tid'] == entry.tid &&
        q?['fid'] == entry.fid &&
        q?['pid'] == postId) {
      return (fid: entry.fid, tid: entry.tid, pid: postId!);
    }
  }
  throw const FormatException('Draft edit link unavailable');
}
