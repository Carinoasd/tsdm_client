import 'package:flutter/foundation.dart' show immutable;
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/thread/v1/utils/post_export.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/html/hidden_content.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// A run of text of a paragraph in the PDF.
@immutable
final class PdfSpan {
  /// Constructor.
  const PdfSpan(this.text, {this.bold = false, this.link});

  /// The text; a `\n` is a line break.
  final String text;

  /// Bold.
  final bool bold;

  /// Where the text links to, absolute.
  final String? link;

  @override
  bool operator ==(Object other) => other is PdfSpan && other.text == text && other.bold == bold && other.link == link;

  @override
  int get hashCode => Object.hash(text, bold, link);

  @override
  String toString() => 'PdfSpan(${[text, if (bold) 'bold', ?link].join(', ')})';
}

/// A block of a floor in the PDF. [quote] is how many quotes it is in.
@immutable
sealed class PdfBlock {
  const PdfBlock({required this.quote});

  /// How deep in quotes (and folds, and hidden content) the block is.
  final int quote;
}

/// A paragraph of [spans].
final class PdfParagraph extends PdfBlock {
  /// Constructor.
  const PdfParagraph(this.spans, {required super.quote});

  /// What the paragraph says.
  final List<PdfSpan> spans;

  /// The text of the paragraph.
  String get text => spans.map((e) => e.text).join();
}

/// An image of the floor, at [url].
final class PdfImageBlock extends PdfBlock {
  /// Constructor.
  const PdfImageBlock(this.url, {required super.quote});

  /// Absolute url of the image.
  final String url;
}

/// Code, kept line by line as it is.
final class PdfCodeBlock extends PdfBlock {
  /// Constructor.
  const PdfCodeBlock(this.code, {required super.quote});

  /// The code.
  final String code;
}

/// A horizontal rule.
final class PdfRuleBlock extends PdfBlock {
  /// Constructor.
  const PdfRuleBlock({required super.quote});
}

/// An attached file: its [name] (and size, as the forum printed it, when it did).
final class PdfAttachmentBlock extends PdfBlock {
  /// Constructor.
  const PdfAttachmentBlock(this.name, {required super.quote});

  /// The file name.
  final String name;
}

/// A floor in the PDF.
@immutable
final class PdfFloor {
  /// Constructor.
  const PdfFloor({
    required this.pid,
    required this.floor,
    required this.author,
    required this.time,
    required this.blocks,
  });

  /// Post id.
  final String pid;

  /// The floor number the forum shows.
  final int? floor;

  /// Author name.
  final String author;

  /// When it was posted.
  final DateTime? time;

  /// The content.
  final List<PdfBlock> blocks;
}

/// The floors of [posts] as the PDF shows them, in their order.
///
/// As the text export, the copy of a floor a hot reply makes is left out when the floor itself is among [posts], and a
/// floor met twice is kept once. The attachments the forum lists apart from the content (not put in it) follow it.
List<PdfFloor> pdfFloorsOf(List<Post> posts, {PostExportLabels labels = const PostExportLabels()}) {
  final originals = {
    for (final p in posts)
      if (!p.hot) p.postID,
  };
  final seen = <String>{};
  return [
    for (final p in posts)
      if (!(p.hot && originals.contains(p.postID)) && seen.add(p.postID))
        PdfFloor(
          pid: p.postID,
          floor: p.shownFloor,
          author: p.author.name,
          time: p.publishTime,
          blocks: [
            ...pdfBlocksOf(p.data, labels: labels),
            for (final a in p.attachments)
              if (!a.inPost && a.filename.trim().isNotEmpty) PdfAttachmentBlock(a.filename.trim(), quote: 0),
          ],
        ),
  ];
}

/// The content [html] of a floor as blocks of the PDF.
///
/// What is left out and how folds and hidden content are marked is as in [postHtmlToText]; their content goes in a
/// quote.
List<PdfBlock> pdfBlocksOf(String html, {PostExportLabels labels = const PostExportLabels()}) {
  final body = parseHtmlDocument(html).body;
  if (body == null) {
    return const [];
  }
  return (_Builder(labels, body)..run()).blocks;
}

