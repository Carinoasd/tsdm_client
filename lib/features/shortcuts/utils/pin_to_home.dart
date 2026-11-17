import 'package:flutter/material.dart';
import 'package:tsdm_client/features/shortcuts/models/app_shortcut.dart';
import 'package:tsdm_client/features/shortcuts/repository/app_shortcuts_channel.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/list_app_bar/list_app_bar.dart';

/// The most characters of the label under the icon on the home screen, as Android suggests for a short label.
const pinnedShortcutShortLabelLength = 10;

/// The most characters of the label where the launcher has room for more, as Android suggests for a long label.
const pinnedShortcutLongLabelLength = 25;

/// "Add to home screen" of a forum or a thread ([PinnedShortcut], Android 8 or later).
abstract final class PinToHome {
  /// Whether the launcher pins shortcuts: the menus offer "add to home screen" while it is true. Never true off
  /// Android.
  ///
  /// Asked once the app shows its first frame, before the shortcut it was started with (the channel answers in the
  /// order it is asked: a page a shortcut opens is built knowing it), and again each time the app comes back to the
  /// front: the default launcher may have changed meanwhile ([refresh]).
  static final ValueNotifier<bool> supported = ValueNotifier(false);

  /// Ask again whether the launcher pins shortcuts, on [channel]; [android] replaces the platform in tests.
  static Future<void> refresh({AppShortcutsChannel channel = const AppShortcutsChannel(), bool? android}) async {
    if (!(android ?? isAndroid)) {
      supported.value = false;
      return;
    }
    supported.value = await channel.pinSupported();
  }
}

/// The labels of a shortcut for [title], white space collapsed: the short one under the icon, the long one where there
/// is room. Cut to the lengths Android suggests by characters as the user sees them, with an ellipsis when cut. Null
/// when there is no title.
({String short, String long})? pinnedShortcutLabels(String title) {
  final text = title.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) {
    return null;
  }
  return (short: _cut(text, pinnedShortcutShortLabelLength), long: _cut(text, pinnedShortcutLongLabelLength));
}

String _cut(String text, int max) {
  final characters = text.characters;
  return characters.length <= max ? text : '${characters.take(max - 1)}…';
}

/// The item of the menu of a forum or a thread page pinning [shortcut], titled [title] (the forum's), to the home
/// screen. Null when it is not offered: off Android, with a launcher that does not pin, a page whose id or title is not
/// known yet.
///
/// Built with the page: the title is taken as the user sees it (the Chinese display mode).
MenuCustomItem? pinToHomeMenuItem(BuildContext context, PinnedShortcut? shortcut, String? title) {
  if (!PinToHome.supported.value || shortcut == null) {
    return null;
  }
  final labels = pinnedShortcutLabels(context.displayText(title ?? ''));
  if (labels == null) {
    return null;
  }
  return MenuCustomItem(
    icon: Icons.add_to_home_screen_outlined,
    description: context.t.appShortcuts.pinToHome,
    onSelected: () async => pinToHomeScreen(context, shortcut, labels: labels),
  );
}

/// Ask the launcher to pin [shortcut] with [labels] ([pinnedShortcutLabels]), on [channel].
///
/// The launcher tells the user itself when it is asked; a shortcut pinned already is updated, and that is told here, as
/// is a refusal.
Future<void> pinToHomeScreen(
  BuildContext context,
  PinnedShortcut shortcut, {
  required ({String short, String long}) labels,
  AppShortcutsChannel channel = const AppShortcutsChannel(),
}) async {
  final result = await channel.requestPin(shortcut, shortLabel: labels.short, longLabel: labels.long);
  if (!context.mounted) {
    return;
  }
  final tr = context.t.appShortcuts;
  switch (result) {
    case PinShortcutResult.requested:
      break;
    case PinShortcutResult.updated:
      showSnackBar(context: context, message: tr.pinUpdated, clearPrevious: true);
    case PinShortcutResult.failed:
      showSnackBar(context: context, message: tr.pinFailed, clearPrevious: true);
  }
}
