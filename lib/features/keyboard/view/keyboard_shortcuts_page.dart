import 'package:flutter/material.dart';
import 'package:tsdm_client/features/keyboard/models/keyboard_shortcut_catalog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The keyboard shortcuts of the desktop app, listed (they can not be changed).
class KeyboardShortcutsPage extends StatelessWidget {
  /// Constructor.
  const KeyboardShortcutsPage({super.key});

  /// Name of a key as printed on the list.
  @visibleForTesting
  static String keyLabel(String token, {required bool mac}) {
    if (token == primaryModifierToken) {
      return mac ? 'Cmd' : 'Ctrl';
    }
    return token;
  }

  String _describe(BuildContext context, KeyboardCommand command) {
    final tr = context.t.keyboardShortcutsPage.commands;
    return switch (command) {
      KeyboardCommand.search => tr.search,
      KeyboardCommand.quickOpen => tr.quickOpen,
      KeyboardCommand.settings => tr.settings,
      KeyboardCommand.back => tr.back,
      KeyboardCommand.refresh => tr.refresh,
      KeyboardCommand.nextFloor => tr.nextFloor,
      KeyboardCommand.previousFloor => tr.previousFloor,
      KeyboardCommand.nextPage => tr.nextPage,
      KeyboardCommand.previousPage => tr.previousPage,
      KeyboardCommand.reply => tr.reply,
      KeyboardCommand.top => tr.top,
      KeyboardCommand.bottom => tr.bottom,
      KeyboardCommand.copyLink => tr.copyLink,
      KeyboardCommand.nextItem => tr.nextItem,
      KeyboardCommand.previousItem => tr.previousItem,
      KeyboardCommand.openItem => tr.openItem,
      KeyboardCommand.send => tr.send,
      KeyboardCommand.bold => tr.bold,
      KeyboardCommand.italic => tr.italic,
      KeyboardCommand.underline => tr.underline,
    };
  }

  String _groupTitle(BuildContext context, KeyboardShortcutGroup group) {
    final tr = context.t.keyboardShortcutsPage.groups;
    return switch (group) {
      KeyboardShortcutGroup.global => tr.global,
      KeyboardShortcutGroup.thread => tr.thread,
      KeyboardShortcutGroup.list => tr.list,
      KeyboardShortcutGroup.editor => tr.editor,
    };
  }

  Widget _buildKeys(BuildContext context, List<List<String>> alternatives) {
    final colorScheme = Theme.of(context).colorScheme;
    Widget cap(String label) => DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(label, style: Theme.of(context).textTheme.labelMedium),
      ),
    );
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 12,
      runSpacing: 4,
      children: [
        for (final keys in alternatives)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < keys.length; i++) ...[
                if (i > 0) const SizedBox(width: 4),
                cap(keyLabel(keys[i], mac: isMacOS)),
              ],
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = [
      for (final group in KeyboardShortcutGroup.values)
        (group, keyboardShortcutCatalog.where((e) => e.group == group).toList()),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(context.t.keyboardShortcutsPage.title)),
      body: SafeArea(
        top: false,
        child: AppCenteredList(
          maxWidth: appFormMaxWidth,
          builder: (context, side, _) => ListView(
            padding: side.copyWith(top: 12, bottom: 24),
            children: [
              for (final (group, entries) in groups) ...[
                AppTileGroup(
                  title: _groupTitle(context, group),
                  children: [
                    for (final entry in entries)
                      ListTile(
                        title: Text(_describe(context, entry.command)),
                        trailing: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 220),
                          child: _buildKeys(context, entry.alternatives),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: appSurfaceGap),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