final _wsRe = RegExp('[ \t\r\n\f ]+');

/// Elements that start and end a line of their own.
const _blockTags = {
  'address', 'article', 'aside', 'center', 'dd', 'details', 'dialog', 'div', 'dl', 'dt', 'fieldset', 'figcaption', //
  'figure', 'footer', 'header', 'li', 'main', 'nav', 'p', 'section', 'summary', 'table', 'tbody', 'td', 'tfoot', //
  'th', 'thead', 'tr',
};

final class _Builder {
  /// [hidden] of the whole floor is given for a part of it (a cell of a table).
  _Builder(this.labels, this.root, [HiddenContent? hidden])
    : hidden = hidden ?? HiddenContent.of(root, postContent: true);

  final PostExportLabels labels;
  final uh.Element root;
  final HiddenContent hidden;

  final blocks = <PdfBlock>[];

  // The paragraph being written.
  final _spans = <PdfSpan>[];
  int _quote = 0;
  int _bold = 0;
  String? _link;

  void run() {
    _children(root);
    _flush();
  }

  bool get _atLineStart => _spans.isEmpty || _spans.last.text.endsWith('\n');

  void _add(String text) {
    if (text.isEmpty) {
      return;
    }
    final bold = _bold > 0;
    if (_spans.isNotEmpty && _spans.last.bold == bold && _spans.last.link == _link) {
      final last = _spans.removeLast();
      _spans.add(PdfSpan(last.text + text, bold: bold, link: _link));
    } else {
      _spans.add(PdfSpan(text, bold: bold, link: _link));
    }
  }

  /// Text of the page: runs of white space are one space, none at the start of a line.
  void _text(String raw) {
    var t = raw.replaceAll(_wsRe, ' ');
    if (t.startsWith(' ') && (_atLineStart || _spans.last.text.endsWith(' '))) {
      t = t.substring(1);
    }
    _add(t);
  }

  void _br() {
    _trimEnd();
    _add('\n');
  }

  void _trimEnd() {
    if (_spans.isEmpty) {
      return;
    }
    final last = _spans.removeLast();
    final t = last.text.replaceFirst(RegExp(r' +$'), '');
    if (t.isNotEmpty) {
      _spans.add(PdfSpan(t, bold: last.bold, link: last.link));
    }
  }

  /// Ends the paragraph being written.
  void _flush() {
    // Line breaks and spaces at the ends of a paragraph show nothing.
    while (_spans.isNotEmpty) {
      final last = _spans.removeLast();
      final t = last.text.replaceFirst(RegExp(r'\s+$'), '');
      if (t.isNotEmpty) {
        _spans.add(PdfSpan(t, bold: last.bold, link: last.link));
        break;
      }
    }
    while (_spans.isNotEmpty) {
      final first = _spans.first;
      final t = first.text.replaceFirst(RegExp(r'^\s+'), '');
      if (t.isNotEmpty) {
        _spans[0] = PdfSpan(t, bold: first.bold, link: first.link);
        break;
      }
      _spans.removeAt(0);
    }
    if (_spans.isNotEmpty) {
      blocks.add(PdfParagraph(List.unmodifiable(_spans), quote: _quote));
      _spans.clear();
    }
  }

  void _addBlock(PdfBlock Function(int quote) block) {
    _flush();
    blocks.add(block(_quote));
  }

  void _children(uh.Node node) {
    for (final child in node.nodes) {
      if (child is uh.Text) {
        _text(child.data ?? '');
      } else if (child is uh.Element) {
        _element(child);
      }
    }
  }

  /// [mark] and [title] in a paragraph of their own, then [content] in a quote.
  void _labelled(String mark, String? title, void Function() content) {
    _flush();
    final head = [mark, if (title != null && title.trim().isNotEmpty) title.trim()].join(' ');
    blocks.add(PdfParagraph([PdfSpan(head, bold: true)], quote: _quote));
    _quote++;
    content();
    _flush();
    _quote--;
  }

  void _quoted(void Function() content) {
    _flush();
    _quote++;
    content();
    _flush();
    _quote--;
  }

  /// The text of [node] on one line.
  static String _lineOf(uh.Node node) => (node.text ?? '').replaceAll(_wsRe, ' ').trim();

