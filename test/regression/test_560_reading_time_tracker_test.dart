import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/reading_time/reading_time_tracker.dart';
import 'package:tsdm_client/instance.dart';

typedef _Credit = ({DateTime day, int fid, String name, int seconds});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => talker = TalkerFlutter.init());

  late DateTime now;
  late List<_Credit> credits;
  late bool enabled;
  late ReadingTimeTracker tracker;

  int total(DateTime day) => credits.where((c) => c.day == day).fold(0, (s, c) => s + c.seconds);
  void advance(Duration d) => now = now.add(d);

  setUp(() {
    now = DateTime(2026, 11, 8, 10);
    credits = [];
    enabled = true;
    tracker = ReadingTimeTracker(
      enabled: () => enabled,
      now: () => now,
      // The timer is not what these tests drive.
      flushEvery: const Duration(days: 1),
      sink: (day, fid, name, seconds) async => credits.add((day: day, fid: fid, name: name, seconds: seconds)),
    );
  });

  tearDown(() => tracker.dispose());

  test('nothing runs before the forum of the thread is known', () {
    expect(tracker.isRunning, isFalse);
    advance(const Duration(minutes: 5));
    tracker.flush();
    expect(credits, isEmpty);
  });

  test('the time of a forum is counted while the page is read', () {
    tracker.setForum(7, 'Forum');
    expect(tracker.isRunning, isTrue);
    advance(const Duration(minutes: 3));
    tracker.touch();
    advance(const Duration(seconds: 20));
    tracker.flush();
    expect(credits.single.fid, 7);
    expect(credits.single.name, 'Forum');
    expect(credits.single.seconds, 200);
    expect(credits.single.day, DateTime(2026, 11, 8));
  });

  test('the app in the background stops the time and the foreground goes on', () {
    tracker.setForum(7, 'Forum');
    advance(const Duration(minutes: 1));
    tracker.setForeground(foreground: false);
    expect(tracker.isRunning, isFalse);
    expect(total(DateTime(2026, 11, 8)), 60);

    advance(const Duration(minutes: 10));
    tracker.setForeground(foreground: true);
    expect(tracker.isRunning, isTrue);
    advance(const Duration(seconds: 30));
    tracker.flush();
    expect(total(DateTime(2026, 11, 8)), 90);
  });

  test('the lifecycle states of the app drive the foreground', () {
    tracker.setForum(7, 'Forum');
    advance(const Duration(seconds: 10));
    tracker.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(tracker.isRunning, isFalse);
    tracker.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(tracker.isRunning, isTrue);
    tracker.didChangeAppLifecycleState(AppLifecycleState.hidden);
    expect(tracker.isRunning, isFalse);
    tracker
      ..didChangeAppLifecycleState(AppLifecycleState.resumed)
      // A desktop window that lost the focus.
      ..didChangeAppLifecycleState(AppLifecycleState.inactive);
    expect(tracker.isRunning, isFalse);
    expect(total(DateTime(2026, 11, 8)), 10);
  });

  test('a page under another page does not count', () {
    tracker.setForum(7, 'Forum');
    advance(const Duration(seconds: 40));
    tracker.setOnTop(onTop: false);
    advance(const Duration(minutes: 5));
    tracker.setOnTop(onTop: true);
    advance(const Duration(seconds: 20));
    tracker.flush();
    expect(total(DateTime(2026, 11, 8)), 60);
  });

  test('a stretch without any touch counts 30 minutes at most', () {
    tracker.setForum(7, 'Forum');
    advance(const Duration(hours: 2));
    tracker.flush();
    expect(total(DateTime(2026, 11, 8)), 30 * 60);
    // Still no touch: nothing more.
    advance(const Duration(hours: 1));
    tracker.flush();
    expect(total(DateTime(2026, 11, 8)), 30 * 60);
  });

  test('the touch after a long pause counts the pause up to the limit only, then the time goes on', () {
    tracker.setForum(7, 'Forum');
    advance(const Duration(hours: 1));
    tracker.touch();
    expect(total(DateTime(2026, 11, 8)), 30 * 60);
    advance(const Duration(seconds: 45));
    tracker.flush();
    expect(total(DateTime(2026, 11, 8)), 30 * 60 + 45);
  });

  test('a touch inside the limit keeps the time running', () {
    tracker.setForum(7, 'Forum');
    for (var i = 0; i < 5; i++) {
      advance(const Duration(minutes: 25));
      tracker.touch();
    }
    tracker.flush();
    expect(total(DateTime(2026, 11, 8)), 125 * 60);
  });

  test('the time across midnight is split by day', () {
    now = DateTime(2026, 11, 8, 23, 59, 30);
    tracker.setForum(7, 'Forum');
    advance(const Duration(seconds: 90));
    tracker
      ..touch()
      ..flush();
    expect(total(DateTime(2026, 11, 8)), 30);
    expect(total(DateTime(2026, 11, 9)), 60);
  });

  test('the setting off counts nothing, on again counts from then', () {
    enabled = false;
    tracker.setForum(7, 'Forum');
    expect(tracker.isRunning, isFalse);
    advance(const Duration(minutes: 5));
    tracker.flush();
    expect(credits, isEmpty);

    enabled = true;
    tracker.setOnTop(onTop: true);
    expect(tracker.isRunning, isTrue);
    advance(const Duration(seconds: 15));
    tracker.flush();
    expect(total(DateTime(2026, 11, 8)), 15);
  });

  test('the time of the forum read before goes to it when the forum changes', () {
    tracker.setForum(7, 'A');
    advance(const Duration(seconds: 30));
    tracker.setForum(8, 'B');
    advance(const Duration(seconds: 20));
    tracker.flush();
    expect(credits.map((c) => (c.fid, c.seconds)), [(7, 30), (8, 20)]);
  });

  test('less than a second is carried to the next hand over', () {
    tracker.setForum(7, 'Forum');
    advance(const Duration(milliseconds: 600));
    tracker.flush();
    expect(credits, isEmpty);
    advance(const Duration(milliseconds: 600));
    tracker.flush();
    expect(credits.single.seconds, 1);
  });

  test('dispose hands over what is left and stops', () {
    tracker.setForum(7, 'Forum');
    advance(const Duration(seconds: 12));
    tracker.dispose();
    expect(total(DateTime(2026, 11, 8)), 12);
    expect(tracker.isRunning, isFalse);
    advance(const Duration(minutes: 1));
    tracker.flush();
    expect(total(DateTime(2026, 11, 8)), 12);
  });

  test('a failing sink does not break the tracker', () {
    final failing = ReadingTimeTracker(
      enabled: () => true,
      now: () => now,
      flushEvery: const Duration(days: 1),
      sink: (day, fid, name, seconds) async => throw StateError('disk full'),
    )..setForum(7, 'Forum');
    advance(const Duration(seconds: 5));
    expect(failing.flush, returnsNormally);
    failing.dispose();
  });
}
