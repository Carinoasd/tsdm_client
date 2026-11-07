import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:universal_html/html.dart' as uh;

/// A tag of the forum's tag cloud.
final class ForumTag {
  /// Constructor.
  const ForumTag({required this.id, required this.name, required this.count});

  /// Tag id (`tagid`).
  final String id;

  /// Tag name.
  final String name;

  /// Number of threads (and other items) the tag is put on, 0 when the page does not tell.
  final int count;

  /// The tag page of the tag, as the in-app tag route reads it.
  String get url => '$baseUrl/misc.php?mod=tag&id=$id';
}

/// The tags of the tag cloud page (`misc.php?mod=tag`), in the page's order:
///
/// <div class="taglist"><a href="misc.php?mod=tag&id=2" title="无损, 关联数据量: 3">无损</a>...</div>
List<ForumTag> parseTagCloud(uh.Document document) {
  final tags = <ForumTag>[];
  final seen = <String>{};
  for (final node in document.querySelectorAll('div.taglist a[href]')) {
    final id = (node.attributes['href'] ?? '').uriQueryParameter('id');
    final name = node.text?.trim() ?? '';
    if (id == null || id.isEmpty || name.isEmpty || !seen.add(id)) {
      continue;
    }
    // The title reads "name, count label: N".
    final count = int.tryParse(RegExp(r'(\d+)\s*$').firstMatch(node.attributes['title'] ?? '')?.group(1) ?? '') ?? 0;
    tags.add(ForumTag(id: id, name: name, count: count));
  }
  return tags;
}
