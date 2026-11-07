import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Smallest text scale offered.
const textScaleFactorMin = 0.7;

/// Largest text scale offered.
const textScaleFactorMax = 1.5;

/// Dialog to show available text scale options as a chooser.
class TextScaleDialog extends StatefulWidget {
  /// Constructor.
  const TextScaleDialog(this.initialScale, {super.key});

  /// Text scale factor when enter this widget.
  final double initialScale;

  @override
  State<TextScaleDialog> createState() => _TextScaleDialogState();
}

class _TextScaleDialogState extends State<TextScaleDialog> {
  late double _currentScale;

  @override
  void initState() {
    super.initState();
    _currentScale = widget.initialScale;
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.appearanceSection.textScaleFactor;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.text_increase_outlined, title: tr.dialogTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          Text(
            '${_currentScale}x',
            textAlign: TextAlign.center,
            style: textTheme.headlineSmall?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold),
          ),
          // Preview at the chosen factor, on top of the scale the system already applies.
          AppInsetBlock(
            outlined: true,
            padding: edgeInsetsL12T12R12B12,
            child: Text(
              context.t.appName,
              textScaler: TextScaler.linear(MediaQuery.textScalerOf(context).scale(1) * _currentScale),
              style: textTheme.bodyMedium,
            ),
          ),
          Row(
            children: [
              Icon(Icons.text_decrease_outlined, size: 18, color: colorScheme.outline),
              Expanded(
                child: Slider(
                  autofocus: true,
                  // Since flutter 3.29
                  // ignore: deprecated_member_use
                  year2023: false,
                  min: textScaleFactorMin,
                  max: textScaleFactorMax,
                  divisions: 8,
                  value: _currentScale,
                  label: '${_currentScale}x',
                  onChanged: (v) => setState(() => _currentScale = double.parse(v.toStringAsFixed(2))),
                ),
              ),
              Icon(Icons.text_increase_outlined, size: 18, color: colorScheme.outline),
            ],
          ),
        ],
      ),
      actions: [FilledButton(onPressed: () => context.pop(_currentScale), child: Text(context.t.general.ok))],
    );
  }
}
