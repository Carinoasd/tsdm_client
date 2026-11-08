import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_pdf_content.dart';

/// The words the PDF prints, in the language of the app.
@immutable
final class ThreadPdfLabels {
  /// Constructor.
  const ThreadPdfLabels({required this.exportedAt, required this.attachment, required this.image});

  /// Before the time of the export.
  final String exportedAt;

  /// Before the name of an attached file.
  final String attachment;

  /// In place of an image that could not be had.
  final String image;
}

/// Everything a PDF of a thread is made of: plain values, sent to an isolate as they are.
@immutable
final class ThreadPdfJob {
  /// Constructor.
  const ThreadPdfJob({
    required this.title,
    required this.url,
    required this.exportedAt,
    required this.floors,
    required this.labels,
    this.font,
    this.images = const {},
  });

  /// Thread title.
  final String title;

  /// Thread url.
  final String url;

  /// When the export was made.
  final DateTime exportedAt;

  /// The floors.
  final List<PdfFloor> floors;

  /// The words the PDF prints.
  final ThreadPdfLabels labels;

  /// TrueType font of the text; the PDF's standard Helvetica when null (no CJK: tests only).
  final Uint8List? font;

  /// The bytes of the images by url, JPEG or PNG; an image missing or unreadable is drawn as a placeholder.
  final Map<String, Uint8List> images;
}

/// Most pages a PDF may have: the floors of a whole thread of thousands of floors.
const _maxPages = 5000;

const _fontSize = 10.5;
const _quoteIndent = 10.0;
const _linkColor = PdfColor.fromInt(0xFF1565C0);
const _greyColor = PdfColor.fromInt(0xFF757575);
const _ruleColor = PdfColor.fromInt(0xFFBDBDBD);
const _codeBackground = PdfColor.fromInt(0xFFF2F2F2);

/// Highest an image is drawn: a tall one is shrunk to fit a page.
const _maxImageHeight = 560.0;

const _horizontalMargin = 48.0;

/// A pixel of an image is drawn as a CSS pixel (96 per inch, 72 points).
const _pointsPerPixel = 0.75;

/// [image] at the size it has on a screen, shrunk to fit the width left by [quote] quotes and [_maxImageHeight]; never
/// enlarged (a small picture blown up to the width of the page).
pw.Widget _sized(pw.ImageProvider image, int quote) {
  final width = (image.width ?? 1) * _pointsPerPixel;
  final height = (image.height ?? 1) * _pointsPerPixel;
  final maxWidth = PdfPageFormat.a4.width - _horizontalMargin * 2 - quote * (_quoteIndent + 4);
  final scale = [1.0, maxWidth / width, _maxImageHeight / height].reduce((a, b) => a < b ? a : b);
  return pw.Image(image, width: width * scale, height: height * scale);
}

/// The PDF of [job].
Future<Uint8List> buildThreadPdf(ThreadPdfJob job) async {
  final fontData = job.font;
  final font = fontData == null ? null : pw.Font.ttf(ByteData.sublistView(fontData));
  final theme = font == null
      ? pw.ThemeData.base()
      : pw.ThemeData.withFont(base: font, bold: font, italic: font, boldItalic: font);
  final doc = pw.Document(title: job.title, creator: 'tsdm_client', theme: theme);
  final images = <String, pw.ImageProvider?>{};

  pw.ImageProvider? imageOf(String url) => images.putIfAbsent(url, () {
    final bytes = job.images[url];
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    try {
      return pw.MemoryImage(bytes);
    } on Object {
      return null;
    }
  });

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.symmetric(horizontal: _horizontalMargin, vertical: 44),
      maxPages: _maxPages,
      theme: theme.copyWith(defaultTextStyle: theme.defaultTextStyle.copyWith(fontSize: _fontSize, lineSpacing: 3)),
      footer: (context) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          '${context.pageNumber} / ${context.pagesCount}',
          style: const pw.TextStyle(fontSize: 8, color: _greyColor),
        ),
      ),
      build: (context) => [
        pw.Text(
          job.title.replaceAll(RegExp(r'\s+'), ' ').trim(),
          style: const pw.TextStyle(fontSize: 17),
          overflow: pw.TextOverflow.span,
        ),
        pw.SizedBox(height: 6),
        pw.UrlLink(
          destination: job.url,
          child: pw.Text(job.url, style: const pw.TextStyle(fontSize: 8.5, color: _linkColor)),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          '${job.labels.exportedAt} ${job.exportedAt.yyyyMMDDHHMM()}',
          style: const pw.TextStyle(fontSize: 8.5, color: _greyColor),
        ),
        for (final floor in job.floors) ..._floor(floor, job.labels, imageOf),
      ],
    ),
  );
  return doc.save();
}

List<pw.Widget> _floor(PdfFloor floor, ThreadPdfLabels labels, pw.ImageProvider? Function(String) imageOf) => [
  pw.SizedBox(height: 14),
  pw.Divider(height: 1, thickness: 0.6, color: _ruleColor),
  pw.SizedBox(height: 6),
  pw.RichText(
    overflow: pw.TextOverflow.span,
    text: pw.TextSpan(
      children: [
        if (floor.floor != null) _boldSpans('#${floor.floor}  ', const pw.TextStyle(color: _greyColor)),
        _boldSpans(floor.author),
        if (floor.time != null)
          pw.TextSpan(
            text: '  ${floor.time!.yyyyMMDDHHMM()}',
            style: const pw.TextStyle(fontSize: 8.5, color: _greyColor),
          ),
      ],
    ),
  ),
  pw.SizedBox(height: 4),
  for (final block in floor.blocks) _quoted(block.quote, _block(block, labels, imageOf)),
];

