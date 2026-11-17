import 'package:flutter/foundation.dart';
import 'package:system_hotkeys/system_hotkeys.dart';
import 'package:tsdm_client/features/keyboard/models/keyboard_shortcut_catalog.dart';

/// The id the boss key is bound under (`SystemHotkeys`).
const bossKeyId = 'bossKey';

/// The combination before the user records one: Ctrl+Alt+H on every platform, Control+Option+H on macOS (where
/// Cmd+Option+H hides the other apps).
const defaultBossKey = HotKey(key: PhysicalKeyboardKey.keyH, modifiers: {HotKeyModifier.control, HotKeyModifier.alt});

/// Why a recorded combination can not be the boss key.
enum BossKeyProblem {
  /// Not a letter, a digit, F1 to F12 or the space bar: the keys every platform can bind.
  unsupportedKey,

  /// Fewer than two modifiers, or none of them Ctrl or Win (Cmd, Super): a single key, Shift with a key (typing a
  /// capital), Option with a key on macOS (typing a symbol), and the one-modifier shortcuts every app has (Ctrl+C,
  /// Cmd+Q, Alt+F4) would be taken from every app on the system.
  needsModifiers,

  /// One of the app's own keyboard shortcuts ([keyboardShortcutCatalog]).
  usedInApp,
}

/// Why [hotKey] can not be the boss key, null when it can.
BossKeyProblem? bossKeyProblem(HotKey hotKey) {
  if (!HotKey.isSupportedKey(hotKey.key)) {
    return BossKeyProblem.unsupportedKey;
  }
  final modifiers = hotKey.modifiers;
  if (modifiers.length < 2 ||
      !(modifiers.contains(HotKeyModifier.control) || modifiers.contains(HotKeyModifier.meta))) {
    return BossKeyProblem.needsModifiers;
  }
  if (inAppHotKeys.contains(hotKey)) {
    return BossKeyProblem.usedInApp;
  }
  return null;
}

/// The combinations of the app's own keyboard shortcuts a boss key could be, from [keyboardShortcutCatalog]: those of
/// a key [HotKey.isSupportedKey] takes. The primary modifier is Ctrl and Cmd alike on every platform (both are bound,
/// `KeyboardShortcutsHost`), so it stands for both.
@visibleForTesting
final Set<HotKey> inAppHotKeys = {
  for (final entry in keyboardShortcutCatalog)
    for (final keys in entry.alternatives) ..._hotKeysOf(keys),
};

Iterable<HotKey> _hotKeysOf(List<String> tokens) {
  var modifierSets = <Set<HotKeyModifier>>[{}];
  final keys = <PhysicalKeyboardKey>[];
  for (final token in tokens) {
    switch (token) {
      case primaryModifierToken:
        modifierSets = [
          for (final set in modifierSets) ...[
            {...set, HotKeyModifier.control},
            {...set, HotKeyModifier.meta},
          ],
        ];
      case 'Ctrl':
        modifierSets = [
          for (final set in modifierSets) {...set, HotKeyModifier.control},
        ];
      case 'Alt':
        modifierSets = [
          for (final set in modifierSets) {...set, HotKeyModifier.alt},
        ];
      case 'Shift':
        modifierSets = [
          for (final set in modifierSets) {...set, HotKeyModifier.shift},
        ];
      default:
        keys.addAll(_keysOfToken(token));
    }
  }
  return [
    for (final modifiers in modifierSets)
      for (final key in keys) HotKey(key: key, modifiers: modifiers),
  ];
}

/// The keys a key name of [keyboardShortcutCatalog] stands for, none when it is not a key a boss key can have.
List<PhysicalKeyboardKey> _keysOfToken(String token) {
  if (token == '1–9') {
    return [for (var digit = 1; digit <= 9; digit++) _keyOfName('$digit')!];
  }
  final key = _keyOfName(token.toLowerCase());
  return key == null ? const [] : [key];
}

const _letterA = 0x00070004;
const _letterZ = 0x0007001d;
const _digit1 = 0x0007001e;
const _digit9 = 0x00070026;
const _digit0 = 0x00070027;
const _f1 = 0x0007003a;
const _f12 = 0x00070045;
const _space = 0x0007002c;

