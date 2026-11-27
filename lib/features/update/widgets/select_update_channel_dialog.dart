import 'package:flutter/material.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/update/models/update_channel.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/selectable_list_tile.dart';

/// The name of the update [channel].
String updateChannelName(BuildContext context, UpdateChannel channel) {
  final tr = context.t.updatePage.channel;
  return switch (channel) {
    UpdateChannel.auto => tr.auto,
    UpdateChannel.mirror => tr.mirror,
    UpdateChannel.github => tr.github,
  };
}

/// Show a dialog to let user select where the update check asks for the latest version, [current] selected.
Future<UpdateChannel?> showSelectUpdateChannelDialog(BuildContext context, UpdateChannel current) async =>
    showDialog<UpdateChannel>(
      context: context,
      builder: (context) => RootPage(DialogPaths.selectUpdateChannel, _SelectUpdateChannelDialog(current)),
    );

class _SelectUpdateChannelDialog extends StatelessWidget {
  const _SelectUpdateChannelDialog(this.current);

  final UpdateChannel current;

  @override
  Widget build(BuildContext context) {
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.alt_route_outlined, title: context.t.updatePage.channel.title),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final channel in UpdateChannel.values)
            SelectableListTile(
              key: ValueKey('update-channel-${channel.name}'),
              title: Text(updateChannelName(context, channel)),
              selected: current == channel,
              onTap: () => Navigator.of(context).pop(channel),
            ),
        ],
      ),
      contentPadding: EdgeInsets.zero,
    );
  }
}
