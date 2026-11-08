import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_converter.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/selectable_list_tile.dart';

/// The name of the display [mode] of Chinese text, for the settings.
String chineseDisplayModeName(BuildContext context, ChineseDisplayMode mode) {
  final tr = context.t.settingsPage.appearanceSection.chineseDisplay;
  return switch (mode) {
    ChineseDisplayMode.off => tr.off,
    ChineseDisplayMode.traditional => tr.traditional,
    ChineseDisplayMode.simplified => tr.simplified,
  };
}

/// Show a dialog to let user select the script Chinese text is shown in, [initialMode] selected.
Future<ChineseDisplayMode?> showSelectChineseDisplayDialog(
  BuildContext context,
  ChineseDisplayMode initialMode,
) async => showDialog<ChineseDisplayMode>(
  context: context,
  builder: (context) => RootPage(DialogPaths.selectChineseDisplay, _SelectChineseDisplayDialog(initialMode)),
);

class _SelectChineseDisplayDialog extends StatelessWidget {
  const _SelectChineseDisplayDialog(this.initialMode);

  final ChineseDisplayMode initialMode;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.chineseDisplay;
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.translate_outlined, title: tr.title),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final mode in ChineseDisplayMode.values)
            SelectableListTile(
              key: ValueKey('chinese-display-mode-${mode.name}'),
              title: Text(chineseDisplayModeName(context, mode)),
              selected: initialMode == mode,
              onTap: () => context.pop(mode),
            ),
        ],
      ),
      contentPadding: EdgeInsets.zero,
    );
  }
}
