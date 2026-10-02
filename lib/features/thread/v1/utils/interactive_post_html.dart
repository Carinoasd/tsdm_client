import 'package:html/dom.dart';
import 'package:html/parser.dart';

final _interactiveMarkup = RegExp(
  r'<(?:style|svg|canvas|script|form|input|select|textarea|button|iframe)\b|\son[a-z]+\s*=',
  caseSensitive: false,
);
final _leadingCell = RegExp(r'^\s*<(?:td|th)(?:\s|>)', caseSensitive: false);
final _leadingRow = RegExp(r'^\s*<tr(?:\s|>)', caseSensitive: false);
final _nativeHandler = RegExp(
  r'^\s*(?:return\s+)?(?:zoom|showWindow|showMenu|hideMenu|showTip|hideTip|atarget|attachimg|thumbImg)'
  r'\s*\([^;{}]*\)\s*;?\s*(?:return\s+(?:false|true)\s*;?\s*)?$',
  caseSensitive: false,
);
final _nativeNeteasePlayer = RegExp(r'//music\.163\.com/outchain/player\?.*id=\d+.*');
final _nativePollIdentity = RegExp(r'''^\s*(?:var\s+)?discuz_uid\s*=\s*['"]\d+['"]\s*;?\s*$''');

/// The authored message HTML when it needs the interactive viewer, otherwise null.
///
/// A post's data can also contain the forum's poll, rating and red packet interfaces. Prefer the exact message id,
/// then a single legacy message with a different id. Ambiguous message boundaries are not exported. Bare fragments
/// are accepted for nonstandard markup. Detection does not sanitize the returned HTML: source spans preserve the
/// message's scripts, styles, whitespace and entities, and a bare fragment is returned exactly as supplied.
String? interactivePostHtml(String data, {required String postId}) {
  // Ordinary text and formatting do not need a second DOM parse alongside the native reader.
  if (!_interactiveMarkup.hasMatch(data)) {
    return null;
  }
  // A standalone table cell needs its normal parent context or the HTML parser discards its message wrapper.
  final container = _leadingCell.hasMatch(data) ? 'tr' : (_leadingRow.hasMatch(data) ? 'tbody' : 'div');
  final fragment = parseFragment(data, container: container, generateSpans: true);
  final messages = fragment.querySelectorAll('[id^="postmessage_"]');
  final exact = messages.where((element) => element.id == 'postmessage_$postId').toList();
  if (exact.length > 1) {
    return null;
  }
  final fallback = messages.where((element) => element.classes.contains('t_f')).toList();
  final Element? message;
  if (exact.isNotEmpty) {
    message = exact.single;
  } else if (fallback.length == 1) {
    message = fallback.single;
  } else if (messages.isNotEmpty) {
    return null;
  } else {
    message = null;
  }

  if (message == null) {
    return _containsInteractiveContent(fragment, bareFragment: true) ? data : null;
  }
  final start = message.sourceSpan?.end.offset;
  final end = message.endSourceSpan?.start.offset;
  if (start == null || end == null || end < start || end > data.length) {
    return null;
  }
  return _containsInteractiveContent(message) ? data.substring(start, end) : null;
}

bool _containsInteractiveContent(Node root, {bool bareFragment = false}) {
  final elements = switch (root) {
    Element() => root.querySelectorAll('*'),
    DocumentFragment() => root.querySelectorAll('*'),
    _ => const <Element>[],
  };
  final hasNativePoll = bareFragment && elements.any((element) => element.localName == 'form' && element.id == 'poll');
  for (final element in elements) {
    if (_isNativeControl(element, root)) {
      continue;
    }
    final tag = element.localName;
    if (tag == 'script' && hasNativePoll && _nativePollIdentity.hasMatch(element.text)) {
      continue;
    }
    if (const {'style', 'svg', 'canvas', 'script', 'form', 'select', 'textarea', 'button'}.contains(tag)) {
      return true;
    }
    if (tag == 'input' && element.attributes['type']?.toLowerCase() != 'hidden') {
      return true;
    }
    if (tag == 'iframe' && !_nativeNeteasePlayer.hasMatch(element.attributes['src'] ?? '')) {
      return true;
    }
    for (final attribute in element.attributes.entries) {
      if (attribute.key is! String || !(attribute.key as String).toLowerCase().startsWith('on')) {
        continue;
      }
      if (attribute.value.trim().isEmpty) {
        continue;
      }
      // Images and links already have native tap handlers for these Discuz helpers. A custom handler still counts.
      if ((tag == 'img' || tag == 'a') && _nativeHandler.hasMatch(attribute.value)) {
        continue;
      }
      return true;
    }
  }
  return false;
}

bool _isNativeControl(Element element, Node root) {
  if (element.classes.contains('spoilerbutton') || element.classes.contains('spoiler_btn')) {
    return true;
  }
  for (Element? current = element; current != null && current != root; current = current.parent) {
    final tag = current.localName;
    if (tag == 'code' || tag == 'pre' || current.classes.contains('blockcode')) {
      return true;
    }
    if ((tag == 'form' && current.id == 'poll') ||
        current.classes.contains('hb-entry') ||
        current.id == 'hb_mask' ||
        (tag == 'dl' && current.id.startsWith('ratelog_'))) {
      return true;
    }
  }
  return false;
}
