/// The check-in calendar reads the days of check-in from the points changelog.
///
/// The check-in plugin keeps no list of days, only the last time and the counts; its rewards are in the changelog as
/// records of no operation code titled "每日签到". The calendar picks them from the changelog of a month
/// (`credit_v12_checkin_month.json`, an answer of the plugin's structured credit log, scrubbed like the earlier ones),
/// and follows the days in a row back into the earlier months.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_calendar_cubit.dart';
import 'package:tsdm_client/features/checkin/utils/checkin_calendar.dart';
import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/utils/changelog_range.dart';
import 'package:tsdm_client/features/points/utils/credit_page_api.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/charts/month_calendar.dart';

List<PointsChange> _fixtureChanges() {
  final json = jsonDecode(File('test/data/tsdmapp/credit_v12_checkin_month.json').readAsStringSync());
  return pointsChangelogFromApi(json as Map<String, dynamic>)!.changes;
}

PointsChange _record(DateTime time, {String operation = '每日签到', String detail = '恭喜你签到成功！随机奖励'}) => PointsChange(
  operation: operation,
  operationFilterUrl: '',
  pointsChangeType: PointsChangeType.more,
  changeMap: const {'天使币': '+8'},
  detail: detail,
  time: time,
);

/// A fetcher answering from [months]: the days checked in by month number, recording the asked ranges in [asked].
ChangelogRangeFetcher _fetcher(
  Map<int, List<int>> months,
  List<DateTime> asked, {
  Set<int> failing = const {},
  Set<int> incomplete = const {},
  Map<int, Completer<void>> gates = const {},
}) => ({required start, required end}) async {
  asked.add(start);
  await gates[start.month]?.future;
  if (failing.contains(start.month)) {
    return Left(LoadFailure(LoadFailureKind.timeout));
  }
  final days = months[start.month] ?? <int>[];
  return Right((
    changes: [for (final day in days) _record(DateTime(start.year, start.month, day, 9))],
    complete: !incomplete.contains(start.month),
    oldest: days.isEmpty ? null : DateTime(start.year, start.month, days.reduce((a, b) => a < b ? a : b), 9),
  ));
};

