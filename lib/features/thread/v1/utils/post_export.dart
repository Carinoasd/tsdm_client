import 'package:flutter/foundation.dart' show immutable;
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/html/hidden_content.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// What a floor or a whole thread is turned into.
enum PostExportFormat {
  /// Text without markup: the structure is kept by blank lines, `- ` and `1. ` lists and `> ` quotes only.
  plainText,

  /// CommonMark with the GFM table and strikethrough.
  markdown
  ;

  /// Extension of the file written in this format, without the dot.
  String get extension => switch (this) {
    plainText => 'txt',
    markdown => 'md',
  };

  /// Media type of the file written in this format.
  String get mimeType => switch (this) {
    plainText => 'text/plain',
    markdown => 'text/markdown',
  };
}

/// The words the exported text marks things with. The defaults are the traditional Chinese ones.
@immutable
final class PostExportLabels {
  /// Constructor.
  const PostExportLabels({
    this.fold = exportFoldMark,
    this.hidden = exportHiddenMark,
    this.image = exportImageMark,
    this.media = exportMediaMark,
    this.smiley = exportSmileyFallback,
  });

  /// Mark of a fold (a spoiler, a `<details>`, a fold the post made itself).
  final String fold;

  /// Mark of the content the forum hides until the reader replies, buys or has the rights.
  final String hidden;

  /// Mark of an image in plain text; Markdown has its own syntax.
  final String image;

  /// Mark of a player or other media.
  final String media;

  /// Name of a smiley that tells none.
  final String smiley;
}

/// Default of [PostExportLabels.fold].
const exportFoldMark = '[折疊]';

/// Default of [PostExportLabels.hidden].
const exportHiddenMark = '[隱藏]';

/// Default of [PostExportLabels.image].
const exportImageMark = '[圖片]';

/// Default of [PostExportLabels.media].
const exportMediaMark = '[媒體]';

/// Default of [PostExportLabels.smiley].
const exportSmileyFallback = '表情';

/// The content [html] of a floor as [format].
///
/// What the web page does not show is left out as the floor's content leaves it out ([HiddenContent]: scripts, styles,
/// the jammer text, what the style hides), but what the page shows after a click is kept and marked: a fold gets
/// [PostExportLabels.fold] and its content goes into a quote, the content a reply or a purchase unlocks gets
/// [PostExportLabels.hidden]. A smiley is `[name]`.
String postHtmlToText(
  String html, {
  required PostExportFormat format,
  PostExportLabels labels = const PostExportLabels(),
}) {
  final body = parseHtmlDocument(html).body;
  if (body == null) {
    return '';
  }
  return _Renderer(format, labels, body).render();
}

/// A floor as the export needs it: plain values, so a list of them goes to an isolate.
typedef ExportFloor = ({String pid, bool hot, int? floor, String author, DateTime? time, String html});

/// [post] as an [ExportFloor].
ExportFloor exportFloorOf(Post post) => (
  pid: post.postID,
  hot: post.hot,
  floor: post.shownFloor,
  author: post.author.name,
  time: post.publishTime,
  html: post.data,
);

/// The floors [posts] and the thread's [title] written as one file in [format].
///
/// The copy of a floor a hot reply makes ([Post.hot]) is left out when the floor itself is among [posts], and a floor
/// met twice (pages loaded over each other) is written once. Each floor has its floor number, author and time.
String buildThreadExport({
  required String title,
  required List<Post> posts,
  required PostExportFormat format,
  String? url,
  PostExportLabels labels = const PostExportLabels(),
}) => buildThreadExportOfFloors(
  title: title,
  floors: posts.map(exportFloorOf).toList(),
  format: format,
  url: url,
  labels: labels,
);

