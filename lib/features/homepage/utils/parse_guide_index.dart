import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// Parse the modules of the Discuz! guide index page (`forum.php?mod=guide&view=index`, GitHub #12).
///
/// Every `div.bm.bmw` block with a `div.bm_h` header is a module; the header holds
/// `<a href="forum.php?mod=guide&view=hot" class="y xi2">更多 »</a>` and `<h2>最新热门</h2>`, the body
/// `div.bm_c > div.xl.xl2.cl` lists the threads as `<li>` (there is no `<ul>`, `<li>` are direct children). A module
/// without threads carries `<p class="emp">暂时还没有帖子</p>` instead. Modules are returned in page order; a block
/// that lacks the title or the 更多 link is skipped, a guest or unrelated page yields an empty list.
List<GuideModule> parseGuideIndex(uh.Document document) {
  final modules = <GuideModule>[];
  for (final node in document.querySelectorAll('div.bm.bmw')) {
    final header = node.querySelector('div.bm_h');
    if (header == null) {
      continue;
    }
    final title = _text(header.querySelector('h2'));
    final moreHref = header.querySelector('a[href*="mod=guide"]')?.attributes['href'];
    final view = moreHref?.uriQueryParameter('view');
    if (title == null || moreHref == null || view == null || view.isEmpty) {
      continue;
    }
    final body = node.querySelector('div.bm_c');
    final items = body?.querySelectorAll('li').map(_parseItem).nonNulls.toList() ?? const <GuideItem>[];
    modules.add(
      GuideModule(
        title: title,
        view: view,
        moreUrl: moreHref.prependHost(),
        items: items,
        emptyMessage: items.isEmpty ? _text(body?.querySelector('p.emp')) : null,
      ),
    );
  }
  return modules;
}

GuideItem? _parseItem(uh.Element li) {
  final titleNode = li.querySelector('a[href*="mod=viewthread"]');
  final href = titleNode?.attributes['href'];
  final tid = href?.uriQueryParameter('tid');
  final title = _text(titleNode);
  if (href == null || tid == null || tid.isEmpty || title == null) {
    return null;
  }
  final forumNode = li.querySelector('a[href*="mod=forumdisplay"]');
  return GuideItem(
    tid: tid,
    title: title,
    url: href.prependHost(),
    fid: forumNode?.attributes['href']?.uriQueryParameter('fid'),
    forumName: _text(forumNode),
    // Direct child only: the title is wrapped in <i>, not <em>.
    extra: _text(li.children.where((e) => e.localName == 'em').firstOrNull),
    highlighted: (titleNode?.attributes['style'] ?? '').trim().isNotEmpty,
  );
}

/// Collapsed text of [node] (nbsp included), null when missing or blank.
String? _text(uh.Element? node) {
  final text = node?.innerText.replaceAll(' ', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return (text == null || text.isEmpty) ? null : text;
}
