import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/post/widgets/activity_dialog.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Ask when a new thread is published, from [initial] (null for now).
///
/// Returns the time chosen (`at` null to publish now), null when cancelled.
Future<({DateTime? at})?> showCronPublishDialog(BuildContext context, DateTime? initial) async =>
    showDialog<({DateTime? at})>(
      context: context,
      builder: (_) => RootPage(DialogPaths.cronPublish, _CronPublishDialog(initial)),
    );

/// Whether [at] is a time the forum publishes a thread later: ahead of [now] (a time passed publishes it at once).
bool cronPublishAhead(DateTime at, DateTime now) => at.isAfter(now);

class _CronPublishDialog extends StatefulWidget {
  const _CronPublishDialog(this.initial);

  final DateTime? initial;

  @override
  State<_CronPublishDialog> createState() => _CronPublishDialogState();
}

class _CronPublishDialogState extends State<_CronPublishDialog> {
  late DateTime? at = widget.initial;

  /// The dialog was confirmed once: the issue of the time is shown from then on.
  bool _checked = false;

  bool get _valid => at == null || cronPublishAhead(at!, DateTime.now());

  @override
  Widget build(BuildContext context) {
    final tr = context.t.postEditPage.cronPublish;
    return CustomAlertDialog.sync(
      title: Row(
        children: [
          const AppIconTile(Icons.schedule_outlined, size: 36),
          sizedBoxW12H12,
          Expanded(child: Text(tr.title)),
        ],
      ),
      content: DateTimeField(
        label: tr.time,
        value: at,
        onChanged: (v) => setState(() => at = v),
        onCleared: () => setState(() => at = null),
        errorText: _checked && !_valid ? tr.passed : null,
      ),
      actions: [
        TextButton(child: Text(context.t.general.cancel), onPressed: () => context.pop()),
        FilledButton(
          child: Text(context.t.general.ok),
          onPressed: () {
            setState(() => _checked = true);
            if (_valid) {
              context.pop((at: at));
            }
          },
        ),
      ],
    );
  }
}
