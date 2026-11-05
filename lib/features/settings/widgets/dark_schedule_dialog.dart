import 'package:flutter/material.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/theme/dark_schedule.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';

/// Show a dialog to set the hours of the day the app is dark, starting from [initial]; the hours chosen, or null.
Future<DarkSchedule?> showDarkScheduleDialog(BuildContext context, DarkSchedule initial) async =>
    showDialog<DarkSchedule>(
      context: context,
      builder: (context) => RootPage(DialogPaths.darkSchedule, DarkScheduleDialog(initial)),
    );

/// Dialog to set the hours of the day the app is dark: a start and an end, each picked with a time picker; pops the
/// [DarkSchedule] on OK.
class DarkScheduleDialog extends StatefulWidget {
  /// Constructor.
  const DarkScheduleDialog(this.initial, {super.key});

  /// The hours set now.
  final DarkSchedule initial;

  @override
  State<DarkScheduleDialog> createState() => _DarkScheduleDialogState();
}

class _DarkScheduleDialogState extends State<DarkScheduleDialog> {
  late DarkSchedule _schedule;

  @override
  void initState() {
    super.initState();
    _schedule = widget.initial;
  }

  Future<void> _pick({required bool start}) async {
    final minutes = start ? _schedule.start : _schedule.end;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minutes ~/ 60 % 24, minute: minutes % 60),
      builder: (context, child) =>
          MediaQuery(data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true), child: child!),
    );
    if (picked == null || !mounted) {
      return;
    }
    final value = picked.hour * 60 + picked.minute;
    setState(() {
      _schedule = DarkSchedule(start: start ? value : _schedule.start, end: start ? _schedule.end : value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.darkSchedule;
    final timeStyle = Theme.of(context).textTheme.bodyLarge;
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.schedule_outlined, title: tr.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionListTile(
            key: const ValueKey('dark-schedule-start'),
            leading: const Icon(Icons.dark_mode_outlined),
            title: Text(tr.start),
            trailing: Text(DarkSchedule.timeText(_schedule.start), style: timeStyle),
            onTap: () async => _pick(start: true),
          ),
          SectionListTile(
            key: const ValueKey('dark-schedule-end'),
            leading: const Icon(Icons.light_mode_outlined),
            title: Text(tr.end),
            trailing: Text(DarkSchedule.timeText(_schedule.end), style: timeStyle),
            onTap: () async => _pick(start: false),
          ),
        ],
      ),
      contentPadding: EdgeInsets.zero,
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        // The same start and end would be an empty window, by time would then mean always light.
        FilledButton(
          onPressed: _schedule.start == _schedule.end ? null : () => Navigator.of(context).pop(_schedule),
          child: Text(context.t.general.ok),
        ),
      ],
    );
  }
}
