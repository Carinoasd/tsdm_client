/// Theme mode "by time" (its own setting beside the theme mode): the app is dark inside a window of the day and light
/// outside it.
///
/// 1. The window: inside, outside, over midnight, the boundaries, an empty one, and the next moment it changes.
/// 2. The theme cubit: the mode it really uses, the timer at the boundary, coming back to the foreground, close.
/// 3. The settings page: the fourth choice of the theme mode, the hours under it, the dialog with the two times.
/// 4. The backup: the hours travel with the exported database.
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/backup_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/settings_page.dart';
import 'package:tsdm_client/features/theme/cubit/theme_cubit.dart';
import 'package:tsdm_client/features/theme/dark_schedule.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';

DateTime _at(int hour, int minute, {int day = 10, int second = 0}) => DateTime(2026, 11, day, hour, minute, second);

// 22:00 to 07:00, the window nothing was set gives.
const _overMidnight = DarkSchedule();
const _sameDay = DarkSchedule(start: 9 * 60, end: 17 * 60);

Translations get tr => LocaleSettings.instance.currentTranslations;

/// No network at all.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

Future<void> _settle(WidgetTester tester, {int rounds = 6}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Close [cubit] inside a widget test: its timer must be gone before the test ends, and awaiting the close of a
/// cubit that had a listener never completes inside the fake async zone of a widget test.
Future<void> _closeIn(WidgetTester tester, ThemeCubit cubit) async {
  unawaited(cubit.close());
  await tester.pump();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('1. the window', () {
    test('the default window, 22:00 to 07:00, runs over midnight', () {
      expect(DarkSchedule.defaultStart, 22 * 60);
      expect(DarkSchedule.defaultEnd, 7 * 60);
      expect(SettingsKeys.darkScheduleStart.defaultValue, DarkSchedule.defaultStart);
      expect(SettingsKeys.darkScheduleEnd.defaultValue, DarkSchedule.defaultEnd);
      expect(_overMidnight.isDark(_at(21, 59)), isFalse);
      expect(_overMidnight.isDark(_at(22, 0)), isTrue, reason: 'the start is inside');
      expect(_overMidnight.isDark(_at(23, 59)), isTrue);
      expect(_overMidnight.isDark(_at(0, 0)), isTrue);
      expect(_overMidnight.isDark(_at(0, 30)), isTrue);
      expect(_overMidnight.isDark(_at(6, 59)), isTrue);
      expect(_overMidnight.isDark(_at(7, 0)), isFalse, reason: 'the end is outside');
      expect(_overMidnight.isDark(_at(15, 0)), isFalse);
    });

    test('a window inside one day', () {
      expect(_sameDay.isDark(_at(8, 59)), isFalse);
      expect(_sameDay.isDark(_at(9, 0)), isTrue);
      expect(_sameDay.isDark(_at(12, 0)), isTrue);
      expect(_sameDay.isDark(_at(16, 59)), isTrue);
      expect(_sameDay.isDark(_at(17, 0)), isFalse);
      expect(_sameDay.isDark(_at(23, 0)), isFalse);
      expect(_sameDay.isDark(_at(0, 0)), isFalse);
    });

    test('seconds do not matter, only the minute', () {
      expect(_overMidnight.isDark(_at(21, 59, second: 59)), isFalse);
      expect(_overMidnight.isDark(_at(22, 0, second: 0)), isTrue);
      expect(_overMidnight.isDark(_at(6, 59, second: 59)), isTrue);
      expect(_overMidnight.isDark(_at(7, 0, second: 0)), isFalse);
    });

    test('the same start and end is an empty window: never dark, never changes', () {
      const empty = DarkSchedule(start: 600, end: 600);
      expect(empty.isDark(_at(3, 0)), isFalse);
      expect(empty.isDark(_at(10, 0)), isFalse);
      expect(empty.isDark(_at(12, 0)), isFalse);
      expect(empty.nextBoundary(_at(12, 0)), isNull);
    });

    test('a time outside the day wraps around', () {
      const wrapped = DarkSchedule(start: 22 * 60 + 24 * 60, end: -17 * 60);
      expect(wrapped, _overMidnight);
      expect(wrapped.isDark(_at(23, 0)), isTrue);
      expect(wrapped.isDark(_at(12, 0)), isFalse);
      expect(DarkSchedule.timeText(25 * 60), '01:00');
      expect(DarkSchedule.timeText(-60), '23:00');
    });

    test('the next boundary: the first start or end after now, today or tomorrow', () {
      expect(_overMidnight.nextBoundary(_at(8, 0)), _at(22, 0));
      expect(_overMidnight.nextBoundary(_at(21, 59, second: 30)), _at(22, 0));
      expect(_overMidnight.nextBoundary(_at(22, 0)), _at(7, 0, day: 11), reason: 'exactly at the start: the end');
      expect(_overMidnight.nextBoundary(_at(23, 30)), _at(7, 0, day: 11));
      expect(_overMidnight.nextBoundary(_at(3, 0)), _at(7, 0));
      expect(_overMidnight.nextBoundary(_at(7, 0)), _at(22, 0), reason: 'exactly at the end: the start');
      expect(_sameDay.nextBoundary(_at(8, 0)), _at(9, 0));
      expect(_sameDay.nextBoundary(_at(12, 0)), _at(17, 0));
      expect(_sameDay.nextBoundary(_at(17, 0)), _at(9, 0, day: 11));
      expect(_sameDay.nextBoundary(_at(23, 0)), _at(9, 0, day: 11));
    });

    test('the next boundary over the end of a month and of a year', () {
      expect(_overMidnight.nextBoundary(DateTime(2026, 11, 30, 23)), DateTime(2026, 12, 1, 7));
      expect(_overMidnight.nextBoundary(DateTime(2026, 12, 31, 23)), DateTime(2027, 1, 1, 7));
    });

    test('times as text', () {
      expect(DarkSchedule.timeText(22 * 60), '22:00');
      expect(DarkSchedule.timeText(7 * 60 + 5), '07:05');
      expect(DarkSchedule.timeText(0), '00:00');
      expect(_overMidnight.text, '22:00–07:00');
      expect(const DarkSchedule(start: 90, end: 1439).text, '01:30–23:59');
    });
  });

  group('2. the theme cubit', () {
    test('by time: dark inside the window, light outside; the other modes are as they are', () async {
      final inside = ThemeCubit(scheduled: true, now: () => _at(23, 0));
      final outside = ThemeCubit(scheduled: true, now: () => _at(12, 0));
      expect(inside.state.scheduled, isTrue);
      expect(inside.state.effectiveThemeMode, ThemeMode.dark);
      expect(outside.state.effectiveThemeMode, ThemeMode.light);
      await inside.close();
      await outside.close();
      for (final mode in ThemeMode.values) {
        // Inside the dark hours, but the clock is not in charge.
        final cubit = ThemeCubit(themeModeIndex: mode.index, now: () => _at(23, 0));
        expect(cubit.state.scheduled, isFalse);
        expect(cubit.state.effectiveThemeMode, mode, reason: mode.name);
        await cubit.close();
      }
    });

    test('an unknown theme mode index falls back to the system', () async {
      final cubit = ThemeCubit(themeModeIndex: 9, now: () => _at(12, 0));
      expect(cubit.state.effectiveThemeMode, ThemeMode.system);
      await cubit.close();
    });

    test('a window of its own', () async {
      final cubit = ThemeCubit(scheduled: true, schedule: _sameDay, now: () => _at(12, 0));
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark);
      expect(cubit.state.schedule, _sameDay);
      await cubit.close();
    });

    testWidgets('handing the theme to the clock and taking it back takes effect at once', (tester) async {
      var now = _at(23, 0);
      final cubit = ThemeCubit(themeModeIndex: 1, now: () => now);
      expect(cubit.state.effectiveThemeMode, ThemeMode.light);
      cubit.setScheduled(scheduled: true);
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark, reason: '23:00 is inside the window');
      cubit.setThemeModeIndex(0);
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark, reason: 'the theme mode is set aside while scheduled');
      expect(cubit.state.themeModeIndex, 0, reason: 'but kept');
      cubit.setScheduled(scheduled: false);
      expect(cubit.state.effectiveThemeMode, ThemeMode.system, reason: 'back to the theme mode kept');
      now = _at(12, 0);
      cubit.setScheduled(scheduled: true);
      expect(cubit.state.effectiveThemeMode, ThemeMode.light, reason: '12:00 is outside');
      await _closeIn(tester, cubit);
    });

    testWidgets('new hours take effect at once', (tester) async {
      var now = _at(12, 0);
      final cubit = ThemeCubit(scheduled: true, now: () => now);
      expect(cubit.state.effectiveThemeMode, ThemeMode.light);
      cubit.setSchedule(const DarkSchedule(start: 11 * 60, end: 17 * 60));
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark);
      cubit.setSchedule(const DarkSchedule(start: 13 * 60, end: 17 * 60));
      expect(cubit.state.effectiveThemeMode, ThemeMode.light);
      now = _at(18, 0);
      cubit.refreshSchedule();
      expect(cubit.state.effectiveThemeMode, ThemeMode.light);
      now = _at(14, 0);
      cubit.refreshSchedule();
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark);
      await _closeIn(tester, cubit);
    });

    testWidgets('the timer switches at the boundary, not before, and over midnight', (tester) async {
      final start = tester.binding.clock.now();
      final base = _at(21, 50);
      DateTime now() => base.add(tester.binding.clock.now().difference(start));
      final cubit = ThemeCubit(scheduled: true, now: now);
      final seen = <ThemeMode>[];
      final sub = cubit.stream.map((s) => s.effectiveThemeMode).listen(seen.add);
      expect(cubit.state.effectiveThemeMode, ThemeMode.light);

      await tester.pump(const Duration(minutes: 9, seconds: 59));
      expect(cubit.state.effectiveThemeMode, ThemeMode.light, reason: 'one second before 22:00');
      await tester.pump(const Duration(seconds: 1));
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark, reason: '22:00');

      await tester.pump(const Duration(hours: 1, minutes: 59, seconds: 59));
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark, reason: '23:59:59');
      await tester.pump(const Duration(seconds: 1));
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark, reason: '00:00, the window runs over midnight');
      await tester.pump(const Duration(hours: 6, minutes: 59, seconds: 59));
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark, reason: '06:59:59');
      await tester.pump(const Duration(seconds: 1));
      expect(cubit.state.effectiveThemeMode, ThemeMode.light, reason: '07:00');
      expect(seen, [ThemeMode.dark, ThemeMode.light], reason: 'one change per boundary, no tick');

      await tester.pump(const Duration(hours: 15));
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark, reason: '22:00 the next day');

      unawaited(sub.cancel());
      await _closeIn(tester, cubit);
    });

    testWidgets('new hours move the timer', (tester) async {
      final start = tester.binding.clock.now();
      final base = _at(12, 0);
      DateTime now() => base.add(tester.binding.clock.now().difference(start));
      final cubit = ThemeCubit(scheduled: true, now: now)
        ..setSchedule(const DarkSchedule(start: 14 * 60, end: 15 * 60));
      await tester.pump(const Duration(hours: 2));
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark, reason: '14:00');
      await tester.pump(const Duration(hours: 1));
      expect(cubit.state.effectiveThemeMode, ThemeMode.light, reason: '15:00');
      await _closeIn(tester, cubit);
    });

    testWidgets('a clock that jumps, as after a sleep, is caught up with within 15 minutes', (tester) async {
      final start = tester.binding.clock.now();
      var jump = Duration.zero;
      DateTime now() => _at(20, 0).add(tester.binding.clock.now().difference(start)).add(jump);
      final cubit = ThemeCubit(scheduled: true, now: now);
      final seen = <ThemeMode>[];
      final sub = cubit.stream.map((s) => s.effectiveThemeMode).listen(seen.add);
      expect(cubit.state.effectiveThemeMode, ThemeMode.light);
      await tester.pump(const Duration(minutes: 20));
      expect(seen, isEmpty, reason: 'waking up between boundaries changes nothing');
      // The device slept from 20:20 to 23:20: the timer did not run, the clock moved on.
      jump = const Duration(hours: 3);
      await tester.pump(ThemeCubit.maxTimerWait);
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark);
      expect(seen, [ThemeMode.dark]);
      unawaited(sub.cancel());
      await _closeIn(tester, cubit);
    });

    testWidgets('no change comes from the clock while another mode is on, or after close', (tester) async {
      final start = tester.binding.clock.now();
      final base = _at(21, 50);
      DateTime now() => base.add(tester.binding.clock.now().difference(start));
      final light = ThemeCubit(themeModeIndex: 1, now: now);
      final seen = <ThemeState>[];
      final sub = light.stream.listen(seen.add);
      await tester.pump(const Duration(days: 2));
      expect(seen, isEmpty);
      expect(light.state.effectiveThemeMode, ThemeMode.light);
      unawaited(sub.cancel());
      await _closeIn(tester, light);

      final closed = ThemeCubit(scheduled: true, now: now);
      expect(closed.state.effectiveThemeMode, ThemeMode.light);
      await _closeIn(tester, closed);
      await tester.pump(const Duration(days: 2));
      expect(closed.state.effectiveThemeMode, ThemeMode.light, reason: 'the timer is cancelled');
    });

    testWidgets('leaving by time cancels the timer', (tester) async {
      final start = tester.binding.clock.now();
      final base = _at(21, 50);
      DateTime now() => base.add(tester.binding.clock.now().difference(start));
      final cubit = ThemeCubit(themeModeIndex: 1, scheduled: true, now: now)..setScheduled(scheduled: false);
      final seen = <ThemeState>[];
      final sub = cubit.stream.listen(seen.add);
      await tester.pump(const Duration(days: 1));
      expect(seen, isEmpty);
      expect(cubit.state.effectiveThemeMode, ThemeMode.light);
      unawaited(sub.cancel());
      await _closeIn(tester, cubit);
    });

    testWidgets('coming back to the foreground works the time out again', (tester) async {
      var now = _at(12, 0);
      final cubit = ThemeCubit(scheduled: true, now: () => now)..observeLifecycle();
      expect(cubit.state.effectiveThemeMode, ThemeMode.light);
      now = _at(23, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(cubit.state.effectiveThemeMode, ThemeMode.light, reason: 'not while it sleeps');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark);
      now = _at(7, 0, day: 11);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(cubit.state.effectiveThemeMode, ThemeMode.light);
      await _closeIn(tester, cubit);
      now = _at(23, 0, day: 11);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(cubit.state.effectiveThemeMode, ThemeMode.light, reason: 'a closed cubit no longer follows');
    });

    testWidgets('coming back to the foreground changes nothing while another mode is on', (tester) async {
      var now = _at(12, 0);
      final cubit = ThemeCubit(themeModeIndex: 2, now: () => now)..observeLifecycle();
      now = _at(23, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(cubit.state.effectiveThemeMode, ThemeMode.dark);
      expect(cubit.state.themeModeIndex, 2);
      await _closeIn(tester, cubit);
    });
  });

  group('3. the settings page', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;
    late ThemeCubit theme;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<AppDatabase>(db)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      // Made here, outside the fake async zone of the widget tests: a bloc made inside it never finishes closing.
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      // The clock says 12:00, outside the default window.
      theme = ThemeCubit(now: () => _at(12, 0));
    });

    tearDown(() async {
      await settingsBloc.close();
      if (!theme.isClosed) {
        await theme.close();
      }
      await getIt.reset();
      await db.close();
    });

    Future<void> pumpSettings(WidgetTester tester, {double width = 420}) async {
      tester.view.physicalSize = Size(width, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<SettingsBloc>.value(value: settingsBloc),
            BlocProvider<ThemeCubit>.value(value: theme),
          ],
          child: TranslationProvider(child: const MaterialApp(home: SettingsPage())),
        ),
      );
      await _settle(tester, rounds: 3);
    }

    /// The end of a test: the cubit arms a timer while the clock is in charge, it must be gone before the test ends.
    Future<void> finish(WidgetTester tester) => _closeIn(tester, theme);

    final tile = find.byKey(const ValueKey('settings-dark-schedule'));
    final startRow = find.byKey(const ValueKey('dark-schedule-start'));
    final endRow = find.byKey(const ValueKey('dark-schedule-end'));
    final switcher = find.byType(SegmentedButton<int>);

    SegmentedButton<int> themeSwitch(WidgetTester tester) => tester.widget<SegmentedButton<int>>(switcher);

    Future<void> chooseMode(WidgetTester tester, IconData icon) async {
      await tester.tap(find.descendant(of: switcher, matching: find.byIcon(icon)));
      await _settle(tester, rounds: 3);
    }

    /// Set [hour]:[minute] in the time picker open now with its keyboard input.
    Future<void> enterTime(WidgetTester tester, int hour, int minute) async {
      await tester.tap(find.byIcon(Icons.keyboard_outlined));
      await _settle(tester, rounds: 2);
      final fields = find.descendant(of: find.byType(TimePickerDialog), matching: find.byType(TextField));
      expect(fields, findsNWidgets(2));
      await tester.enterText(fields.at(0), '$hour');
      await tester.enterText(fields.at(1), '$minute');
      await tester.tap(find.descendant(of: find.byType(TimePickerDialog), matching: find.text('OK')));
      await _settle(tester);
    }

    testWidgets('the theme mode has four choices, by time the last; no hours row until it is chosen', (tester) async {
      await pumpSettings(tester);
      expect(themeSwitch(tester).segments.map((s) => s.value), [1, 0, 2, 3]);
      expect(themeSwitch(tester).segments.last.tooltip, tr.settingsPage.appearanceSection.themeMode.scheduled);
      expect(themeSwitch(tester).selected, {0});
      expect(tile, findsNothing);
      expect(tester.getRect(switcher).right, lessThanOrEqualTo(420), reason: 'inside the window');
      await finish(tester);
    });

    testWidgets('by time: saved, applied at once, the hours row under the theme mode with 22:00–07:00', (
      tester,
    ) async {
      await pumpSettings(tester);
      await chooseMode(tester, Icons.schedule_outlined);
      expect(settings.currentSettings.themeModeScheduled, isTrue);
      expect(settings.currentSettings.themeMode, 0, reason: 'its own setting, the theme mode stays what it was');
      expect(theme.state.scheduled, isTrue);
      expect(theme.state.themeModeIndex, 0);
      expect(theme.state.effectiveThemeMode, ThemeMode.light, reason: '12:00 is outside the window');
      expect(themeSwitch(tester).selected, {3});
      expect(
        find.text(tr.settingsPage.appearanceSection.themeMode.scheduled),
        findsOneWidget,
        reason: 'the subtitle of the theme mode',
      );
      expect(tile, findsOneWidget);
      expect(
        find.descendant(of: tile, matching: find.text(tr.settingsPage.appearanceSection.darkSchedule.title)),
        findsOneWidget,
      );
      expect(find.descendant(of: tile, matching: find.text('22:00–07:00')), findsOneWidget);
      final themeTitle = tester.getRect(find.text(tr.settingsPage.appearanceSection.themeMode.title));
      expect(tester.getRect(tile).top, greaterThan(themeTitle.bottom), reason: 'right under the theme mode');
      expect(tester.takeException(), isNull);

      await chooseMode(tester, Icons.light_mode_outlined);
      expect(settings.currentSettings.themeMode, 1);
      expect(settings.currentSettings.themeModeScheduled, isFalse);
      expect(theme.state.scheduled, isFalse);
      expect(theme.state.effectiveThemeMode, ThemeMode.light);
      expect(themeSwitch(tester).selected, {1});
      expect(tile, findsNothing, reason: 'the hours row goes with the mode');
      await finish(tester);
    });

    testWidgets('the hours dialog: two rows with the times, each picked with a time picker, saved on OK', (
      tester,
    ) async {
      await pumpSettings(tester);
      await chooseMode(tester, Icons.schedule_outlined);
      await tester.tap(tile);
      await _settle(tester, rounds: 3);
      final dark = tr.settingsPage.appearanceSection.darkSchedule;
      expect(find.descendant(of: find.byType(AlertDialog), matching: find.text(dark.title)), findsOneWidget);
      expect(find.descendant(of: startRow, matching: find.text(dark.start)), findsOneWidget);
      expect(find.descendant(of: startRow, matching: find.text('22:00')), findsOneWidget);
      expect(find.descendant(of: endRow, matching: find.text(dark.end)), findsOneWidget);
      expect(find.descendant(of: endRow, matching: find.text('07:00')), findsOneWidget);
      expect(
        find.descendant(of: find.byType(AlertDialog), matching: find.byType(Text)).evaluate().length,
        7,
        reason: 'title, two labels, two times and the two buttons, nothing else',
      );

      await tester.tap(startRow);
      await _settle(tester, rounds: 3);
      expect(find.byType(TimePickerDialog), findsOneWidget);
      await enterTime(tester, 21, 30);
      expect(find.byType(TimePickerDialog), findsNothing);
      expect(find.descendant(of: startRow, matching: find.text('21:30')), findsOneWidget);
      expect(settings.currentSettings.darkScheduleStart, DarkSchedule.defaultStart, reason: 'not saved before OK');

      await tester.tap(endRow);
      await _settle(tester, rounds: 3);
      await enterTime(tester, 5, 45);
      expect(find.descendant(of: endRow, matching: find.text('05:45')), findsOneWidget);

      await tester.tap(find.text(tr.general.ok));
      await _settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(settings.currentSettings.darkScheduleStart, 21 * 60 + 30);
      expect(settings.currentSettings.darkScheduleEnd, 5 * 60 + 45);
      expect(theme.state.schedule, const DarkSchedule(start: 21 * 60 + 30, end: 5 * 60 + 45));
      expect(find.descendant(of: tile, matching: find.text('21:30–05:45')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await finish(tester);
    });

    testWidgets('cancel keeps the hours', (tester) async {
      await pumpSettings(tester);
      await chooseMode(tester, Icons.schedule_outlined);
      await tester.tap(tile);
      await _settle(tester, rounds: 3);
      await tester.tap(startRow);
      await _settle(tester, rounds: 3);
      await enterTime(tester, 20, 0);
      expect(find.descendant(of: startRow, matching: find.text('20:00')), findsOneWidget);
      await tester.tap(find.text(tr.general.cancel));
      await _settle(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(settings.currentSettings.darkScheduleStart, DarkSchedule.defaultStart);
      expect(theme.state.schedule, _overMidnight);
      expect(find.descendant(of: tile, matching: find.text('22:00–07:00')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('the same start and end cannot be saved', (tester) async {
      await pumpSettings(tester);
      await chooseMode(tester, Icons.schedule_outlined);
      await tester.tap(tile);
      await _settle(tester, rounds: 3);
      FilledButton ok() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, tr.general.ok));
      expect(ok().onPressed, isNotNull);
      await tester.tap(endRow);
      await _settle(tester, rounds: 3);
      await enterTime(tester, 22, 0);
      expect(find.descendant(of: endRow, matching: find.text('22:00')), findsOneWidget);
      expect(ok().onPressed, isNull, reason: 'an empty window');
      await tester.tap(endRow);
      await _settle(tester, rounds: 3);
      await enterTime(tester, 22, 1);
      expect(ok().onPressed, isNotNull);
      await tester.tap(find.text(tr.general.ok));
      await _settle(tester);
      expect(settings.currentSettings.darkScheduleEnd, 22 * 60 + 1);
      await finish(tester);
    });

    testWidgets('new hours covering now switch the theme at once', (tester) async {
      await pumpSettings(tester);
      await chooseMode(tester, Icons.schedule_outlined);
      expect(theme.state.effectiveThemeMode, ThemeMode.light);
      await tester.tap(tile);
      await _settle(tester, rounds: 3);
      await tester.tap(startRow);
      await _settle(tester, rounds: 3);
      await enterTime(tester, 11, 0);
      await tester.tap(endRow);
      await _settle(tester, rounds: 3);
      await enterTime(tester, 13, 0);
      await tester.tap(find.text(tr.general.ok));
      await _settle(tester);
      expect(theme.state.effectiveThemeMode, ThemeMode.dark, reason: '12:00 is inside 11:00–13:00');
      await finish(tester);
    });

    testWidgets('the saved choice is read back', (tester) async {
      // The database works in real time: outside the fake async zone.
      await tester.runAsync(() async {
        await settings.setValue(SettingsKeys.themeMode, 2);
        await settings.setValue(SettingsKeys.themeModeScheduled, true);
        await settings.setValues<int>([
          (SettingsKeys.darkScheduleStart, 23 * 60),
          (SettingsKeys.darkScheduleEnd, 8 * 60 + 5),
        ]);
      });
      await pumpSettings(tester);
      expect(themeSwitch(tester).selected, {3});
      expect(find.text(tr.settingsPage.appearanceSection.themeMode.scheduled), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.text('23:00–08:05')), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a narrow phone: the four segments stay inside the window', (tester) async {
      await pumpSettings(tester, width: 320);
      final title = tester.getRect(find.text(tr.settingsPage.appearanceSection.themeMode.title));
      final rect = tester.getRect(switcher);
      expect(rect.right, lessThanOrEqualTo(320));
      expect(rect.left >= title.right || rect.top >= title.bottom, isTrue, reason: 'beside or below, never over');
      expect(tester.takeException(), isNull);
      await finish(tester);
    });
  });

  group('4. the backup', () {
    test('the theme mode and the hours travel with the exported database', () async {
      final dir = Directory.systemTemp.createTempSync('tsdm_dark_schedule');
      addTearDown(() => dir.deleteSync(recursive: true));
      final dbFile = File('${dir.path}/mainV2.db');
      final db = AppDatabase(NativeDatabase(dbFile));
      final settings = SettingsRepository(StorageProvider(db, {}, {}));
      await settings.init();
      await settings.setValue(SettingsKeys.themeMode, 2);
      await settings.setValue(SettingsKeys.themeModeScheduled, true);
      await settings.setValues<int>([
        (SettingsKeys.darkScheduleStart, 21 * 60),
        (SettingsKeys.darkScheduleEnd, 6 * 60),
      ]);
      final bytes = await const BackupRepository().exportSanitized(dbFile);
      await db.close();

      final restoredFile = File('${dir.path}/restored.db')..writeAsBytesSync(bytes);
      final restored = AppDatabase(NativeDatabase(restoredFile));
      final restoredSettings = SettingsRepository(StorageProvider(restored, {}, {}));
      await restoredSettings.init();
      expect(restoredSettings.currentSettings.themeModeScheduled, isTrue);
      expect(restoredSettings.currentSettings.themeMode, 2);
      expect(
        restoredSettings.currentSettings.themeMode,
        inInclusiveRange(0, ThemeMode.values.length - 1),
        reason: 'an older version restoring this backup indexes ThemeMode.values with it',
      );
      expect(restoredSettings.currentSettings.darkScheduleStart, 21 * 60);
      expect(restoredSettings.currentSettings.darkScheduleEnd, 6 * 60);
      await restored.close();
    });

    test('a backup from an older version has no hours: the defaults', () async {
      final db = AppDatabase(NativeDatabase.memory());
      final settings = SettingsRepository(StorageProvider(db, {}, {}));
      await settings.init();
      expect(settings.currentSettings.themeMode, 0);
      expect(settings.currentSettings.themeModeScheduled, isFalse);
      expect(settings.currentSettings.darkScheduleStart, DarkSchedule.defaultStart);
      expect(settings.currentSettings.darkScheduleEnd, DarkSchedule.defaultEnd);
      await db.close();
    });
  });
}
