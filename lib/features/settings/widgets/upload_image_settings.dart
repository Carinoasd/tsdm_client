import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/post/utils/image_edits.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';

/// The 發帖 group of the settings: whether images open the editor before every upload, and the size and quality they
/// go up with.
class UploadImageSettingsGroup extends StatelessWidget {
  /// Constructor.
  const UploadImageSettingsGroup(this.settings, {super.key});

  /// The settings now.
  final SettingsMap settings;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.imageUpload.settings;
    final side = settings.uploadImageMaxSide;
    return AppTileGroup(
      title: tr.title,
      icon: Icons.edit_note_outlined,
      children: [
        SectionSwitchListTile(
          key: const ValueKey('settings-edit-image-before-upload'),
          secondary: const Icon(Icons.photo_filter_outlined),
          title: Text(tr.editFirst),
          value: settings.editImageBeforeUpload,
          onChanged: (v) =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.editImageBeforeUpload, v)),
        ),
        SectionListTile(
          key: const ValueKey('settings-upload-image-output'),
          leading: const Icon(Icons.photo_size_select_large_outlined),
          title: Text(tr.output),
          trailing: Text(
            '${side == 0 ? tr.original : side} · ${settings.uploadImageQuality}',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.secondary),
          ),
          onTap: () async {
            final chosen = await showDialog<(int, int)>(
              context: context,
              builder: (_) => RootPage(
                DialogPaths.uploadImageOutput,
                UploadImageOutputDialog(maxSide: side, quality: settings.uploadImageQuality),
              ),
            );
            if (chosen == null || !context.mounted) return;
            context.read<SettingsBloc>()
              ..add(SettingsValueChanged(SettingsKeys.uploadImageMaxSide, chosen.$1))
              ..add(SettingsValueChanged(SettingsKeys.uploadImageQuality, chosen.$2));
          },
        ),
      ],
    );
  }
}

/// Dialog to choose the longest side ([uploadImageMaxSides]) and the JPEG quality images go up with; pops both.
class UploadImageOutputDialog extends StatefulWidget {
  /// Constructor.
  const UploadImageOutputDialog({required this.maxSide, required this.quality, super.key});

  /// The longest side set now.
  final int maxSide;

  /// The quality set now.
  final int quality;

  @override
  State<UploadImageOutputDialog> createState() => _UploadImageOutputDialogState();
}

class _UploadImageOutputDialogState extends State<UploadImageOutputDialog> {
  late int _side = uploadImageMaxSides.contains(widget.maxSide) ? widget.maxSide : 0;
  late double _quality = widget.quality.clamp(10, 100).toDouble();

  @override
  Widget build(BuildContext context) {
    final tr = context.t.imageUpload.settings;
    final labelStyle = Theme.of(context).textTheme.labelLarge;
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.photo_size_select_large_outlined, title: tr.output),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr.longSide, style: labelStyle),
          sizedBoxW8H8,
          SegmentedButton<int>(
            segments: [
              for (final side in uploadImageMaxSides)
                ButtonSegment(value: side, label: Text(side == 0 ? tr.original : '$side')),
            ],
            selected: {_side},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _side = v.first),
          ),
          sizedBoxW16H16,
          Row(
            children: [
              Text(tr.quality, style: labelStyle),
              const Spacer(),
              Text('${_quality.round()}', style: labelStyle),
            ],
          ),
          Slider(
            value: _quality,
            min: 10,
            max: 100,
            divisions: 18,
            label: '${_quality.round()}',
            onChanged: (v) => setState(() => _quality = v),
          ),
        ],
      ),
      actions: [
        FilledButton(child: Text(context.t.general.ok), onPressed: () => context.pop((_side, _quality.round()))),
      ],
    );
  }
}
