/// The points trend charts the net change of a kind of points per day (30 days) and per week (8 weeks) from the
/// points changelog of the last 56 days (`credit_v12_trend.json`, an answer of the plugin's structured credit log,
/// scrubbed like the earlier ones).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_calendar_cubit.dart';
import 'package:tsdm_client/features/points/bloc/points_trend_cubit.dart';
import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/utils/credit_page_api.dart';
import 'package:tsdm_client/features/points/utils/points_trend.dart';
import 'package:tsdm_client/features/points/widgets/points_trend_tab.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/charts/net_bar_chart.dart';
import 'package:tsdm_client/widgets/charts/trend_line_chart.dart';

List<PointsChange> _fixtureChanges() {
  final json = jsonDecode(File('test/data/tsdmapp/credit_v12_trend.json').readAsStringSync());
  return pointsChangelogFromApi(json as Map<String, dynamic>)!.changes;
}

final _today = DateTime(2026, 11, 8);

ChangelogRangeFetcher _fetcher(List<PointsChange> changes, {List<(DateTime, DateTime)>? asked, bool fail = false}) =>
    ({required start, required end}) async {
      asked?.add((start, end));
      if (fail) {
        return Left(LoadFailure(LoadFailureKind.timeout));
      }
      return Right((changes: changes, complete: true));
    };

void main() {
  group('the numbers', () {
    test('a printed change is a signed number, the reset is none', () {
      expect(signedChangeOf('+2'), 2);
      expect(signedChangeOf('-5'), -5);
      expect(signedChangeOf('+1,000'), 1000);
      expect(signedChangeOf('清零'), isNull);
      expect(signedChangeOf(''), isNull);
    });

    test('the kinds are the ones the records changed, the most changed first; a reset alone is no kind', () {
      expect(pointsKindsOf(_fixtureChanges()), ['天使币', '威望']);
    });

    test('daily: 30 days ending today, the days without a record 0, what is out of the window left out', () {
      final daily = dailyNetOf(_fixtureChanges(), '天使币', _today);
      expect(daily.length, 30);
      expect(daily.last, 3, reason: 'two records of today');
      expect(daily[28], -5, reason: 'yesterday');
      expect(daily[22], 10, reason: 'Nov 1');
      expect(daily.first, 7, reason: 'Oct 10, the oldest day of the window');
      expect(daily.where((e) => e != 0).length, 4, reason: 'the reset and Sep 1 (out of it) count for nothing');
      expect(dailyNetOf(_fixtureChanges(), '威望', _today).last, 1);
    });

    test('weekly: 8 weeks of 7 days ending today', () {
      final weekly = weeklyNetOf(_fixtureChanges(), '天使币', _today);
      expect(weekly.length, 8);
      expect(weekly.last, -2, reason: 'Nov 2 to Nov 8');
      expect(weekly[6], 10, reason: 'Oct 26 to Nov 1');
      expect(weekly[3], 7, reason: 'Oct 10 is 29 days back');
      expect(weekly.fold(0, (a, b) => a + b), 15, reason: 'Sep 1 is older than 8 weeks');
    });
  });

  group('the cubit', () {
    final now = DateTime.utc(2026, 11, 8, 4);

    test('reads the last 56 days once and shows the first kind', () async {
      final asked = <(DateTime, DateTime)>[];
      final cubit = PointsTrendCubit(
        fetchRange: _fetcher(_fixtureChanges(), asked: asked),
        now: now,
      );
      await cubit.load();
      expect(asked, [(DateTime(2026, 9, 14), DateTime(2026, 11, 8))]);
      expect(cubit.state.status, PointsTrendStatus.success);
      expect(cubit.state.kind, '天使币');
      cubit.select(1);
      expect(cubit.state.kind, '威望');
      cubit.select(9);
      expect(cubit.state.kind, '威望');
      expect(asked.length, 1, reason: 'a kind is a choice, not a request');
      await cubit.close();
    });

    test('a reload keeps the kind shown; a failed reload keeps the charts', () async {
      final changes = _fixtureChanges();
      var fail = false;
      final cubit = PointsTrendCubit(
        fetchRange: ({required start, required end}) => _fetcher(changes, fail: fail)(start: start, end: end),
        now: now,
      );
      await cubit.load();
      cubit.select(1);
      await cubit.load();
      expect(cubit.state.kind, '威望');
      fail = true;
      await cubit.load();
      expect(cubit.state.status, PointsTrendStatus.success);
      expect(cubit.state.kind, '威望');
      expect(cubit.state.failure?.kind, LoadFailureKind.timeout);
      await cubit.close();
    });

    test('a failed first read fails the tab', () async {
      final cubit = PointsTrendCubit(fetchRange: _fetcher([], fail: true), now: now);
      await cubit.load();
      expect(cubit.state.status, PointsTrendStatus.failed);
      await cubit.close();
    });
  });

  group('the tab', () {
    Future<PointsTrendCubit> pump(WidgetTester tester, List<PointsChange> changes) async {
      await LocaleSettings.setLocale(AppLocale.en);
      final cubit = PointsTrendCubit(fetchRange: _fetcher(changes), now: DateTime.utc(2026, 11, 8, 4));
      await tester.runAsync(cubit.load);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: BlocProvider.value(value: cubit, child: const PointsTrendTab()),
            ),
          ),
        ),
      );
      await tester.pump();
      return cubit;
    }

    testWidgets('draws the line and the bars of the kind, the chips switch the kind', (tester) async {
      final cubit = await pump(tester, _fixtureChanges());
      expect(tester.widget<TrendLineChart>(find.byKey(const ValueKey('trend-line'))).values.last, 3);
      expect(tester.widget<NetBarChart>(find.byKey(const ValueKey('trend-bars'))).values.length, 8);
      await tester.tap(find.byKey(const ValueKey('trend-kind-1')));
      await tester.pump();
      expect(tester.widget<TrendLineChart>(find.byKey(const ValueKey('trend-line'))).values.last, 1);
      expect(tester.takeException(), isNull);
      await cubit.close();
    });

    testWidgets('no record: no chart', (tester) async {
      final cubit = await pump(tester, []);
      expect(find.byType(TrendLineChart), findsNothing);
      await cubit.close();
    });
  });
}
