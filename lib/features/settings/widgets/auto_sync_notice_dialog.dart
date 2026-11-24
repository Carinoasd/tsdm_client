import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Body shared by the duration dialogs of the settings: optional description, the chosen value in a block, a slider
/// between the first and the last choice.
class SettingsDurationSliderBody extends StatelessWidget {
  /// Constructor.
  const SettingsDurationSliderBody({
    required this.valueText,
    required this.firstText,
    required this.lastText,
    required this.index,
    required this.count,
    required this.onChanged,
    this.description,
    super.key,
  });

  /// Optional explanation above the value.
  final String? description;

  /// Text of the chosen value.
  final String valueText;

  /// Text of the first choice, under the start of the slider.
  final String firstText;

  /// Text of the last choice, under the end of the slider.
  final String lastText;

  /// Index of the chosen value.
  final double index;

  /// Number of choices.
  final int count;

  /// Called with the new index.
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final edgeStyle = textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (description != null) ...[
          Text(description!, style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant)),
          sizedBoxW12H12,
        ],
        AppInsetBlock(
          outlined: true,
          padding: edgeInsetsL12T12R12B12,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.schedule_outlined, color: colorScheme.primary),
              sizedBoxW8H8,
              Flexible(
                child: Text(
                  valueText,
                  style: textTheme.titleMedium?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
        sizedBoxW12H12,
        Slider(
          autofocus: true,
          // Since flutter 3.29
          // ignore: deprecated_member_use
          year2023: false,
          max: count.toDouble() - 1,
          value: index,
          divisions: count - 1,
          onChanged: onChanged,
        ),
        Row(
          children: [
            Expanded(child: Text(firstText, style: edgeStyle)),
            Expanded(
              child: Text(lastText, textAlign: TextAlign.end, style: edgeStyle),
            ),
          ],
        ),
      ],
    );
  }
}

/// Dialog for user selecting a duration on auto sync notice feature.
class AutoSyncNoticeDialog extends StatefulWidget {
  /// Constructor.
  const AutoSyncNoticeDialog(this.currentSeconds, {super.key});

  /// Initial seconds when open dialog.
  final int currentSeconds;

  @override
  State<AutoSyncNoticeDialog> createState() => _AutoSyncNoticeDialogState();
}

class _AutoSyncNoticeDialogState extends State<AutoSyncNoticeDialog> {
  late double _choiceIndex;

  static const allTimes = [
    // 1 min
    60,

    // 2 min
    120,

    // 3 min
    180,

    // 5 min
    300,

    // 10 min
    //
    // The default one.
    600,

    // 20 min
    1200,

    // 30 min
    1800,

    // 40 min
    2400,

    // 1 hour
    3600,

    // Never
    -1,
  ];

  @override
  void initState() {
    super.initState();
    _choiceIndex = allTimes.contains(widget.currentSeconds)
        ? allTimes.indexOf(widget.currentSeconds).toDouble()
        // Index of the 10 minutes default.
        : allTimes.indexOf(600).toDouble();
  }

  String _timeText(BuildContext context, int time) => switch (time) {
    < 0 => context.t.general.never,
    >= 0 && < 3600 => context.t.general.minutes(value: time ~/ 60),
    _ => context.t.general.hours(value: time ~/ 3600),
  };

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.behaviorSection.autoSyncNotice;

    final time = allTimes[_choiceIndex.toInt()];

    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.sync_outlined, title: tr.title),
      content: SettingsDurationSliderBody(
        description: tr.detail,
        valueText: _timeText(context, time),
        firstText: _timeText(context, allTimes.first),
        lastText: _timeText(context, allTimes.last),
        index: _choiceIndex,
        count: allTimes.length,
        onChanged: (v) => setState(() => _choiceIndex = v),
      ),
      actions: [
        FilledButton(child: Text(context.t.general.ok), onPressed: () => context.pop(allTimes[_choiceIndex.toInt()])),
      ],
    );
  }
}
