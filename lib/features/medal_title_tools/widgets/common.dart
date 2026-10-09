import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/medal_title_tools/models/models.dart';
import 'package:tsdm_client/features/medal_title_tools/repository/medal_title_tools_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';

/// Date and time of [seconds] (`yyyy-MM-dd HH:mm`, device time).
String toolsDateTime(int seconds) {
  final t = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// Date of [seconds] (`yyyy-MM-dd`, device time).
String toolsDate(int seconds) => toolsDateTime(seconds).substring(0, 10);

/// The image of a medal or a title in a [width] × [height] box, contained.
class ToolsImage extends StatelessWidget {
  /// Constructor.
  const ToolsImage(this.url, {required this.width, required this.height, super.key});

  /// Image URL.
  final String? url;

  /// Box width.
  final double width;

  /// Box height.
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: url == null
        ? Icon(Icons.image_not_supported_outlined, color: Theme.of(context).colorScheme.outline)
        : CachedImage(url!, width: width, height: height, fit: BoxFit.contain),
  );
}

/// The page body of a list page: centred and as wide as the forms of the app.
class ToolsBody extends StatelessWidget {
  /// Constructor.
  const ToolsBody({required this.children, this.onRefresh, super.key});

  /// Content.
  final List<Widget> children;

  /// Pull to refresh.
  final Future<void> Function()? onRefresh;

  @override
  Widget build(BuildContext context) {
    final list = Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: appFormMaxWidth),
        child: ListView(padding: edgeInsetsL16T16R16B16, children: children),
      ),
    );
    return SafeArea(
      top: false,
      child: onRefresh == null ? list : RefreshIndicator(onRefresh: onRefresh!, child: list),
    );
  }
}

/// What a page shows when it has no data: loading, failed (with retry), not supported (with the website), refused.
class ToolsStateView extends StatelessWidget {
  /// Constructor.
  const ToolsStateView({required this.onRetry, this.failed = false, this.message, this.webUrl, super.key});

  /// Retry.
  final VoidCallback onRetry;

  /// Loading failed.
  final bool failed;

  /// A message instead (not supported, no permission).
  final String? message;

  /// The website page, for a message.
  final String? webUrl;

  @override
  Widget build(BuildContext context) {
    if (failed) {
      return Center(child: buildRetryButton(context, onRetry, message: context.t.general.failedToLoad));
    }
    if (message case final m?) {
      return AppStateView(
        icon: Icons.info_outline,
        message: m,
        action: webUrl == null
            ? null
            : TextButton.icon(
                onPressed: () async => context.dispatchAsUrl(webUrl!, external: true),
                icon: const Icon(Icons.open_in_browser_outlined),
                label: Text(context.t.general.openInBrowser),
              ),
      );
    }
    return const Center(child: CircularProgressIndicator());
  }
}

/// Previous／next of a paged list.
class ToolsPager extends StatelessWidget {
  /// Constructor.
  const ToolsPager({required this.paging, required this.onPage, this.enabled = true, super.key});

  /// Paging.
  final ApiPaging paging;

  /// Go to a page.
  final ValueChanged<int> onPage;

  /// Buttons enabled.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    if (paging.pages <= 1) return const SizedBox.shrink();
    final tr = context.t.medalTitleTools;
    return Padding(
      padding: const EdgeInsets.only(top: appSurfaceGap),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          TextButton.icon(
            onPressed: enabled && paging.page > 1 ? () => onPage(paging.page - 1) : null,
            icon: const Icon(Icons.chevron_left),
            label: Text(tr.previous),
          ),
          Text(tr.page(page: paging.page, pages: paging.pages)),
          TextButton.icon(
            onPressed: enabled && paging.page < paging.pages ? () => onPage(paging.page + 1) : null,
            icon: const Icon(Icons.chevron_right),
            label: Text(tr.next),
          ),
        ],
      ),
    );
  }
}

/// Ask before a write: [title], [content] and the [confirm] button; true when confirmed.
Future<bool> showToolsConfirm(
  BuildContext context, {
  required String title,
  required List<Widget> content,
  required String confirm,
  bool destructive = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: content,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.general.cancel)),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirm),
          ),
        ],
      ),
    ) ??
    false;

/// Show the forum's answer to a form; an exception becomes the "could not confirm" message.
Future<void> showFormResult(BuildContext context, Future<FormResult> Function() send) async {
  final fallback = context.t.medalTitleTools.unconfirmed;
  String message;
  try {
    final r = await send();
    message = r.message.isEmpty ? fallback : r.message;
  } on Exception {
    message = fallback;
  }
  if (context.mounted) showSnackBar(context: context, message: message);
}
