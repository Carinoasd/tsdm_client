/// The combination of the desktop boss key: stored as a short name (`ctrl+alt+h`), Ctrl+Alt+H by default, recorded
/// only with two modifiers or more (one of them Ctrl or Win/Cmd), on a key every platform can bind, and never one of
/// the app's own shortcuts.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:system_hotkeys/system_hotkeys.dart';
import 'package:tsdm_client/features/boss_key/models/boss_key_combo.dart';
import 'package:tsdm_client/shared/models/models.dart';

const HotKeyModifier _control = HotKeyModifier.control;
const HotKeyModifier _alt = HotKeyModifier.alt;
const HotKeyModifier _shift = HotKeyModifier.shift;
const HotKeyModifier _meta = HotKeyModifier.meta;

HotKey _key(PhysicalKeyboardKey key, Set<HotKeyModifier> modifiers) => HotKey(key: key, modifiers: modifiers);

void main() {
  group('settings', () {
    test('off by default, Ctrl+Alt+H stored by name', () {
      expect(SettingsKeys.bossKey.defaultValue, isFalse);
      expect(SettingsKeys.bossKeyCombo.defaultValue, 'ctrl+alt+h');
      expect(encodeBossKey(defaultBossKey), SettingsKeys.bossKeyCombo.defaultValue);
      expect(bossKeyOf(SettingsKeys.bossKeyCombo.defaultValue), defaultBossKey);
      expect(bossKeyProblem(defaultBossKey), isNull);
    });

    test('every key and every set of modifiers comes back as it was stored', () {
      final modifierSets = [
        for (var bits = 0; bits < 16; bits++)
          {
            for (final m in HotKeyModifier.values)
              if (bits & (1 << m.index) != 0) m,
          },
      ];
      for (final usage in HotKey.supportedUsages) {
        for (final modifiers in modifierSets) {
          final hotKey = _key(PhysicalKeyboardKey(usage), modifiers);
          final stored = encodeBossKey(hotKey);
          expect(stored, isNotNull, reason: '$hotKey');
          expect(decodeBossKey(stored!), hotKey, reason: stored);
        }
      }
      expect(encodeBossKey(_key(PhysicalKeyboardKey.keyQ, {_meta, _shift})), 'shift+meta+q');
      expect(encodeBossKey(_key(PhysicalKeyboardKey.f12, {_control, _alt})), 'ctrl+alt+f12');
      expect(encodeBossKey(_key(PhysicalKeyboardKey.space, {_control, _alt})), 'ctrl+alt+space');
      expect(encodeBossKey(_key(PhysicalKeyboardKey.digit0, {_control, _alt})), 'ctrl+alt+0');
      expect(encodeBossKey(_key(PhysicalKeyboardKey.enter, {_control, _alt})), isNull);
    });

    test('anything else stored falls back to the default', () {
      for (final junk in ['', 'ctrl+alt', 'ctrl+ctrl+h', 'hyper+alt+h', 'ctrl+alt+enter', 'ctrl+alt+H', '+h']) {
        expect(decodeBossKey(junk), isNull, reason: junk);
        expect(bossKeyOf(junk), defaultBossKey, reason: junk);
      }
      // Combinations a hand or a later version might store that this one does not accept.
      for (final invalid in ['h', 'ctrl+h', 'shift+alt+h']) {
        expect(decodeBossKey(invalid), isNotNull, reason: invalid);
        expect(bossKeyOf(invalid), defaultBossKey, reason: invalid);
      }
      expect(bossKeyOf('ctrl+shift+c'), defaultBossKey);
      expect(bossKeyOf('ctrl+shift+meta+j'), _key(PhysicalKeyboardKey.keyJ, {_control, _shift, _meta}));
    });
  });

  group('what can be the boss key', () {
    test('a single key, Shift or Option with a key, one modifier: not enough', () {
      for (final modifiers in [
        <HotKeyModifier>{},
        {_shift},
        {_alt},
        {_control},
        {_meta},
        {_alt, _shift},
      ]) {
        expect(
          bossKeyProblem(_key(PhysicalKeyboardKey.keyH, modifiers)),
          BossKeyProblem.needsModifiers,
          reason: '$modifiers',
        );
      }
      expect(bossKeyProblem(_key(PhysicalKeyboardKey.f4, {_alt})), BossKeyProblem.needsModifiers, reason: 'Alt+F4');
      expect(bossKeyProblem(_key(PhysicalKeyboardKey.keyQ, {_meta})), BossKeyProblem.needsModifiers, reason: 'Cmd+Q');
      expect(bossKeyProblem(_key(PhysicalKeyboardKey.keyH, {_control, _shift})), isNull);
      expect(bossKeyProblem(_key(PhysicalKeyboardKey.keyH, {_meta, _alt})), isNull);
      expect(bossKeyProblem(_key(PhysicalKeyboardKey.f9, {_control, _alt, _shift, _meta})), isNull);
    });

    test('letters, digits, F1 to F12 and the space bar only', () {
      for (final key in [
        PhysicalKeyboardKey.enter,
        PhysicalKeyboardKey.escape,
        PhysicalKeyboardKey.tab,
        PhysicalKeyboardKey.arrowUp,
        PhysicalKeyboardKey.comma,
        PhysicalKeyboardKey.f13,
        PhysicalKeyboardKey.numpad1,
        PhysicalKeyboardKey.delete,
      ]) {
        expect(bossKeyProblem(_key(key, {_control, _alt})), BossKeyProblem.unsupportedKey, reason: '$key');
      }
      for (final key in [
        PhysicalKeyboardKey.keyA,
        PhysicalKeyboardKey.keyZ,
        PhysicalKeyboardKey.digit1,
        PhysicalKeyboardKey.digit0,
        PhysicalKeyboardKey.f1,
        PhysicalKeyboardKey.f12,
        PhysicalKeyboardKey.space,
      ]) {
        expect(bossKeyProblem(_key(key, {_control, _alt})), isNull, reason: '$key');
      }
    });

    test("the app's own shortcuts are taken from the list of shortcuts, Ctrl and Cmd alike", () {
      // Ctrl/Cmd+Shift+C copies the link of a thread.
      expect(bossKeyProblem(_key(PhysicalKeyboardKey.keyC, {_control, _shift})), BossKeyProblem.usedInApp);
      expect(bossKeyProblem(_key(PhysicalKeyboardKey.keyC, {_meta, _shift})), BossKeyProblem.usedInApp);
      expect(bossKeyProblem(_key(PhysicalKeyboardKey.keyC, {_control, _alt})), isNull);
      expect(bossKeyProblem(_key(PhysicalKeyboardKey.keyC, {_control, _meta, _shift})), isNull);
      expect(
        inAppHotKeys,
        containsAll([
          _key(PhysicalKeyboardKey.keyF, {_control}),
          _key(PhysicalKeyboardKey.keyF, {_meta}),
          _key(PhysicalKeyboardKey.keyK, {_control}),
          _key(PhysicalKeyboardKey.keyR, {_meta}),
          _key(PhysicalKeyboardKey.keyW, {_control}),
          _key(PhysicalKeyboardKey.f5, {}),
          _key(PhysicalKeyboardKey.keyJ, {}),
          for (final digit in [
            PhysicalKeyboardKey.digit1,
            PhysicalKeyboardKey.digit5,
            PhysicalKeyboardKey.digit9,
          ]) ...[
            _key(digit, {_control}),
            _key(digit, {_meta}),
          ],
        ]),
      );
      expect(inAppHotKeys, isNot(contains(_key(PhysicalKeyboardKey.digit0, {_control}))), reason: '1 to 9 only');
      expect(inAppHotKeys, isNot(contains(_key(PhysicalKeyboardKey.keyF, {_control, _meta}))));
    });
  });

  test('the keys are named as on the keyboard of each platform', () {
    final hotKey = _key(PhysicalKeyboardKey.keyH, {_meta, _alt, _control, _shift});
    expect(bossKeyLabels(hotKey, TargetPlatform.windows), ['Ctrl', 'Alt', 'Shift', 'Win', 'H']);
    expect(bossKeyLabels(hotKey, TargetPlatform.macOS), ['Ctrl', 'Option', 'Shift', 'Cmd', 'H']);
    expect(bossKeyLabels(hotKey, TargetPlatform.linux), ['Ctrl', 'Alt', 'Shift', 'Super', 'H']);
    expect(bossKeyLabels(defaultBossKey, TargetPlatform.macOS), ['Ctrl', 'Option', 'H']);
    expect(bossKeyLabels(_key(PhysicalKeyboardKey.space, {_control, _alt}), TargetPlatform.windows).last, 'Space');
    expect(bossKeyLabels(_key(PhysicalKeyboardKey.f11, {_control, _alt}), TargetPlatform.windows).last, 'F11');
    expect(bossKeyLabels(_key(PhysicalKeyboardKey.digit7, {_control, _alt}), TargetPlatform.windows).last, '7');
    expect(metaKeyName(TargetPlatform.macOS), 'Cmd');
    expect(metaKeyName(TargetPlatform.windows), 'Win');
    expect(metaKeyName(TargetPlatform.linux), 'Super');
  });
}
