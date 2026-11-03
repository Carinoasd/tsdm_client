import 'package:tsdm_client/utils/html/author_style.dart';
import 'package:universal_html/html.dart' as uh;

/// What a piece of html does not show, as the web page shows it: the elements hidden by what they are
/// ([isHiddenBySelf]) or by the style sheets of the html ([isHidden]), the elements a browser never shows as text
/// ([invisibleElements]), and the folds a post made itself ([folds]): hidden until a click on another element shows
/// them, so shown by the app as a spoiler.
///
/// The munched content (`munchElement`) and the search in a thread (`threadSearchText`) read it alike: what is
/// searched is what can be seen, a fold's content included. Before, the search had rules of its own and the two came
/// apart: a fold's content was shown but not searched, and what the `hidden` attribute, `visibility: hidden` or a
/// style sheet hid was searched but not shown.
///
/// Not here: the text in a font size of 1px or less, which the muncher leaves out (its `tinyText`) as it reads the
/// font sizes down the elements (an `em` size is of the size around it). The search counts a hit in it: the floor is
/// marked, the words are not seen.
final class HiddenContent {
  /// [root] with the style the author gave each element read by [styleOf] (null when none): the muncher's, which it
  /// keeps for the rest of the munching.
  HiddenContent(this.root, {required this.styleOf});

  /// [root] with its style sheets read for this alone ([AuthorStyleSheets.of], [postContent] the content of a post).
  factory HiddenContent.of(uh.Element root, {required bool postContent}) {
    final styler = AuthorStyleSheets.of(root, postContent: postContent).styler(root);
    final styles = Map<uh.Element, AuthorStyle?>.identity();
    return HiddenContent(
      root,
      styleOf: (element) => styles.putIfAbsent(element, () {
        try {
          return styler.styleOf(element);
        } on Object {
          // A style that cannot be read is no style, as the muncher takes it.
          return null;
        }
      }),
    );
  }

  /// The html, where the folds are looked for.
  final uh.Element root;

  /// The style the author gave an element (its `style`, the style sheets), null when none.
  final AuthorStyle? Function(uh.Element element) styleOf;

  /// Whether [element] is not shown on the web page by itself: hidden by its own style (`display: none`, also
  /// written without the space: the jammer text some posts hide in `<span style="display:none">` was shown;
  /// `visibility: hidden`), by the `hidden` attribute, or the forum's jammer text (`<font class="jammer">`, which the
  /// style sheet paints white in a small size on the white page).
  static bool isHiddenBySelf(uh.Element element) =>
      element.attributes.containsKey('hidden') ||
      element.classes.contains('jammer') ||
      hiddenStyleRe.hasMatch(element.attributes['style'] ?? '');

  /// A `style` attribute hiding its element, whatever the case and the spaces.
  static final hiddenStyleRe = RegExp(
    r'(^|;)\s*(display\s*:\s*none|visibility\s*:\s*(hidden|collapse))\b',
    caseSensitive: false,
  );

  /// Whether [element] is not shown on the web page ([isHiddenBySelf]), also when the style sheets of the html hide it
  /// (`.answer { display: none }`).
  bool isHidden(uh.Element element) => isHiddenBySelf(element) || styleOf(element)?.display == 'none';

  /// Whether nothing of [element] is shown: it is hidden ([isHidden]) and no fold ([isFold]), whose content a click
  /// shows.
  bool leavesOut(uh.Element element) => isHidden(element) && !isFold(element);

  /// Whether [element] is a fold the post made itself ([folds]): hidden, it is still shown, as a spoiler.
  bool isFold(uh.Element element) => element.id.isNotEmpty && identical(folds[element.id]?.target, element);

  /// Whether [element] is the element whose click shows a fold ([folds]): the fold's title, shown with the fold.
  bool isFoldTitle(uh.Element element) => element.attributes.isNotEmpty && foldTitles.contains(element);

