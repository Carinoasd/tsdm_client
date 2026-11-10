import 'package:tsdm_client/extensions/string.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:xml/xml.dart';

/// A page of the forum's statistics (`misc.php?mod=stat`) to switch to: a tab of the side navigation, a month of the
/// moderation statistics.
final class SiteStatsLink {
  /// Constructor.
  const SiteStatsLink({required this.label, required this.url, this.selected = false});

  /// The words of the link.
  final String label;

  /// Absolute url of the page.
  final String url;

  /// Whether this is the page shown.
  final bool selected;
}

/// One cell of a table of the statistics: its text, and where it links to, if anywhere.
final class SiteStatsCell {
  /// Constructor.
  const SiteStatsCell(this.text, {this.url, this.header = false});

  /// The text of the cell, white space collapsed.
  final String text;

  /// Absolute url of the link of the cell, null when it has none.
  final String? url;

  /// Whether the cell is a heading (`th`).
  final bool header;
}

/// A table of the statistics, as the forum prints it.
final class SiteStatsTable {
  /// Constructor.
  const SiteStatsTable({required this.rows, this.title});

  /// The title of the table (its `caption`, or the heading the forum puts above it), null when it has none.
  final String? title;

  /// The rows, each the cells in order.
  final List<List<SiteStatsCell>> rows;

  /// Whether every row pairs a heading with its value (`th td th td ...`, the "基本概况" tables): shown as labeled
  /// values instead of a grid. The pairs are kept in order; the same label may come twice in one table (the forum's
  /// "最热门的版块" column repeats "主题数" and "帖子数" for that forum).
  bool get isKeyValue =>
      rows.isNotEmpty &&
      rows.every(
        (row) => row.isNotEmpty && row.length.isEven && row.indexed.every((e) => e.$2.header == e.$1.isEven),
      );

  /// The (label, value) pairs of a key-value table ([isKeyValue]), in order, row by row.
  List<(SiteStatsCell, SiteStatsCell)> get pairs => [
    for (final row in rows)
      for (var i = 0; i + 1 < row.length; i += 2) (row[i], row[i + 1]),
  ];
}

/// The trend the forum draws above a statistics page (`div#statchart`): one or more lines over the same days.
final class SiteStatsChart {
  /// Constructor.
  const SiteStatsChart({required this.labels, required this.series});

  /// The label of every point, oldest first ("11-01").
  final List<String> labels;

  /// The lines: a title and a value for every label each.
  final List<({String title, List<int> values})> series;

  /// Whether there is anything to draw.
  bool get isEmpty => labels.isEmpty || series.isEmpty;
}

/// A page of the forum's statistics.
final class SiteStatsData {
  /// Constructor.
  const SiteStatsData({
    required this.title,
    this.tabs = const [],
    this.months = const [],
    this.heading,
    this.tables = const [],
    this.chart,
    this.chartUrl,
    this.note,
    this.nextPageUrl,
    this.previousPageUrl,
    this.currentPage,
    this.totalPages,
  });

  /// The title the page prints (`h1`).
  final String title;

  /// The pages of the side navigation: 基本概况, 版块统计, 管理团队, 管理统计, 会员列表, 趋势统计 (as the forum lists
  /// them for the viewer).
  final List<SiteStatsLink> tabs;

  /// The months the moderation statistics offer (`ul.ttp`).
  final List<SiteStatsLink> months;

  /// The line the page prints under its title, e.g. the period of the moderation statistics.
  final String? heading;

  /// The tables, in order.
  final List<SiteStatsTable> tables;

  /// The trend, when the page draws one and it was read from the page itself.
  final SiteStatsChart? chart;

  /// Where the page loads its trend from (the `xml=1` answer), when it draws one from there.
  final String? chartUrl;

  /// The forum's note about its cache ("统计数据已被缓存，上次于 ... 被更新").
  final String? note;

  /// Absolute url of the next page of a paged list.
  final String? nextPageUrl;

  /// Absolute url of the previous page of a paged list.
  final String? previousPageUrl;

  /// The page of a paged list shown (`div.pg strong`), null for a page that is not one.
  final int? currentPage;

  /// How many pages the paged list has (`div.pg label span` "共 N 页"), null when the forum does not say.
  final int? totalPages;

  /// This page with the [chart] loaded from [chartUrl].
  SiteStatsData withChart(SiteStatsChart? chart) => SiteStatsData(
    title: title,
    tabs: tabs,
    months: months,
    heading: heading,
    tables: tables,
    chart: chart,
    note: note,
    nextPageUrl: nextPageUrl,
    previousPageUrl: previousPageUrl,
    currentPage: currentPage,
    totalPages: totalPages,
  );
}

final _spaces = RegExp(r'\s+');

String _text(uh.Element? e) => (e?.text ?? '').replaceAll(_spaces, ' ').trim();

