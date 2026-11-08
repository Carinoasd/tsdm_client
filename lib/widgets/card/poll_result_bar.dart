import 'package:flutter/material.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// The result of one poll option: a bar as wide as its share of the votes, with the number of votes at its tail.
/// The option the account voted for is drawn in the primary color.
class PollResultBar extends StatelessWidget {
  /// Constructor.
  const PollResultBar({required this.votes, required this.percent, this.mine = false, super.key});

  /// Votes of the option.
  final int votes;

  /// Share of the votes, 0 to 100.
  final double percent;

  /// The account voted for this option.
  final bool mine;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final fraction = (percent / 100).clamp(0.0, 1.0);
    final label = '$votes · ${percent.toStringAsFixed(percent == percent.roundToDouble() ? 0 : 2)}%';
    final tr = context.t.pollCard;
    final spoken = tr.resultLabel(votes: votes, percent: percent.toStringAsFixed(2));
    return Semantics(
      label: mine ? '$spoken, ${tr.myChoice}' : spoken,
      excludeSemantics: true,
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: Stack(
                  children: [
                    Positioned.fill(child: ColoredBox(color: colorScheme.surfaceContainerHighest)),
                    Positioned.fill(
                      child: FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: fraction,
                        child: ColoredBox(
                          key: const ValueKey('poll-result-fill'),
                          color: mine ? colorScheme.primary : colorScheme.primaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: textTheme.labelMedium?.copyWith(
              color: mine ? colorScheme.primary : colorScheme.onSurfaceVariant,
              fontWeight: mine ? FontWeight.w600 : null,
            ),
          ),
        ],
      ),
    );
  }
}