void main() {
  group('reading the days', () {
    test('the check-in records of the answer are the days, a reward and its bonus count once', () {
      final changes = _fixtureChanges();
      expect(changes.length, greaterThan(10));
      expect(checkinDaysOf(changes).map((e) => e.day).toList()..sort(), [1, 2, 3, 5, 6]);
      expect(checkinDaysOf(changes).every((e) => e.month == 11 && e.year == 2026), isTrue);
    });

    test('a record is a check-in by the word, not by the operation code', () {
      expect(isCheckinRecord(_record(DateTime(2026, 11))), isTrue);
      expect(isCheckinRecord(_record(DateTime(2026, 11), operation: '积分规则', detail: '签到额外奖励')), isTrue);
      expect(isCheckinRecord(_record(DateTime(2026, 11), operation: '积分规则', detail: '发表回复(fid:6)')), isFalse);
    });

    test('the days in a row end at today, or at yesterday when today is not checked yet', () {
      final days = {
        for (final d in [1, 2, 3, 5, 6]) DateTime(2026, 11, d),
      };
      expect(checkinStreakOf(days, DateTime(2026, 11, 6)).length, 2);
      expect(checkinStreakOf(days, DateTime(2026, 11, 7)).length, 2);
      expect(checkinStreakOf(days, DateTime(2026, 11, 8)).length, 0);
      final row = checkinStreakOf(days, DateTime(2026, 11, 3));
      expect((row.length, row.before), (3, DateTime(2026, 10, 31)));
    });

    test('today is the day of the forum, UTC+8, whatever the zone of the device', () {
      expect(forumToday(DateTime.utc(2026, 11, 7, 16, 30)), DateTime(2026, 11, 8));
      expect(forumToday(DateTime.utc(2026, 11, 7, 15, 59)), DateTime(2026, 11, 7));
    });
  });

  group('the cubit', () {
    final now = DateTime.utc(2026, 11, 8, 4);

    test('reads the month of today and the total, then the earlier month the row reaches into', () async {
      final asked = <DateTime>[];
      final cubit = CheckinCalendarCubit(
        fetchRange: _fetcher({
          11: [1, 2, 3, 4, 5, 6, 7, 8],
          10: [29, 30, 31],
        }, asked),
        totalDays: () async => 120,
        now: now,
      );
      await cubit.load();
      expect(cubit.state.status, CheckinCalendarStatus.success);
      expect(cubit.state.markedDays, {1, 2, 3, 4, 5, 6, 7, 8});
      expect(cubit.state.streak, 11);
      expect(cubit.state.totalDays, 120);
      expect(asked, [DateTime(2026, 11), DateTime(2026, 10)], reason: 'the row ends inside October');
      await cubit.close();
    });

    test('a row that stops inside the month reads nothing more', () async {
      final asked = <DateTime>[];
      final cubit = CheckinCalendarCubit(
        fetchRange: _fetcher({
          11: [1, 2, 3, 6, 7, 8],
        }, asked),
        totalDays: () async => null,
        now: now,
      );
      await cubit.load();
      expect(cubit.state.streak, 3);
      expect(cubit.state.totalDays, isNull);
      expect(asked, [DateTime(2026, 11)]);
      await cubit.close();
    });

    test('the arrows move between months, a month is read once, the future is not shown', () async {
      final asked = <DateTime>[];
      final cubit = CheckinCalendarCubit(
        fetchRange: _fetcher({
          11: [8],
          10: [3, 4],
        }, asked),
        totalDays: () async => null,
        now: now,
      );
      await cubit.load();
      await cubit.moveMonth(1);
      expect(cubit.state.month, DateTime(2026, 11), reason: 'no month after the current one');
      await cubit.moveMonth(-1);
      expect(cubit.state.month, DateTime(2026, 10));
      expect(cubit.state.markedDays, {3, 4});
      await cubit.moveMonth(1);
      await cubit.moveMonth(-1);
      expect(asked.where((e) => e.month == 10).length, 1);
      await cubit.close();
    });

    test('a month that fails is not shown empty: the calendar stays and the failure is told', () async {
      final cubit = CheckinCalendarCubit(
        fetchRange: _fetcher(
          {
            11: [8],
          },
          [],
          failing: {10},
        ),
        totalDays: () async => null,
        now: now,
      );
      await cubit.load();
      await cubit.moveMonth(-1);
      expect(cubit.state.month, DateTime(2026, 11));
      expect(cubit.state.failure?.kind, LoadFailureKind.timeout);
      expect(cubit.state.loadingMonth, isFalse);
      await cubit.close();
    });

    test('a month asked while the streak reads it is read once', () async {
      final asked = <DateTime>[];
      final gate = Completer<void>();
      final cubit = CheckinCalendarCubit(
        fetchRange: _fetcher(
          {
            11: [for (var d = 1; d <= 8; d++) d],
            10: [31],
          },
          asked,
          gates: {10: gate},
        ),
        totalDays: () async => null,
        now: now,
      );
      final loading = cubit.load();
      await pumpEventQueue();
      expect(cubit.state.status, CheckinCalendarStatus.success, reason: 'the page does not wait for the streak');
      final moving = cubit.moveMonth(-1);
      await pumpEventQueue();
      gate.complete();
      await Future.wait([loading, moving]);
      expect(asked.where((e) => e.month == 10).length, 1);
      expect(cubit.state.month, DateTime(2026, 10));
      expect(cubit.state.markedDays, {31});
      expect(cubit.state.streak, 9);
      await cubit.close();
    });

    test('the page does not wait for the total', () async {
      final total = Completer<int?>();
      final cubit = CheckinCalendarCubit(
        fetchRange: _fetcher({
          11: [8],
        }, []),
        totalDays: () => total.future,
        now: now,
      );
      final loading = cubit.load();
      await pumpEventQueue();
      expect(cubit.state.status, CheckinCalendarStatus.success);
      expect(cubit.state.totalDays, isNull);
      total.complete(42);
      await loading;
      expect(cubit.state.totalDays, 42);
      await cubit.close();
    });

    test('the calendar goes back 36 months and no further', () async {
      final cubit = CheckinCalendarCubit(fetchRange: _fetcher({}, []), totalDays: () async => null, now: now);
      await cubit.load();
      for (var i = 0; i < 40; i++) {
        await cubit.moveMonth(-1);
      }
      expect(cubit.state.month, DateTime(2023, 11));
      await cubit.close();
    });

    test('the row is followed back 14 months at most', () async {
      final asked = <DateTime>[];
      final cubit = CheckinCalendarCubit(
        fetchRange: ({required start, required end}) async {
          asked.add(start);
          return Right((
            changes: [for (var d = 1; d <= end.day; d++) _record(DateTime(start.year, start.month, d, 9))],
            complete: true,
            oldest: null,
          ));
        },
        totalDays: () async => null,
        now: now,
      );
      await cubit.load();
      expect(asked.length, 14);
      expect(cubit.state.streak, greaterThan(300));
      await cubit.close();
    });

    test('on the 1st, not checked yet, the row of yesterday is read from the month before', () async {
      final asked = <DateTime>[];
      final cubit = CheckinCalendarCubit(
        fetchRange: _fetcher({
          11: [28, 29, 30],
        }, asked),
        totalDays: () async => null,
        now: DateTime.utc(2026, 12, 1, 4),
      );
      await cubit.load();
      expect(cubit.state.markedDays, isEmpty);
      expect(cubit.state.streak, 3);
      expect(asked, [DateTime(2026, 12), DateTime(2026, 11)]);
      await cubit.close();
    });

    test('a row that ends in a month cut at the page limit is only the least', () async {
      final cubit = CheckinCalendarCubit(
        fetchRange: _fetcher(
          {
            11: [1, 2, 3, 4, 5, 6, 7, 8],
            10: [20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31],
          },
          [],
          incomplete: {10},
        ),
        totalDays: () async => null,
        now: now,
      );
      await cubit.load();
      expect(cubit.state.streak, 20);
      expect(cubit.state.streakAtLeast, isTrue);
      await cubit.close();
    });

    test('a break inside the records that were read is a break, the month cut or not', () async {
      final cubit = CheckinCalendarCubit(
        fetchRange: _fetcher(
          {
            11: [1, 2, 3, 4, 5, 6, 7, 8],
            10: [10, 11, 12, 13, 14, 15, 16, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31],
          },
          [],
          incomplete: {10},
        ),
        totalDays: () async => null,
        now: now,
      );
      await cubit.load();
      expect(cubit.state.streak, 20, reason: 'Oct 19 is inside what was read, nothing was cut there');
      expect(cubit.state.streakAtLeast, isFalse);
      await cubit.close();
    });

    test('a reload while a month is read does not read it twice', () async {
      final asked = <DateTime>[];
      final gate = Completer<void>();
      final cubit = CheckinCalendarCubit(
        fetchRange: _fetcher(
          {
            11: [for (var d = 1; d <= 8; d++) d],
            10: [31],
          },
          asked,
          gates: {10: gate},
        ),
        totalDays: () async => null,
        now: now,
      );
      final first = cubit.load();
      await pumpEventQueue();
      final second = cubit.load();
      await pumpEventQueue();
      gate.complete();
      await Future.wait([first, second]);
      expect(cubit.state.streak, 9);
      expect(asked.where((e) => e.month == 10).length, 2, reason: 'once per load, the first load is dropped');
      await cubit.moveMonth(-1);
      expect(asked.where((e) => e.month == 10).length, 2, reason: 'October is in, asking it again reads nothing');
      await cubit.close();
    });

    test('an earlier month that fails while the row is followed is told, the row stays as counted', () async {
      final cubit = CheckinCalendarCubit(
        fetchRange: _fetcher(
          {
            11: [1, 2, 3, 4, 5, 6, 7, 8],
          },
          [],
          failing: {10},
        ),
        totalDays: () async => null,
        now: now,
      );
      await cubit.load();
      expect(cubit.state.status, CheckinCalendarStatus.success);
      expect(cubit.state.streak, 8);
      expect(cubit.state.failure?.kind, LoadFailureKind.timeout);
      await cubit.close();
    });

    test('the first month failing fails the page', () async {
      final cubit = CheckinCalendarCubit(
        fetchRange: _fetcher({}, [], failing: {11}),
        totalDays: () async => null,
        now: now,
      );
      await cubit.load();
      expect(cubit.state.status, CheckinCalendarStatus.failed);
      await cubit.close();
    });
  });

  group('the changelog range', () {
    test('is written as the query takes it', () {
      expect(changelogQueryDate(DateTime(2026, 1, 5)), '2026-01-05');
    });
  });

  group('the calendar widget', () {
    Future<void> pump(WidgetTester tester, {VoidCallback? onNext}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MonthCalendar(
            month: DateTime(2026, 11),
            marked: const {1, 2, 30},
            today: DateTime(2026, 11, 8),
            onPrevious: () {},
            onNext: onNext,
          ),
        ),
      ),
    );

    testWidgets('lays the days of the month, the marked ones filled', (tester) async {
      await pump(tester);
      for (var day = 1; day <= 30; day++) {
        expect(find.byKey(ValueKey('calendar-day-$day')), findsOneWidget, reason: '$day');
      }
      expect(find.byKey(const ValueKey('calendar-day-31')), findsNothing);
      Color? fill(int day) =>
          ((tester.widget<Container>(find.byKey(ValueKey('calendar-day-$day'))).decoration) as BoxDecoration?)?.color;
      expect(fill(1), isNotNull);
      expect(fill(30), isNotNull);
      expect(fill(3), isNull);
      // November 2026 starts on a Sunday: the first column.
      final sunday = tester.getTopLeft(find.byKey(const ValueKey('calendar-day-1'))).dx;
      final monday = tester.getTopLeft(find.byKey(const ValueKey('calendar-day-2'))).dx;
      expect(sunday, lessThan(monday));
      expect(tester.getTopLeft(find.byKey(const ValueKey('calendar-day-8'))).dx, sunday);
    });

    testWidgets('the next arrow is off without a month after', (tester) async {
      await pump(tester);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('calendar-next'))).onPressed, isNull);
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('calendar-previous'))).onPressed, isNotNull);
    });
  });
}
