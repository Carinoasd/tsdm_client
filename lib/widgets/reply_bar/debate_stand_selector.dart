import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The name of side [stand] of a debate: 1 affirmative, 2 negative, anything else neutral.
String debateSideName(BuildContext context, int stand) {
  final tr = context.t.specialThread.debate;
  return switch (stand) {
    1 => tr.affirm,
    2 => tr.nega,
    _ => tr.neutral,
  };
}

/// The side a reply takes in a debate, as the forum's reply forms ask it (the `stand` select: neutral, affirmative,
/// negative) while the account took none.
///
/// Once the account replied on a side ([fixed], plugin 2.8.0 `reply.stand` / `reply_stand`) the forum keeps every
/// later reply on it and its forms ask nothing: the side is only told then. When the page does not tell ([unknown]:
/// an older answer past the first page) the choice is offered with a note that the forum keeps a side already taken.
class DebateStandSelector extends StatelessWidget {
  /// Constructor.
  const DebateStandSelector({
    required this.value,
    required this.onChanged,
    this.fixed,
    this.unknown = false,
    super.key,
  });

  /// The chosen side (0 neutral, 1 affirmative, 2 negative).
  final int value;

  /// The side is chosen.
  final ValueChanged<int> onChanged;

  /// The side the account took with its first reply, null while it took none.
  final int? fixed;

  /// The page does not tell whether the account took a side.
  final bool unknown;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.specialThread.debate;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    if (fixed case final fixed?) {
      return Row(
        children: [
          Icon(Icons.forum_outlined, size: 18, color: colorScheme.onSurfaceVariant),
          sizedBoxW8H8,
          Expanded(
            child: Text(
              tr.fixedSide(side: debateSideName(context, fixed)),
              style: textTheme.labelLarge?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      );
    }
    final selector = Row(
      children: [
        Text(tr.replySide, style: textTheme.labelLarge?.copyWith(color: colorScheme.onSurfaceVariant)),
        sizedBoxW8H8,
        Flexible(
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            style: const ButtonStyle(visualDensity: VisualDensity.compact),
            segments: [
              for (final stand in const [0, 1, 2])
                ButtonSegment(value: stand, label: Text(debateSideName(context, stand))),
            ],
            selected: {value},
            onSelectionChanged: (selection) => onChanged(selection.first),
          ),
        ),
      ],
    );
    if (!unknown) {
      return selector;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        selector,
        sizedBoxW4H4,
        Text(tr.sideKeptNote, style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant)),
      ],
    );
  }
}
