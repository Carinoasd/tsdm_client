import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/thread_open_position.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/selectable_list_tile.dart';

/// The words for [position] in the settings.
String threadOpenPositionLabel(BuildContext context, ThreadOpenPosition position) {
  final tr = context.t.settingsPage.behaviorSection.threadOpenPosition;
  return switch (position) {
    ThreadOpenPosition.fromStart => tr.fromStart,
    ThreadOpenPosition.ask => tr.ask,
    ThreadOpenPosition.resume => tr.resume,
  };
}

/// Show a dialog to let user select where a thread read before opens from a list.
Future<ThreadOpenPosition?> showSelectThreadOpenPosition(BuildContext context, ThreadOpenPosition initial) async =>
    showDialog<ThreadOpenPosition>(
      context: context,
      builder: (context) => RootPage(DialogPaths.selectThreadOpenPosition, _SelectThreadOpenPositionDialog(initial)),
    );

class _SelectThreadOpenPositionDialog extends StatelessWidget {
  const _SelectThreadOpenPositionDialog(this.initial);

  final ThreadOpenPosition initial;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.behaviorSection.threadOpenPosition;
    const icons = {
      ThreadOpenPosition.fromStart: Icons.vertical_align_top_outlined,
      ThreadOpenPosition.ask: Icons.help_outline,
      ThreadOpenPosition.resume: Icons.bookmark_outline,
    };
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.bookmark_outline, title: tr.title),
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
          for (final position in ThreadOpenPosition.values)
            SelectableListTile(
              key: ValueKey('thread-open-position-${position.name}'),
              leading: initial == position ? null : Icon(icons[position]),
              title: Text(threadOpenPositionLabel(context, position)),
              selected: initial == position,
              onTap: () => Navigator.of(context).pop(position),
            ),
        ],
      ),
      contentPadding: EdgeInsets.zero,
    );
  }
}