  void _element(uh.Element el) {
    final tag = el.localName.toLowerCase();
    final classes = el.classes;

    // Before the hiding checks: a spoiler's body is hidden by its style until the button shows it.
    if (tag == 'div' && classes.contains('spoiler') && _spoiler(el)) {
      return;
    }
    if (tag == 'details') {
      final summary = el.children.where((e) => e.localName == 'summary').firstOrNull;
      _labelled(labels.fold, summary == null ? null : _lineOf(summary), () {
        for (final node in el.nodes) {
          if (identical(node, summary)) {
            continue;
          }
          if (node is uh.Text) {
            _text(node.data ?? '');
          } else if (node is uh.Element) {
            _element(node);
          }
        }
      });
      return;
    }
    if (hidden.isFoldTitle(el)) {
      return;
    }
    if (hidden.isFold(el)) {
      final title = hidden.folds[el.id]?.title;
      _labelled(labels.fold, title == null ? null : _lineOf(title), () => _children(el));
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
      _labelled(labels.hidden, _lineOf(el), () {});
      return;
    }
    if (tag == 'div' && classes.contains('showhide')) {
      _labelled(labels.hidden, null, () => _children(el));
      return;
    }
    if (tag == 'div' && classes.contains('blockcode')) {
      final lines = el.querySelectorAll('div ol li');
      var code = lines.isNotEmpty ? lines.map((e) => (e.text ?? '').trimRight()).join('\n') : (el.text ?? '').trim();
      final label = el.querySelector('em')?.text?.trim();
      // The `<em>` printing "copy code" is no part of the code.
      if (lines.isEmpty && label != null && label.isNotEmpty && code.endsWith(label)) {
        code = code.substring(0, code.length - label.length).trimRight();
      }
      if (code.isNotEmpty) {
        _addBlock((q) => PdfCodeBlock(code, quote: q));
      }
      return;
    }
    // An attachment the content shows: its name and size.
    if (tag == 'span' && el.id.startsWith('attach_')) {
      final name = _lineOf(el);
      if (name.isNotEmpty) {
        _addBlock((q) => PdfAttachmentBlock(name, quote: q));
      }
      return;
    }

    switch (tag) {
      case 'br':
        _br();
      case 'hr':
        _addBlock((q) => PdfRuleBlock(quote: q));
      case 'img':
        _image(el);
      case 'a':
        _anchor(el);
      case 'b' || 'strong':
        _bold++;
        _children(el);
        _bold--;
      case 'pre' || 'textarea':
        final code = (el.text ?? '').replaceAll(RegExp(r'^\n|\n$'), '');
        if (code.trim().isNotEmpty) {
          _addBlock((q) => PdfCodeBlock(code, quote: q));
        }
      case 'blockquote':
        _quoted(() => _children(el));
      case 'ul' || 'ol':
        _list(el, ordered: tag == 'ol');
      case 'table':
        _table(el);
      case 'rt':
        final text = _lineOf(el);
        if (text.isNotEmpty) {
          _add('($text)');
        }
      case 'iframe' || 'embed' || 'video' || 'audio' || 'object':
        final src = el.attributes['src'] ?? el.querySelector('source')?.attributes['src'] ?? el.attributes['data'];
        if (src != null && src.trim().isNotEmpty) {
          final url = _absolute(src);
          _text(' ${labels.media} ');
          final link = _link;
          _link = url;
          _add(url);
          _link = link;
          _text(' ');
        }
      default:
        if (_blockTags.contains(tag)) {
          _flush();
          _children(el);
          _flush();
        } else {
          _children(el);
        }
    }
  }

  /// A `div.spoiler` of the forum; false when it is none we know.
  bool _spoiler(uh.Element el) {
    final title =
        el.querySelector('div.spoiler_control > input.spoiler_btn')?.attributes['value'] ??
        el.querySelector('div.spoilerheader > input.spoilerbutton')?.attributes['value'];
    final body = el.querySelector('div.spoiler_content') ?? el.querySelector('div.spoilerbody');
    if (title == null || body == null) {
      return false;
    }
    _labelled(labels.fold, title, () => _children(body));
    return true;
  }

