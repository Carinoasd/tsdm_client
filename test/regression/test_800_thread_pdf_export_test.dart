// HTML fixtures are written as adjacent strings of tags, no white space between them is meant.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/thread/v1/repository/pdf_font_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/post_export.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_pdf_builder.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_pdf_content.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_pdf_export_action.dart';
import 'package:tsdm_client/features/update/repository/release_update_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// The PDF export of a thread: the content of a floor as blocks (paragraphs with bold and links, quotes, images,
/// code, attached files), the floors of a whole thread, the document built of them, and the font kept on the device.
///
/// `thread_pdf/viewthread_v18_rich.json` is a thread of the test forum (plugin 3.4.0, `tsdmapp=json`): the first
/// floor quotes an image attachment and a zip attachment, the second is bold text, a link, a quote, an image that
/// can not load, a list, code and a rule.

const _labels = ThreadPdfLabels(exportedAt: 'Exported at', attachment: 'Attachment', image: '[Image]');

Map<String, dynamic> _fixture() =>
    jsonDecode(File('test/data/thread_pdf/viewthread_v18_rich.json').readAsStringSync()) as Map<String, dynamic>;

List<Post> _fixturePosts() {
  final data = _fixture();
  return [
    for (final p in (data['posts'] as List).cast<Map<String, dynamic>>())
      Post.fromApi(p, tid: '${data['tid']}', fid: data['fid'] as int, viewerUid: 31, page: 1),
  ];
}

Post _post(
  int floor,
  String data, {
  String author = 'alice',
  bool hot = false,
  String? pid,
  List<PostAttachment> attachments = const [],
}) => Post(
  postID: pid ?? '${700000 + floor}',
  postFloor: hot ? null : floor,
  author: User(name: author, url: 'u'),
  publishTime: DateTime(2026, 10, 23, 8, 5),
  data: data,
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: 1,
  isDraft: false,
  packetAllTaken: false,
  hot: hot,
  hotFloor: hot ? floor : null,
  attachments: attachments,
);

PostAttachment _attachment(String name, {required bool inPost}) => PostAttachment(
  aid: 5,
  filename: name,
  description: '',
  isImage: false,
  url: 'https://forum.test/forum.php?mod=attachment&aid=x',
  thumb: '',
  download: 'https://forum.test/forum.php?mod=attachment&aid=x',
  width: 0,
  height: 0,
  filesize: 153,
  price: 0,
  readPerm: 0,
  downloads: 0,
  locked: false,
  inPost: inPost,
);

/// The blocks as short strings: `P:` paragraph (bold runs in `**`, links as `[text](url)`), `I:` image, `C:` code,
/// `A:` attachment, `HR`; `>` for each quote.
List<String> _shape(List<PdfBlock> blocks) => [
  for (final b in blocks)
    '${'>' * b.quote}${switch (b) {
      PdfParagraph(:final spans) => 'P:${spans.map((s) {
        final t = s.bold ? '**${s.text}**' : s.text;
        return s.link == null ? t : '[$t](${s.link})';
      }).join()}',
      PdfImageBlock(:final url) => 'I:$url',
      PdfCodeBlock(:final code) => 'C:$code',
      PdfAttachmentBlock(:final name) => 'A:$name',
      PdfRuleBlock() => 'HR',
    }}',
];

