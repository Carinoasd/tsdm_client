import 'package:universal_html/html.dart' as uh;

/// Discuz uses `psave` for both publishing drafts and recovering hidden posts.
bool isDraftPublishLink(uh.Element link) =>
    Uri.tryParse(link.attributes['href'] ?? '')?.queryParameters['action'] == 'pubsave';

/// Themes can replace the numeric first-floor label with text such as 楼主.
/// Its share link still points to viewthread; reply floors use redirect/findpost.
bool isFirstThreadPost(uh.Element? post, {String? tid}) {
  final link = post?.querySelector('.pi > strong > a');
  if (link?.querySelector('em')?.innerText.trim() == '1') return true;
  final query = Uri.tryParse(link?.attributes['href'] ?? '')?.queryParameters;
  return query?['mod'] == 'viewthread' &&
      RegExp(r'^[1-9]\d*$').hasMatch(query?['tid'] ?? '') &&
      (tid == null || query?['tid'] == tid);
}

/// Recognizes only the thread header, never a word inside the subject or body.
bool isDraftThreadDocument(uh.Document document) {
  final heading = document.querySelector('#postlist h1.ts');
  if (heading == null) return false;
  bool marked(uh.Element node) =>
      node.localName == 'span' &&
      node.id != 'thread_subject' &&
      (RegExp(r'^\s*[\[(（【]?草稿[\])）】]?\s*$').hasMatch(node.innerText) ||
          node.querySelectorAll('a.psave').any(isDraftPublishLink));
  if (heading.children.any(marked)) return true;
  // X5 moves the marker out of h1 into its immediate sibling.
  final sibling = heading.nextElementSibling;
  return sibling != null && sibling.localName == 'span' && marked(sibling);
}
