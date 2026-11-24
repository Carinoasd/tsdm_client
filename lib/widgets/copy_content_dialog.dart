import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/copy_button.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Item represents some content user would copy.
final class CopyableContent {
  /// Constructor.
  const CopyableContent({required this.name, required this.data});

  /// Name of the content.
  final String name;

  /// Content data.
  final String data;
}

/// Show a dialog that list groups of [contents] and allow user copy them.
///
/// See also:
///
///  * [showCopyContentDialogFutureBuilder], for showing content built from a future.
Future<void> showCopyContentDialog({
  required BuildContext context,
  required List<CopyableContent> contents,
  String? title,
  String? route,
}) async => showDialog(
  context: context,
  builder: (_) => RootPage(route ?? DialogPaths.copyContent, _CopyContentDialog(title, contents)),
);

/// Show a dialog that list groups of contents built from [contentFuture] and allow user copy them.
///
/// The [CopyableContent] used here are built from [contentFuture].
///
/// See also:
///
///  * [showCopyContentDialog], for showing content built directly from instances.
Future<void> showCopyContentDialogFutureBuilder({
  required BuildContext context,
  required Future<List<CopyableContent>> contentFuture,
  Widget Function(BuildContext context, Object? error)? errorBuilder,
  String? title,
  String? route,
}) async => showDialog(
  context: context,
  builder: (_) => RootPage(
    route ?? DialogPaths.copyContent,
    FutureBuilder(
      future: contentFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return errorBuilder?.call(context, snapshot.error) ?? Center(child: Text(context.t.general.failedToLoad));
        }

        if (!snapshot.hasData) {
          return const CenteredCircularIndicator();
        }

        return _CopyContentDialog(title, snapshot.data!);
      },
    ),
  ),
);

/// Dialog showing contents and allow user to copy.
///
/// Contents are attached with description.
///
/// See also:
///
///  * [_CopySelectContentDialog], for copying group of contents attached with description.
class _CopyContentDialog extends StatefulWidget {
  /// Constructor.
  const _CopyContentDialog(this.title, this.contents);

  /// Optional title.
  final String? title;

  /// Contents showed in the dialog.
  ///
  /// Key is the name of content, and value is content itself.
  final List<CopyableContent> contents;

  @override
  State<_CopyContentDialog> createState() => _CopyContentDialogState();
}

class _CopyContentDialogState extends State<_CopyContentDialog> {
  late final List<TextEditingController> controllers;

  @override
  void initState() {
    super.initState();
    controllers = List.generate(
      widget.contents.length,
      (idx) => TextEditingController(text: widget.contents[idx].data),
    );
  }

  @override
  void dispose() {
    for (final e in controllers) {
      e.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.copyDialog;

    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return CustomAlertDialog.sync(
      title: Row(
        children: [
          const AppIconTile(Icons.content_copy_outlined, size: 36),
          sizedBoxW12H12,
          Expanded(child: Text(widget.title ?? tr.copyTitle)),
        ],
      ),
      content: Padding(
        padding: edgeInsetsT12,
        child: Column(
          spacing: 8,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          // One block per value: its name, the value itself (selectable, wraps) and a copy button beside it.
          children: widget.contents
              .mapIndexed(
                (idx, e) => AppInsetBlock(
                  padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.name, style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
                            sizedBoxW2H2,
                            SelectableText(
                              controllers[idx].text,
                              maxLines: 4,
                              style: textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ),
                      CopyButton(data: controllers[idx].text),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
      ),
      actions: [TextButton(child: Text(tr.close), onPressed: () => context.pop())],
    );
  }
}

/// Show a dialog that shows [data] and allow user select and copy the [data].
Future<void> showCopySelectContentDialog({
  required BuildContext context,
  required String data,
  String? title,
  String? route,
}) async => showDialog(
  context: context,
  builder: (_) => RootPage(route ?? DialogPaths.copyContent, _CopySelectContentDialog(title, data)),
);

/// Dialog showing contents and allow user to select and copy.
///
/// Content showing in this dialog is a [String].
///
/// See also:
///
///  * [_CopyContentDialog], where contents are grouped and attached with description.
class _CopySelectContentDialog extends StatelessWidget {
  /// Constructor.
  const _CopySelectContentDialog(this.title, this.data);

  /// Optional dialog title.
  final String? title;

  /// Data to copy.
  final String data;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.copyDialog;

    return CustomAlertDialog.sync(
      title: Row(
        children: [
          const AppIconTile(Icons.text_snippet_outlined, size: 36),
          sizedBoxW12H12,
          Expanded(child: Text(title ?? tr.copySelectTitle)),
        ],
      ),
      content: AppInsetBlock(padding: edgeInsetsL12T12R12B12, child: SelectableText(data)),
      actions: [
        TextButton.icon(
          icon: const Icon(Icons.share_outlined),
          label: Text(tr.share),
          onPressed: () async {
            await SharePlus.instance.share(ShareParams(text: data));
            if (!context.mounted) {
              return;
            }
            context.pop();
          },
        ),
        FilledButton.icon(
          icon: const Icon(Icons.copy_all_outlined),
          label: Text(tr.copyAll),
          onPressed: () async {
            await copyToClipboard(context, data);
            if (!context.mounted) {
              return;
            }
            context.pop();
          },
        ),
      ],
    );
  }
}
