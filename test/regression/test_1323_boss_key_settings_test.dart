/// The boss key in the window settings: a switch, unavailable where the desktop can bind no shortcut, and the
/// combination, recorded from the keys pressed. The recorder takes two modifiers or more and a key every platform can
/// bind, says why another combination can not be used, and keeps Esc, Tab, Enter and Space for the dialog.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:system_hotkeys/system_hotkeys.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/boss_key/boss_key_controller.dart';
import 'package:tsdm_client/features/boss_key/models/boss_key_combo.dart';
import 'package:tsdm_client/features/boss_key/widgets/boss_key_tiles.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';

/// The recorder names the keys as on Windows.
final _windows = TargetPlatformVariant.only(TargetPlatform.windows);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  late AppDatabase db;
  late SettingsRepository settings;
  late List<String> calls;
  late HotKeyResult result;

  BossKey newBossKey({Stream<Map<String, String>> triggers = const Stream.empty(), bool configuredByDesktop = false}) =>
      BossKey.forTesting(
        register: (hotKey) async {
          calls.add('register ${encodeBossKey(hotKey)}');
          return result;
        },
        unregister: () async => calls.add('unregister'),
        events: const Stream.empty(),
        windowOnScreen: () async => true,
        hideWindow: () async {},
        showWindow: () async {},
        onHidden: () {},
        onShown: () {},
        report: (_) {},
        triggers: triggers,
        configuredByDesktop: configuredByDesktop,
      );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(StorageProvider(db, {}, {}));
    await settings.init();
    getIt.registerSingleton<SettingsRepository>(settings);
    await LocaleSettings.setLocale(AppLocale.en);
    calls = [];
    result = HotKeyResult.bound;
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Widget app(Widget child) => TranslationProvider(
    child: MaterialApp(home: Scaffold(body: child)),
  );

  group('recorder', () {
    late HotKey? recorded;
    late bool closed;

    Future<void> open(WidgetTester tester, {HotKey current = defaultBossKey}) async {
      closed = false;
      recorded = null;
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                recorded = await showBossKeyRecorder(context, current);
                closed = true;
              },
              child: const Text('record'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('record'));
      await tester.pumpAndSettle();
    }

    Future<void> pressCombo(WidgetTester tester, List<LogicalKeyboardKey> modifiers, LogicalKeyboardKey key) async {
      for (final m in modifiers) {
        await tester.sendKeyDownEvent(m);
      }
      await tester.sendKeyEvent(key);
      for (final m in modifiers.reversed) {
        await tester.sendKeyUpEvent(m);
      }
      await tester.pump();
    }

    TextButton button(WidgetTester tester, String label) =>
        tester.widget<TextButton>(find.widgetWithText(TextButton, label));

    testWidgets('shows the combination in use, saves the one pressed', (tester) async {
      await open(tester);
      expect(find.text('Ctrl'), findsOneWidget);
      expect(find.text('Alt'), findsOneWidget);
      expect(find.text('H'), findsOneWidget);
      await pressCombo(tester, [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft], LogicalKeyboardKey.keyJ);
      expect(find.text('Shift'), findsOneWidget);
      expect(find.text('J'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(
        recorded,
        const HotKey(key: PhysicalKeyboardKey.keyJ, modifiers: {HotKeyModifier.control, HotKeyModifier.shift}),
      );
    }, variant: _windows);

    testWidgets('a single modifier is not enough', (tester) async {
      await open(tester);
      await pressCombo(tester, [LogicalKeyboardKey.controlLeft], LogicalKeyboardKey.keyH);
      expect(find.text('Hold two modifier keys or more, one of them Ctrl or Win'), findsOneWidget);
      expect(button(tester, 'OK').onPressed, isNull);
    }, variant: _windows);

    testWidgets("one of the app's shortcuts can not be used", (tester) async {
      await open(tester);
      await pressCombo(tester, [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft], LogicalKeyboardKey.keyC);
      expect(find.text('Already a shortcut of the app'), findsOneWidget);
      expect(button(tester, 'OK').onPressed, isNull);
      // Another combination pressed after it can.
      await pressCombo(tester, [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.altLeft], LogicalKeyboardKey.keyB);
      expect(find.text('Already a shortcut of the app'), findsNothing);
      expect(button(tester, 'OK').onPressed, isNotNull);
    }, variant: _windows);

    testWidgets('a key no platform can bind says which keys can', (tester) async {
      await open(tester);
      await pressCombo(tester, [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.altLeft], LogicalKeyboardKey.enter);
      expect(find.text('Use a letter, a digit, F1–F12 or Space'), findsOneWidget);
      expect(closed, isFalse, reason: 'Enter with modifiers is recorded, not pressing a button');
      expect(button(tester, 'OK').onPressed, isNull);
    }, variant: _windows);

    testWidgets('reset brings the default back', (tester) async {
      await open(
        tester,
        current: const HotKey(key: PhysicalKeyboardKey.keyJ, modifiers: {HotKeyModifier.control, HotKeyModifier.alt}),
      );
      await tester.tap(find.text('Reset to default'));
      await tester.pump();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(recorded, defaultBossKey);
    }, variant: _windows);

    testWidgets('Esc closes without saving', (tester) async {
      await open(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      expect(recorded, isNull);
    }, variant: _windows);
  });

  group('tiles', () {
    // The controller and the settings database run on real time: started, driven and disposed in `runAsync`.
    Future<BossKey> started(WidgetTester tester, {Stream<Map<String, String>>? triggers}) async {
      // Made there too: its futures belong to the zone it was made in.
      late final BossKey boss;
      await tester.runAsync(
        () async => boss = newBossKey(
          triggers: triggers ?? const Stream.empty(),
          configuredByDesktop: triggers != null,
        )..start(),
      );
      return boss;
    }

    testWidgets('the switch turns the boss key on', (tester) async {
      final boss = await started(tester);
      await tester.pumpWidget(app(BossKeySwitchTile(enabled: false, controller: boss)));
      final tile = tester.widget<SectionSwitchListTile>(find.byType(SectionSwitchListTile));
      expect(tile.onChanged, isNotNull);
      await tester.runAsync(() async {
        tile.onChanged!(true);
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
      expect(settings.currentSettings.bossKey, isTrue);
      expect(calls, ['register ctrl+alt+h']);
      await tester.runAsync(boss.dispose);
    });

    testWidgets('unavailable: both tiles are disabled', (tester) async {
      final boss = await started(tester);
      result = HotKeyResult.unsupported;
      await tester.runAsync(() => boss.setEnabled(enable: true));
      await tester.pumpWidget(
        app(
          Column(
            children: [
              BossKeySwitchTile(enabled: true, controller: boss),
              BossKeyShortcutTile(combo: 'ctrl+alt+h', controller: boss),
            ],
          ),
        ),
      );
      expect(boss.available.value, isFalse);
      final tile = tester.widget<SectionSwitchListTile>(find.byType(SectionSwitchListTile));
      expect(tile.value, isFalse);
      expect(tile.onChanged, isNull);
      expect(tester.widget<SectionListTile>(find.widgetWithText(SectionListTile, 'Shortcut')).enabled, isFalse);
      await tester.runAsync(boss.dispose);
    });

    testWidgets('the shortcut tile shows the keys in use', (tester) async {
      final boss = await started(tester);
      await tester.pumpWidget(app(BossKeyShortcutTile(combo: 'ctrl+shift+meta+f9', controller: boss)));
      for (final label in ['Ctrl', 'Shift', 'Win', 'F9']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(tester.widget<SectionListTile>(find.widgetWithText(SectionListTile, 'Shortcut')).enabled, isTrue);
      await tester.runAsync(boss.dispose);
    }, variant: _windows);

    testWidgets('where the desktop decides the keys, the ones it bound are shown', (tester) async {
      final triggers = StreamController<Map<String, String>>.broadcast();
      final boss = await started(tester, triggers: triggers.stream);
      await tester.runAsync(() => boss.setEnabled(enable: true));
      await tester.pumpWidget(app(BossKeyShortcutTile(combo: 'ctrl+alt+h', controller: boss)));
      expect(find.text('H'), findsOneWidget, reason: 'nothing reported yet: the suggestion');
      await tester.runAsync(() async {
        triggers.add({bossKeyId: 'Ctrl+Alt+K'});
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      expect(find.text('K'), findsOneWidget);
      expect(find.text('H'), findsNothing);
      await tester.runAsync(() async {
        triggers.add({bossKeyId: ''});
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      expect(find.text('—'), findsOneWidget, reason: 'bound without keys yet');
      await tester.runAsync(() async {
        await boss.dispose();
        await triggers.close();
      });
    });
  });
}
