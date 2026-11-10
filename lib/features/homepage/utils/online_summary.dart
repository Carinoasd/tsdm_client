import 'package:flutter/foundation.dart' show immutable;
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/html.dart' as uh;

/// The numbers of the "在线会员" line of the forum's homepage, as the forum's app API gives them with the homepage
/// answer (plugin 3.8.0, `online`): everyone online, the members among them with the invisible ones, the guests, and
/// the record with its day as the page prints it.
@immutable
final class HomeOnline {
  /// Constructor.
  const HomeOnline({
    required this.total,
    required this.members,
    required this.invisible,
    required this.guests,
    required this.record,
    required this.recordDate,
  });

  /// The numbers in `online` of a homepage answer; null when the answer has none: an older plugin (no such field),
  /// or a forum that prints no such line on its homepage (`online` null).
  static HomeOnline? fromApi(Object? online) {
    if (online is! Map<String, dynamic> || online['total'] is! num) {
      return null;
    }
    return HomeOnline(
      total: tsdmAppInt(online['total']),
      members: tsdmAppInt(online['members']),
      invisible: tsdmAppInt(online['invisible']),
      guests: tsdmAppInt(online['guests']),
      record: tsdmAppInt(online['record']),
      recordDate: tsdmAppText(online['record_date']).trim(),
    );
  }

  /// Everyone online.
  final int total;

  /// The members online, the invisible ones among them.
  final int members;

  /// The members online who hide it.
  final int invisible;

  /// The guests online.
  final int guests;

  /// The most ever online at once, 0 when the forum keeps none.
  final int record;

  /// The day of [record], as the page prints it ("2026-9-24"); empty when the forum keeps none.
  final String recordDate;

  @override
  bool operator ==(Object other) =>
      other is HomeOnline &&
      other.total == total &&
      other.members == members &&
      other.invisible == invisible &&
      other.guests == guests &&
      other.record == record &&
      other.recordDate == recordDate;

  @override
  int get hashCode => Object.hash(total, members, invisible, guests, record, recordDate);
}

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
/// no such line (the forum turned it off, the structured answer of the app API, which gives the numbers instead:
/// [HomeOnline]).
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