/// The absolute url of the link [a], null for a script link or none.
String? _href(uh.Element? a) {
  final href = a?.attributes['href']?.trim() ?? '';
  if (href.isEmpty || href.startsWith('javascript')) {
    return null;
  }
  return href.prependHost();
}

/// `statchart('misc.php?mod=stat&op=trend&xml=1&...')` in the script under `div#statchart`.
final _statChartRe = RegExp(r"""statchart\('([^']*)'""");

/// A day of the forum's daily log ("2026-11-07").
final _dayRe = RegExp(r'^\d{4}-(\d{1,2})-(\d{1,2})$');

/// The forum's message instead of a statistics page (a group that may not see them: "抱歉，您所在的用户组(游客)无法进行此
/// 操作"), null when [document] is a statistics page.
String? siteStatsServerMessage(uh.Document document) {
  if (document.querySelector('div#ct h1.mt') != null) {
    return null;
  }
  final text = _text(document.querySelector('div#messagetext > p'));
  return text.isEmpty ? null : text;
}

/// Parse a page of the forum's statistics (`misc.php?mod=stat&op=...`); null when [document] is none (the forum's
/// message, [siteStatsServerMessage]).
///
/// ```html
/// <div id="ct" class="ct2_a wp cl">
///   <div class="mn"><div class="bm bw0">
///     <h1 class="mt">基本概况</h1>
///     <table summary="会员统计" class="dt bm mbw">
///       <caption><h2 class="mbn">会员统计</h2></caption>
///       <tr><th>注册会员</th><td>5087</td><th>发帖会员</th><td>5048</td></tr>
///     </table>
///     <div class="notice">统计数据已被缓存，上次于 ... 被更新，下次将于 ... 进行更新</div>
///   </div></div>
///   <div class="appl"><div class="tbn"><ul>
///     <li class="cl a"><a href="misc.php?mod=stat&op=basic">基本概况</a></li> ...
///   </ul></div></div>
/// </div>
/// ```
///
/// * The tables are every `table.dt` but the filter form of the trends; a heading above a table (`div#ID_c h3`, the
///   groups of the moderators) is its title when it has no `caption`.
/// * The moderation statistics print the names (`div.stl`) and the numbers (`div.str`, 3000 px wide) as two tables
///   whose rows go together: they are joined into one.
/// * A trend (`div#statchart`) is loaded by the page from the `xml=1` answer its script names ([SiteStatsData.chartUrl]). The daily
///   log of a forum names a broken url there (`month={getgpc('month')}`, a template the forum never filled in, which
///   it answers with an error): that trend is read from the log's own table instead (the days and the posts).
SiteStatsData? parseSiteStatsPage(uh.Document document) {
  final main = document.querySelector('div#ct div.mn');
  final title = _text(main?.querySelector('h1.mt'));
  if (main == null || title.isEmpty) {
    return null;
  }
  final tabs = [
    for (final li in document.querySelectorAll('div#ct div.tbn li'))
      if (li.querySelector('a') case final a?)
        if (_href(a) case final url?) SiteStatsLink(label: _text(a), url: url, selected: li.classes.contains('a')),
  ];
  final months = [
    for (final li in main.querySelectorAll('ul.ttp > li'))
      if (li.querySelector('a') case final a?)
        if (_href(a) case final url?) SiteStatsLink(label: _text(a), url: url, selected: li.classes.contains('a')),
  ];
  // The period of the moderation statistics: the heading's text without its "[导出]" link.
  final headingNode = main.querySelectorAll('h3').where((e) => e.parent?.classes.contains('umh') != true).firstOrNull;
  final heading = headingNode?.nodes
      .where((n) => n is! uh.Element || n.localName != 'a')
      .map((n) => n.text ?? '')
      .join()
      .replaceAll(_spaces, ' ')
      .trim();

  final tables = <SiteStatsTable>[];
  final joined = <uh.Element>{};
  for (final table in main.querySelectorAll('table.dt')) {
    if (joined.contains(table) || _inside(table, (e) => e.localName == 'form')) {
      continue;
    }
    var rows = _rowsOf(table);
    final parent = table.parent;
    if (parent != null && parent.classes.contains('stl')) {
      final numbers = (parent.nextElementSibling?.classes.contains('str') ?? false)
          ? parent.nextElementSibling!.querySelector('table')
          : null;
      if (numbers != null) {
        joined.add(numbers);
        final more = _rowsOf(numbers);
        rows = [
          for (var i = 0; i < rows.length; i++) [...rows[i], if (i < more.length) ...more[i]],
        ];
      }
    }
    if (rows.isEmpty) {
      continue;
    }
    final caption = _text(table.querySelector('caption h2') ?? table.querySelector('caption'));
    final above = table.id.isEmpty ? '' : _text(document.querySelector('div#${table.id}_c h3'));
    tables.add(
      SiteStatsTable(
        title: caption.isNotEmpty
            ? caption
            : above.isNotEmpty
            ? above
            : null,
        rows: rows,
      ),
    );
  }

  SiteStatsChart? chart;
  String? chartUrl;
  if (main.querySelector('div#statchart') != null) {
    final source = main.querySelectorAll('script').map((e) => e.text ?? '').join('\n');
    final url = _statChartRe.firstMatch(source)?.group(1);
    if (url != null && !url.contains('{')) {
      chartUrl = url.replaceAll('&amp;', '&').prependHost();
    } else {
      chart = _chartOfDailyLog(tables);
    }
  }

  final note = _text(main.querySelector('div.notice'));
  return SiteStatsData(
    title: title,
    tabs: tabs,
    months: months,
    heading: heading == null || heading.isEmpty ? null : heading,
    tables: tables,
    chart: chart,
    chartUrl: chartUrl,
    note: note.isEmpty ? null : note,
    nextPageUrl: _href(main.querySelector('div.pg a.nxt')),
    previousPageUrl: _href(main.querySelector('div.pg a.prev')),
    currentPage: _text(main.querySelector('div.pg > strong')).parseToInt(),
    totalPages: RegExp(
      r'\d+',
    ).firstMatch(main.querySelector('div.pg label span')?.attributes['title'] ?? '')?.group(0)?.parseToInt(),
  );
}

