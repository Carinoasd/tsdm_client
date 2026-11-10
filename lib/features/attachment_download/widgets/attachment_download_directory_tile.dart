import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/attachment_download/utils/download_location.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';

/// The folder the attachments are downloaded to (Windows, Linux, see [canChooseDownloadDirectory]): its path, a tap
/// picks another, the button beside a chosen one goes back to the downloads folder.
class AttachmentDownloadDirectoryTile extends StatefulWidget {
  /// Constructor.
  const AttachmentDownloadDirectoryTile({super.key});

  @override
  State<AttachmentDownloadDirectoryTile> createState() => _AttachmentDownloadDirectoryTileState();
}

class _AttachmentDownloadDirectoryTileState extends State<AttachmentDownloadDirectoryTile> {
  String? _shown;
  String? _shownFor;

  void _resolve(String chosen) {
    if (_shownFor == chosen) {
      return;
    }
    _shownFor = chosen;
    unawaited(
      attachmentDownloadDirectory(chosen: chosen).then((dir) {
        if (mounted && _shownFor == chosen) {
          setState(() => _shown = dir.path);
        }
      }),
    );
  }

  Future<void> _pick(BuildContext context) async {
    final title = context.t.settingsPage.storageSection.attachmentDownloadDirectory;
    final picked = await FilePicker.platform.getDirectoryPath(dialogTitle: title);
    if (picked == null || !context.mounted) {
      return;
    }
    context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.attachmentDownloadDirectory, picked));
  }

  @override
  Widget build(BuildContext context) {
    final chosen = context.select<SettingsBloc, String>((e) => e.state.settingsMap.attachmentDownloadDirectory);
    _resolve(chosen);
    return SectionListTile(
      key: const ValueKey('settings-attachment-download-directory'),
      leading: const Icon(Icons.folder_outlined),
      title: Text(context.t.settingsPage.storageSection.attachmentDownloadDirectory),
      subtitle: _shown == null ? null : Text(_shown!),
      trailing: chosen.isEmpty
          ? null
          : IconButton(
              icon: const Icon(Icons.restart_alt),
              onPressed: () => context.read<SettingsBloc>().add(
                const SettingsValueChanged(SettingsKeys.attachmentDownloadDirectory, ''),
              ),
            ),
      onTap: () async => _pick(context),
    );
  }
}