/// The text a PDF draws, as far as the uncompressed content shows it: enough to tell it is a PDF of pages.
int _pageCount(Uint8List pdf) => RegExp(r'/Type\s*/Page\b').allMatches(latin1.decode(pdf)).length;

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('content of a floor', () {
    test('the rich floor of the fixture', () {
      final posts = _fixturePosts();
      final floors = pdfFloorsOf(posts);
      expect(floors.map((f) => f.floor), [1, 2]);
      expect(floors.map((f) => f.author), ['alice', 'alice']);
      expect(_shape(floors[1].blocks), [
        'P:PDF 匯出夾具：**粗體文字** 與一般文字，[連結文字](https://example.com/page)。\n第二行 斜體',
        '>P:引用的內容 **引用內粗體**\n[quote]第二層引用',
        'P:[/quote]',
        'I:https://forum.test/broken-image.png',
        'P:• 項目一',
        'P:• 項目二',
        // The indent of the forum's code is `&nbsp;`.
        'C:int main() {\n\u00a0\u00a0return 0;\n}',
        'P:[spoiler=摺疊標題]摺疊內容[/spoiler]',
        'HR',
        'P:最後一段 :)',
      ]);
    });

    test('the attachments the floor shows: the image as an image, the file by its name, the tips left out', () {
      final floors = pdfFloorsOf(_fixturePosts());
      final shape = _shape(floors[0].blocks);
      expect(shape.first, '>P:封面：');
      // A relative image url is on the forum the app uses.
      expect(shape, contains('>I:$baseUrl/data/attachment/forum/202610/14/132345utvny82hyo2tt2no.png'));
      expect(shape, contains('>A:acc_note.zip (153 Bytes, 下载次数: 0)'));
      // The hidden menus of the attachments (download link, upload time) are no content.
      expect(shape.join('\n'), isNot(contains('上传')));
      expect(shape.join('\n'), isNot(contains('filetype')));
      expect(shape.last, 'P:网盘链接 Link：https://mega.nz/up422478');
    });

    test('nested quotes, folds, hidden content and smileys', () {
      const html =
          '<div class="quote"><blockquote>outer<div class="quote"><blockquote>inner</blockquote></div></blockquote></div>'
          '<details><summary>Sum</summary>folded <b>bold</b></details>'
          '<div class="showhide">secret</div>'
          '<div class="locked">reply to see</div>'
          'a <img src="static/image/smiley/x/1.gif" smilieid="1" alt=":smile:"> b'
          '<div style="display:none">gone</div>';
      expect(_shape(pdfBlocksOf(html)), [
        '>P:outer',
        '>>P:inner',
        'P:**[折疊] Sum**',
        '>P:folded **bold**',
        'P:**[隱藏]**',
        '>P:secret',
        'P:**[隱藏] reply to see**',
        'P:a [smile] b',
      ]);
    });

    test('a link around a picture is the picture, a script link is no link', () {
      const html =
          '<a href="https://forum.test/big.jpg"><img src="https://forum.test/small.jpg"></a>'
          '<a href="javascript:void(0)">js</a> <a href="forum.php?mod=viewthread&amp;tid=9">t</a>';
      final shape = _shape(pdfBlocksOf(html));
      expect(shape.first, 'I:https://forum.test/small.jpg');
      expect(shape.last, startsWith('P:js [t](http'));
      expect(shape.last, endsWith('forum.php?mod=viewthread&tid=9)'));
    });

    test('a table is a paragraph per row, its pictures after the row', () {
      const html =
          '<table><tr><th>a</th><th><b>b</b></th></tr>'
          '<tr><td>1<img src="https://forum.test/p.png"></td><td>2</td></tr></table>';
      expect(_shape(pdfBlocksOf(html)), ['P:a | **b**', 'P:1 | 2', 'I:https://forum.test/p.png']);
    });

    test('the copy of a hot reply and a floor met twice are kept once; files not in the content follow it', () {
      final floors = pdfFloorsOf([
        _post(1, 'one', attachments: [_attachment('in.zip', inPost: true), _attachment('apart.rar', inPost: false)]),
        _post(2, 'two', author: 'bob'),
        _post(2, 'two', author: 'bob', hot: true, pid: '700002'),
        _post(1, 'one'),
      ]);
      expect(floors.map((f) => f.pid), ['700001', '700002']);
      expect(_shape(floors[0].blocks), ['P:one', 'A:apart.rar']);
    });
  });

  group('the document', () {
    test('a thread of many pages, long quotes and paragraphs, bold, links and images', () async {
      final png = Uint8List.fromList(img.encodePng(img.Image(width: 40, height: 30)));
      final long = 'word ' * 600;
      final posts = [
        for (var i = 1; i <= 60; i++)
          _post(
            i,
            '<b>Bold</b> text <a href="https://example.com/$i">link</a>'
            '<div class="quote"><blockquote>$long<div class="quote"><blockquote>$long</blockquote></div></blockquote></div>'
            '<img src="https://forum.test/ok.png"><img src="https://forum.test/broken.png">'
            '<div class="blockcode"><div><ol><li>code line</ol></div></div><hr>',
            attachments: [_attachment('file.zip', inPost: false)],
          ),
      ];
      final pdf = await buildThreadPdf(
        ThreadPdfJob(
          title: 'A long thread',
          url: 'https://forum.test/forum.php?mod=viewthread&tid=1',
          exportedAt: DateTime(2026, 11, 9, 10),
          floors: pdfFloorsOf(posts),
          labels: _labels,
          images: {
            'https://forum.test/ok.png': png,
            'https://forum.test/broken.png': Uint8List.fromList([1, 2, 3, 4]),
          },
        ),
      );
      expect(latin1.decode(pdf.sublist(0, 5)), '%PDF-');
      // More than the 20 pages the pdf package allows by default.
      expect(_pageCount(pdf), greaterThan(20));
    });

    test('an empty thread is a page with the title', () async {
      final pdf = await buildThreadPdf(
        ThreadPdfJob(
          title: 'Empty',
          url: 'https://forum.test/forum.php?mod=viewthread&tid=2',
          exportedAt: DateTime(2026, 11, 9, 10),
          floors: const [],
          labels: _labels,
        ),
      );
      expect(_pageCount(pdf), 1);
    });

    test('images the PDF takes: a JPEG as it is, others as a PNG within 1600 × 2400, unreadable ones none', () {
      final jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 10, height: 10)));
      final asIs = pdfImageBytes(jpeg)!;
      expect(identical(asIs.bytes, jpeg), isTrue);
      expect(asIs.cost, jpeg.length);
      final wide = pdfImageBytes(Uint8List.fromList(img.encodeGif(img.Image(width: 3200, height: 100))))!;
      expect(img.PngDecoder().isValidFile(wide.bytes), isTrue);
      expect(img.decodePng(wide.bytes)!.width, 1600);
      // The pdf package decodes a PNG to pixels: that is its cost.
      expect(wide.cost, 1600 * 50 * 4);
      final tall = pdfImageBytes(Uint8List.fromList(img.encodePng(img.Image(width: 100, height: 4800))))!;
      expect([img.decodePng(tall.bytes)!.width, img.decodePng(tall.bytes)!.height], [50, 2400]);
      expect(pdfImageBytes(Uint8List.fromList(utf8.encode('<html>not an image</html>'))), isNull);
      // Too many pixels: not decoded, a placeholder.
      final huge = Uint8List.fromList(img.encodeBmp(img.Image(width: 8000, height: 5001, numChannels: 1)));
      expect(pdfImageBytes(huge), isNull);
    });

    test('bold text is cut in words and CJK characters, a line break kept apart', () {
      List<String> pieces(String s) => boldPieceRe.allMatches(s).map((m) => m[0]!).toList();
      expect(pieces('Hello\nWorld'), ['Hello', '\n', 'World']);
      expect(pieces('two words'), ['two ', 'words']);
      expect(pieces('粗體 bold'), ['粗', '體', ' ', 'bold']);
    });

    test('the file name ends with .pdf', () {
      expect(
        threadExportFileName(title: 'a/b', tid: '12', format: PostExportFormat.plainText, extension: 'pdf'),
        'a_b-12.pdf',
      );
    });
  });

  group('the font', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('pdf_font_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    final good = Uint8List.fromList(List.generate(100, (i) => i));
    // Not the hash of [good].
    const wrongSha = '0000000000000000000000000000000000000000000000000000000000000000';

    PdfFontRepository repo(Map<String, List<int>> served, List<PdfFontSource> sources) {
      final dio = Dio()..httpClientAdapter = _MapAdapter(served);
      return PdfFontRepository(dio: dio, directory: () async => dir, sources: sources);
    }

    test('a file of the wrong hash is refused and not kept, the next source is used', () async {
      final digest = await _sha256(good);
      final r = repo(
        {'https://a.test/f': good, 'https://b.test/f': good},
        [
          const PdfFontSource(url: 'https://a.test/f', size: 100, sha256: wrongSha),
          PdfFontSource(url: 'https://b.test/f', size: 100, sha256: digest),
        ],
      );
      var progressed = false;
      final file = await r.obtain(onProgress: (received, total) => progressed = true);
      expect(file.readAsBytesSync(), good);
      expect(progressed, isTrue);
      expect(dir.listSync().map((e) => e.uri.pathSegments.last), [pdfFontFileName]);
      // Kept: no second download.
      expect(await r.cached(), isNotNull);
    });

    test('no source with the right file: unavailable, nothing left on the device', () async {
      final r = repo(
        {'https://a.test/f': good},
        [const PdfFontSource(url: 'https://a.test/f', size: 100, sha256: wrongSha)],
      );
      await expectLater(r.obtain(), throwsA(isA<PdfFontUnavailableException>()));
      expect(dir.listSync(), isEmpty);
      expect(await r.cached(), isNull);
    });

    test('the sources are fixed files of GitHub, ours first', () {
      expect(
        pdfFontSources.first.url,
        'https://github.com/Carinoasd/tsdm_client/releases/download/assets-fonts-1/NotoSansSC-Regular.ttf',
      );
      expect(pdfFontSources.first.sha256, pdfFontSources[1].sha256, reason: 'the same file as the first origin');
      expect(pdfFontSources.first.size, pdfFontSources[1].size);
      for (final s in pdfFontSources.skip(1)) {
        expect(s.url, startsWith('https://media.githubusercontent.com/media/'));
      }
      for (final s in pdfFontSources) {
        expect(s.url, endsWith('/$pdfFontFileName'));
        expect(s.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(s.size, greaterThan(10000000));
      }
    });
  });
}

/// The SHA-256 of [data] as the app computes it.
Future<String> _sha256(List<int> data) async {
  final dir = Directory.systemTemp.createTempSync('pdf_font_sha');
  try {
    final file = File('${dir.path}/f')..writeAsBytesSync(data);
    return (await ReleaseUpdateRepository.hashFile(file.path, data.length))!;
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// Serves [files] by url, 404 for any other.
final class _MapAdapter implements HttpClientAdapter {
  _MapAdapter(this.files);

  final Map<String, List<int>> files;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final data = files[options.uri.toString()];
    if (data == null) {
      return ResponseBody.fromString('', 404);
    }
    return ResponseBody.fromBytes(
      data,
      200,
      headers: {
        Headers.contentLengthHeader: ['${data.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
