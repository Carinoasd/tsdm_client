import 'package:flutter/material.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Widget to show some quoted text.
class QuotedText extends StatelessWidget {
  /// Construct from [String] [text].
  const QuotedText(this.text, {super.key}) : span = null;

  /// Construct from an [InlineSpan] span.
  const QuotedText.rich(this.span, {super.key}) : text = null;

  /// Text to show in quoted style.
  final String? text;

  /// Span to show in quoted style.
  final InlineSpan? span;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final quotedStyle = Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurface);

    final Widget content;
    if (text != null) {
      content = Text(text!, style: quotedStyle);
    } else if (span != null) {
      content = Text.rich(TextSpan(style: quotedStyle, children: [span!]));
    } else {
      // Impossible.
      return const SizedBox.shrink();
    }

    // An opaque block of the inset layer with a neutral bar on the start side: reads as quoted without quote marks,
    // and stays clear on any seed color (a translucent tinted block went muddy on dark themes). The rich content
    // (links, images, emojis) keeps its own styles.
    return ClipRRect(
      borderRadius: BorderRadius.circular(appInnerRadius),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppSurfaces.of(context).inset,
          border: Border(left: BorderSide(color: colorScheme.outline, width: 3)),
        ),
        child: Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 8), child: content),
      ),
    );
  }
}