List<List<SiteStatsCell>> _rowsOf(uh.Element table) => [
  for (final tr in table.querySelectorAll('tr'))
    if (_tableOf(tr) == table)
      if ([
            for (final cell in tr.children)
              if (cell.localName == 'th' || cell.localName == 'td')
                SiteStatsCell(_text(cell), url: _href(cell.querySelector('a')), header: cell.localName == 'th'),
          ]
          case final cells when cells.isNotEmpty)
        cells,
];

/// Whether an ancestor of [e] is one [test] accepts.
bool _inside(uh.Element e, bool Function(uh.Element e) test) {
  for (var p = e.parent; p != null; p = p.parent) {
    if (test(p)) {
      return true;
    }
  }
  return false;
}

/// The table the row [tr] is in, the nearest one (a table inside a cell has rows of its own).
uh.Element? _tableOf(uh.Element tr) {
  for (var p = tr.parent; p != null; p = p.parent) {
    if (p.localName == 'table') {
      return p;
    }
  }
  return null;
}

/// The trend of a forum's daily log: the first table whose rows are a day and a count.
SiteStatsChart? _chartOfDailyLog(List<SiteStatsTable> tables) {
  for (final table in tables) {
    final days = [
      for (final row in table.rows)
        if (row.length == 2 && !row[0].header)
          if (_dayRe.firstMatch(row[0].text) case final m?)
            ('${m.group(1)!.padLeft(2, '0')}-${m.group(2)!.padLeft(2, '0')}', row[1].text.parseToInt() ?? 0),
    ];
    if (days.isNotEmpty) {
      return SiteStatsChart(
        labels: [for (final d in days) d.$1],
        series: [
          (
            title: table.rows.first.length == 2 && table.rows.first[1].header ? table.rows.first[1].text : '',
            values: [for (final d in days) d.$2],
          ),
        ],
      );
    }
  }
  return null;
}

/// Parse the trend the forum answers for its chart ([SiteStatsData.chartUrl], `xml=1`):
///
/// ```xml
/// <chart><xaxis><value xid='1'>1011</value>...</xaxis>
///   <graphs><graph gid='0' title='登录用户'><value xid='1'>14</value>...</graph>...</graphs></chart>
/// ```
///
/// A day is "MMDD" on the axis, shown "MM-DD". Null when [xml] is no such answer.
SiteStatsChart? parseSiteStatsChart(String xml) {
  final XmlDocument document;
  try {
    document = XmlDocument.parse(xml.trim());
  } on XmlException {
    return null;
  }
  final axis = document.findAllElements('xaxis').firstOrNull;
  if (axis == null) {
    return null;
  }
  final ids = <String>[];
  final labels = <String>[];
  for (final value in axis.findElements('value')) {
    ids.add(value.getAttribute('xid') ?? '');
    final text = value.innerText.trim();
    labels.add(RegExp(r'^\d{4}$').hasMatch(text) ? '${text.substring(0, 2)}-${text.substring(2)}' : text);
  }
  final series = <({String title, List<int> values})>[];
  for (final graph in document.findAllElements('graph')) {
    final byId = {
      for (final value in graph.findElements('value')) value.getAttribute('xid') ?? '': value.innerText.trim(),
    };
    series.add((
      title: graph.getAttribute('title')?.trim() ?? '',
      values: [for (final id in ids) byId[id]?.parseToInt() ?? 0],
    ));
  }
  final chart = SiteStatsChart(labels: labels, series: series);
  return chart.isEmpty ? null : chart;
}
