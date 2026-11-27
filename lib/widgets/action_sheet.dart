import 'package:flutter/material.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';

/// One action of an [showActionSheet].
@immutable
final class ActionSheetItem<T> {
  /// Constructor.
  const ActionSheetItem({required this.value, required this.icon, required this.label, this.color});

  /// What the sheet gives back when the action is picked.
  final T value;

  /// Icon of the action.
  final IconData icon;

  /// Name of the action: under the icon in the row, beside it in the list. Also what a screen reader says.
  final String label;

  /// Color of the icon and the name, for an action that destroys something; null for the usual ones.
  final Color? color;
}

/// A bottom sheet of actions: the ones used most as a row of icons ([primary]), the others as a list under it
/// ([secondary]). Either may be empty.
///
/// The sheet only tells which action was picked: it closes itself and gives the action's value back (null when it
/// was dismissed). The caller runs the action afterwards, from its own context, so a dialog or a page the action
/// opens is not stacked on the sheet and never uses the context of a sheet that is gone. Check `mounted` first.
Future<T?> showActionSheet<T>({
  required BuildContext context,
  required String title,
  List<ActionSheetItem<T>> primary = const [],
  List<ActionSheetItem<T>> secondary = const [],
}) => showCustomBottomSheet<T>(
  context: context,
  title: title,
  childrenBuilder: (context) => [
    if (primary.isNotEmpty)
      Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Wrap(
          alignment: WrapAlignment.spaceEvenly,
          runSpacing: 4,
          children: [for (final item in primary) _IconAction(item)],
        ),
      ),
    if (primary.isNotEmpty && secondary.isNotEmpty) const Divider(height: 1),
    for (final item in secondary)
      ListTile(
        key: ValueKey('action-sheet-${item.value}'),
        leading: Icon(item.icon, color: item.color),
        title: Text(item.label, style: item.color == null ? null : TextStyle(color: item.color)),
        onTap: () => Navigator.of(context).pop(item.value),
      ),
  ],
);

/// An action of the icon row: the icon in a tonal circle, its name under it.
class _IconAction<T> extends StatelessWidget {
  const _IconAction(this.item);

  final ActionSheetItem<T> item;

  /// Width of one action: five fit a 384dp phone.
  static const _width = 72.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: item.label,
      excludeSemantics: true,
      child: Tooltip(
        message: item.label,
        child: InkWell(
          key: ValueKey('action-sheet-${item.value}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () => Navigator.of(context).pop(item.value),
          child: SizedBox(
            width: _width,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: colorScheme.secondaryContainer,
                    foregroundColor: item.color ?? colorScheme.onSecondaryContainer,
                    child: Icon(item.icon),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.label,
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: item.color),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
