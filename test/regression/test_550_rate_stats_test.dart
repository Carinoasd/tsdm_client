/// The rating statistics read the rate notices the app keeps: who rated the user's posts the most, the points they
/// gave and how many ratings came each week. The forum has no page of the ratings a member gave, so only the ones
/// received are counted.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/rate_stats/utils/rate_stats.dart';
import 'package:tsdm_client/features/rate_stats/view/rate_stats_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/charts/net_bar_chart.dart';

/// 2026-11-08 10:00 in UTC+8, the forum's clock, as unix seconds.
final int _base = DateTime.utc(2026, 11, 8, 2).millisecondsSinceEpoch ~/ 1000;

String _rateHtml(String rater, int uid, String score, {String reason = '活動加分'}) =>
    '您在主题 <a href="forum.php?mod=redirect&goto=findpost&pid=51&ptid=1025" target="_blank">2 樓</a> 的帖子被 '
    '<a href="home.php?mod=space&uid=$uid">$rater</a> 评分 $score  <div class="quote"><blockquote>$reason</blockquote></div>';

NoticeV2 _rate(
  String rater,
  int uid,
  String score, {
  int daysAgo = 0,
  int id = 1,
  String type = 'rate',
  String reason = '活動加分',
}) => NoticeV2(
  id: id,
  timestamp: _base - daysAgo * 86400,
  data: _rateHtml(rater, uid, score, reason: reason),
  ignoreType: type,
  authorId: uid,
  fromIdType: type,
);

void main() {
  group('the score of a notice', () {
    test('one kind, several kinds, a deduction', () {
      expect(rateScoresOf(_rateHtml('甲', 7, '威望 +10')), {'威望': 10});
      expect(rateScoresOf(_rateHtml('甲', 7, '威望 +1 天使币 -2')), {'威望': 1, '天使币': -2});
    });

    test('the reason is not read, it may say anything', () {
      expect(rateScoresOf(_rateHtml('甲', 7, '威望 +1', reason: '评分 威望 +99')), {'威望': 1});
    });

    test('the word in a thread title before the rater does not start the score early', () {
      const html =
          '您在主题 <a href="forum.php?mod=redirect&goto=findpost&pid=51&ptid=1025">评分 +1 名额</a> 的帖子被 '
          '<a href="home.php?mod=space&uid=7">甲</a> 评分 威望 +10';
      expect(rateScoresOf(html), {'威望': 10});
    });

    test('a notice without a score gives none', () {
      expect(rateScoresOf('<a href="x">甲</a> 回复了你'), isEmpty);
    });
  });

  group('the ratings received', () {
    test('rate notices only: not a rate track, a reply, or a notice without a score', () {
      final events = rateEventsOf([
        _rate('甲', 7, '威望 +10'),
        _rate('乙', 8, '威望 +1', type: 'ratetrack', id: 2),
        const NoticeV2(id: 3, timestamp: 1, data: '<a href="home.php?mod=space&uid=9">丙</a> 回复了', ignoreType: 'post'),
        _rate('丁', 10, '', id: 4),
      ]);
      expect(events.length, 1);
      expect(events.single.rater, '甲');
      expect(events.single.raterId, 7);
      expect(events.single.scores, {'威望': 10});
      expect(events.single.time, DateTime(2026, 11, 8, 10));
    });

    test('the raters are ranked by their number of ratings, the points given break a tie, ten at most', () {
      final events = rateEventsOf([
        _rate('甲', 7, '威望 +1'),
        _rate('甲', 7, '威望 +2', id: 2),
        _rate('乙', 8, '威望 +1', id: 3),
        _rate('乙', 8, '威望 +5', id: 4),
        _rate('丙', 9, '威望 +1', id: 5),
        for (var i = 0; i < 12; i++) _rate('用户$i', 100 + i, '威望 +1', id: 10 + i),
      ]);
      final top = topRatersOf(events);
      expect(top.length, 10);
      expect(top[0].rater, '乙', reason: 'as many ratings as 甲, more points');
      expect(top[0].count, 2);
      expect(top[0].scores, {'威望': 6});
      expect(top[1].rater, '甲');
      expect(top[2].rater, '丙', reason: 'one rating, the first of those');
    });

    test('a deduction takes away when the ratings are as many', () {
      final events = rateEventsOf([
        _rate('甲', 7, '威望 -50'),
        _rate('乙', 8, '威望 +10', id: 2),
        _rate('丙', 9, '威望 +1', id: 3),
      ]);
      final top = topRatersOf(events);
      expect([for (final e in top) e.rater], ['乙', '丙', '甲']);
    });

    test('totals by kind and counts by week', () {
      final events = rateEventsOf([
        _rate('甲', 7, '威望 +3'),
        _rate('乙', 8, '威望 +2 天使币 +1', daysAgo: 6, id: 2),
        _rate('乙', 8, '威望 +1', daysAgo: 7, id: 3),
        _rate('丙', 9, '威望 +1', daysAgo: 55, id: 4),
        _rate('丙', 9, '威望 +1', daysAgo: 56, id: 5),
      ]);
      expect(scoreTotalsOf(events), {'威望': 8, '天使币': 1});
      final weekly = weeklyCountsOf(events, DateTime(2026, 11, 8));
      expect(weekly.length, 8);
      expect(weekly.last, 2, reason: 'today and 6 days back');
      expect(weekly[6], 1, reason: '7 days back');
      expect(weekly.first, 1, reason: '55 days back; 56 is out');
      expect(weekly.fold(0, (a, b) => a + b), 4);
    });
  });

  group('the page', () {
    Future<void> pump(WidgetTester tester, List<RateEvent> events, {bool loading = false}) async {
      await LocaleSettings.setLocale(AppLocale.en);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: RateStatsView(events: events, today: DateTime(2026, 11, 8), loading: loading),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('lists the top raters with their counts and the weekly chart', (tester) async {
      await pump(
        tester,
        rateEventsOf([_rate('甲', 7, '威望 +1'), _rate('甲', 7, '威望 +1', id: 2), _rate('乙', 8, '威望 +1', id: 3)]),
      );
      expect(find.byKey(const ValueKey('ranked-row-0')), findsOneWidget);
      expect(find.byKey(const ValueKey('ranked-row-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('ranked-row-2')), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('ranked-row-0')), matching: find.text('甲')), findsOneWidget);
      expect(tester.widget<NetBarChart>(find.byKey(const ValueKey('rate-weekly'))).values.last, 3);
      expect(
        find.descendant(of: find.byKey(const ValueKey('rate-total-count')), matching: find.text('3')),
        findsOneWidget,
      );
      expect(find.text('+3'), findsOneWidget, reason: 'the points given in all');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the notices still on their way: loading, not no data', (tester) async {
      await pump(tester, const [], loading: true);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text(t.general.noData), findsNothing);
    });

    testWidgets('no rating: no data', (tester) async {
      await pump(tester, const []);
      expect(find.byType(NetBarChart), findsNothing);
      expect(find.text(t.general.noData), findsOneWidget);
    });
  });
}
