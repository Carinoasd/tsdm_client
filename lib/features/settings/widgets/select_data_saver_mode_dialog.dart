import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/data_saver_mode.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/selectable_list_tile.dart';

/// The name of [value] in the settings.
String dataSaverModeLabel(BuildContext context, DataSaverMode value) {
  final tr = context.t.settingsPage.othersSection.dataSaver;
  return switch (value) {
    DataSaverMode.off => tr.off,
    DataSaverMode.meteredOnly => tr.meteredOnly,
    DataSaverMode.always => tr.always,
  };
}

/// Show a dialog to let user select when the data saver holds the large pictures back.
Future<DataSaverMode?> showSelectDataSaverMode(BuildContext context, DataSaverMode initial) async =>
    showDialog<DataSaverMode>(
      context: context,
      builder: (context) => RootPage(DialogPaths.selectDataSaverMode, _SelectDataSaverModeDialog(initial)),
    );

class _SelectDataSaverModeDialog extends StatelessWidget {
  const _SelectDataSaverModeDialog(this.initial);

  final DataSaverMode initial;

  @override
  Widget build(BuildContext context) {
    return CustomAlertDialog.sync(
      title: AppDialogTitle(
        icon: Icons.data_saver_on_outlined,
        title: context.t.settingsPage.othersSection.dataSaver.title,
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final value in DataSaverMode.values)
            SelectableListTile(
              key: ValueKey('data-saver-mode-${value.name}'),
              leading: initial == value
                  ? null
                  : Icon(switch (value) {
                      DataSaverMode.off => Icons.image_outlined,
                      DataSaverMode.meteredOnly => Icons.signal_cellular_alt_outlined,
                      DataSaverMode.always => Icons.data_saver_on_outlined,
                    }),
              title: Text(dataSaverModeLabel(context, value)),
              selected: initial == value,
              onTap: () => context.pop(value),
            ),
        ],
      ),
      contentPadding: EdgeInsets.zero,
    );
  }
}
