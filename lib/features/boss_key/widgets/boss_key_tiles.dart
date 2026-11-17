import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:system_hotkeys/system_hotkeys.dart';
import 'package:tsdm_client/features/boss_key/boss_key_controller.dart';
import 'package:tsdm_client/features/boss_key/models/boss_key_combo.dart';
import 'package:tsdm_client/features/keyboard/widgets/key_caps.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';

/// The switch of the boss key in the window settings: off and unavailable where the desktop can not bind a shortcut
/// ([BossKey.available]).
class BossKeySwitchTile extends StatefulWidget {
  /// Constructor.
  const BossKeySwitchTile({required this.enabled, this.controller, super.key});

  /// `SettingsKeys.bossKey`.
  final bool enabled;

  /// [BossKey.instance] when null (tests give their own).
  final BossKey? controller;

  @override
  State<BossKeySwitchTile> createState() => _BossKeySwitchTileState();
}

class _BossKeySwitchTileState extends State<BossKeySwitchTile> {
  BossKey get _controller => widget.controller ?? BossKey.instance;

  /// Set while the shortcut is being bound or released.
  bool _switching = false;

  Future<void> _toggle({required bool enable}) async {
    setState(() => _switching = true);
    try {
      await _controller.setEnabled(enable: enable);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: _controller.available,
    builder: (context, available, _) => SectionSwitchListTile(
      secondary: const Icon(Icons.visibility_off_outlined),
      title: Text(context.t.settingsPage.windowSection.bossKey),
      value: widget.enabled && available,
      onChanged: !available || _switching ? null : (v) => _toggle(enable: v),
    ),
  );
}

/// The combination of the boss key in the window settings; a tap records another one ([showBossKeyRecorder]).
///
/// Where the desktop decides the keys ([BossKey.configuredByDesktop], Linux) and the boss key is bound, the keys shown
/// are the ones the desktop reports ([BossKey.desktopTrigger], none yet: a dash), and a tap opens the desktop's own
/// settings of the shortcut; the recorder only where it has none to open.
class BossKeyShortcutTile extends StatelessWidget {
  /// Constructor.
  const BossKeyShortcutTile({required this.combo, this.controller, super.key});

  /// `SettingsKeys.bossKeyCombo`.
  final String combo;

  /// [BossKey.instance] when null (tests give their own).
  final BossKey? controller;

  Future<void> _onTap(BuildContext context, BossKey controller) async {
    if (await controller.configureInDesktop() || !context.mounted) {
      return;
    }
    // The page may be gone once the shortcut is released.
    await controller.record(
      () async => context.mounted ? showBossKeyRecorder(context, bossKeyOf(combo)) : null,
    );
  }

  List<String> _labels(BossKey controller) {
    final trigger = controller.desktopTrigger.value;
    if (controller.configuredByDesktop && trigger != null) {
      return desktopTriggerLabels(trigger);
    }
    return bossKeyLabels(bossKeyOf(combo), defaultTargetPlatform);
  }

  @override
  Widget build(BuildContext context) {
    final controller = this.controller ?? BossKey.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([controller.available, controller.desktopTrigger]),
      builder: (context, _) => SectionListTile(
        leading: const Icon(Icons.keyboard_command_key_outlined),
        title: Text(context.t.settingsPage.windowSection.bossKeyShortcut),
        trailing: KeyCaps(_labels(controller)),
        enabled: controller.available.value,
        onTap: () => unawaited(_onTap(context, controller)),
      ),
    );
  }
}

/// The key caps of [trigger], what a desktop says triggers a shortcut in its own words: split at `+` when that gives
/// clean names (`Ctrl+Alt+H`), else the words as one cap (`Ctrl++`, several combinations); a dash for none yet.
@visibleForTesting
List<String> desktopTriggerLabels(String trigger) {
  final text = trigger.trim();
  if (text.isEmpty) {
    return const ['—'];
  }
  final keys = text.split('+').map((e) => e.trim()).toList();
  if (keys.any((e) => e.isEmpty) || text.contains(RegExp('[;,]'))) {
    return [text];
  }
  return keys;
}

/// Record a new boss key, starting from [current]: the combination to save, null when cancelled.
Future<HotKey?> showBossKeyRecorder(BuildContext context, HotKey current) => showDialog<HotKey>(
  context: context,
  builder: (_) => BossKeyRecorderDialog(current: current),
);