  static String _absolute(String url) {
    final u = url.trim();
    if (u.startsWith('http://') || u.startsWith('https://') || u.startsWith('mailto:')) {
      return u;
    }
    return u.prependHost();
  }

  void _anchor(uh.Element el) {
    final href = el.attributes['href']?.trim() ?? '';
    final usable = href.isNotEmpty && !href.startsWith('#') && !href.toLowerCase().startsWith('javascript:');
    if (!usable || _link != null) {
      _children(el);
      return;
    }
    _link = _absolute(href);
    _children(el);
    _link = null;
  }

  void _image(uh.Element el) {
    final src = el.attributes['src'] ?? '';
    final isSmiley =
        el.attributes.containsKey('smilieid') || src.contains('/smiley/') || src.contains('static/image/smiley');
    if (isSmiley) {
      var name = (el.attributes['alt'] ?? '').trim();
      final wrapped = RegExp(r'^:([^:]+):$').firstMatch(name);
      if (wrapped != null) {
        name = wrapped.group(1)!;
      }
      if (name.isEmpty) {
        final file = src.split('?').first.split('/').last;
        name = file.contains('.') ? file.substring(0, file.lastIndexOf('.')) : file;
      }
      _add('[${name.isEmpty ? labels.smiley : name}]');
      return;
    }
    // The icons of the forum's own (file types, the placeholder of an image loaded later without its file).
    final file = el.attributes['file']?.trim();
    final placeholder = src.contains('static/image/common/none.gif');
    if (src.contains('static/image/filetype/') || (placeholder && (file == null || file.isEmpty))) {
      return;
    }
    final url = placeholder && el.attributes['zoomfile'] == null ? _absolute(file!) : el.imageUrl();
    if (url == null || url.isEmpty) {
      return;
    }
    _addBlock((q) => PdfImageBlock(url, quote: q));
  }

  void _list(uh.Element el, {required bool ordered}) {
    _flush();
    var n = int.tryParse(el.attributes['start'] ?? '') ?? 1;
    for (final child in el.children) {
      if (child.localName != 'li' || hidden.leavesOut(child)) {
        continue;
      }
      _add(ordered ? '${n++}. ' : '• ');
      _children(child);
      _flush();
    }
  }

  static uh.Element? _tableOf(uh.Element el) {
    for (var p = el.parent; p != null; p = p.parent) {
      if (p.localName == 'table') {
        return p;
      }
    }
    return null;
  }

  /// A table of the post: a row is a paragraph, its cells apart by ` | `. The table of one cell the forum wraps a
  /// post in is no table.
  void _table(uh.Element table) {
    final rows = table
        .querySelectorAll('tr')
        .where((tr) => identical(_tableOf(tr), table) && !hidden.leavesOut(tr))
        .toList();
    List<uh.Element> cellsOf(uh.Element tr) =>
        tr.children.where((c) => (c.localName == 'td' || c.localName == 'th') && !hidden.leavesOut(c)).toList();
    _flush();
    if (rows.isEmpty) {
      _children(table);
      _flush();
      return;
    }
    if (rows.length == 1 && cellsOf(rows.first).length <= 1) {
      cellsOf(rows.first).forEach(_children);
      _flush();
      return;
    }
    for (final tr in rows) {
      var first = true;
      // The images and code of a cell would split the row: they follow it.
      final after = <PdfBlock>[];
      for (final cell in cellsOf(tr)) {
        if (!first) {
          _trimEnd();
          _add(' | ');
        }
        first = false;
        final inner = _Builder(labels, cell, hidden)
          .._quote = _quote
          .._children(cell)
          .._flush();
        for (final b in inner.blocks) {
          if (b is! PdfParagraph) {
            after.add(b);
            continue;
          }
          final link = _link;
          for (final s in b.spans) {
            _bold += s.bold ? 1 : 0;
            _link = s.link;
            _add(s.text.replaceAll('\n', ' '));
            _bold -= s.bold ? 1 : 0;
          }
          _link = link;
          _add(' ');
        }
        _trimEnd();
      }
      _flush();
      blocks.addAll(after);
    }
  }
}
