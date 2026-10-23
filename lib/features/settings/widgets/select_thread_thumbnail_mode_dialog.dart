import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/selectable_list_tile.dart';

/// The name of the thumbnail [mode] of the thread lists, for the settings.
String threadThumbnailModeName(BuildContext context, ThreadThumbnailMode mode) {
  final tr = context.t.settingsPage.appearanceSection.threadCard.listPreview.thumbnail;
  return switch (mode) {
    ThreadThumbnailMode.always => tr.always,
    ThreadThumbnailMode.wifiOnly => tr.wifiOnly,
    ThreadThumbnailMode.never => tr.never,
  };
}

/// Show a dialog to let user select when the thread lists show the thumbnails of the threads, [initialMode] selected.
Future<ThreadThumbnailMode?> showSelectThreadThumbnailModeDialog(
  BuildContext context,
  ThreadThumbnailMode initialMode,
) async => showDialog<ThreadThumbnailMode>(
  context: context,
  builder: (context) => RootPage(DialogPaths.selectThreadThumbnailMode, _SelectThreadThumbnailModeDialog(initialMode)),
);

class _SelectThreadThumbnailModeDialog extends StatelessWidget {
  const _SelectThreadThumbnailModeDialog(this.initialMode);

  final ThreadThumbnailMode initialMode;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.threadCard.listPreview.thumbnail;
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.image_outlined, title: tr.title),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (mode, icon, detail) in [
            (ThreadThumbnailMode.always, Icons.image_outlined, tr.alwaysDetail),
            (ThreadThumbnailMode.wifiOnly, Icons.wifi_outlined, tr.wifiOnlyDetail),
            (ThreadThumbnailMode.never, Icons.hide_image_outlined, tr.neverDetail),
          ])
            SelectableListTile(
              key: ValueKey('thread-thumbnail-mode-${mode.name}'),
              leading: initialMode == mode ? null : Icon(icon),
              title: Text(threadThumbnailModeName(context, mode)),
              subtitle: Text(detail),
              selected: initialMode == mode,
              onTap: () => context.pop(mode),
            ),
        ],
      ),
      contentPadding: EdgeInsets.zero,
    );
  }
}
