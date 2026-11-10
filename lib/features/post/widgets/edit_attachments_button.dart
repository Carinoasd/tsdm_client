import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/remove_rate.dart';
import 'package:tsdm_client/features/moderate/repository/floor_ops_repository.dart';
import 'package:tsdm_client/features/post/utils/edit_attachments.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// The attachments of the edited post (the website's attachment list of the edit page): a button with their count,
/// opening the list, where each one is deleted (the post's author, a moderator of the forum: the forum decides).
///
/// The forum deletes an attachment right away, whether the edit is saved or not: each deletion is confirmed and sent
/// once; [onDeleted] is called with the attachment once the forum deleted it.
class EditAttachmentsButton extends StatelessWidget {
  /// Constructor.
  const EditAttachmentsButton({
    required this.attachments,
    required this.tid,
    required this.pid,
    required this.formHash,
    required this.formUid,
    required this.onDeleted,
    this.repository,
    super.key,
  });

  /// The attachments of the post.
  final List<EditAttachment> attachments;

  /// The thread.
  final String tid;

  /// The post.
  final String pid;

  /// The form hash the edit page was served with.
  final String formHash;

  /// The account the edit page was served to.
  final int formUid;

  /// Called with the attachment the forum deleted.
  final void Function(int aid) onDeleted;

  /// Where the deletion goes; the network by default.
  final FloorOpsRepository? repository;

  @override
  Widget build(BuildContext context) => Badge(
    label: Text('${attachments.length}'),
    offset: const Offset(-4, 4),
    child: IconButton(
      icon: const Icon(Icons.attach_file_outlined),
      tooltip: context.t.moderateFloorOps.attachments,
      onPressed: () async => showModalBottomSheet<void>(
        context: context,
        // Closed by a tap outside or back only: the list stays while a deletion is out (dragging it down would close it
        // past its PopScope).
        enableDrag: false,
        builder: (_) => _AttachmentList(
          attachments: attachments,
          tid: tid,
          pid: pid,
          formHash: formHash,
          formUid: formUid,
          onDeleted: onDeleted,
          repository: repository ?? FloorOpsRepository.network(),
        ),
      ),
    ),
  );
}

class _AttachmentList extends StatefulWidget {
  const _AttachmentList({
    required this.attachments,
    required this.tid,
    required this.pid,
    required this.formHash,
    required this.formUid,
    required this.onDeleted,
    required this.repository,
  });

  final List<EditAttachment> attachments;
  final String tid;
  final String pid;
  final String formHash;
  final int formUid;
  final void Function(int aid) onDeleted;
  final FloorOpsRepository repository;

  @override
  State<_AttachmentList> createState() => _AttachmentListState();
}

class _AttachmentListState extends State<_AttachmentList> {
  late final List<EditAttachment> _left = List.of(widget.attachments);

  /// The attachment being deleted.
  int? _deleting;

  Future<void> _delete(EditAttachment attachment) async {
    final tr = context.t.moderateFloorOps;
    final confirmed = await showQuestionDialog(
      context: context,
      title: tr.deleteAttachment,
      message: attachment.filename.isNotEmpty ? attachment.filename : '${attachment.aid}',
      dangerous: true,
    );
    if (!(confirmed ?? false) || !mounted || _deleting != null) {
      return;
    }
    setState(() => _deleting = attachment.aid);
    final outcome = await widget.repository
        .deleteAttachment(
          tid: widget.tid,
          pid: widget.pid,
          aid: attachment.aid,
          formHash: widget.formHash,
          formUid: widget.formUid,
        )
        .run();
    // The forum deleted it whatever became of the list: the editor learns it even when the list was closed.
    if (outcome case Right(value: FloorOpSucceeded())) {
      widget.onDeleted(attachment.aid);
    }
    if (!mounted) {
      return;
    }
    setState(() => _deleting = null);
    switch (outcome) {
      case Right(value: FloorOpSucceeded()):
        setState(() => _left.removeWhere((e) => e.aid == attachment.aid));
        if (_left.isEmpty) {
          Navigator.of(context).pop();
        }
      case Right(value: FloorOpRefused(:final message)):
        showSnackBar(context: context, message: message.isNotEmpty ? message : context.t.moderate.failed);
      case Left(:final value):
        showSnackBar(
          context: context,
          message: value is IdentityChangedException
              ? context.t.general.accountChangedRetry
              : context.t.moderate.failed,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // Stays while a deletion is out, so its answer is shown.
    return PopScope(
      canPop: _deleting == null,
      child: SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final attachment in _left)
              ListTile(
                leading: Icon(attachment.isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined),
                title: Text(
                  attachment.filename.isNotEmpty ? attachment.filename : '${attachment.aid}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: _deleting == attachment.aid
                    ? const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : IconButton(
                        icon: Icon(Icons.delete_outline, color: colorScheme.error),
                        tooltip: context.t.moderateFloorOps.deleteAttachment,
                        onPressed: _deleting == null ? () async => _delete(attachment) : null,
                      ),
              ),
          ],
        ),
      ),
    );
  }
}