  /// The folds the post made itself, by the id of the hidden element: the element whose click shows it, its title.
  ///
  /// Posts written in html make folds of their own: an element with an id hidden by its style, shown by a click on
  /// another element (`<div onclick="document.getElementById('c1').style.display=…">▼ 展开</div>`, `$('c1')` too).
  /// Hidden like any hidden element, what they held could not be seen at all. The forum's popups (`.tip`, `*_menu`)
  /// and elements without an id (the jammer text) stay hidden.
  late final Map<String, ({uh.Element target, uh.Element title})> folds = () {
    final folds = <String, ({uh.Element target, uh.Element title})>{};
    final hidden = <String, uh.Element>{};
    for (final e in root.querySelectorAll('[id]')) {
      if (isHidden(e) && _canFold(e) && !_showsNothing(e)) {
        hidden.putIfAbsent(e.id, () => e);
      }
    }
    if (hidden.isEmpty) {
      return folds;
    }
    for (final title in root.querySelectorAll('[onclick], a[href]')) {
      final code = '${title.attributes['onclick'] ?? ''} ${title.attributes['href'] ?? ''}';
      for (final match in _foldTargetRe.allMatches(code)) {
        final id = match.namedGroup('id')!;
        final target = hidden[id];
        // A title holding its fold is shown, it shows the fold too.
        if (target != null && !folds.containsKey(id) && !_holds(title, target)) {
          folds[id] = (target: target, title: title);
        }
      }
    }
    return folds;
  }();

  /// The titles of [folds].
  late final Set<uh.Element> foldTitles = {for (final fold in folds.values) fold.title};

  static final _foldTargetRe = RegExp(r'''(?:getElementById|\$)\(\s*['"](?<id>[^'"]+)['"]\s*\)''');

  /// Whether the hidden [element] can be a fold of the post: it is none of the forum's popups.
  static bool _canFold(uh.Element element) =>
      element.id.isNotEmpty && !element.id.endsWith('_menu') && !element.classes.contains('tip');

  /// Whether the hidden [element] shows nothing when it is shown: no text, not even in what is hidden in it (another
  /// fold), no picture, no player, no control (a spoiler's title is the value of its button). It is no fold: what
  /// shows it stays as it is, as on the web page (before, the fold and its title were both left out). A form, as for
  /// a dialog (the forum's `activityjoincancel`), a script and a style show nothing.
  static bool _showsNothing(uh.Element element) {
    bool holdsSomething(uh.Node node) {
      for (final child in node.nodes) {
        if (child is uh.Element) {
          switch (child.localName) {
            case 'form' || 'script' || 'style':
              continue;
            case 'img' || 'iframe' || 'embed' || 'object' || 'video' || 'audio' || 'details' || 'textarea' || 'select':
              return true;
            case 'input':
              if (child.attributes['type']?.trim().toLowerCase() != 'hidden' &&
                  (child.attributes['value']?.trim().isNotEmpty ?? false)) {
                return true;
              }
            default:
              if (child.classes.contains('spoiler') || holdsSomething(child)) {
                return true;
              }
          }
        } else if (child.nodeType == uh.Node.TEXT_NODE &&
            (child.text ?? '').replaceAll(_htmlWhiteSpaceRe, '').isNotEmpty) {
          return true;
        }
      }
      return false;
    }

    return !holdsSomething(element);
  }

  static bool _holds(uh.Element ancestor, uh.Element element) {
    for (uh.Node? node = element; node != null; node = node.parentNode) {
      if (identical(node, ancestor)) {
        return true;
      }
    }
    return false;
  }

  static final _htmlWhiteSpaceRe = RegExp('[ \t\n\r\f]+');

  /// What the web page does not show: scripts, styles, a form (a template's form, the poll's, is shown by the app's
  /// own card) and its fields, ruby parentheses (the ruby text is shown above its base), what is there for browsers
  /// without plugins or frames, and other things a browser never shows as text. A button, a text box and a choice
  /// box out of a form are shown as their text.
  static const invisibleElements = {
    'script',
    'style',
    'noscript',
    'noembed',
    'noframes',
    'template',
    'head',
    'title',
    'meta',
    'link',
    'base',
    'form',
    'input',
    'option',
    'optgroup',
    'datalist',
    'rp',
    'param',
    'source',
    'track',
    'colgroup',
    'col',
    'map',
    'area',
    'canvas',
    'svg',
    'math',
    'dialog',
  };
}
