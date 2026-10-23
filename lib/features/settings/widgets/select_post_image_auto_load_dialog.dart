import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/post_image_auto_load.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/selectable_list_tile.dart';

/// The name of [value] in the settings.
String postImageAutoLoadLabel(BuildContext context, PostImageAutoLoad value) {
  final tr = context.t.settingsPage.behaviorSection.postImageAutoLoad;
  return switch (value) {
    PostImageAutoLoad.always => tr.always,
    PostImageAutoLoad.wifiOnly => tr.wifiOnly,
    PostImageAutoLoad.never => tr.never,
  };
}

/// Show a dialog to let user select when the pictures of the posts load by themselves.
Future<PostImageAutoLoad?> showSelectPostImageAutoLoad(BuildContext context, PostImageAutoLoad initial) async =>
    showDialog<PostImageAutoLoad>(
      context: context,
      builder: (context) => RootPage(DialogPaths.selectPostImageAutoLoad, _SelectPostImageAutoLoadDialog(initial)),
    );

class _SelectPostImageAutoLoadDialog extends StatelessWidget {
  const _SelectPostImageAutoLoadDialog(this.initial);

  final PostImageAutoLoad initial;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.behaviorSection.postImageAutoLoad;
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.image_outlined, title: tr.title),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: edgeInsetsL24R24.add(const EdgeInsets.only(bottom: 8)),
            child: Text(
              tr.detail,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
          for (final value in PostImageAutoLoad.values)
            SelectableListTile(
              key: ValueKey('post-image-auto-load-${value.name}'),
              leading: initial == value
                  ? null
                  : Icon(switch (value) {
                      PostImageAutoLoad.always => Icons.image_outlined,
                      PostImageAutoLoad.wifiOnly => Icons.wifi_outlined,
                      PostImageAutoLoad.never => Icons.touch_app_outlined,
                    }),
              title: Text(postImageAutoLoadLabel(context, value)),
              selected: initial == value,
              onTap: () => context.pop(value),
            ),
        ],
      ),
      contentPadding: EdgeInsets.zero,
    );
  }
}
