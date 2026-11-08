import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/reading_time/models/reading_time_summary.dart';
import 'package:tsdm_client/features/reading_time/repository/reading_time_repository.dart';
import 'package:tsdm_client/features/reading_time/view/reading_stats_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

ReadingTimeRow _row(int day, int fid, int seconds, [String name = '']) =>
    ReadingTimeRow(day: day, fid: fid, forumName: name.isEmpty ? 'F$fid' : name, seconds: seconds);

void main() {
  setUpAll(() async => LocaleSettings.setLocale(AppLocale.en));

  // Sunday 2026-11-08: the week started on Monday 2026-11-02.
  final now = DateTime(2026, 11, 8, 15);

  group('summary', () {
    test('sums today, this week from Monday and this month', () {
      final summary = ReadingTimeSummary.of([
        _row(20261108, 1, 100),
        _row(20261108, 2, 50),
        _row(20261102, 1, 10),
        _row(20261101, 1, 1000), // Sunday of the week before.
        _row(20261031, 1, 5000), // The month before.
      ], now: now);
      expect(summary.today, 150);
      expect(summary.week, 160);
      expect(summary.month, 1160);
    });

    test('the last 14 days run oldest first and end with today, empty days are zero', () {
      final summary = ReadingTimeSummary.of([
        _row(20261108, 1, 60),
        _row(20261026, 1, 30),
        _row(20261025, 1, 99),
      ], now: now);
      expect(summary.days.length, 14);
      expect(summary.days.first.day, DateTime(2026, 10, 26));
      expect(summary.days.last.day, DateTime(2026, 11, 8));
      expect(summary.days.first.seconds, 30);
      expect(summary.days.last.seconds, 60);
      expect(summary.days[5].seconds, 0);
      expect(summary.total, 90, reason: 'the day before the range is not in it');
    });

    test('the forums are the five read the longest and the rest is summed', () {
      final summary = ReadingTimeSummary.of([
        for (var fid = 1; fid <= 7; fid++) _row(20261108, fid, fid * 10),
        _row(20261107, 7, 5),
      ], now: now);
      expect(summary.forums.map((f) => f.fid), [7, 6, 5, 4, 3, null]);
      expect(summary.forums.first.seconds, 75);
      expect(summary.forums.last.seconds, 30, reason: 'forums 1 and 2');
    });

    test('a forum keeps the name last given and an empty summary says so', () {
      expect(ReadingTimeSummary.of(const [], now: now).isEmpty, isTrue);
      final summary = ReadingTimeSummary.of([_row(20261107, 1, 5, 'Old'), _row(20261108, 1, 5, 'New')], now: now);
      expect(summary.forums.single.forumName, isNotEmpty);
      expect(summary.forums.single.seconds, 10);
    });

    test('rows after today and without time are left out', () {
      final summary = ReadingTimeSummary.of([_row(20261109, 1, 500), _row(20261108, 1, 0)], now: now);
      expect(summary.total, 0);
      expect(summary.month, 0);
    });

    test('the day keys round trip', () {
      expect(readingDayKey(DateTime(2026, 1, 5, 23, 59)), 20260105);
      expect(readingDayOf(20260105), DateTime(2026, 1, 5));
    });
  });

  group('storage', () {
    late AppDatabase db;
    late ReadingTimeStore store;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      store = StorageReadingTimeStore(StorageProvider(db, {}, {}));
    });

    tearDown(() => db.close());

    test('time added again on the same day and forum adds up', () async {
      await store.add(uid: 1, day: DateTime(2026, 11, 8, 9), fid: 7, forumName: 'A', seconds: 30);
      await store.add(uid: 1, day: DateTime(2026, 11, 8, 20), fid: 7, forumName: 'B', seconds: 45);
      await store.add(uid: 1, day: DateTime(2026, 11, 8), fid: 8, forumName: 'C', seconds: 5);
      final rows = await store.fetch(uid: 1, from: DateTime(2026, 11), to: DateTime(2026, 11, 8));
      expect(rows.length, 2);
      final forum7 = rows.singleWhere((r) => r.fid == 7);
      expect((forum7.seconds, forum7.forumName, forum7.day), (75, 'B', 20261108));
    });

    test('accounts and ranges are kept apart', () async {
      await store.add(uid: 1, day: DateTime(2026, 11, 8), fid: 7, forumName: 'A', seconds: 10);
      await store.add(uid: 2, day: DateTime(2026, 11, 8), fid: 7, forumName: 'A', seconds: 20);
      await store.add(uid: 1, day: DateTime(2026, 10), fid: 7, forumName: 'A', seconds: 40);
      final rows = await store.fetch(uid: 1, from: DateTime(2026, 11), to: DateTime(2026, 11, 30));
      expect(rows.single.seconds, 10);
    });

    test('nothing is added for no time and clear forgets every account', () async {
      await store.add(uid: 1, day: DateTime(2026, 11, 8), fid: 7, forumName: 'A', seconds: 0);
      await store.add(uid: 1, day: DateTime(2026, 11, 8), fid: 7, forumName: 'A', seconds: 10);
      await store.add(uid: 2, day: DateTime(2026, 11, 8), fid: 7, forumName: 'A', seconds: 10);
      await store.clear();
      expect(await store.fetch(uid: 1, from: DateTime(2026), to: DateTime(2027)), isEmpty);
      expect(await store.fetch(uid: 2, from: DateTime(2026), to: DateTime(2027)), isEmpty);
    });
  });

  group('page', () {
    Future<void> pump(WidgetTester tester, ReadingTimeStore store, {int? uid = 1}) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: ReadingStatsPage(store: store, now: () => now, uid: uid),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows today, the week, the month, the chart and the forums', (tester) async {
      final store = MemoryReadingTimeStore();
      await store.add(uid: 1, day: DateTime(2026, 11, 8), fid: 7, forumName: 'Anime', seconds: 3725);
      await store.add(uid: 1, day: DateTime(2026, 11, 3), fid: 8, forumName: 'Games', seconds: 600);
      await pump(tester, store);

      expect(find.text('Today'), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(const ValueKey('reading-stats-today')), matching: find.text('1 h 2 min')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: find.byKey(const ValueKey('reading-stats-week')), matching: find.text('1 h 12 min')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('reading-stats-daily-bars')), findsOneWidget);
      expect(find.text('Anime'), findsOneWidget);
      expect(find.text('Games'), findsOneWidget);
    });

    testWidgets('a guest sees zeros and no forums', (tester) async {
      await pump(tester, MemoryReadingTimeStore(), uid: null);
      expect(
        find.descendant(of: find.byKey(const ValueKey('reading-stats-today')), matching: find.text('0 s')),
        findsOneWidget,
      );
      expect(find.text('By forum'), findsNothing);
    });
  });
}
