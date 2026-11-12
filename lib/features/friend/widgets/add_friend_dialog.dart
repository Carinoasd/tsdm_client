import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// What the user filled in: the note and the group.
typedef AddFriendChoice = ({String note, String gid});

/// Longest note the forum accepts ("最多 10 个字").
const addFriendNoteMaxLength = 10;

/// Send a friend request to [uid] the way the forum's popup does: load the form, let the user write a note and pick a
/// group, submit, and show the forum's answer. A refusal (already friends, request pending, oneself) is shown as is.
Future<void> showAddFriendDialog(
  BuildContext context, {
  required String uid,
  String? username,
  FriendRepository repository = const FriendRepository(),
}) async {
  final tr = context.t.friendPage.addFriend;
  final formResult = await repository.fetchAddFriendForm(uid).run();
  if (!context.mounted) {
    return;
  }
  final AddFriendForm form;
  switch (formResult) {
    case Left():
      showSnackBar(context: context, message: tr.failed);
      return;
    case Right(value: AddFriendRefused(:final message)):
      showSnackBar(context: context, message: context.displayText(message));
      return;
    case Right(value: final AddFriendForm f):
      form = f;
  }
  final choice = await showDialog<AddFriendChoice>(
    context: context,
    builder: (_) => AddFriendDialog(form: form, username: username ?? form.targetName),
  );
  if (choice == null || !context.mounted) {
    return;
  }
  final result = await repository
      .addFriend(uid: uid, formHash: form.formHash, note: choice.note, gid: choice.gid)
      .run();
  if (!context.mounted) {
    return;
  }
  showSnackBar(
    context: context,
    message: switch (result) {
      Left() => tr.failed,
      // The app's own words when the forum said nothing (see parseAddFriendResult) stay as they are.
      Right(:final value) when value.message == tr.sent || value.message == tr.failed => value.message,
      Right(:final value) => context.displayText(value.message),
    },
  );
}

/// The note and group dialog; pops with an [AddFriendChoice], or null when cancelled.
class AddFriendDialog extends StatefulWidget {
  /// Constructor.
  const AddFriendDialog({required this.form, required this.username, super.key});

  /// The form loaded from the forum.
  final AddFriendForm form;

  /// Name of the member to add.
  final String username;

  @override
  State<AddFriendDialog> createState() => _AddFriendDialogState();
}

class _AddFriendDialogState extends State<AddFriendDialog> {
  final note = TextEditingController();
  late String gid = widget.form.selectedGid;

  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop((note: note.text.trim(), gid: gid));

  @override
  Widget build(BuildContext context) {
    final tr = context.t.friendPage.addFriend;
    final border = OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius));
    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          const AppIconTile(Icons.person_add_alt_outlined, size: 36),
          sizedBoxW12H12,
          Expanded(child: Text(tr.title(name: widget.username))),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: note,
            autofocus: true,
            maxLength: addFriendNoteMaxLength,
            decoration: InputDecoration(
              labelText: tr.note,
              helperText: widget.form.noteHint,
              helperMaxLines: 3,
              prefixIcon: const Icon(Icons.edit_note_outlined),
              filled: true,
              border: border,
            ),
            onSubmitted: (_) => _submit(),
          ),
          if (widget.form.groups.isNotEmpty) ...[
            sizedBoxW8H8,
            DropdownButtonFormField<String>(
              initialValue: gid,
              isExpanded: true,
              borderRadius: BorderRadius.circular(appInnerRadius),
              decoration: InputDecoration(
                labelText: tr.group,
                prefixIcon: const Icon(Icons.group_outlined),
                filled: true,
                border: border,
              ),
              items: [
                for (final group in widget.form.groups)
                  DropdownMenuItem(
                    value: group.gid,
                    child: Text(context.displayText(group.name), overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (v) => setState(() => gid = v ?? gid),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton.icon(onPressed: _submit, icon: const Icon(Icons.send_outlined), label: Text(tr.send)),
      ],
    );
  }
}