/// [buildThreadExport] of [floors].
String buildThreadExportOfFloors({
  required String title,
  required List<ExportFloor> floors,
  required PostExportFormat format,
  String? url,
  PostExportLabels labels = const PostExportLabels(),
}) {
  final md = format == PostExportFormat.markdown;
  final out = StringBuffer();
  final oneLineTitle = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (md) {
    out.writeln('# ${_escapeMarkdown(oneLineTitle)}');
    if (url != null) {
      out
        ..writeln()
        ..writeln('<$url>');
    }
  } else {
    out.writeln(oneLineTitle);
    if (url != null) {
      out.writeln(url);
    }
  }
  final originals = {
    for (final f in floors)
      if (!f.hot) f.pid,
  };
  final seen = <String>{};
  for (final f in floors) {
    if ((f.hot && originals.contains(f.pid)) || !seen.add(f.pid)) {
      continue;
    }
    final floor = f.floor;
    final time = f.time?.yyyyMMDDHHMM();
    final content = postHtmlToText(f.html, format: format, labels: labels);
    out.writeln();
    if (md) {
      out
        ..writeln('---')
        ..writeln()
        ..writeln('## ${[if (floor != null) '#$floor', _escapeMarkdown(f.author), ?time].join(' · ')}');
    } else {
      out
        ..writeln('-' * 40)
        ..writeln([if (floor != null) '#$floor', f.author, ?time].join('  '));
    }
    if (content.isNotEmpty) {
      out
        ..writeln()
        ..writeln(content);
    }
  }
  return out.toString();
}

/// The name of the file a thread is written to: its [title] and [tid], with the characters a file name can not hold
/// replaced. [extension] replaces the one of [format].
String threadExportFileName({
  required String title,
  required String tid,
  required PostExportFormat format,
  String? extension,
}) {
  var name = title.replaceAll(RegExp(r'[\u0000-\u001f\u007f\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (name.runes.length > 60) {
    name = String.fromCharCodes(name.runes.take(60)).trim();
  }
  // A name ending with a dot or a space is refused on Windows.
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty) {
    name = 'thread';
  }
  return '$name-$tid.${extension ?? format.extension}';
}

final _wsRe = RegExp('[ \t\r\n\f ]+');

final _lineStartRe = RegExp(r'^(#{1,6}\s|>|[-+]\s)');
final _orderedStartRe = RegExp(r'^(\d+)([.)]\s)');

// A line of nothing but dashes or equal signs under a line of text makes it a heading.
final _underlineRe = RegExp(r'^\s*(-+|=+)\s*$');

final _underscoreRe = RegExp(r'(?<![\p{L}\p{N}])_|_(?![\p{L}\p{N}])', unicode: true);

/// Escapes what Markdown would read as markup in text; an underscore between letters or digits is none.
String _escapeMarkdown(String s) => s
    .replaceAll(r'\', r'\\')
    .replaceAll('`', r'\`')
    .replaceAll('*', r'\*')
    .replaceAll('~', r'\~')
    .replaceAll('[', r'\[')
    .replaceAll(']', r'\]')
    // Read as the start of a tag or an entity, the text would be html.
    .replaceAll('<', r'\<')
    .replaceAllMapped(RegExp('&(?=[A-Za-z#])'), (_) => r'\&')
    .replaceAllMapped(_underscoreRe, (_) => r'\_');

/// The text being written: tracks where a line starts so white space is collapsed as a browser does.
final class _Out {
  /// With [inline], the white space at both ends is kept: the content of an element in the middle of a line.
  _Out({required this.md, this.inline = false}) : _newlines = inline ? 0 : 2;

  final bool md;
  final bool inline;
  String _s = '';

  // Trailing line breaks of what is written, 2 at the very start (nothing to separate from).
  int _newlines;
  bool _space = false;

  bool get isEmpty => _s.isEmpty;

  /// Text of the page: runs of white space are one space, none at the start of a line.
  void text(String raw) {
    var t = raw.replaceAll(_wsRe, ' ');
    if (t.startsWith(' ') && (_newlines > 0 || _space)) {
      t = t.substring(1);
    }
    if (t.isEmpty) {
      return;
    }
    if (md && _newlines > 0) {
      if (_orderedStartRe.hasMatch(t)) {
        // The punctuation is escaped: a backslash before a digit shows.
        t = t.replaceFirstMapped(_orderedStartRe, (m) => '${m[1]}\\${m[2]}');
      } else if (_lineStartRe.hasMatch(t) || _underlineRe.hasMatch(t)) {
        t = '\\$t';
      }
    }
    _s += t;
    _newlines = 0;
    _space = t.endsWith(' ');
  }

  /// [s] as it is.
  void raw(String s) {
    if (s.isEmpty) {
      return;
    }
    _s += s;
    var n = 0;
    for (var i = s.length - 1; i >= 0 && s[i] == '\n'; i--) {
      n++;
    }
    _newlines = n == s.length ? _newlines + n : n;
    _space = false;
  }

  /// `<br>`: a line break, a hard one in Markdown.
  void br() {
    if (_newlines >= 2) {
      return;
    }
    _trimSpaces();
    _s += md && _newlines == 0 && _s.isNotEmpty ? '  \n' : '\n';
    _newlines++;
    _space = false;
  }

  /// A blank line between what is written and what follows.
  void blockBreak() {
    if (_s.isEmpty) {
      return;
    }
    _trimSpaces();
    // A hard break before a blank line breaks nothing.
    if (_newlines == 1 && _s.endsWith('  \n')) {
      _s = '${_s.substring(0, _s.length - 3)}\n';
    }
    if (_newlines < 2) {
      _s += '\n' * (2 - _newlines);
      _newlines = 2;
    }
    _space = false;
  }

  void _trimSpaces() {
    if (_newlines == 0 && _s.endsWith(' ')) {
      _s = _s.replaceFirst(RegExp(r' +$'), '');
    }
  }

  String get result => inline ? _s : _s.replaceFirst(RegExp(r'^\n+'), '').replaceFirst(RegExp(r'\s+$'), '');
}

/// Elements that start and end a line of their own.
const _blockTags = {
  'address', 'article', 'aside', 'center', 'dd', 'details', 'dialog', 'div', 'dl', 'dt', 'fieldset', 'figcaption', //
  'figure', 'footer', 'header', 'li', 'main', 'nav', 'p', 'section', 'summary', 'table', 'tbody', 'td', 'tfoot', //
  'th', 'thead', 'tr',
};

final class _Renderer {
  _Renderer(this.format, this.labels, this.root) : hidden = HiddenContent.of(root, postContent: true);

  final PostExportFormat format;
  final PostExportLabels labels;
  final uh.Element root;
  final HiddenContent hidden;

  bool get md => format == PostExportFormat.markdown;

  String render() {
    final out = _Out(md: md);
    _children(root, out);
    return out.result;
  }

  String _sub(uh.Node node) {
    final out = _Out(md: md);
    _children(node, out);
    return out.result;
  }

  void _children(uh.Node node, _Out out) {
    for (final child in node.nodes) {
      if (child is uh.Text) {
        _text(out, child.data ?? '');
      } else if (child is uh.Element) {
        _element(child, out);
      }
    }
  }

  void _text(_Out out, String data) => out.text(md ? _escapeMarkdown(data) : data);

  static String _quoted(String s) => s.split('\n').map((l) => l.isEmpty ? '>' : '> $l').join('\n');

  /// A labelled block: the [mark] and [title], then the [content] in a quote.
  void _labelled(_Out out, String mark, String? title, String content) {
    out.blockBreak();
    final head = [mark, if (title != null && title.trim().isNotEmpty) title.trim()].join(' ');
    out
      ..raw(content.isEmpty ? head : '$head\n${_quoted(content)}')
      ..blockBreak();
  }

  void _block(uh.Element el, _Out out, [void Function()? inner]) {
    out.blockBreak();
    if (inner != null) {
      inner();
    } else {
      _children(el, out);
    }
    out.blockBreak();
  }

  void _element(uh.Element el, _Out out) {
    final tag = el.localName.toLowerCase();
    final classes = el.classes;

    // Before the hiding checks: a spoiler's body is hidden by its style until the button shows it.
    if (tag == 'div' && classes.contains('spoiler')) {
      if (_spoiler(el, out)) {
        return;
      }
    }
    if (tag == 'details') {
      final summary = el.children.where((e) => e.localName == 'summary').firstOrNull;
      final body = _Out(md: md);
      for (final node in el.nodes) {
        if (identical(node, summary)) {
          continue;
        }
        if (node is uh.Text) {
          _text(body, node.data ?? '');
        } else if (node is uh.Element) {
          _element(node, body);
        }
      }
      _labelled(out, labels.fold, summary == null ? null : _inlineLine(_sub(summary)), body.result);
      return;
    }
    // The title of a fold a post made itself is the title of the fold, not text in its place.
    if (hidden.isFoldTitle(el)) {
      return;
    }
    if (hidden.isFold(el)) {
      final title = hidden.folds[el.id]?.title;
      _labelled(out, labels.fold, title == null ? null : _inlineLine(_sub(title)), _sub(el));
      return;
    }
    if (HiddenContent.invisibleElements.contains(tag) || hidden.leavesOut(el)) {
      return;
    }
    if (el.id == 'hb_mask' ||
        el.id.startsWith('ratelog_') ||
        classes.contains('pstatus') ||
        classes.contains('hb-entry')) {
      return;
    }
    if (tag == 'div' && classes.contains('locked')) {
      final text = _sub(el);
      out
        ..blockBreak()
        ..raw(text.isEmpty ? labels.hidden : '${labels.hidden} $text')
        ..blockBreak();
      return;
    }
    if (tag == 'div' && classes.contains('showhide')) {
      _labelled(out, labels.hidden, null, _sub(el));
      return;
    }
    if (tag == 'div' && classes.contains('blockcode')) {
      final lines = el.querySelectorAll('div ol li');
      final code = lines.isNotEmpty ? lines.map((e) => (e.text ?? '').trimRight()).join('\n') : (el.text ?? '').trim();
      // The `<em>` printing "copy code" is no part of the code.
      _codeBlock(out, lines.isNotEmpty ? code : _withoutCopyLabel(el, code));
      return;
    }

    switch (tag) {
      case 'br':
        out.br();
      case 'hr':
        out
          ..blockBreak()
          ..raw('---')
          ..blockBreak();
      case 'img':
        _image(el, out);
      case 'a':
        _link(el, out);
      case 'b' || 'strong':
        _wrapped(el, out, '**');
      case 'i' || 'em':
        _wrapped(el, out, '*');
      case 's' || 'strike' || 'del':
        _wrapped(el, out, '~~');
      case 'code':
        _inlineCode(el, out);
      case 'pre' || 'textarea':
        _codeBlock(out, (el.text ?? '').replaceAll(RegExp(r'^\n|\n$'), ''));
      case 'blockquote':
        final content = _sub(el);
        out.blockBreak();
        if (content.isNotEmpty) {
          out.raw(_quoted(content));
        }
        out.blockBreak();
      case 'h1' || 'h2' || 'h3' || 'h4' || 'h5' || 'h6':
        final text = _inlineLine(_sub(el));
        if (text.isNotEmpty) {
          out
            ..blockBreak()
            ..raw(md ? '${'#' * int.parse(tag.substring(1))} $text' : text)
            ..blockBreak();
        }
      case 'ul' || 'ol':
        _list(el, out, ordered: tag == 'ol');
      case 'table':
        _table(el, out);
      case 'rt':
        final text = _inlineLine(_sub(el));
        if (text.isNotEmpty) {
          out.text('($text)');
        }
      case 'iframe' || 'embed' || 'video' || 'audio' || 'object':
        final src = el.attributes['src'] ?? el.querySelector('source')?.attributes['src'] ?? el.attributes['data'];
        if (src != null && src.trim().isNotEmpty) {
          out.text(' ${labels.media} ${_absolute(src)} ');
        }
      default:
        if (_blockTags.contains(tag)) {
          _block(el, out);
        } else {
          _children(el, out);
        }
    }
  }

  static String _withoutCopyLabel(uh.Element el, String code) {
    final label = el.querySelector('em')?.text?.trim();
    return label != null && label.isNotEmpty && code.endsWith(label)
        ? code.substring(0, code.length - label.length).trimRight()
        : code;
  }

  /// The text of [s] on one line.
  static String _inlineLine(String s) => s.replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();

  /// A `div.spoiler` of the forum; false when it is none we know (rendered as any block then).
  bool _spoiler(uh.Element el, _Out out) {
    final title =
        el.querySelector('div.spoiler_control > input.spoiler_btn')?.attributes['value'] ??
        el.querySelector('div.spoilerheader > input.spoilerbutton')?.attributes['value'];
    final body = el.querySelector('div.spoiler_content') ?? el.querySelector('div.spoilerbody');
    if (title == null || body == null) {
      return false;
    }
    var content = body;
    // X5 wraps the body in a one-cell table.
    if (body.children.length == 1 && body.children.first.localName == 'table') {
      final cells = body.children.first.querySelectorAll('td');
      if (cells.length == 1) {
        content = cells.first;
      }
    }
    _labelled(out, labels.fold, md ? _escapeMarkdown(title) : title, _sub(content));
    return true;
  }

  /// Backticks that open and close [code] without it closing them: one more than its longest run, at least [min].
  static String _fenceFor(String code, int min) {
    final longest = RegExp('`+').allMatches(code).fold(0, (n, m) => m.group(0)!.length > n ? m.group(0)!.length : n);
    return '`' * (longest + 1 < min ? min : longest + 1);
  }

  void _codeBlock(_Out out, String code) {
    out.blockBreak();
    if (md) {
      final fence = _fenceFor(code, 3);
      out.raw('$fence\n$code\n$fence');
    } else {
      out.raw(code.split('\n').map((l) => l.isEmpty ? l : '    $l').join('\n'));
    }
    out.blockBreak();
  }

  void _inlineCode(uh.Element el, _Out out) {
    final code = (el.text ?? '').replaceAll(RegExp(r'\s+'), ' ');
    if (code.trim().isEmpty) {
      return;
    }
    if (!md) {
      out.text(code);
      return;
    }
    final fence = _fenceFor(code, 1);
    final pad = code.startsWith('`') || code.endsWith('`') ? ' ' : '';
    out.text('$fence$pad${code.trim()}$pad$fence');
  }

  /// How deep the emphasis of each marker is: a `<b>` in a `<b>` is bold once.
  final _emphasis = <String, int>{};

  static final _punctuationEdgeRe = RegExp(r'^(?!\*)[\p{P}\p{S}]|(?!\*)[\p{P}\p{S}]$', unicode: true);

  /// [core] in [marker]; in html tags when it starts or ends with punctuation: Markdown does not take `文字**「粗體」**`
  /// (a marker next to punctuation and a letter does not open or close).
  static String _mark(String marker, String core) {
    if (_punctuationEdgeRe.hasMatch(core)) {
      final tag = switch (marker) {
        '**' => 'strong',
        '*' => 'em',
        _ => 'del',
      };
      return '<$tag>$core</$tag>';
    }
    return '$marker$core$marker';
  }

  static final _blockStartRe = RegExp(r'^(\||>|```|#|[-+] |\d+\. )');

  /// [marker] around the content of [el] in Markdown, line by line where the content holds line breaks (a marker
  /// could not close on the next line); nothing around it in plain text, in the same emphasis, or around blocks.
  void _wrapped(uh.Element el, _Out out, String marker) {
    final depth = _emphasis[marker] ?? 0;
    _emphasis[marker] = depth + 1;
    final content = _Out(md: md, inline: true);
    _children(el, content);
    _emphasis[marker] = depth;
    final all = content.result;
    final inner = all.trim();
    if (inner.isEmpty) {
      if (all.isNotEmpty) {
        out.text(' ');
      }
      return;
    }
    // The white space at the ends stays outside the markers (`** a **` is no bold).
    if (all.startsWith(' ')) {
      out.text(' ');
    }
    if (!md || depth > 0) {
      out.raw(inner);
    } else {
      final lines = inner.split('\n');
      if (inner.contains('\n\n') || lines.any(_blockStartRe.hasMatch)) {
        out
          ..blockBreak()
          ..raw(inner)
          ..blockBreak();
        return;
      }
      out.raw(
        lines
            .map((line) {
              final core = line.trim();
              if (core.isEmpty) {
                return line;
              }
              return '${line.startsWith(' ') ? ' ' : ''}${_mark(marker, core)}${line.endsWith('  ') ? '  ' : ''}';
            })
            .join('\n'),
      );
    }
    if (all.endsWith(' ')) {
      out.text(' ');
    }
  }

  String _absolute(String url) {
    final u = url.trim();
    if (u.startsWith('http://') || u.startsWith('https://') || u.startsWith('mailto:')) {
      return u;
    }
    return u.prependHost();
  }

  String _mdUrl(String url) => url.replaceAll(' ', '%20').replaceAll('(', '%28').replaceAll(')', '%29');

  void _link(uh.Element el, _Out out) {
    final href = el.attributes['href']?.trim() ?? '';
    final inner = _sub(el);
    final usable = href.isNotEmpty && !href.startsWith('#') && !href.toLowerCase().startsWith('javascript:');
    // A picture in a link to itself or to a bigger one is the picture.
    if (!usable || (el.querySelector('img') != null && (el.text ?? '').trim().isEmpty)) {
      if (inner.isNotEmpty) {
        out.raw(inner);
      }
      return;
    }
    final url = _absolute(href);
    if (inner.isEmpty) {
      out.text(md ? '<$url>' : url);
    } else if ((el.text ?? '').trim() == href || (el.text ?? '').trim() == url) {
      out.text(md ? '<$url>' : url);
    } else if (md && !inner.contains('\n')) {
      out.text('[$inner](${_mdUrl(url)})');
    } else {
      out.text('${_inlineLine(inner)} ($url)');
    }
  }

  void _image(uh.Element el, _Out out) {
    final alt = (el.attributes['alt'] ?? '').trim();
    final src = el.attributes['src'] ?? '';
    final isSmiley =
        el.attributes.containsKey('smilieid') || src.contains('/smiley/') || src.contains('static/image/smiley');
    if (isSmiley) {
      var name = alt;
      final wrapped = RegExp(r'^:([^:]+):$').firstMatch(name);
      if (wrapped != null) {
        name = wrapped.group(1)!;
      }
      if (name.isEmpty) {
        final file = src.split('?').first.split('/').last;
        name = file.contains('.') ? file.substring(0, file.lastIndexOf('.')) : file;
      }
      final shown = name.isEmpty ? labels.smiley : name;
      // Escaped: a `[name]` before a `(` would be a link.
      out.text(md ? '\\[${_escapeMarkdown(shown)}\\]' : '[$shown]');
      return;
    }
    final url = el.imageUrl();
    if (url == null) {
      return;
    }
    if (md) {
      out.text('![${_escapeMarkdown(alt)}](${_mdUrl(url)})');
    } else {
      out.text(' ${labels.image} $url ');
    }
  }

  void _list(uh.Element el, _Out out, {required bool ordered}) {
    out.blockBreak();
    var n = int.tryParse(el.attributes['start'] ?? '') ?? 1;
    var first = true;
    for (final child in el.children) {
      if (child.localName != 'li' || hidden.leavesOut(child)) {
        continue;
      }
      final marker = ordered ? '${n++}. ' : '- ';
      final lines = _tightened(_sub(child).split('\n'));
      final indent = ' ' * marker.length;
      if (!first) {
        out.raw('\n');
      }
      first = false;
      out.raw(
        [
          for (var i = 0; i < lines.length; i++)
            i == 0 ? '$marker${lines[i]}' : (lines[i].isEmpty ? '' : '$indent${lines[i]}'),
        ].join('\n'),
      );
    }
    out.blockBreak();
  }

  static final _tightListRe = RegExp(r'^\s*(- |1\. )');

  /// [lines] of an item without the blank line before a list inside it that may follow a paragraph.
  static List<String> _tightened(List<String> lines) => [
    for (var i = 0; i < lines.length; i++)
      if (!(lines[i].isEmpty &&
          i > 0 &&
          i + 1 < lines.length &&
          lines[i - 1].isNotEmpty &&
          _tightListRe.hasMatch(lines[i + 1])))
        lines[i],
  ];

  static uh.Element? _tableOf(uh.Element el) {
    for (var p = el.parent; p != null; p = p.parent) {
      if (p.localName == 'table') {
        return p;
      }
    }
    return null;
  }

  void _table(uh.Element table, _Out out) {
    final rows = table
        .querySelectorAll('tr')
        .where((tr) => identical(_tableOf(tr), table) && !hidden.leavesOut(tr))
        .toList();
    List<uh.Element> cellsOf(uh.Element tr) =>
        tr.children.where((c) => (c.localName == 'td' || c.localName == 'th') && !hidden.leavesOut(c)).toList();
    // The forum wraps a post, and the body of a spoiler, in a table of one cell: not a table of the post.
    if (rows.isEmpty) {
      _block(table, out);
      return;
    }
    if (rows.length == 1 && cellsOf(rows.first).length <= 1) {
      _block(table, out, () {
        for (final cell in cellsOf(rows.first)) {
          _children(cell, out);
        }
      });
      return;
    }
    final grid = <List<String>>[];
    for (final tr in rows) {
      final row = <String>[];
      for (final cell in cellsOf(tr)) {
        var text = _sub(cell).replaceAll(RegExp(r'\s*\n\s*'), md ? '<br>' : ' ').trim();
        if (md) {
          text = text.replaceAll('|', r'\|');
        }
        row.add(text);
        final span = int.tryParse(cell.attributes['colspan'] ?? '') ?? 1;
        for (var i = 1; i < span && i < 50; i++) {
          row.add('');
        }
      }
      if (row.isNotEmpty) {
        grid.add(row);
      }
    }
    if (grid.isEmpty) {
      return;
    }
    final width = grid.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    for (final row in grid) {
      row.addAll(List.filled(width - row.length, ''));
    }
    out.blockBreak();
    if (md) {
      String line(List<String> r) => '| ${r.join(' | ')} |';
      out
        ..raw(line(grid.first))
        ..raw('\n')
        ..raw(line(List.filled(width, '---')));
      for (final row in grid.skip(1)) {
        out
          ..raw('\n')
          ..raw(line(row));
      }
    } else {
      out.raw(grid.map((r) => r.join(' | ')).join('\n'));
    }
    out.blockBreak();
  }
}
