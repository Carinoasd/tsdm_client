import 'package:universal_html/html.dart' as uh;

/// The "在线会员" line of the forum's homepage (`forum.php`), split where the forum puts its dashes: the totals as
/// the page prints them, the words of the forum kept.
///
/// ```html
/// <div id="online" class="bm oll">
///   <div class="bm_h"><h3>
///     <strong><a href="home.php?mod=space&do=friend&view=online&type=member">在线会员</a></strong>
///     <span class="xs1">- <strong>7</strong> 人在线
///     - <strong>7</strong> 会员(<strong>0</strong> 隐身),
///     <strong>0</strong> 位游客
///     - 最高记录是 <strong>24</strong> 于 <strong>2026-9-24</strong>.</span>
///   </h3></div>
///   ...
/// </div>
/// ```
///
/// The forum prints the details (members, invisible ones, guests) only when it lists the members there too: under
/// 500 online and not folded; otherwise the line is "- 总计 N 人在线 - 最高记录是 N 于 DATE.". Empty when the page has
/// no such line (the forum turned it off, the structured answer of the app API, which carries none).
List<String> parseOnlineSummary(uh.Document document) {
  final text = document.querySelector('div#online div.bm_h h3 span.xs1')?.text;
  if (text == null) {
    return const [];
  }
  return text
      .replaceAll(RegExp(r'\s+'), ' ')
      .split(RegExp(r'(?:^|\s)-\s'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList(growable: false);
}
