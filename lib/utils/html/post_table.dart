import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A width the author gave a table or a cell of a post (`<table width="98%">`, `[table=98%]`, `<td width="200">`,
/// `style="width: 50%"`): a share of the width the table is laid out in, or css pixels.
@immutable
final class PostTableLength {
  /// [value] of the width the table is laid out in, a fraction (0.98 for `98%`).
  const PostTableLength.percent(this.value) : percent = true;

  /// [value] css pixels.
  const PostTableLength.pixels(this.value) : percent = false;

  /// The width: a fraction of the width the table is laid out in when [percent], css pixels otherwise.
  final double value;

  /// Whether [value] is a share of the width the table is laid out in.
  final bool percent;

  static final _re = RegExp(r'^(\d+(?:\.\d+)?|\.\d+)\s*(%|px)?$');

  /// The length written in [text] (`98%`, `200`, `200px`), null when there is none or it is not a length (`auto`, a
  /// unit the app does not know, 0).
  static PostTableLength? tryParse(String? text) {
    final match = _re.firstMatch(text?.trim().toLowerCase() ?? '');
    final value = double.tryParse(match?.group(1) ?? '');
    if (match == null || value == null || value <= 0) {
      return null;
    }
    return match.group(2) == '%' ? PostTableLength.percent(value / 100) : PostTableLength.pixels(value);
  }

  @override
  bool operator ==(Object other) => other is PostTableLength && other.value == value && other.percent == percent;

  @override
  int get hashCode => Object.hash(value, percent);

  @override
  String toString() => percent ? '${value * 100}%' : '${value}px';
}

/// Where the content of a cell lies in the height of its row (`valign`, `vertical-align`); the web page puts it in
/// the middle.
enum PostTableCellAlign {
  /// At the top.
  top,

  /// In the middle.
  middle,

  /// At the bottom.
  bottom
  ;

  /// The alignment written in [text] (`top`, `middle`, `bottom`; `baseline` is laid out as `top`), null when there is
  /// none.
  static PostTableCellAlign? tryParse(String? text) => switch (text?.trim().toLowerCase()) {
    'top' || 'baseline' || 'text-top' => PostTableCellAlign.top,
    'middle' || 'center' => PostTableCellAlign.middle,
    'bottom' || 'text-bottom' => PostTableCellAlign.bottom,
    _ => null,
  };
}

/// Where a cell of a [PostTable] is and how it is drawn.
class PostTableParentData extends ContainerBoxParentData<RenderBox> {
  /// The row the cell starts in.
  int row = 0;

  /// The column the cell starts in.
  int column = 0;

  /// How many rows the cell spans (`rowspan`).
  int rowSpan = 1;

  /// How many columns the cell spans (`colspan`).
  int columnSpan = 1;

  /// The background of the cell, over the background of its row.
  Color? background;

  /// The width the author gave the cell.
  PostTableLength? width;

  /// Where the content lies in the height of the cell.
  PostTableCellAlign verticalAlign = PostTableCellAlign.middle;

  /// The box of the cell in the table, its padding in it, the lines around it outside it. Set by the layout.
  Rect rect = Rect.zero;

  @override
  String toString() => '${super.toString()}; row=$row column=$column span=${rowSpan}x$columnSpan';
}

/// A cell of a [PostTable]: [child] in [row] and [column], spanning [rowSpan] rows and [columnSpan] columns.
class PostTableCell extends ParentDataWidget<PostTableParentData> {
  /// Constructor.
  const PostTableCell({
    required this.row,
    required this.column,
    required super.child,
    this.rowSpan = 1,
    this.columnSpan = 1,
    this.background,
    this.width,
    this.verticalAlign = PostTableCellAlign.middle,
    super.key,
  });

  /// The row the cell starts in.
  final int row;

  /// The column the cell starts in.
  final int column;

  /// How many rows the cell spans.
  final int rowSpan;

  /// How many columns the cell spans.
  final int columnSpan;

  /// The background of the cell, as shown in the theme.
  final Color? background;

  /// The width the author gave the cell.
  final PostTableLength? width;

  /// Where the content lies in the height of the cell.
  final PostTableCellAlign verticalAlign;

  @override
  void applyParentData(RenderObject renderObject) {
    final parentData = renderObject.parentData! as PostTableParentData;
    var needsLayout = false;
    if (parentData.row != row ||
        parentData.column != column ||
        parentData.rowSpan != rowSpan ||
        parentData.columnSpan != columnSpan ||
        parentData.width != width ||
        parentData.verticalAlign != verticalAlign) {
      parentData
        ..row = row
        ..column = column
        ..rowSpan = rowSpan
        ..columnSpan = columnSpan
        ..width = width
        ..verticalAlign = verticalAlign;
      needsLayout = true;
    }
    final needsPaint = parentData.background != background;
    parentData.background = background;
    final table = renderObject.parent;
    if (needsLayout) {
      table?.markNeedsLayout();
    } else if (needsPaint) {
      table?.markNeedsPaint();
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => PostTable;

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(IntProperty('row', row))
      ..add(IntProperty('column', column))
      ..add(IntProperty('rowSpan', rowSpan, defaultValue: 1))
      ..add(IntProperty('columnSpan', columnSpan, defaultValue: 1));
  }
}

/// A table of a post laid out as the web page lays out its tables (the automatic table layout of css), in the width
/// it is given: a cell spans the columns and rows it spans (`colspan`, `rowspan`), each column is as wide as its
/// content asks, a table wider than the width is narrowed the way a browser narrows it before it scrolls.
///
/// A [Table] could do none of that: its cells cannot span, and it narrows its columns one after the other. Spanning
/// cells were drawn in their first place, the places they span left empty.
///
/// Each column has a preferred width (its content on one line, or the width in pixels the author gave a cell of it)
/// and two narrower widths:
///
/// * its comfortable width: a column of long text wraps down to [minColumnWidth], a short column (names, numbers,
///   dates, at most [maxShortWidth]) stays on one line, a widget in it is narrowed down to [minWidgetWidth] (an image
///   to a thumbnail, a card wraps its text), a table in it to its own comfortable widths;
/// * its tight width: its text wraps anywhere down to [tightColumnWidth] (as `overflow-wrap: anywhere` does on the
///   web page's `.t_table td`, down to one character), an image down to [tightImageWidth], a card still not below
///   [minWidgetWidth] (its icon and margins leave no room for its text), a table in it to its own tight widths.
///
/// The table is as wide as the preferred widths when that fits (or as the width the author gave it, `[table=98%]`).
/// Otherwise it is as wide as it can be and its columns are narrowed, as a browser does before a table overflows:
/// down to their comfortable widths, the columns of long text first, each keeping the same share of its preferred
/// width, then those the author gave a width in pixels, then in percent; then all of them alike down to their tight
/// widths. Only a table that does not fit even at its tight widths (many columns, a table in a cell) scrolls
/// sideways, [PostTableScrollView] laying it out at its comfortable widths: squeezing it more would not spare the
/// scrolling, only make every cell taller.
///
/// Each cell has [cellPadding] around its content, as the forum's style sheet gives `.t_table td`, and lines of
/// [borderWidth] between the cells and around the table.
class PostTable extends MultiChildRenderObjectWidget {
  /// Constructor.
  const PostTable({
    required List<PostTableCell> cells,
    required this.rowCount,
    this.rowBackgrounds = const [],
    this.background,
    this.borderColor,
    this.width,
    super.key,
  }) : super(children: cells);

  /// How many rows the table has, some maybe without cells of their own.
  final int rowCount;

  /// The background of each row, as shown in the theme, null for none: under the cells that start in it.
  final List<Color?> rowBackgrounds;

  /// The background of the table, as shown in the theme: under everything.
  final Color? background;

  /// The color of the lines around the cells, none when null.
  final Color? borderColor;

  /// The width the author gave the table.
  final PostTableLength? width;

  /// Space around the content of a cell.
  static const double cellPadding = 4;

  /// Width of the lines between the cells.
  static const double borderWidth = 1;

  /// Comfortable width of a column of long text, unless its content is narrower: about four characters a line. A
  /// longer word, an address, wraps.
  static const double minColumnWidth = 64;

  /// Tight width of a column of text, unless its content is narrower: three characters a line. The web page wraps
  /// the text of a cell anywhere and narrows a column down to one character, which on a phone is unreadable.
  static const double tightColumnWidth = 42;

  /// Comfortable width of a widget in a cell, unless it is narrower: an image is a thumbnail (see [PostTableImage]),
  /// a card wraps its text.
  static const double minWidgetWidth = PostTableImage.minWidth;

  /// Tight width of an image in a cell, unless it is narrower: a smaller thumbnail.
  static const double tightImageWidth = 80;

  /// Widest a column is counted as short: a column of names, numbers or dates keeps its line until the table has to
  /// be narrowed to its tight widths.
  static const double maxShortWidth = 2 * minColumnWidth;

  @override
  RenderPostTable createRenderObject(BuildContext context) => RenderPostTable(
    rowCount: rowCount,
    rowBackgrounds: rowBackgrounds,
    background: background,
    borderColor: borderColor,
    width: width,
  );

  @override
  void updateRenderObject(BuildContext context, RenderPostTable renderObject) {
    renderObject
      ..rowCount = rowCount
      ..rowBackgrounds = rowBackgrounds
      ..background = background
      ..borderColor = borderColor
      ..width = width;
  }

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(IntProperty('rowCount', rowCount))
      ..add(DiagnosticsProperty<PostTableLength>('width', width, defaultValue: null));
  }
}

/// The widths of a column of a [PostTable], its padding included (see [PostTable]).
///
/// `tight`: its tight width. `min`: its comfortable width. `max`: its preferred width, its content on one line or the
/// width in pixels the author gave a cell of it (`fixed`). `percent`: the share of the table the author gave a cell
/// of it.
typedef PostTableColumn = ({double tight, double min, double max, double? percent, double? fixed});

double _sum(Iterable<double> values) => values.fold(0, (sum, value) => sum + value);

/// [_distribute] for tests: the widths of [columns] in a table whose columns take [width] in all.
@visibleForTesting
List<double> debugPostTableColumnWidths(List<PostTableColumn> columns, double width) => _distribute(columns, width);

/// The preferred width of a table of [columns], what it takes when nothing limits it: each column at its preferred
/// width, more when a column given a share of the table needs more for that share to be its width (as a browser
/// works it out). Infinite when the shares add up to the whole table: it takes the width it has.
double _preferredWidth(List<PostTableColumn> columns) {
  final all = _sum(columns.map((e) => e.max));
  final share = _sum(columns.map((e) => e.percent ?? 0));
  if (share <= 0) {
    return all;
  }
  if (share >= 1 - precisionErrorTolerance) {
    return double.infinity;
  }
  var width = math.max(all, _sum(columns.where((e) => e.percent == null).map((e) => e.max)) / (1 - share));
  for (final column in columns) {
    if (column.percent case final percent? when percent > 0) {
      width = math.max(width, column.max / percent);
    }
  }
  return width;
}

/// Widths of [columns] taking [width] in all.
///
/// Every column gets its comfortable width. What is left goes, as in a browser, first to the columns with a width in
/// percent (up to that share of [width]), then to those with a width in pixels, then to the others (up to their
/// preferred widths): the group that cannot get all it asks shares what is left, each of its columns keeping the same
/// share of its preferred width wherever it is in the table, one that would be narrower than its comfortable width
/// staying at it. What is left when all have what they ask goes to the columns without a width in proportion to their
/// widths (a table the author made wider than its content), else to the others.
///
/// Narrower than the comfortable widths, each column gives up the same share of what it has above its tight width;
/// narrower than the tight widths (only when nothing else can be done), the same share of its tight width.
List<double> _distribute(List<PostTableColumn> columns, double width) {
  final widths = [for (final column in columns) column.min];
  final minimum = _sum(widths);
  if (width < minimum - precisionErrorTolerance) {
    final tight = _sum(columns.map((e) => e.tight));
    if (width >= tight && minimum - tight > precisionErrorTolerance) {
      final part = (width - tight) / (minimum - tight);
      return [for (final column in columns) column.tight + (column.min - column.tight) * part];
    }
    return [for (final column in columns) tight > 0 ? column.tight * math.min(1, width / tight) : 0];
  }
  if (width <= minimum + precisionErrorTolerance) {
    return widths;
  }
  final share = _sum(columns.map((e) => e.percent ?? 0));
  // Shares adding up to more than the table are scaled down to it.
  final shareScale = share > 1 ? 1 / share : 1.0;
  final targets = [
    for (final column in columns)
      math.max(column.min, column.percent == null ? column.max : column.percent! * shareScale * width),
  ];
  List<int> where(bool Function(PostTableColumn column) test) => [
    for (var x = 0; x < columns.length; x++)
      if (test(columns[x])) x,
  ];
  bool isAuto(PostTableColumn column) => column.percent == null && column.fixed == null;
  final autoColumns = where(isAuto);
  final groups = [where((e) => e.percent != null), where((e) => e.percent == null && e.fixed != null), autoColumns];
  var left = width - minimum;
  for (final group in groups) {
    final asked = _sum(group.map((x) => targets[x] - columns[x].min));
    if (asked <= precisionErrorTolerance) {
      continue;
    }
    if (asked <= left) {
      for (final x in group) {
        widths[x] = targets[x];
      }
      left -= asked;
      continue;
    }
    // The share of its preferred width each column keeps. A column it would make narrower than its minimum width is
    // kept at its minimum, which leaves less to the others: the share is worked out again without it.
    final room = _sum(group.map((x) => columns[x].min)) + left;
    final atMinimum = <int>{};
    var keep = 1.0;
    while (true) {
      final others = group.where((x) => !atMinimum.contains(x));
      final preferred = _sum(others.map((x) => targets[x]));
      if (preferred <= precisionErrorTolerance) {
        break;
      }
      keep = (room - _sum(atMinimum.map((x) => columns[x].min))) / preferred;
      final reached = others.where((x) => targets[x] * keep < columns[x].min).toList();
      if (reached.isEmpty) {
        break;
      }
      atMinimum.addAll(reached);
    }
    for (final x in group) {
      widths[x] = atMinimum.contains(x) ? columns[x].min : targets[x] * keep;
    }
    return widths;
  }
  if (left <= precisionErrorTolerance) {
    return widths;
  }
  // Wider than the columns ask: the room goes to the columns without a width, in proportion to their widths.
  for (final (group, weight) in [
    (autoColumns, (int x) => widths[x]),
    (groups[1], (int x) => widths[x]),
    (groups[0], (int x) => columns[x].percent!),
  ]) {
    final total = _sum(group.map(weight));
    if (group.isNotEmpty && total > precisionErrorTolerance) {
      final weights = [for (final x in group) weight(x)];
      for (final (i, x) in group.indexed) {
        widths[x] += left * weights[i] / total;
      }
      return widths;
    }
  }
  // Only empty columns: they share it.
  for (var x = 0; x < widths.length; x++) {
    widths[x] += left / widths.length;
  }
  return widths;
}

/// Adds to [values] (the widths or heights of the columns or rows a cell spans, [gaps] between them) what they lack
/// to hold [needed], in proportion to [weights], equally when the weights are all zero.
void _spread(List<double> values, double gaps, double needed, List<double> weights) {
  final lack = needed - _sum(values) - gaps;
  if (lack <= precisionErrorTolerance || values.isEmpty) {
    return;
  }
  final total = _sum(weights);
  for (var i = 0; i < values.length; i++) {
    values[i] += total > precisionErrorTolerance ? lack * weights[i] / total : lack / values.length;
  }
}

/// The widths of a cell: tight, comfortable as in a column of long text, preferred (see [PostTable]).
typedef _CellWidths = ({double tight, double long, double max});

/// The geometry of a laid out [RenderPostTable].
typedef _Geometry = ({List<double> columnX, List<double> columnWidths, List<double> rowY, List<double> rowHeights});

/// The render object of a [PostTable].
class RenderPostTable extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, PostTableParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, PostTableParentData> {
  /// Constructor.
  RenderPostTable({
    required int rowCount,
    List<Color?> rowBackgrounds = const [],
    Color? background,
    Color? borderColor,
    PostTableLength? width,
  }) : _rowCount = rowCount,
       _rowBackgrounds = rowBackgrounds,
       _background = background,
       _borderColor = borderColor,
       _width = width;

  /// How many rows the table has.
  int get rowCount => _rowCount;
  int _rowCount;
  set rowCount(int value) {
    if (value != _rowCount) {
      _rowCount = value;
      markNeedsLayout();
    }
  }

  /// The background of each row.
  List<Color?> get rowBackgrounds => _rowBackgrounds;
  List<Color?> _rowBackgrounds;
  set rowBackgrounds(List<Color?> value) {
    if (!listEquals(value, _rowBackgrounds)) {
      _rowBackgrounds = value;
      markNeedsPaint();
    }
  }

  /// The background of the table.
  Color? get background => _background;
  Color? _background;
  set background(Color? value) {
    if (value != _background) {
      _background = value;
      markNeedsPaint();
    }
  }

  /// The color of the lines around the cells.
  Color? get borderColor => _borderColor;
  Color? _borderColor;
  set borderColor(Color? value) {
    if (value != _borderColor) {
      _borderColor = value;
      markNeedsPaint();
    }
  }

  /// The width the author gave the table.
  PostTableLength? get width => _width;
  PostTableLength? _width;
  set width(PostTableLength? value) {
    if (value != _width) {
      _width = value;
      markNeedsLayout();
    }
  }

  static const double _border = PostTable.borderWidth;
  static const double _padding = PostTable.cellPadding;

  /// The columns, worked out from the intrinsic widths of the cells; kept until something in the table changes.
  List<PostTableColumn>? _columns;

  /// The geometry of the last layout, what is painted.
  _Geometry? _geometry;

  /// The lines around the cells in the last layout.
  Path? _borders;

  @override
  void markNeedsLayout() {
    _columns = null;
    super.markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! PostTableParentData) {
      child.parentData = PostTableParentData();
    }
  }

  Iterable<RenderBox> get _cells sync* {
    var child = firstChild;
    while (child != null) {
      yield child;
      child = childAfter(child);
    }
  }

  static PostTableParentData _dataOf(RenderBox cell) => cell.parentData! as PostTableParentData;

  int get _columnCount => _cells.fold(0, (count, cell) {
    final data = _dataOf(cell);
    return math.max(count, data.column + data.columnSpan);
  });

  /// What [box], a cell or a widget in the text of a cell, is: text (the paragraph, maybe in an aligned block), a
  /// table (in its scroll view), an image, or another widget (a card) when all are null and false.
  static ({RenderParagraph? text, RenderPostTable? table, bool image}) _kindOf(RenderObject box) {
    RenderObject? current = box;
    for (var depth = 0; current != null && depth < 32; depth++) {
      switch (current) {
        case final RenderPostTable table:
          return (text: null, table: table, image: false);
        case _RenderPostTableImage():
          return (text: null, table: null, image: true);
        case final RenderParagraph paragraph:
          return (text: paragraph, table: null, image: false);
        case RenderObjectWithChildMixin(:final child):
          current = child;
        default:
          return (text: null, table: null, image: false);
      }
    }
    return (text: null, table: null, image: false);
  }

  /// The narrowest [box] (a cell, a widget in it) can be made for what is not text in it, at its tight and comfortable
  /// widths (see [PostTable]). Text, even in an aligned block, wraps anywhere.
  static ({double tight, double comfortable}) _widgetsWidth(RenderBox box) {
    final kind = _kindOf(box);
    if (kind.text case final paragraph?) {
      var tight = 0.0;
      var comfortable = 0.0;
      paragraph.visitChildren((child) {
        final widths = _widgetsWidth(child as RenderBox);
        tight = math.max(tight, widths.tight);
        comfortable = math.max(comfortable, widths.comfortable);
      });
      return (tight: tight, comfortable: comfortable);
    }
    if (kind.table case final table?) {
      return (tight: table.getMinIntrinsicWidth(double.infinity), comfortable: table._scrollWidth);
    }
    final min = box.getMinIntrinsicWidth(double.infinity);
    return (
      tight: math.min(min, kind.image ? PostTable.tightImageWidth : PostTable.minWidgetWidth),
      comfortable: math.min(min, PostTable.minWidgetWidth),
    );
  }

  /// The widths of [cell], its padding included: its tight width, its comfortable width as in a column of long text,
  /// and its preferred width (see [PostTable]).
  ///
  /// The minimum width of a paragraph is not used for its text: it is its widest word, and the widest run of chinese
  /// characters the line breaker finds no break in (a whole title), which lays out narrower all the same.
  static _CellWidths _cellWidths(RenderBox cell) {
    final max = cell.getMaxIntrinsicWidth(double.infinity);
    final widgets = _widgetsWidth(cell);
    final tight = math.min(max, math.max(PostTable.tightColumnWidth, widgets.tight));
    final long = math.min(max, math.max(PostTable.minColumnWidth, widgets.comfortable));
    return (tight: tight + 2 * _padding, long: long + 2 * _padding, max: max + 2 * _padding);
  }

  /// The comfortable width of a column or a cell spanning columns with [widths]: on one line when it is short.
  static double _comfortable(_CellWidths widths) =>
      widths.max - 2 * _padding > PostTable.maxShortWidth ? widths.long : widths.max;

  /// The columns of the table: from the cells in one column, then the cells spanning several, the narrower spans
  /// first, each giving the columns it spans what they lack in proportion to their preferred widths.
  List<PostTableColumn> _measureColumns() {
    final cached = _columns;
    if (cached != null) {
      return cached;
    }
    final count = _columnCount;
    final tights = List<double>.filled(count, 0);
    final longs = List<double>.filled(count, 0);
    final maxes = List<double>.filled(count, 0);
    final percents = List<double?>.filled(count, null);
    final fixed = List<double?>.filled(count, null);
    final spanning = <(PostTableParentData, _CellWidths)>[];
    for (final cell in _cells) {
      final data = _dataOf(cell);
      final widths = _cellWidths(cell);
      if (data.columnSpan > 1) {
        spanning.add((data, widths));
        continue;
      }
      final x = data.column;
      tights[x] = math.max(tights[x], widths.tight);
      longs[x] = math.max(longs[x], widths.long);
      maxes[x] = math.max(maxes[x], widths.max);
      switch (data.width) {
        case PostTableLength(percent: true, :final value):
          percents[x] = math.max(percents[x] ?? 0, value);
        case PostTableLength(percent: false, :final value):
          fixed[x] = math.max(fixed[x] ?? 0, value);
        case null:
          break;
      }
    }
    final mins = [for (var x = 0; x < count; x++) _comfortable((tight: tights[x], long: longs[x], max: maxes[x]))];
    // A width in pixels is the preferred width of its column, whatever the content (a browser wraps the text at
    // that width), never narrower than the comfortable width.
    for (var x = 0; x < count; x++) {
      if (fixed[x] case final width? when percents[x] == null) {
        maxes[x] = math.max(mins[x], width);
      }
    }
    spanning.sort((a, b) => a.$1.columnSpan.compareTo(b.$1.columnSpan));
    for (final (data, widths) in spanning) {
      final span = [for (var x = data.column; x < data.column + data.columnSpan; x++) x];
      final gaps = _border * (span.length - 1);
      final min = _comfortable(widths);
      final preferred = switch (data.width) {
        PostTableLength(percent: false, :final value) => math.max(min, value),
        _ => widths.max,
      };
      final weights = [for (final x in span) maxes[x]];
      for (final (values, needed) in [(tights, widths.tight), (mins, min), (maxes, preferred)]) {
        final spanned = [for (final x in span) values[x]];
        _spread(spanned, gaps, needed, weights);
        for (final (i, x) in span.indexed) {
          values[x] = spanned[i];
        }
      }
    }
    return _columns = [
      for (var x = 0; x < count; x++)
        (
          tight: math.min(tights[x], mins[x]),
          min: mins[x],
          max: math.max(maxes[x], mins[x]),
          percent: percents[x],
          fixed: fixed[x],
        ),
    ];
  }

  /// The columns of the table, for tests.
  @visibleForTesting
  List<PostTableColumn> get debugColumns => _measureColumns();

  /// The width of each column in the last layout, for tests.
  @visibleForTesting
  List<double> get debugColumnWidths => List.unmodifiable(_geometry?.columnWidths ?? const <double>[]);

  /// The width the table is laid out at when it does not fit and scrolls: its comfortable widths.
  double get _scrollWidth {
    final columns = _measureColumns();
    return columns.isEmpty ? 0 : _sum(columns.map((e) => e.min)) + _bordersOf(columns.length);
  }

  double _bordersOf(int count) => _border * (count + 1);

  // The narrowest the table is laid out without scrolling: its tight widths.
  @override
  double computeMinIntrinsicWidth(double height) {
    final columns = _measureColumns();
    return columns.isEmpty ? 0 : _sum(columns.map((e) => e.tight)) + _bordersOf(columns.length);
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    final columns = _measureColumns();
    if (columns.isEmpty) {
      return 0;
    }
    final borders = _bordersOf(columns.length);
    var width = _sum(columns.map((e) => e.max)) + borders;
    if (_width case PostTableLength(percent: false, :final value)) {
      width = math.max(width, value);
    }
    return width;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _layout(BoxConstraints(maxWidth: width), ChildLayoutHelper.dryLayoutChild).size.height;

  @override
  double computeMaxIntrinsicHeight(double width) => computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) => _layout(constraints, ChildLayoutHelper.dryLayoutChild).size;

  @override
  void performLayout() {
    final layout = _layout(constraints, ChildLayoutHelper.layoutChild);
    size = layout.size;
    final geometry = layout.geometry;
    _geometry = geometry;
    for (final cell in _cells) {
      final data = _dataOf(cell);
      if (geometry == null || !_isPlaced(data, geometry.columnWidths.length)) {
        // Out of the table: laid out and painted as nothing.
        cell.layout(const BoxConstraints.tightFor(width: 0, height: 0));
        data
          ..rect = Rect.zero
          ..offset = Offset.zero;
        continue;
      }
      final rect = _rectOf(geometry, data);
      data.rect = rect;
      final free = rect.height - 2 * _padding - cell.size.height;
      final dy = switch (data.verticalAlign) {
        PostTableCellAlign.top => 0.0,
        PostTableCellAlign.middle => free / 2,
        PostTableCellAlign.bottom => free,
      };
      data.offset = Offset(rect.left + _padding, rect.top + _padding + math.max(0, dy));
    }
    _borders = geometry == null ? null : _bordersAround(geometry);
  }

  /// The lines around the cells laid out in [geometry], outside them, built once a layout: the lines of a row or a
  /// column of cells are one line, not one per cell (a table of a thousand rows painted twenty thousand pieces).
  Path _bordersAround(_Geometry geometry) {
    // The pieces of each line between rows, by the row under it (the last one under the table), and of each line
    // between columns, by the column right of it.
    final horizontal = <int, List<(double, double)>>{};
    final vertical = <int, List<(double, double)>>{};
    final columns = geometry.columnWidths.length;
    final rows = geometry.rowHeights.length;
    for (final cell in _cells) {
      final data = _dataOf(cell);
      if (!_isPlaced(data, columns)) {
        continue;
      }
      final rect = data.rect;
      final across = (rect.left - _border, rect.right + _border);
      final down = (rect.top, rect.bottom);
      (horizontal[data.row] ??= []).add(across);
      (horizontal[math.min<int>(data.row + data.rowSpan, rows)] ??= []).add(across);
      (vertical[data.column] ??= []).add(down);
      (vertical[math.min<int>(data.column + data.columnSpan, columns)] ??= []).add(down);
    }
    // Where a line is: the space before row or column [index], after the last one for the last index.
    double lineAt(int index, List<double> starts, List<double> sizes) =>
        index < starts.length ? starts[index] - _border : starts.last + sizes.last;
    final path = Path();
    void add(Map<int, List<(double, double)>> lines, void Function(int index, double from, double to) addPiece) {
      for (final MapEntry(key: index, value: pieces) in lines.entries) {
        pieces.sort((a, b) => a.$1.compareTo(b.$1));
        var (from, to) = pieces.first;
        for (final (start, end) in pieces.skip(1)) {
          if (start <= to + precisionErrorTolerance) {
            to = math.max(to, end);
          } else {
            addPiece(index, from, to);
            (from, to) = (start, end);
          }
        }
        addPiece(index, from, to);
      }
    }

    add(horizontal, (index, from, to) {
      final y = lineAt(index, geometry.rowY, geometry.rowHeights);
      path.addRect(Rect.fromLTRB(from, y, to, y + _border));
    });
    add(vertical, (index, from, to) {
      final x = lineAt(index, geometry.columnX, geometry.columnWidths);
      path.addRect(Rect.fromLTRB(x, from, x + _border, to));
    });
    return path;
  }

  /// Whether the cell with [data] is in the table of [rowCount] rows and [columns] columns.
  bool _isPlaced(PostTableParentData data, int columns) => data.row < rowCount && data.column < columns;

  static Rect _rectOf(_Geometry geometry, PostTableParentData data) {
    final lastColumn = math.min(data.column + data.columnSpan, geometry.columnWidths.length) - 1;
    final lastRow = math.min(data.row + data.rowSpan, geometry.rowHeights.length) - 1;
    final left = geometry.columnX[data.column];
    final top = geometry.rowY[math.min(data.row, geometry.rowY.length - 1)];
    return Rect.fromLTRB(
      left,
      top,
      geometry.columnX[lastColumn] + geometry.columnWidths[lastColumn],
      geometry.rowY[lastRow] + geometry.rowHeights[lastRow],
    );
  }

  /// The width the columns take in all (borders left out) in [constraints].
  double _contentWidth(List<PostTableColumn> columns, BoxConstraints constraints) {
    final borders = _bordersOf(columns.length);
    final minimum = _sum(columns.map((e) => e.tight));
    final available = constraints.maxWidth - borders;
    final preferred = _preferredWidth(columns);
    var width = switch (_width) {
      // A share of the width: a table laid out without one is as wide as its cells.
      PostTableLength(percent: true, :final value) =>
        constraints.hasBoundedWidth ? value * constraints.maxWidth - borders : preferred,
      // The pixels of the desktop page, at most the width there is: a phone is narrower.
      PostTableLength(percent: false, :final value) => math.min(value - borders, available),
      null => math.min(preferred, available),
    };
    if (!width.isFinite) {
      width = _sum(columns.map((e) => e.max));
    }
    width = math.max(math.max(width, minimum), constraints.minWidth - borders);
    // Narrower than its minimum widths only when the constraints leave no other way (see [PostTableScrollView]).
    return math.max(0, math.min(width, available));
  }

  ({Size size, _Geometry? geometry}) _layout(BoxConstraints constraints, ChildLayouter layoutChild) {
    final columns = _measureColumns();
    if (columns.isEmpty || rowCount <= 0) {
      return (size: constraints.smallest, geometry: null);
    }
    final columnWidths = _distribute(columns, _contentWidth(columns, constraints));
    final columnX = <double>[];
    var x = _border;
    for (final width in columnWidths) {
      columnX.add(x);
      x += width + _border;
    }

    // Each cell laid out in the width of the columns it spans: the rows as tall as their cells, a cell spanning rows
    // giving the rows it spans what they lack in proportion to their heights.
    final rowHeights = List<double>.filled(rowCount, 0);
    final spanning = <(PostTableParentData, double)>[];
    for (final cell in _cells) {
      final data = _dataOf(cell);
      if (!_isPlaced(data, columnWidths.length)) {
        continue;
      }
      final lastColumn = math.min(data.column + data.columnSpan, columnWidths.length);
      final width = columnX[lastColumn - 1] + columnWidths[lastColumn - 1] - columnX[data.column] - 2 * _padding;
      final height = layoutChild(cell, BoxConstraints.tightFor(width: math.max(0, width))).height + 2 * _padding;
      final rowSpan = math.min(data.rowSpan, rowCount - data.row);
      if (rowSpan > 1) {
        spanning.add((data, height));
      } else {
        rowHeights[data.row] = math.max(rowHeights[data.row], height);
      }
    }
    spanning.sort((a, b) => a.$1.rowSpan.compareTo(b.$1.rowSpan));
    for (final (data, height) in spanning) {
      final end = math.min(data.row + data.rowSpan, rowCount);
      final heights = rowHeights.sublist(data.row, end);
      _spread(heights, _border * (heights.length - 1), height, List.of(heights));
      rowHeights.setRange(data.row, end, heights);
    }
    final rowY = <double>[];
    var y = _border;
    for (final height in rowHeights) {
      rowY.add(y);
      y += height + _border;
    }
    return (
      size: constraints.constrain(Size(x, y)),
      geometry: (columnX: columnX, columnWidths: columnWidths, rowY: rowY, rowHeights: rowHeights),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final geometry = _geometry;
    if (geometry == null) {
      return;
    }
    final canvas = context.canvas;
    if (_background case final color?) {
      canvas.drawRect(offset & size, Paint()..color = color);
    }
    for (final cell in _cells) {
      final data = _dataOf(cell);
      if (!_isPlaced(data, geometry.columnWidths.length)) {
        continue;
      }
      if (data.background ?? _rowBackgrounds.elementAtOrNull(data.row) case final color?) {
        canvas.drawRect(data.rect.shift(offset), Paint()..color = color);
      }
    }
    if ((_borderColor, _borders) case (final color?, final borders?)) {
      canvas
        ..save()
        ..translate(offset.dx, offset.dy)
        ..drawPath(borders, Paint()..color = color)
        ..restore();
    }
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties
      ..add(IntProperty('rowCount', rowCount))
      ..add(DiagnosticsProperty<PostTableLength>('width', width, defaultValue: null));
  }
}

/// An image in a cell of a table in a post.
///
/// An image reports no minimum width, a table narrowed to the screen would shrink it to nothing. In a table it is
/// narrowed down to [minWidth] (a thumbnail, tap it to see it whole), to [PostTable.tightImageWidth] when the table
/// would scroll otherwise, but not further: a table of more images than that scrolls sideways instead. Only the
/// minimum width the table asks for changes, the image is laid out in the width of its cell, its aspect ratio kept.
class PostTableImage extends SingleChildRenderObjectWidget {
  /// Constructor.
  const PostTableImage({required super.child, super.key});

  /// Narrowest an image is made, unless it is narrower than that.
  static const double minWidth = 120;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderPostTableImage();
}

class _RenderPostTableImage extends RenderProxyBox {
  @override
  double computeMinIntrinsicWidth(double height) => math.min(PostTableImage.minWidth, getMaxIntrinsicWidth(height));
}

/// Horizontal scroll view of a [PostTable] in a post.
///
/// The table is laid out in the width of the view, which it fits when its columns fit at their tight widths (see
/// [PostTable]). A table that cannot fit even then (many columns, a table in its cell) is laid out at its comfortable
/// widths and scrolls sideways.
///
/// The view only takes horizontal drags, and only when the table is wider than it: a vertical drag on the table
/// scrolls the page.
class PostTableScrollView extends StatelessWidget {
  /// Constructor.
  const PostTableScrollView({required this.child, super.key});

  /// The table.
  final Widget child;

  @override
  Widget build(BuildContext context) => Scrollable(
    axisDirection: AxisDirection.right,
    viewportBuilder: (context, offset) => _TableViewport(offset: offset, child: child),
  );
}

class _TableViewport extends SingleChildRenderObjectWidget {
  const _TableViewport({required this.offset, super.child});

  final ViewportOffset offset;

  @override
  _RenderTableViewport createRenderObject(BuildContext context) => _RenderTableViewport(offset: offset);

  @override
  void updateRenderObject(BuildContext context, _RenderTableViewport renderObject) => renderObject.offset = offset;

  @override
  SingleChildRenderObjectElement createElement() => _TableViewportElement(this);
}

// Scroll notifications of the table get the depth of a nested scroll view, as in a [SingleChildScrollView].
class _TableViewportElement extends SingleChildRenderObjectElement with NotifiableElementMixin, ViewportElementMixin {
  _TableViewportElement(_TableViewport super.widget);
}

/// The viewport of a [SingleChildScrollView] scrolling to the right, except for how its child is laid out: in the width
/// it has, wider only when it cannot be narrower (see [PostTableScrollView]).
class _RenderTableViewport extends RenderBox
    with RenderObjectWithChildMixin<RenderBox>
    implements RenderAbstractViewport {
  _RenderTableViewport({required ViewportOffset offset}) : _offset = offset;

  ViewportOffset get offset => _offset;
  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) {
      return;
    }
    if (attached) {
      _offset.removeListener(_hasScrolled);
    }
    _offset = value;
    if (attached) {
      _offset.addListener(_hasScrolled);
    }
    markNeedsLayout();
  }

  void _hasScrolled() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! ParentData) {
      child.parentData = ParentData();
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_hasScrolled);
  }

  @override
  void detach() {
    _offset.removeListener(_hasScrolled);
    super.detach();
  }

  @override
  bool get isRepaintBoundary => true;

  double get _maxScrollExtent => child == null ? 0 : math.max(0, child!.size.width - size.width);

  /// The constraints of [child] in [constraints]: at most the width of the view; when it is narrower than the table
  /// can be, exactly as wide as the table scrolls (see [PostTable]).
  static BoxConstraints _childConstraints(RenderBox child, BoxConstraints constraints) {
    final heights = constraints.heightConstraints();
    if (!constraints.hasBoundedWidth) {
      return heights;
    }
    final minimum = child.getMinIntrinsicWidth(double.infinity);
    if (minimum <= constraints.maxWidth + precisionErrorTolerance) {
      return heights.copyWith(maxWidth: constraints.maxWidth);
    }
    final width = math.max(minimum, child is RenderPostTable ? child._scrollWidth : minimum);
    return heights.copyWith(minWidth: width, maxWidth: width);
  }

  @override
  double computeMinIntrinsicWidth(double height) => child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) => child?.getMaxIntrinsicWidth(height) ?? 0;

  // The table is as high as it is laid out in the width.
  @override
  double computeMinIntrinsicHeight(double width) =>
      child == null ? 0 : child!.getDryLayout(_childConstraints(child!, BoxConstraints(maxWidth: width))).height;

  @override
  double computeMaxIntrinsicHeight(double width) => computeMinIntrinsicHeight(width);

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) {
      return constraints.smallest;
    }
    return constraints.constrain(child.getDryLayout(_childConstraints(child, constraints)));
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
    } else {
      child.layout(_childConstraints(child, constraints), parentUsesSize: true);
      size = constraints.constrain(child.size);
    }

    if (offset.hasPixels) {
      if (offset.pixels > _maxScrollExtent) {
        offset.correctBy(_maxScrollExtent - offset.pixels);
      } else if (offset.pixels < 0) {
        offset.correctBy(-offset.pixels);
      }
    }
    offset
      ..applyViewportDimension(size.width)
      ..applyContentDimensions(0, _maxScrollExtent);
  }

  Offset get _paintOffset => _paintOffsetForPosition(offset.pixels);

  Offset _paintOffsetForPosition(double position) => Offset(-position, 0);

  bool get _overflows => child != null && child!.size.width > size.width;

  final _clipRectLayer = LayerHandle<ClipRectLayer>();

  @override
  void dispose() {
    _clipRectLayer.layer = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) {
      return;
    }
    final paintOffset = _paintOffset;
    void paintContents(PaintingContext context, Offset offset) => context.paintChild(child, offset + paintOffset);
    if (_overflows || paintOffset.dx != 0) {
      _clipRectLayer.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        paintContents,
        oldLayer: _clipRectLayer.layer,
      );
    } else {
      _clipRectLayer.layer = null;
      paintContents(context, offset);
    }
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final paintOffset = _paintOffset;
    transform.translateByDouble(paintOffset.dx, paintOffset.dy, 0, 1);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject? child) =>
      child != null && (_overflows || _paintOffset.dx != 0) ? Offset.zero & size : null;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) {
      return false;
    }
    return result.addWithPaintOffset(
      offset: _paintOffset,
      position: position,
      hitTest: (result, transformed) => child.hitTest(result, position: transformed),
    );
  }

  @override
  RevealedOffset getOffsetToReveal(RenderObject target, double alignment, {Rect? rect, Axis? axis}) {
    rect ??= target.paintBounds;
    if (target is! RenderBox) {
      return RevealedOffset(offset: offset.pixels, rect: rect);
    }
    final bounds = MatrixUtils.transformRect(target.getTransformTo(child), rect);
    final targetOffset = bounds.left - (size.width - bounds.width) * alignment;
    return RevealedOffset(offset: targetOffset, rect: bounds.shift(_paintOffsetForPosition(targetOffset)));
  }

  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    if (!offset.allowImplicitScrolling) {
      return super.showOnScreen(descendant: descendant, rect: rect, duration: duration, curve: curve);
    }
    final newRect = RenderViewportBase.showInViewport(
      descendant: descendant,
      viewport: this,
      offset: offset,
      rect: rect,
      duration: duration,
      curve: curve,
    );
    super.showOnScreen(rect: newRect, duration: duration, curve: curve);
  }

  @override
  Rect describeSemanticsClip(RenderObject child) => Rect.fromLTRB(
    semanticBounds.left - offset.pixels,
    semanticBounds.top,
    semanticBounds.right + _maxScrollExtent - offset.pixels,
    semanticBounds.bottom,
  );
}
