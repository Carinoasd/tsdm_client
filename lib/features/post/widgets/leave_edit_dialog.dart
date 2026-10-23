import 'package:flutter/material.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// What to do with the content of the editor when leaving it.
enum LeaveEditChoice {
  /// Leave, dropping the content.
  discard,

  /// Save the content in the forum's draft box, then leave.
  saveDraft,

  /// Leave, the content kept on this device as the local draft of the editor (offered again when it opens).
  keepDraft,

  /// Stay in the editor.
  keepEditing,
}

/// Ask what to do with the content not sent yet when leaving the editor: discard it, save it as a draft (only offered
/// with [canSaveDraft]), leave with it kept on this device (only offered with [keepsLocalDraft], the editor keeps one)
/// or keep editing. Dismissing the dialog keeps editing.
Future<LeaveEditChoice> showLeaveEditDialog(
  BuildContext context, {
  required bool canSaveDraft,
  bool keepsLocalDraft = false,
}) async {
  final choice = await showDialog<LeaveEditChoice>(
    context: context,
    builder: (context) {
      final tr = context.t.postEditPage.leaveDialog;
      return RootPage(
        DialogPaths.question,
        CustomAlertDialog.sync(
          title: AppDialogTitle(icon: Icons.edit_note_outlined, title: tr.title),
          content: Text(keepsLocalDraft ? tr.messageLocal : tr.message),
          actions: [
            TextButton(
              key: const ValueKey('leave-edit-discard'),
              onPressed: () => Navigator.pop(context, LeaveEditChoice.discard),
              child: Text(tr.discard, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
            if (canSaveDraft)
              TextButton(
                key: const ValueKey('leave-edit-save-draft'),
                onPressed: () => Navigator.pop(context, LeaveEditChoice.saveDraft),
                child: Text(tr.saveDraft),
              ),
            if (keepsLocalDraft) ...[
              TextButton(
                key: const ValueKey('leave-edit-keep'),
                onPressed: () => Navigator.pop(context, LeaveEditChoice.keepEditing),
                child: Text(tr.keepEditing),
              ),
              FilledButton(
                key: const ValueKey('leave-edit-keep-draft'),
                onPressed: () => Navigator.pop(context, LeaveEditChoice.keepDraft),
                child: Text(tr.keepDraft),
              ),
            ] else
              FilledButton(
                key: const ValueKey('leave-edit-keep'),
                onPressed: () => Navigator.pop(context, LeaveEditChoice.keepEditing),
                child: Text(tr.keepEditing),
              ),
          ],
        ),
      );
    },
  );
  return choice ?? LeaveEditChoice.keepEditing;
}
