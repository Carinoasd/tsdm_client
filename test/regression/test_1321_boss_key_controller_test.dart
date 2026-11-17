/// The desktop boss key: off by default and nothing bound; turned on, its combination is bound and each press hides
/// the window or brings it back with the focus, the app lock told before the window goes and before it is seen again.
/// A combination another app holds or the desktop turns down turns the switch back off with a message; a desktop that
/// can bind none makes the switch unavailable. Recording releases the shortcut, a new one is saved only once bound and
/// the old one comes back when it is not.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:system_hotkeys/system_hotkeys.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/boss_key/boss_key_controller.dart';
import 'package:tsdm_client/features/boss_key/models/boss_key_combo.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

const _ctrlAltJ = HotKey(key: PhysicalKeyboardKey.keyJ, modifiers: {HotKeyModifier.control, HotKeyModifier.alt});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  late AppDatabase db;
  late SettingsRepository settings;
  late StreamController<HotKeyEvent> presses;
  late List<String> calls;
  late List<HotKeyResult> results;
  late List<HotKeyResult> reports;
  late bool onScreen;
  late Completer<void>? hiding;
  late bool failHide;
  late bool throwOnRegister;
  final controllers = <BossKey>[];

  BossKey newBossKey() {
    final boss = BossKey.forTesting(
      register: (hotKey) async {
        calls.add('register ${encodeBossKey(hotKey)}');
        if (throwOnRegister) throw PlatformException(code: 'test_failure');
        return results.isEmpty ? HotKeyResult.bound : results.removeAt(0);
      },
      unregister: () async => calls.add('unregister'),
      events: presses.stream,
      windowOnScreen: () async => onScreen,
      hideWindow: () async {
        calls.add('hide');
        await hiding?.future;
        if (failHide) throw PlatformException(code: 'test_failure');
        onScreen = false;
      },
      showWindow: () async {
        calls.add('show');
        onScreen = true;
      },
      onHidden: () => calls.add('lock: hidden'),
      onShown: () => calls.add('lock: shown'),
      report: reports.add,
    );
    controllers.add(boss);
    return boss;
  }

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> press([String id = bossKeyId]) async {
    presses.add(HotKeyEvent(id));
    await settle();
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(StorageProvider(db, {}, {}));
    await settings.init();
    getIt.registerSingleton<SettingsRepository>(settings);
    presses = StreamController<HotKeyEvent>.broadcast();
    calls = [];
    results = [];
    reports = [];
    onScreen = true;
    hiding = null;
    failHide = false;
    throwOnRegister = false;
  });

  tearDown(() async {
    for (final boss in controllers) {
      await boss.dispose();
    }
    controllers.clear();
    await presses.close();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  group('switch', () {
    test('off by default: nothing bound, presses ignored', () async {
      final boss = newBossKey()..start();
      await settle();
      expect(boss.available.value, isTrue);
      expect(boss.bound, isNull);
      await press();
      expect(calls, isEmpty);
    });

    test('turned on, the combination is bound; turned off, released', () async {
      final boss = newBossKey()..start();
      await boss.setEnabled(enable: true);
      expect(settings.currentSettings.bossKey, isTrue);
      expect(boss.bound, defaultBossKey);
      expect(calls, ['register ctrl+alt+h']);
      await boss.setEnabled(enable: false);
      await settle();
      expect(boss.bound, isNull);
      expect(calls, ['register ctrl+alt+h', 'unregister']);
      expect(reports, isEmpty);
    });

    test('held by another app or turned down by the desktop: back off, told why, still available', () async {
      for (final failure in [HotKeyResult.conflict, HotKeyResult.declined]) {
        final boss = newBossKey()..start();
        results = [failure];
        await boss.setEnabled(enable: true);
        await settle();
        expect(settings.currentSettings.bossKey, isFalse, reason: '$failure');
        expect(boss.bound, isNull);
        expect(boss.available.value, isTrue);
        expect(reports, [failure]);
        reports.clear();
        await boss.dispose();
      }
    });

    test('a desktop that can bind none: back off, told, unavailable for the run', () async {
      final boss = newBossKey()..start();
      results = [HotKeyResult.unsupported];
      await boss.setEnabled(enable: true);
      await settle();
      expect(settings.currentSettings.bossKey, isFalse);
      expect(boss.available.value, isFalse);
      expect(reports, [HotKeyResult.unsupported]);
      calls.clear();
      await boss.setEnabled(enable: true);
      expect(calls, isEmpty, reason: 'not tried again');
      expect(settings.currentSettings.bossKey, isFalse);
    });

    test('the platform throwing counts as unable', () async {
      final boss = newBossKey()..start();
      throwOnRegister = true;
      await boss.setEnabled(enable: true);
      await settle();
      expect(boss.available.value, isFalse);
      expect(settings.currentSettings.bossKey, isFalse);
    });

    test('on at startup: bound, or turned off and told when another app took it meanwhile', () async {
      await settings.setValue(SettingsKeys.bossKey, true);
      await settings.setValue(SettingsKeys.bossKeyCombo, 'ctrl+alt+j');
      final boss = newBossKey()..start();
      await settle();
      expect(boss.bound, _ctrlAltJ);
      await boss.dispose();

      results = [HotKeyResult.conflict];
      final again = newBossKey()..start();
      await settle();
      expect(again.bound, isNull);
      expect(settings.currentSettings.bossKey, isFalse);
      expect(reports, [HotKeyResult.conflict]);
    });

    test('a combination changed in the settings (a backup restored) is bound in place of the old one', () async {
      final boss = newBossKey()..start();
      await boss.setEnabled(enable: true);
      await settings.setValue(SettingsKeys.bossKeyCombo, 'ctrl+alt+j');
      await settle();
      expect(boss.bound, _ctrlAltJ);
      expect(calls.last, 'register ctrl+alt+j');
    });
  });

  group('presses', () {
    Future<BossKey> on() async {
      final boss = newBossKey()..start();
      await boss.setEnabled(enable: true);
      calls.clear();
      return boss;
    }

    test('hide the window on the screen, then bring it back; the lock is told first each time', () async {
      final boss = await on();
      await press();
      expect(calls, ['lock: hidden', 'hide']);
      expect(boss.hidden, isTrue);
      await press();
      expect(calls, ['lock: hidden', 'hide', 'lock: shown', 'show']);
      expect(boss.hidden, isFalse);
    });

    test('a window not on the screen (minimized) comes back', () async {
      await on();
      onScreen = false;
      await press();
      expect(calls, ['show'], reason: 'not hidden by the boss key: nothing to tell the lock');
    });

    test('presses of other shortcuts are not the boss key', () async {
      await on();
      await press('somethingElse');
      expect(calls, isEmpty);
    });

    test('a second press waits for the first', () async {
      await on();
      hiding = Completer<void>();
      await press();
      await press();
      expect(calls, ['lock: hidden', 'hide']);
      hiding!.complete();
      await settle();
      expect(calls, ['lock: hidden', 'hide', 'lock: shown', 'show']);
    });

    test('a window that could not be hidden is not counted as away', () async {
      final boss = await on();
      failHide = true;
      await press();
      expect(calls, ['lock: hidden', 'hide', 'lock: shown']);
      expect(boss.hidden, isFalse);
    });

    test('brought back another way (tray, Dock): the lock is told once, on the focus', () async {
      final boss = await on();
      await press();
      boss
        ..onWindowFocus()
        ..onWindowFocus();
      expect(calls, ['lock: hidden', 'hide', 'lock: shown']);
      expect(boss.hidden, isFalse);
    });
  });

  group('recording', () {
    Future<BossKey> on() async {
      final boss = newBossKey()..start();
      await boss.setEnabled(enable: true);
      calls.clear();
      return boss;
    }

    test('releases the shortcut, presses ignored meanwhile; cancelled, the old one comes back', () async {
      final boss = await on();
      await boss.suspend();
      expect(boss.bound, isNull);
      expect(calls, ['unregister']);
      await press();
      expect(calls, ['unregister']);
      await boss.resume();
      expect(boss.bound, defaultBossKey);
      expect(calls, ['unregister', 'register ctrl+alt+h']);
    });

    test('a new combination is saved once bound', () async {
      final boss = await on();
      await boss.suspend();
      await boss.resume(hotKey: _ctrlAltJ);
      await settle();
      expect(boss.bound, _ctrlAltJ);
      expect(settings.currentSettings.bossKeyCombo, 'ctrl+alt+j');
      expect(calls, ['unregister', 'register ctrl+alt+j']);
    });

    test('one another app holds is told, not saved, and the old one is bound again', () async {
      final boss = await on();
      await boss.suspend();
      results = [HotKeyResult.conflict];
      await boss.resume(hotKey: _ctrlAltJ);
      await settle();
      expect(reports, [HotKeyResult.conflict]);
      expect(settings.currentSettings.bossKeyCombo, 'ctrl+alt+h');
      expect(settings.currentSettings.bossKey, isTrue);
      expect(boss.bound, defaultBossKey);
      expect(calls, ['unregister', 'register ctrl+alt+j', 'register ctrl+alt+h']);
    });

    test('while the boss key is off, a new combination is only saved', () async {
      final boss = newBossKey()..start();
      await settle();
      await boss.suspend();
      await boss.resume(hotKey: _ctrlAltJ);
      await settle();
      expect(settings.currentSettings.bossKeyCombo, 'ctrl+alt+j');
      expect(calls, isEmpty);
    });

    test('a combination that can not be the boss key is never saved', () async {
      final boss = newBossKey()..start();
      await settle();
      await boss.suspend();
      await boss.resume(
        hotKey: const HotKey(key: PhysicalKeyboardKey.keyC, modifiers: {HotKeyModifier.control}),
      );
      await settle();
      expect(settings.currentSettings.bossKeyCombo, 'ctrl+alt+h');
    });
  });
}
