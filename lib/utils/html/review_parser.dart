import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:universal_html/html.dart' as uh;

/// Fields parsed from a post comment (点评) block.
typedef ReviewInfo = ({String? avatarUrl, String? name, String? content});

/// Parse the post comment block [element] (`<div class="cm">`).
///
/// Layout rendered by Discuz! X5:
///
/// ```html
/// <div class="cm">
///   <h3 class="psth">点评</h3>
///   <div class="pstl">
///     <div class="psta"><a><img></a><a class="xi2 xw1">NAME</a></div>
///     <div class="psti">COMMENT TEXT<span class="xg1">发表于 TIME</span></div>
///   </div>
/// </div>
/// ```
///
/// Preserve nested body text and line breaks, excluding the timestamp and
/// the author link used by older layouts inside `div.psti`.
ReviewInfo parseReviewElement(uh.Element element) {
  final avatarUrl = element.querySelector('div.psta > a > img')?.imageUrl();
  final author = element.querySelector('div.psta > a.xi2') ?? element.querySelector('div.psti > a.xi2');
  final name = author?.innerText.trim();
  final body = element.querySelector('div.psti');
  final buffer = StringBuffer();
  void collect(uh.Node node) {
    if (node == author) {
      return;
    }
    if (node.nodeType == uh.Node.TEXT_NODE) {
      buffer.write(node.text ?? '');
    } else if (node is uh.Element) {
      if ((node.parentNode == body && node.classes.contains('xg1')) ||
          node.localName == 'script' ||
          node.localName == 'style') {
        return;
      }
      if (node.localName == 'br') {
        buffer.writeln();
        return;
      }
      node.nodes.forEach(collect);
      if (node.localName == 'p' || node.localName == 'div') {
        buffer.writeln();
      }
    }
  }

  body?.nodes.forEach(collect);
  final content = body == null ? null : buffer.toString().replaceAll('\u00a0', ' ').trim();
  return (avatarUrl: avatarUrl, name: name, content: content);
}
