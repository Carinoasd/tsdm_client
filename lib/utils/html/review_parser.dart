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
/// The comment text is a bare text node inside `div.psti`, so it is collected
/// from text nodes instead of a fixed child index. Older layouts kept the
/// author link inside `div.psti`; that is still accepted as a fallback and the
/// text-node collection skips it as well.
ReviewInfo parseReviewElement(uh.Element element) {
  final avatarUrl = element.querySelector('div.psta > a > img')?.imageUrl();
  final name = (element.querySelector('div.psta > a.xi2') ?? element.querySelector('div.psti > a'))
      ?.firstEndDeepText()
      ?.trim();
  final content = element
      .querySelector('div.psti')
      ?.nodes
      .where((n) => n.nodeType == uh.Node.TEXT_NODE)
      .map((n) => n.text ?? '')
      .join()
      // `&nbsp;` is used as spacing in older layouts.
      .replaceAll('\u00a0', ' ')
      .trim();
  return (avatarUrl: avatarUrl, name: name, content: content);
}
