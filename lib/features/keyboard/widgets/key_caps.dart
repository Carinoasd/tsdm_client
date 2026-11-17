import 'package:flutter/material.dart';

/// The keys of one combination as key caps, side by side.
class KeyCaps extends StatelessWidget {
  /// Constructor.
  const KeyCaps(this.labels, {this.color, super.key});

  /// The names of the keys, in the order pressed.
  final List<String> labels;

  /// Color of the names, the color of the theme when null.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(color: color);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: colorScheme.outlineVariant),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text(labels[i], style: style),
            ),
          ),
        ],
      ],
    );
  }
}
