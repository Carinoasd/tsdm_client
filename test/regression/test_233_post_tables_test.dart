/// Tables in a post laid out as the web page lays them out (the third phase of the post display work, measured against
/// the forum's web page floor by floor), and three things left over from the first phase.
///
/// What was wrong, and is checked here on small samples written after the real posts:
///
/// * a cell spanning columns or rows (`colspan`, `rowspan`) was drawn in its first place only, the places it spans
///   left empty: a header over three columns sat over the first of them, a cell spanning two rows was as tall as the
///   first row;
/// * a table was laid out by a [Table], whose columns are narrowed one after the other and only as far as words and
///   images let them; a table that did not fit scrolled with each column up to the screen wide. A row of books with
///   five columns was 1185 px wide on a 346 px post, the reader had to slide each row; three cells "image, link, hidden
///   content" put the hidden content past the screen;
/// * an image in a cell kept at least 120 px, three images side by side made the table scroll;
/// * the widths the author gives a table or a cell (`[table=98%]`, `width="50%"`, `width="200"`) were ignored, and
///   the cells had no space around their text, the web page has 4 px;
/// * `valign` was ignored.
///
/// Left from the first phase:
///
/// * a `<script>`, `<style>` or `<iframe>` the muncher failed on had its source shown as text;
/// * read from the web page, the forum's buttons in the blocks of a special thread ("支持", "我来回答", "结束此次辩论")
///   were text that could not be pressed;
/// * an empty spoiler lost its title with its content.
library;

// HTML fixtures are split into lines at tag boundaries.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/post_table.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/card/lock_card/locked_card.dart';
import 'package:tsdm_client/widgets/card/spoiler_card.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';
import 'package:universal_html/parsing.dart';

/// The width of a phone the tests lay a post out on: the post is 16 px narrower on each side.
const _screen = 378.0;

/// The width of the post on [_screen].
const double _post = _screen - 32;

/// A long text, wrapped on a phone.
const _long =
    '这是表格里一段很长的说明文字，在手机的屏幕上一行放不下，以前整个表格只能左右滑动，现在要在屏幕里面自动换行，'
    '读的人不用再一行一行地左右滑动来看完。';

