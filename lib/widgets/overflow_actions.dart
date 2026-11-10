import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';

/// Where an [OverflowAction] is shown.
enum OverflowPlacement {
  /// Always an icon button in the bar.
  pinned,

  /// An icon button in the bar when there is room, an item of the overflow menu on a narrow screen.
  adaptive,

  /// Always an item of the overflow menu.
  menuOnly,
}

/// One action of [OverflowActions].
class OverflowAction {
  /// Constructor.
  const OverflowAction({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.placement = OverflowPlacement.adaptive,
  });

  /// Icon of the button and of the menu item.
  final IconData icon;

  /// Tooltip of the button and text of the menu item.
  final String label;

  /// Called when the action is picked.
  final VoidCallback onPressed;

  /// Where to show the action.
  final OverflowPlacement placement;
}

/// Width below which [OverflowPlacement.adaptive] actions move into the overflow menu.
const double overflowActionsNarrowWidth = 480;

/// App bar actions that keep the back button clear on a phone: [OverflowPlacement.pinned] ones stay as buttons, the
/// [OverflowPlacement.adaptive] ones fold into a menu on a narrow screen.
class OverflowActions extends StatelessWidget {
  /// Constructor.
  const OverflowActions({required this.actions, super.key});

  /// Actions in the order shown.
  final List<OverflowAction> actions;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < overflowActionsNarrowWidth;
    bool inMenu(OverflowAction a) =>
        a.placement == OverflowPlacement.menuOnly || (narrow && a.placement == OverflowPlacement.adaptive);
    final menu = actions.where(inMenu).toList();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final a in actions)
          if (!inMenu(a)) IconButton(icon: Icon(a.icon), tooltip: a.label, onPressed: a.onPressed),
        if (menu.isNotEmpty)
          PopupMenuButton<OverflowAction>(
            onSelected: (a) => a.onPressed(),
            itemBuilder: (context) => [
              for (final a in menu)
                PopupMenuItem(
                  value: a,
                  child: Row(children: [Icon(a.icon), sizedBoxPopupMenuItemIconSpacing, Text(a.label)]),
                ),
            ],
          ),
      ],
    );
  }
}