/// The name of a key of [HotKey.supportedUsages] in a stored combination: `a` to `z`, `0` to `9`, `f1` to `f12`,
/// `space`. Null for any other key.
String? _nameOfKey(PhysicalKeyboardKey key) => switch (key.usbHidUsage) {
  final u when u >= _letterA && u <= _letterZ => String.fromCharCode(0x61 + u - _letterA),
  final u when u >= _digit1 && u <= _digit9 => '${u - _digit1 + 1}',
  _digit0 => '0',
  final u when u >= _f1 && u <= _f12 => 'f${u - _f1 + 1}',
  _space => 'space',
  _ => null,
};

final Map<String, PhysicalKeyboardKey> _keysByName = {
  for (final usage in HotKey.supportedUsages) ?_nameOfKey(PhysicalKeyboardKey(usage)): PhysicalKeyboardKey(usage),
};

PhysicalKeyboardKey? _keyOfName(String name) => _keysByName[name];

const Map<HotKeyModifier, String> _modifierNames = {
  HotKeyModifier.control: 'ctrl',
  HotKeyModifier.alt: 'alt',
  HotKeyModifier.shift: 'shift',
  HotKeyModifier.meta: 'meta',
};

/// [hotKey] as stored in `SettingsKeys.bossKeyCombo`: the modifiers in a fixed order, then the key, joined by `+`
/// (`ctrl+alt+h`). Null for a key that is not one of [HotKey.supportedUsages].
String? encodeBossKey(HotKey hotKey) {
  final key = _nameOfKey(hotKey.key);
  if (key == null) {
    return null;
  }
  return [
    for (final modifier in HotKeyModifier.values)
      if (hotKey.modifiers.contains(modifier)) _modifierNames[modifier]!,
    key,
  ].join('+');
}

/// The combination stored as [value] by [encodeBossKey], null when [value] is not one.
HotKey? decodeBossKey(String value) {
  final parts = value.split('+');
  final key = _keyOfName(parts.last);
  if (key == null) {
    return null;
  }
  final modifiers = <HotKeyModifier>{};
  for (final name in parts.take(parts.length - 1)) {
    final modifier = _modifierNames.entries.where((e) => e.value == name).firstOrNull?.key;
    if (modifier == null || !modifiers.add(modifier)) {
      return null;
    }
  }
  return HotKey(key: key, modifiers: modifiers);
}

/// The boss key stored as [value]: [defaultBossKey] when [value] is not a combination or one that can not be the boss
/// key (written by hand, or by a later version with other rules).
HotKey bossKeyOf(String value) {
  final hotKey = decodeBossKey(value);
  return hotKey == null || bossKeyProblem(hotKey) != null ? defaultBossKey : hotKey;
}

/// The name of the modifier [HotKeyModifier.meta] on [platform]: Cmd on macOS, Win on Windows, Super elsewhere.
String metaKeyName(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS || TargetPlatform.iOS => 'Cmd',
  TargetPlatform.windows => 'Win',
  _ => 'Super',
};

/// The names of [modifiers] as printed on the key caps on [platform], in the order of [HotKeyModifier].
List<String> bossKeyModifierLabels(Set<HotKeyModifier> modifiers, TargetPlatform platform) {
  final mac = platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
  return [
    for (final m in HotKeyModifier.values)
      if (modifiers.contains(m))
        switch (m) {
          HotKeyModifier.control => 'Ctrl',
          HotKeyModifier.alt => mac ? 'Option' : 'Alt',
          HotKeyModifier.shift => 'Shift',
          HotKeyModifier.meta => metaKeyName(platform),
        },
  ];
}

/// The keys of [hotKey] as printed on the key caps on [platform]: the modifiers ([bossKeyModifierLabels]), then the
/// key. Only for a key of [HotKey.supportedUsages].
List<String> bossKeyLabels(HotKey hotKey, TargetPlatform platform) => [
  ...bossKeyModifierLabels(hotKey.modifiers, platform),
  switch (_nameOfKey(hotKey.key)) {
    null => '?',
    'space' => 'Space',
    final name => name.toUpperCase(),
  },
];