/// Takes the keys pressed while it is open and shows them; only a combination that can be the boss key
/// ([bossKeyProblem]) can be saved, any other one says why.
///
/// Esc, Tab, Enter and Space pressed without Ctrl, Alt or Win (Cmd) keep their use in the dialog: closing it, moving
/// between the buttons, pressing one.
@visibleForTesting
class BossKeyRecorderDialog extends StatefulWidget {
  /// Constructor.
  const BossKeyRecorderDialog({required this.current, super.key});

  /// The combination in use.
  final HotKey current;

  @override
  State<BossKeyRecorderDialog> createState() => _BossKeyRecorderDialogState();
}

class _BossKeyRecorderDialogState extends State<BossKeyRecorderDialog> {
  static final Set<LogicalKeyboardKey> _dialogKeys = {
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
  };

  static final Set<PhysicalKeyboardKey> _modifierKeys = {
    PhysicalKeyboardKey.controlLeft,
    PhysicalKeyboardKey.controlRight,
    PhysicalKeyboardKey.altLeft,
    PhysicalKeyboardKey.altRight,
    PhysicalKeyboardKey.shiftLeft,
    PhysicalKeyboardKey.shiftRight,
    PhysicalKeyboardKey.metaLeft,
    PhysicalKeyboardKey.metaRight,
    PhysicalKeyboardKey.capsLock,
    PhysicalKeyboardKey.fn,
  };

  /// The combination to save, null after a key that can not be the boss key.
  late HotKey? _hotKey = widget.current;

  /// The keys shown.
  late List<String> _labels = bossKeyLabels(widget.current, defaultTargetPlatform);

  /// Why the keys shown can not be the boss key.
  BossKeyProblem? _problem;

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    final keyboard = HardwareKeyboard.instance;
    final command = keyboard.isControlPressed || keyboard.isAltPressed || keyboard.isMetaPressed;
    if (!command && _dialogKeys.contains(event.logicalKey)) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent || _modifierKeys.contains(event.physicalKey)) {
      return KeyEventResult.handled;
    }
    final modifiers = {
      if (keyboard.isControlPressed) HotKeyModifier.control,
      if (keyboard.isAltPressed) HotKeyModifier.alt,
      if (keyboard.isShiftPressed) HotKeyModifier.shift,
      if (keyboard.isMetaPressed) HotKeyModifier.meta,
    };
    final hotKey = HotKey(key: event.physicalKey, modifiers: modifiers);
    final problem = bossKeyProblem(hotKey);
    setState(() {
      _problem = problem;
      _hotKey = problem == null ? hotKey : null;
      _labels = problem == BossKeyProblem.unsupportedKey
          ? [
              ...bossKeyModifierLabels(modifiers, defaultTargetPlatform),
              if (event.logicalKey.keyLabel.trim() case final label when label.isNotEmpty) label else '?',
            ]
          : bossKeyLabels(hotKey, defaultTargetPlatform);
    });
    return KeyEventResult.handled;
  }

  void _reset() => setState(() {
    _hotKey = defaultBossKey;
    _labels = bossKeyLabels(defaultBossKey, defaultTargetPlatform);
    _problem = null;
  });

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.windowSection;
    final colorScheme = Theme.of(context).colorScheme;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: AlertDialog(
        icon: const Icon(Icons.keyboard_command_key_outlined),
        title: Text(tr.bossKeyShortcut),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            KeyCaps(_labels, color: _problem == null ? null : colorScheme.error),
            if (_problem case final problem?)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(switch (problem) {
                  BossKeyProblem.unsupportedKey => tr.bossKeyUnsupportedKey,
                  BossKeyProblem.needsModifiers => tr.bossKeyNeedsModifiers(meta: metaKeyName(defaultTargetPlatform)),
                  BossKeyProblem.usedInApp => tr.bossKeyUsedInApp,
                }, style: TextStyle(color: colorScheme.error)),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: _reset, child: Text(context.t.general.reset)),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
          TextButton(
            onPressed: _hotKey == null ? null : () => Navigator.of(context).pop(_hotKey),
            child: Text(context.t.general.ok),
          ),
        ],
      ),
    );
  }
}