Future<void> _pump(WidgetTester tester, String html, {double textScale = 1, double height = 3000}) async {
  tester.view.physicalSize = Size(_screen, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final body = parseHtmlDocument('<html><body>$html</body></html>').body!;
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: PostTypographyScope(
              typography: const PostTypography(),
              child: Builder(builder: (context) => munchElement(context, body)),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The text on the screen that is [text], or contains it.
RenderParagraph _paragraph(WidgetTester tester, String text) => tester
    .renderObjectList<RenderParagraph>(find.byType(RichText))
    .lastWhere((e) => e.text.toPlainText(includeSemanticsLabels: false).contains(text));

/// The cell holding [text], its place in its table.
PostTableParentData _cell(WidgetTester tester, String text) {
  RenderObject? box = _paragraph(tester, text);
  while (box != null && box.parentData is! PostTableParentData) {
    box = box.parent;
  }
  return box!.parentData! as PostTableParentData;
}

/// The box of the cell holding [text] on the screen.
Rect _cellRect(WidgetTester tester, String text) {
  RenderObject? box = _paragraph(tester, text);
  while (box != null && box.parentData is! PostTableParentData) {
    box = box.parent;
  }
  final table = box!.parent! as RenderPostTable;
  final rect = (box.parentData! as PostTableParentData).rect;
  return rect.shift(table.localToGlobal(Offset.zero));
}

Rect _globalRect(RenderBox box) =>
    Rect.fromPoints(box.localToGlobal(Offset.zero), box.localToGlobal(box.size.bottomRight(Offset.zero)));

/// The horizontal scroll view of the only table on the screen.
ScrollPosition _scroll(WidgetTester tester) => tester
    .stateList<ScrollableState>(find.ancestor(of: find.byType(PostTable).first, matching: find.byType(Scrollable)))
    .map((e) => e.position)
    .firstWhere((e) => e.axis == Axis.horizontal);

RenderPostTable _table(WidgetTester tester) => tester.renderObject<RenderPostTable>(find.byType(PostTable).first);

/// Puts an image of [width] x [height] at [url] in the image cache, as a post on [_screen] decodes it.
Future<void> _seedImage(WidgetTester tester, String url, {required int width, required int height}) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()), Paint()..color = Colors.blue);
  final picture = recorder.endRecording();
  final image = await tester.runAsync(() => picture.toImage(width, height));
  picture.dispose();
  final provider = ResizeImage.resizeIfNeeded(_screen.toInt(), null, CachedImageProvider(url));
  final key = await provider.obtainKey(ImageConfiguration.empty);
  PaintingBinding.instance.imageCache.putIfAbsent(
    key,
    () => OneFrameImageStreamCompleter(Future.value(ImageInfo(image: image!))),
  );
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  late ImageCacheProvider cache;
  setUp(() {
    cache = ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio(), cookie: CookieProvider.buildEmpty()));
    getIt.registerSingleton<ImageCacheProvider>(cache);
  });
  tearDown(() async {
    await cache.dispose();
    await getIt.reset();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  group('a cell spanning columns or rows', () {
    testWidgets('spans the columns it spans, the cells after it in their columns', (tester) async {
      await _pump(
        tester,
        '<table><tr><td></td><td colspan="3"><div align="center">第1-7场</div></td><td colspan="2">第8场</td></tr>'
        '<tr><td>阶段</td><td>常规赛</td><td>春季</td><td>夏季</td><td>项链赛</td><td>资格赛</td></tr></table>',
      );
      expect(tester.takeException(), isNull);
      final first = _cellRect(tester, '第1-7场');
      final eighth = _cellRect(tester, '第8场');
      expect(first.left, closeTo(_cellRect(tester, '常规赛').left, 0.01));
      expect(first.right, closeTo(_cellRect(tester, '夏季').right, 0.01));
      expect(eighth.left, closeTo(_cellRect(tester, '项链赛').left, 0.01));
      expect(eighth.right, closeTo(_cellRect(tester, '资格赛').right, 0.01));
      // The centered header is in the middle of the three columns, as on the web page.
      final header = _globalRect(_paragraph(tester, '第1-7场'));
      expect(header.left, closeTo(first.left + PostTable.cellPadding, 0.01));
      expect(header.right, closeTo(first.right - PostTable.cellPadding, 0.01));
      expect(_cell(tester, '第8场').columnSpan, 2);
    });

    testWidgets('a cell wider than the columns it spans widens them', (tester) async {
      await _pump(
        tester,
        '<table><tr><td colspan="2">跨两栏的一个比较长的标题</td></tr><tr><td>甲</td><td>乙</td></tr></table>',
      );
      final title = _paragraph(tester, '跨两栏');
      expect(title.getMaxIntrinsicWidth(double.infinity), lessThanOrEqualTo(title.size.width + 0.01));
      expect(_cellRect(tester, '跨两栏').right, closeTo(_cellRect(tester, '乙').right, 0.01));
    });

    testWidgets('spans the rows it spans, the rows as tall as it needs', (tester) async {
      await _pump(
        tester,
        '<table><tr><td rowspan="2">左<br />左<br />左<br />左<br />左</td><td>右上</td><td>x</td></tr>'
        '<tr><td>右下</td><td>y</td></tr><tr><td>下一列</td><td colspan="2">跨两栏</td></tr></table>',
      );
      expect(tester.takeException(), isNull);
      final left = _cellRect(tester, '左');
      expect(left.top, closeTo(_cellRect(tester, '右上').top, 0.01));
      expect(left.bottom, closeTo(_cellRect(tester, '右下').bottom, 0.01));
      // Its five lines are in it.
      final text = _globalRect(_paragraph(tester, '左'));
      expect(text.top, greaterThanOrEqualTo(left.top + PostTable.cellPadding - 0.01));
      expect(text.bottom, lessThanOrEqualTo(left.bottom - PostTable.cellPadding + 0.01));
      // The rows it spans share what it needs.
      expect(_cellRect(tester, '右上').height, closeTo(_cellRect(tester, '右下').height, 0.01));
      expect(_cellRect(tester, '右上').height, greaterThan(_cellRect(tester, '下一列').height));
      // The cell below it is in its column.
      expect(_cellRect(tester, '下一列').left, closeTo(left.left, 0.01));
    });
  });

  group('column widths', () {
    testWidgets('a table that fits is as wide as its cells, each with 4 px around its text', (tester) async {
      await _pump(tester, '<table><tr><td>甲</td><td>乙乙</td></tr><tr><td>丙丙丙</td><td>丁</td></tr></table>');
      final table = tester.getRect(find.byType(PostTable));
      expect(table.width, lessThan(_post / 2));
      expect(_scroll(tester).maxScrollExtent, 0);
      final cell = _cellRect(tester, '丙丙丙');
      final text = _globalRect(_paragraph(tester, '丙丙丙'));
      expect(text.left - cell.left, closeTo(PostTable.cellPadding, 0.01));
      expect(cell.right - text.right, closeTo(PostTable.cellPadding, 0.01));
      // A line around and between the cells.
      expect(cell.left - table.left, closeTo(PostTable.borderWidth, 0.01));
      expect(_cellRect(tester, '丁').left - cell.right, closeTo(PostTable.borderWidth, 0.01));
    });

    testWidgets('[table=98%] is 98% of the post, its columns sharing the room', (tester) async {
      await _pump(tester, '<table class="t_table" style="width:98%"><tr><td>甲</td><td>乙乙</td></tr></table>');
      expect(tester.getSize(find.byType(PostTable)).width, closeTo(_post * 0.98, 0.01));
      // The room goes to the columns in proportion to their widths.
      expect(_cellRect(tester, '乙乙').width, greaterThan(_cellRect(tester, '甲').width));
    });

    testWidgets('a cell given a share of the table has it', (tester) async {
      await _pump(
        tester,
        '<table width="100%"><tr><td width="70%">七成</td><td>三成</td></tr><tr><td>甲</td><td>乙</td></tr></table>',
      );
      final table = tester.getSize(find.byType(PostTable)).width;
      expect(table, closeTo(_post, 0.01));
      expect(_cellRect(tester, '七成').width, closeTo((table - 3 * PostTable.borderWidth) * 0.7, 0.5));
    });

    testWidgets('a cell given a width in pixels has it when it fits, the long text in it wraps at it', (tester) async {
      await _pump(tester, '<table><tr><td width="150">$_long</td><td>短的</td></tr></table>');
      expect(_cellRect(tester, '这是表格里').width, closeTo(150, 0.01));
      expect(_scroll(tester).maxScrollExtent, 0);
    });

    testWidgets('widths for the desktop page are narrowed to the phone rather than scroll', (tester) async {
      // A table of 730 px and cells of 722 and 325 px, laid out for the 958 px of the desktop page.
      await _pump(
        tester,
        '<table width="730"><tr><td width="722">$_long</td><td width="325">另一段比较长的文字，也是为桌面版写的宽度</td></tr>'
        '</table>',
      );
      expect(tester.takeException(), isNull);
      expect(_scroll(tester).maxScrollExtent, 0);
      expect(tester.getSize(find.byType(PostTable)).width, closeTo(_post, 0.01));
      // In the proportion the author gave them.
      final ratio = _cellRect(tester, '这是表格里').width / _cellRect(tester, '另一段').width;
      expect(ratio, closeTo(722 / 325, 0.05));
    });
  });

  group('a cell', () {
    testWidgets('lies at the top, in the middle or at the bottom of its row', (tester) async {
      await _pump(
        tester,
        '<table><tr><td>一<br />二<br />三<br />四</td><td valign="top">上</td><td>中</td>'
        '<td style="vertical-align: bottom">下</td></tr><tr valign="bottom"><td>甲<br />乙</td><td>行底</td></tr>'
        '</table>',
      );
      final row = _cellRect(tester, '一');
      final top = _globalRect(_paragraph(tester, '上'));
      final middle = _globalRect(_paragraph(tester, '中'));
      final bottom = _globalRect(_paragraph(tester, '下'));
      expect(top.top, closeTo(row.top + PostTable.cellPadding, 0.01));
      expect(middle.center.dy, closeTo(row.center.dy, 0.01));
      expect(bottom.bottom, closeTo(row.bottom - PostTable.cellPadding, 0.01));
      // The row's `valign`.
      expect(
        _globalRect(_paragraph(tester, '行底')).bottom,
        closeTo(_cellRect(tester, '行底').bottom - PostTable.cellPadding, 0.01),
      );
    });

    testWidgets('the backgrounds of the table, its rows and its cells are painted under them', (tester) async {
      await _pump(
        tester,
        '<table bgcolor="#ffe0b3"><tr bgcolor="#99ccff"><td>甲</td><td bgcolor="pink">乙</td></tr>'
        '<tr><td>丙</td><td>丁</td></tr></table>',
      );
      final table = _table(tester);
      expect(
        table,
        paints
          // The table, then each cell on its own color or its row's, then the lines.
          ..rect(rect: Offset.zero & table.size, color: const Color(0xFFFFE0B3))
          ..rect(rect: _cell(tester, '甲').rect, color: const Color(0xFF99CCFF))
          ..rect(rect: _cell(tester, '乙').rect, color: const Color(0xFFFFC0CB))
          ..path(),
      );
    });
  });

  group('on a phone', () {
    // A real row of a post: a 300 x 300 cover, a link to the thread, the download hidden to guests. On the web page
    // the three cells fit the desktop page; on a phone the hidden content was past the screen.
    testWidgets('a row of an image, a link and hidden content is all on the screen', (tester) async {
      const cover = 'https://example.com/data/attachment/forum/cover.jpg';
      await _seedImage(tester, cover, width: 300, height: 300);
      await _pump(
        tester,
        '<table cellspacing="0" class="t_table" style="width:98%"><tr><td><img class="zoom" width="300" height="300" '
        'file="$cover" border="0" alt="" /></td><td><strong><a href="https://www.tsdm39.com/forum.php?mod=viewthread'
        '&amp;tid=841490" target="_blank">试听及介绍</a></strong></td><td><br /><br /><a href="http://pan.baidu.com/s/1"'
        ' target="_blank"><div class="locked">游客，如果您要查看本帖隐藏内容请<a href="forum.php?mod=post&amp;'
        'action=reply&amp;fid=20&amp;tid=780041">回复</a></div></a><br /><br /></td></tr></table>',
      );
      expect(tester.takeException(), isNull);
      expect(_scroll(tester).maxScrollExtent, 0);
      final image = tester.getRect(find.byType(NetworkIndicatorImage));
      // A thumbnail in the width of its cell.
      expect(image.width, inInclusiveRange(PostTable.tightImageWidth, _post / 2));
      expect(image.height, closeTo(image.width, 0.5), reason: 'keeps its aspect ratio');
      final locked = tester.getRect(find.byType(LockedCard));
      expect(locked.right, lessThanOrEqualTo(16 + _post));
      expect(locked.width, greaterThanOrEqualTo(PostTable.minWidgetWidth - 0.01));
      expect(_globalRect(_paragraph(tester, '试听及介绍')).right, lessThan(locked.left));
    });

    testWidgets('a table that cannot fit scrolls by what does not fit, a vertical drag scrolls the page', (
      tester,
    ) async {
      final row = [for (var i = 1; i <= 9; i++) '<td>第$i列</td>'].join();
      await _pump(
        tester,
        '<p>${'前文' * 100}</p><table><tr>$row</tr><tr>$row</tr></table><p>${'后文' * 1000}</p>',
        height: 800,
      );
      expect(tester.takeException(), isNull);
      final scroll = _scroll(tester);
      final table = _table(tester);
      // At its tight widths it would still be wider than the post: laid out at its comfortable widths, the short
      // cells on one line, as little past the post as that leaves.
      expect(table.getMinIntrinsicWidth(double.infinity), greaterThan(_post));
      expect(scroll.maxScrollExtent, closeTo(table.size.width - _post, 0.01));
      for (final column in table.debugColumns) {
        expect(column.min, column.max);
      }
      final page = tester
          .stateList<ScrollableState>(find.byType(Scrollable))
          .map((e) => e.position)
          .firstWhere((e) => e.axis == Axis.vertical);
      await tester.dragFrom(tester.getCenter(find.byType(PostTable)), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(page.pixels, greaterThan(0));
      expect(scroll.pixels, 0);
      await tester.dragFrom(tester.getCenter(find.byType(PostTable)), const Offset(-150, 0));
      await tester.pumpAndSettle();
      expect(scroll.pixels, greaterThan(0));
    });

    testWidgets('a table in a cell gets its comfortable width, the outer table gives up the room around it', (
      tester,
    ) async {
      await _pump(
        tester,
        '<table class="t_table" style="width:98%"><tr><td>$_long</td><td><div align="center">水无月祭</div>'
        '<table class="t_table" style="width:98%"><tr><td>第一期</td><td><div class="locked">游客，如果您要查看本帖'
        '隐藏内容请回复</div></td></tr></table></td></tr></table>',
      );
      expect(tester.takeException(), isNull);
      final tables = tester.renderObjectList<RenderPostTable>(find.byType(PostTable)).toList();
      expect(tables, hasLength(2));
      final inner = tables[1];
      final innerComfortable = inner.debugColumns.fold<double>(0, (sum, e) => sum + e.min) + 3;
      expect(inner.size.width, greaterThanOrEqualTo(innerComfortable - 0.01));
      for (final position in tester.stateList<ScrollableState>(find.byType(Scrollable)).map((e) => e.position)) {
        if (position.axis == Axis.horizontal) {
          expect(position.maxScrollExtent, 0);
        }
      }
    });

    // Narrowed to fit, its long columns in three characters a line, the rows would be twice as tall: the table scrolls
    // at its comfortable widths instead. Narrowed a little, it fits.
    testWidgets('a table narrowed to fit until its rows are much taller scrolls at its comfortable widths', (
      tester,
    ) async {
      String table(String word) {
        final cell = '<td>${List.filled(10, word).join(' ')}</td>';
        return '<table><tr>${List.filled(6, cell).join()}</tr><tr>${List.filled(6, '<td>短</td>').join()}</tr></table>';
      }

      // Words of four letters do not fit a tight column, they would break: twice as many lines.
      await _pump(tester, table('abcd'));
      expect(tester.takeException(), isNull);
      final table4 = _table(tester);
      expect(table4.getMinIntrinsicWidth(double.infinity), lessThan(_post), reason: 'it would fit');
      expect(_scroll(tester).maxScrollExtent, greaterThan(0));
      for (final (x, width) in table4.debugColumnWidths.indexed) {
        expect(width, closeTo(table4.debugColumns[x].min, 0.01));
      }
      // Words of two letters fit one a line all the same: it is narrowed and fits.
      await _pump(tester, table('ab'));
      expect(_scroll(tester).maxScrollExtent, 0);
      expect(_table(tester).size.width, closeTo(_post, 0.01));
    });

    testWidgets('a cell spanning more columns than the other rows have spans no empty column', (tester) async {
      await _pump(tester, '<table><tr><td>甲</td><td>乙</td><td>丙</td></tr><tr><td colspan="5">跨五栏的一格</td></tr></table>');
      expect(tester.takeException(), isNull);
      final table = _table(tester);
      expect(table.debugColumnWidths, hasLength(3));
      expect(table.debugColumnWidths, everyElement(greaterThan(0)));
      // The table is a rectangle: the cell under the row ends where the row ends.
      expect(_cellRect(tester, '跨五栏').right, closeTo(_cellRect(tester, '丙').right, 0.01));
    });

    testWidgets('the lines of a row or a column of cells are one line each', (tester) async {
      final rows = [
        for (var y = 0; y < 100; y++) '<tr>${[for (var x = 0; x < 5; x++) '<td>$y-$x</td>'].join()}</tr>',
      ];
      await _pump(tester, '<table>${rows.join()}</table>');
      // 101 lines between and around the rows, 6 between and around the columns.
      expect(_table(tester).debugBorders!.computeMetrics().length, 101 + 6);
    });

    testWidgets('a table in a card in a cell: the card is as wide as the table, which does not scroll in it', (
      tester,
    ) async {
      const inner =
          '<table class="t_table" style="width:98%"><tr><th>名称</th><th>说明</th><th>大小</th></tr>'
          '<tr><td>第一项</td><td>一段说明文字，在手机上要换行。</td><td>1.2GB</td></tr><tr><td colspan="2">合计</td>'
          '<td>2.4GB</td></tr></table>';
      await _pump(
        tester,
        '<table><tr><td>$_long</td><td><div class="spoiler"><div class="spoilerheader"><input type="button" '
        'class="spoilerbutton" value="打开" /></div><div class="spoilerbody" style="display: none;">$inner</div></div>'
        '</td></tr></table>',
      );
      await tester.tap(find.byType(OutlinedButton));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      for (final position in tester.stateList<ScrollableState>(find.byType(Scrollable)).map((e) => e.position)) {
        if (position.axis == Axis.horizontal) {
          expect(position.maxScrollExtent, 0);
        }
      }
      expect(_globalRect(_paragraph(tester, '2.4GB')).right, lessThanOrEqualTo(16 + _post));
    });

    testWidgets('a table scrolls with its own physics, not the bounce of a page around it', (tester) async {
      final row = [for (var i = 1; i <= 9; i++) '<td>第$i列</td>'].join();
      tester.view.physicalSize = const Size(_screen, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final body = parseHtmlDocument('<html><body><table><tr>$row</tr></table></body></html>').body!;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: ScrollConfiguration(
              behavior: const ScrollBehavior().copyWith(physics: const BouncingScrollPhysics()),
              child: Scaffold(
                body: SingleChildScrollView(child: Builder(builder: (context) => munchElement(context, body))),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final physics = _scroll(tester).physics;
      expect(physics, isA<ClampingScrollPhysics>());
      expect(physics.parent, isNot(isA<BouncingScrollPhysics>()));
    });

    testWidgets('in pages, a table that fits leaves a sideways drag to the pages, one that scrolls takes it', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(_screen, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = PageController();
      addTearDown(controller.dispose);
      Widget pages(String table) {
        Widget page(String html) {
          final body = parseHtmlDocument('<html><body>$html</body></html>').body!;
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Builder(builder: (context) => munchElement(context, body)),
          );
        }

        return TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: PageView(controller: controller, children: [page(table), page('<p>第二页</p>')]),
            ),
          ),
        );
      }

      await tester.pumpWidget(pages('<table><tr><td>甲甲甲</td><td>乙乙乙</td></tr><tr><td>丙</td><td>丁</td></tr></table>'));
      await tester.pumpAndSettle();
      await tester.dragFrom(tester.getCenter(find.byType(PostTable)), const Offset(-250, 0));
      await tester.pumpAndSettle();
      expect(controller.page, 1);

      controller.jumpToPage(0);
      await tester.pumpAndSettle();
      final row = [for (var i = 1; i <= 9; i++) '<td>第$i列</td>'].join();
      await tester.pumpWidget(pages('<table><tr>$row</tr></table>'));
      await tester.pumpAndSettle();
      await tester.dragFrom(tester.getCenter(find.byType(PostTable)), const Offset(-150, 0));
      await tester.pumpAndSettle();
      expect(controller.page, 0);
      expect(_scroll(tester).pixels, greaterThan(0));
    });

    testWidgets('a big table, tables in tables, lay out', (tester) async {
      final rows = [
        for (var y = 0; y < 300; y++)
          '<tr><td>$y</td><td>第$y行</td><td>$_long</td><td>2023.5.$y</td><td>${y}F</td></tr>',
      ].join();
      var nested = '<table><tr><td>最里层</td><td>$_long</td></tr></table>';
      for (var depth = 0; depth < 3; depth++) {
        nested = '<table><tr><td>第$depth层</td><td>$nested</td></tr></table>';
      }
      await _pump(tester, '<table class="t_table" style="width:98%">$rows</table>$nested');
      expect(tester.takeException(), isNull);
      expect(find.byType(PostTable), findsNWidgets(5));
      expect(_table(tester).size.width, closeTo(_post * 0.98, 0.01));
    });
  });

  group('left from the first phase', () {
    tearDown(() => debugBeforeMunchElement = null);

    testWidgets('a script, a style or a frame the muncher fails on is left out, its source is not shown', (
      tester,
    ) async {
      for (final failing in ['script', 'style', 'iframe']) {
        debugBeforeMunchElement = (e) {
          if (e.localName == failing) {
            throw ArgumentError('failing on <$failing>');
          }
        };
        await _pump(
          tester,
          '<p>开头</p><script type="text/javascript">var source = "脚本源码";</script><style>.x { color: red; }</style>'
          '<iframe src="https://example.com/frame">框架后备</iframe><p>结尾</p>',
        );
        expect(tester.takeException(), isNull, reason: failing);
        final all = find.byType(RichText).evaluate().map((e) => (e.widget as RichText).text.toPlainText()).join('|');
        expect(all, contains('开头'), reason: failing);
        expect(all, contains('结尾'), reason: failing);
        for (final source in ['脚本源码', 'color: red', '框架后备']) {
          expect(all, isNot(contains(source)), reason: '<$failing>: $source');
        }
      }
    });

    testWidgets("the forum's buttons of a special thread read from the web page are left out", (tester) async {
      // The debate's votes and its end, the bounty's answer, as the forum's templates print them.
      await _pump(
        tester,
        '<p class="dtm pns"><button type="button" class="pn" onclick="showWindow(\'debate\', \'forum.php?mod=misc&'
        'action=debateumpire&tid=1&pid=2\')"><span>结束此次辩论</span></button></p>'
        '<div class="dr"><table summary="全部观点" cellspacing="0" cellpadding="0"><tr><td class="sr_1 pns">'
        '<button href="forum.php?mod=misc&amp;action=debatevote&amp;tid=1&amp;stand=1" id="affirmbutton" '
        'onclick="ajaxmenu(this);doane(event);" class="pn"><span>支持</span></button><h5>辩手:1</h5></td>'
        '<td class="sr_2 pns"><button href="forum.php?mod=misc&amp;action=debatevote&amp;tid=1&amp;stand=2" '
        'id="negabutton" onclick="ajaxmenu(this);doane(event);" class="pn"><span>支持</span></button><h5>辩手:0</h5>'
        '</td></tr></table></div><p class="pns mtw"><button name="answer" value="ture" class="pn" '
        'onclick="showWindow(\'reply\', \'forum.php?mod=post&action=reply&fid=2&tid=1\')"><span>我来回答</span>'
        '</button></p>按<button type="button">按钮</button>'
        // The post's own buttons, doing something of the page's own or nothing: their text, as on the web page.
        '<p><a href="https://pan.baidu.com/s/abc"><button type="button" onclick="return true;">百度网盘下载</button></a></p>'
        '<h3><button onclick="void(0)">当标题用的按钮</button></h3>',
      );
      expect(tester.takeException(), isNull);
      final all = find.byType(RichText).evaluate().map((e) => (e.widget as RichText).text.toPlainText()).join('|');
      for (final label in ['结束此次辩论', '支持', '我来回答']) {
        expect(all, isNot(contains(label)), reason: label);
      }
      expect(all, contains('辩手:1'));
      // A button doing nothing of its own still shows its text, as on the web page.
      expect(all, contains('按按钮'));
      expect(all, contains('百度网盘下载'));
      expect(all, contains('当标题用的按钮'));
    });

    testWidgets('a fold of the post holding only a spoiler, or only another fold, is a fold', (tester) async {
      await _pump(
        tester,
        '<div onclick="document.getElementById(\'f1\').style.display=\'\'"><b>点击展开</b></div>'
        '<div id="f1" style="display:none"><div class="spoiler"><div class="spoilerheader">'
        '<input type="button" class="spoilerbutton" value="内层折叠" /></div><div class="spoilerbody" '
        'style="display: none;">内层折叠里的正文</div></div></div>'
        '<div onclick="\$(\'a\').style.display=\'\'">第一层</div>'
        '<div id="a" style="display:none"><div id="b" style="display:none">最里面的内容</div></div>'
        '<div onclick="\$(\'b\').style.display=\'\'">第二层</div>后文',
      );
      expect(tester.takeException(), isNull);
      final titles = tester.widgetList<SpoilerCard>(find.byType(SpoilerCard)).map((e) => e.title.toPlainText());
      expect(titles, containsAll(['点击展开', '第一层']));
      // The title of each fold is its title, not text of the post as well.
      final post = (find.byType(RichText).evaluate().first.widget as RichText).text.toPlainText();
      expect(post, isNot(contains('点击展开')));
      expect(post, contains('后文'));
      await tester.tap(find.widgetWithText(OutlinedButton, '点击展开'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(OutlinedButton, '内层折叠'), findsOneWidget);
    });

    testWidgets('an empty spoiler keeps its title, a button that opens nothing', (tester) async {
      await _pump(
        tester,
        '<div class="spoiler"><div class="spoilerheader"><input type="button" class="spoilerbutton" value="空的折叠" />'
        '</div><div class="spoilerbody" style="display: none;"><table><td> </td></table></div></div>'
        '<div class="spoiler"><div class="spoiler_control"><input type="button" class="spoiler_btn" value="旧的空折叠" />'
        '</div><div class="spoiler_content"></div></div>'
        '<details><summary>只有摘要</summary></details>'
        '<div onclick="document.getElementById(\'f\').style.display=\'\'"><b>自制的空折叠</b></div>'
        '<div id="f" style="display:none"></div>后文',
      );
      expect(tester.takeException(), isNull);
      final titles = tester.widgetList<SpoilerCard>(find.byType(SpoilerCard)).map((e) => e.title.toPlainText());
      expect(titles, ['空的折叠', '旧的空折叠', '只有摘要']);
      // A fold the post made of an element showing nothing is no fold: what shows it is there, as on the web page.
      expect(find.textContaining('自制的空折叠', findRichText: true), findsOneWidget);
      await tester.tap(find.byType(OutlinedButton).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('后文', findRichText: true), findsOneWidget);
    });
  });
}