/// [child] in [depth] quotes: a bar on the left for each. Applied block by block, so a long quote can go on to the
/// next page.
pw.Widget _quoted(int depth, pw.Widget child) {
  var w = child;
  for (var i = 0; i < depth; i++) {
    w = pw.Container(
      padding: const pw.EdgeInsets.only(left: _quoteIndent - 2),
      margin: const pw.EdgeInsets.only(left: 2),
      decoration: const pw.BoxDecoration(
        border: pw.Border(left: pw.BorderSide(color: _ruleColor, width: 2)),
      ),
      child: w,
    );
  }
  return w;
}

pw.Widget _block(PdfBlock block, ThreadPdfLabels labels, pw.ImageProvider? Function(String) imageOf) => switch (block) {
  PdfParagraph(:final spans) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 3),
    child: pw.RichText(
      overflow: pw.TextOverflow.span,
      text: pw.TextSpan(children: [for (final s in spans) _span(s)]),
    ),
  ),
  PdfImageBlock(:final url) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 4),
    child: switch (imageOf(url)) {
      final image? => pw.Align(
        alignment: pw.Alignment.centerLeft,
        child: _sized(image, block.quote),
      ),
      null => pw.Container(
        width: double.infinity,
        padding: const pw.EdgeInsets.all(6),
        decoration: pw.BoxDecoration(border: pw.Border.all(color: _ruleColor, width: 0.6)),
        child: pw.UrlLink(
          destination: url,
          child: pw.Text(
            '${labels.image} $url',
            style: const pw.TextStyle(fontSize: 8.5, color: _greyColor),
            overflow: pw.TextOverflow.span,
          ),
        ),
      ),
    },
  ),
  PdfCodeBlock(:final code) => pw.Container(
    width: double.infinity,
    margin: const pw.EdgeInsets.symmetric(vertical: 3),
    padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    color: _codeBackground,
    child: pw.Text(code, style: const pw.TextStyle(fontSize: 9), overflow: pw.TextOverflow.span),
  ),
  PdfRuleBlock() => pw.Divider(height: 10, thickness: 0.5, color: _ruleColor),
  PdfAttachmentBlock(:final name) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 3),
    child: pw.RichText(
      overflow: pw.TextOverflow.span,
      text: pw.TextSpan(
        children: [
          pw.TextSpan(
            text: '${labels.attachment}  ',
            style: const pw.TextStyle(color: _greyColor),
          ),
          pw.TextSpan(text: name),
        ],
      ),
    ),
  ),
};

pw.InlineSpan _span(PdfSpan s) {
  final link = s.link;
  final style = link == null
      ? null
      : const pw.TextStyle(color: _linkColor, decoration: pw.TextDecoration.underline, decorationColor: _linkColor);
  final annotation = link == null ? null : pw.AnnotationUrl(link);
  if (s.bold) {
    return _boldSpans(s.text, style, annotation);
  }
  return pw.TextSpan(text: s.text, style: style, annotation: annotation);
}

/// A CJK character, or a word with the white space after it.
final _boldPieceRe = RegExp(r'\n|[^\s⺀-鿿가-힯豈-﫿＀-￯]+\s*|\s+|.', unicode: true);

/// [text] in bold.
///
/// The font has one weight, the strokes of the glyphs are drawn over them. The way of drawing text is kept by the PDF
/// from one text to the next and the pdf package never sets it back: each piece is drawn in a state of its own
/// ([_BoldPiece]), so the text after is not bold too. Pieces as small as a word let the line break among them.
pw.InlineSpan _boldSpans(String text, [pw.TextStyle? style, pw.AnnotationBuilder? annotation]) => pw.TextSpan(
  style: style,
  annotation: annotation,
  children: [
    for (final m in _boldPieceRe.allMatches(text))
      if (m[0]!.trim().isEmpty)
        pw.TextSpan(text: m[0])
      else
        pw.WidgetSpan(
          child: _BoldPiece(m[0]!.trimRight(), style, spaceAfter: m[0]!.length != m[0]!.trimRight().length),
        ),
  ],
);

/// A piece of bold text, inline.
final class _BoldPiece extends pw.Widget {
  _BoldPiece(this.text, this.style, {required this.spaceAfter});

  final String text;

  /// The style of the span, over the default one.
  final pw.TextStyle? style;

  /// Whether a space follows the piece (a word of latin text).
  final bool spaceAfter;

  late pw.TextStyle _style;
  late PdfFont _font;

  @override
  void layout(pw.Context context, pw.BoxConstraints constraints, {bool parentUsesSize = false}) {
    _style = pw.Theme.of(context).defaultTextStyle.merge(style);
    _font = _style.font!.getFont(context);
    final size = _style.fontSize!;
    final metrics = _font.stringMetrics(text) * size;
    final space = spaceAfter ? _font.stringMetrics(' ').advanceWidth * size : 0.0;
    // The box stands on the baseline.
    box = PdfRect(0, 0, metrics.advanceWidth + space, _font.ascent * size);
  }

  @override
  void paint(pw.Context context) {
    super.paint(context);
    final color = _style.color ?? PdfColors.black;
    context.canvas
      ..saveContext()
      ..setFillColor(color)
      ..setStrokeColor(color)
      ..setLineWidth(_style.fontSize! * 0.035)
      ..setLineJoin(PdfLineJoin.round)
      ..drawString(_font, _style.fontSize!, text, box!.left, box!.bottom, mode: PdfTextRenderingMode.fillAndStroke)
      ..restoreContext();
  }
}
