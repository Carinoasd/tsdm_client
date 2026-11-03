import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The pattern finding [query] in a floor, null for a query of nothing but spaces: every word of it in this order,
/// any run of white space between them, whatever their case.
RegExp? threadSearchPattern(String query) {
  final words = query.trim().split(RegExp(r'\s+')).where((e) => e.isNotEmpty).toList();
  if (words.isEmpty) {
    return null;
  }
  return RegExp(words.map(RegExp.escape).join(r'\s+'), caseSensitive: false);
}

/// The text of each post searched ([threadSearchText]) and the html it was read from, kept with the post: a floor is
/// read once, not again for every word typed.
final _texts = Expando<(String, String)>('thread search text');

/// The text of [post] searched, read from [data] (the content as shown: the quotes of blocked users replaced, see
/// `BlockAwarePost`; the content of the post when null): without the markup (quotes in it included; the signature is
/// not part of it), what is hidden in it left out (jammer text, styles, scripts), and its author's name.
///
/// A line break or a block ends a word: `a<br>b` and `<div>a</div><div>b</div>` read as two words, not as `ab`.
String threadSearchText(Post post, {String? data}) {
  final html = data ?? post.data;
  if (_texts[post] case (final source, final text) when identical(source, html) || source == html) {
    return text;
  }
  final text = _textOf(post, html);
  _texts[post] = (html, text);
  return text;
}

/// Elements whose content is not part of the text around it.
const _blocks = {
  'address', 'article', 'aside', 'blockquote', 'dd', 'details', 'dialog', 'div', 'dl', 'dt', 'fieldset', //
  'figcaption', 'figure', 'footer', 'form', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'header', 'hr', 'li', 'main', //
  'nav', 'ol', 'p', 'pre', 'section', 'summary', 'table', 'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'ul', //
};

String _textOf(Post post, String html) {
  final body = parseHtmlDocument(html).body;
  final text = StringBuffer('${post.author.name}\n');
  if (body != null) {
    for (final hidden in body.querySelectorAll(
      'script, style, .jammer, [style*="display:none"], [style*="display: none"]',
    )) {
      hidden.remove();
    }
    _write(body, text);
  }
  return text.toString();
}

void _write(uh.Node node, StringBuffer text) {
  for (final child in node.nodes) {
    if (child is uh.Text) {
      text.write(child.data);
    } else if (child is uh.Element) {
      final tag = child.localName.toLowerCase();
      if (tag == 'br') {
        text.write('\n');
        continue;
      }
      final block = _blocks.contains(tag);
      if (block) {
        text.write('\n');
      }
      _write(child, text);
      if (block) {
        text.write('\n');
      }
    }
  }
}

/// The floors of [posts] (in the order shown) that [pattern] is found in, each once: a hot reply only when the floor
/// it copies is not among [posts]; never a floor that [hidden] says is not shown. [shownData] gives the content of a
/// post as shown (its quotes of blocked users replaced), the post's content when null.
List<Post> threadSearchHits(
  List<Post> posts,
  RegExp pattern, {
  bool Function(Post post)? hidden,
  String Function(Post post)? shownData,
}) {
  final floors = {
    for (final post in posts)
      if (!post.hot) post.postID,
  };
  final seen = <String>{};
  return [
    for (final post in posts)
      if (!(post.hot && floors.contains(post.postID)) &&
          !(hidden?.call(post) ?? false) &&
          pattern.hasMatch(threadSearchText(post, data: shownData?.call(post))) &&
          seen.add(post.postID))
        post,
  ];
}
