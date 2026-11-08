import 'package:flutter/material.dart';

/// One row of [RankedBars].
final class RankedBarItem {
  /// Constructor.
  const RankedBarItem({required this.label, required this.value, this.detail});

  /// Name of the row.
  final String label;

  /// Its number, the length of its bar.
  final int value;

  /// Words under the name, null for none.
  final String? detail;
}

/// Rows of a name, a bar as long as its number against the largest and the number, the largest first.
class RankedBars extends StatelessWidget {
  /// Constructor.
  const RankedBars({required this.items, super.key});

  /// The rows, in the order shown.
  final List<RankedBarItem> items;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final largest = items.fold(0, (a, b) => b.value > a ? b.value : a);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (index, item) in items.indexed)
          Padding(
            key: ValueKey('ranked-row-$index'),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(item.label, maxLines: 1, overflow: TextOverflow.ellipsis)),
                    Text(
                      '${item.value}',
                      style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold, color: colorScheme.primary),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: largest == 0 ? 0 : item.value / largest,
                    minHeight: 6,
                    backgroundColor: colorScheme.surfaceContainerHighest,
                  ),
                ),
                if (item.detail?.isNotEmpty ?? false)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      item.detail!,
                      style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
