import 'package:tsdm_client/shared/models/models.dart';
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

/// The text of each post searched ([threadSearchText]), kept with the post: a floor is read once, not again for
/// every word typed.
final _texts = Expando<String>('thread search text');

/// The text of [post] searched: its content without the markup (quotes in it included; the signature is not part of
/// it), what is hidden in it left out (jammer text, styles, scripts), and its author's name.
String threadSearchText(Post post) => _texts[post] ??= _textOf(post);

String _textOf(Post post) {
  final body = parseHtmlDocument(post.data).body;
  if (body != null) {
    for (final hidden in body.querySelectorAll(
      'script, style, .jammer, [style*="display:none"], [style*="display: none"]',
    )) {
      hidden.remove();
    }
  }
  return '${post.author.name}\n${body?.text ?? ''}';
}

/// The floors of [posts] (in the order shown) that [pattern] is found in, each once: a hot reply only when the floor
/// it copies is not among [posts]; never a floor that [hidden] says is not shown.
List<Post> threadSearchHits(List<Post> posts, RegExp pattern, {bool Function(Post post)? hidden}) {
  final floors = {
    for (final post in posts)
      if (!post.hot) post.postID,
  };
  final seen = <String>{};
  return [
    for (final post in posts)
      if (!(post.hot && floors.contains(post.postID)) &&
          !(hidden?.call(post) ?? false) &&
          pattern.hasMatch(threadSearchText(post)) &&
          seen.add(post.postID))
        post,
  ];
}
