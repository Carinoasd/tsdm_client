import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart' show threadContentMaxTextScale;
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// Dialog to pick the line height and the paragraph spacing of the post content, with a preview of a post laid out
/// with them.
///
/// Pops a [PostTypography] with the values picked, null when dismissed.
class ThreadContentLayoutDialog extends StatefulWidget {
  /// Constructor.
  const ThreadContentLayoutDialog({required this.initial, required this.contentScale, super.key});

  /// How the post content is laid out when the dialog opens (its [PostTypography.splitLongParagraphs] is kept).
  final PostTypography initial;

  /// The extra text scale of the post content (the thread content scale setting), for the preview.
  final double contentScale;

  @override
  State<ThreadContentLayoutDialog> createState() => _ThreadContentLayoutDialogState();
}

class _ThreadContentLayoutDialogState extends State<ThreadContentLayoutDialog> {
  late double _lineHeight;
  late double _paragraphSpacing;

  @override
  void initState() {
    super.initState();
    _lineHeight = widget.initial.lineHeight.clamp(PostTypography.minLineHeight, PostTypography.maxLineHeight);
    _paragraphSpacing = widget.initial.paragraphSpacing.clamp(
      PostTypography.minParagraphSpacing,
      PostTypography.maxParagraphSpacing,
    );
  }

  PostTypography get _typography => PostTypography(
    lineHeight: _lineHeight,
    paragraphSpacing: _paragraphSpacing,
    splitLongParagraphs: widget.initial.splitLongParagraphs,
  );

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.threadContentLayout;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final scale = math.min(MediaQuery.textScalerOf(context).scale(1) * widget.contentScale, threadContentMaxTextScale);
    // The preview is as wide as the content of the dialog (at most 70% of the screen, 400) less its block's padding:
    // what a short line is there.
    final previewWidth = math.min(MediaQuery.sizeOf(context).width * 0.7, 400) - 24;
    final fontSize = textTheme.bodyMedium?.fontSize ?? 14;
    final lineWidth = math.max<double>(1, (2 * previewWidth / (fontSize * scale)).floor() / 2);

    Widget slider({
      required String label,
      required String value,
      required double current,
      required double min,
      required double max,
      required int divisions,
      required ValueChanged<double> onChanged,
    }) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: textTheme.titleSmall)),
            Text(value, style: textTheme.titleSmall?.copyWith(color: colorScheme.primary)),
          ],
        ),
        Slider(
          // Since flutter 3.29
          // ignore: deprecated_member_use
          year2023: false,
          min: min,
          max: max,
          divisions: divisions,
          value: current,
          label: value,
          onChanged: onChanged,
        ),
      ],
    );

    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.format_line_spacing_outlined, title: tr.dialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 8,
        children: [
          slider(
            label: tr.lineHeight,
            value: _lineHeight.toStringAsFixed(1),
            current: _lineHeight,
            min: PostTypography.minLineHeight,
            max: PostTypography.maxLineHeight,
            divisions: 6,
            onChanged: (v) => setState(() => _lineHeight = double.parse(v.toStringAsFixed(1))),
          ),
          slider(
            label: tr.paragraphSpacing,
            value: _paragraphSpacing.toStringAsFixed(0),
            current: _paragraphSpacing,
            min: PostTypography.minParagraphSpacing,
            max: PostTypography.maxParagraphSpacing,
            divisions: 8,
            onChanged: (v) => setState(() => _paragraphSpacing = v.roundToDouble()),
          ),
          Text(tr.preview, style: textTheme.labelMedium?.copyWith(color: colorScheme.outline)),
          // The preview is a post's content laid out as in the thread page, at its text scale.
          AppInsetBlock(
            outlined: true,
            padding: edgeInsetsL12T12R12B12,
            child: MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: PostTypographyScope(
                key: const ValueKey('thread-content-layout-preview'),
                typography: _typography.withLineWidth(lineWidth),
                child: MunchedHtml(tr.previewText),
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => setState(() {
            _lineHeight = PostTypography.defaultLineHeight;
            _paragraphSpacing = PostTypography.defaultParagraphSpacing;
          }),
          child: Text(context.t.general.reset),
        ),
        FilledButton(onPressed: () => context.pop(_typography), child: Text(context.t.general.ok)),
      ],
    );
  }
}
