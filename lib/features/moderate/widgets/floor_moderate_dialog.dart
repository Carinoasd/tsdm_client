import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Icon of a floor's operation.
IconData floorModerateIcon(FloorModerateAction action, {bool undo = false}) => switch (action) {
  FloorModerateAction.delete => Icons.delete_outline,
  FloorModerateAction.warn => undo ? Icons.report_off_outlined : Icons.report_outlined,
  FloorModerateAction.ban => undo ? Icons.visibility_outlined : Icons.visibility_off_outlined,
  FloorModerateAction.stick => undo ? Icons.vertical_align_center_outlined : Icons.vertical_align_top_outlined,
};

/// Name of a floor's operation; [undo] names taking the warning or the hiding back.
String floorModerateName(BuildContext context, FloorModerateAction action, {bool undo = false}) {
  final tr = context.t.moderate;
  return switch (action) {
    FloorModerateAction.delete => tr.deletePost,
    FloorModerateAction.warn => undo ? tr.unwarn : tr.warn,
    FloorModerateAction.ban => undo ? tr.unban : tr.ban,
    FloorModerateAction.stick => undo ? context.t.moderateFloorOps.unstick : context.t.moderateFloorOps.stick,
  };
}

/// The operations offered on a floor: warn, hide, stick, and the deletion of a reply last (stick and delete not on the
/// [first] floor: the forum sticks replies only, and the first floor's deletion is the thread's).
List<FloorModerateAction> floorModerateActionsFor({required bool first}) => [
  FloorModerateAction.warn,
  FloorModerateAction.ban,
  if (!first) FloorModerateAction.stick,
  if (!first) FloorModerateAction.delete,
];

/// Do [action] on floor [pid] of thread [tid] in forum [fid]: the forum's window of it, confirmed by the moderator,
/// sent once. True once the forum carried it out; [onDone] is then called with the window sent (whether it undid the
/// warning or the hiding: [FloorModerateForm.undo]). [undo] asks a choosable action's window with the undoing chosen
/// (a floor known stuck).
Future<bool> showFloorModerateDialog(
  BuildContext context, {
  required FloorModerateAction action,
  required String tid,
  required int fid,
  required String pid,
  bool undo = false,
  ModerateRepository? repository,
  void Function(FloorModerateForm form)? onDone,
}) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => FloorModerateDialog(
      action: action,
      tid: tid,
      fid: fid,
      pid: pid,
      undo: undo,
      repository: repository ?? ModerateRepository.network(),
      onDone: onDone,
    ),
  );
  return done ?? false;
}

/// The window of [action] on floor [pid]: loads the forum's window, lets the moderator give a reason and sends it.
/// Pops true once the forum carried it out.
class FloorModerateDialog extends StatefulWidget {
  /// Constructor.
  const FloorModerateDialog({
    required this.action,
    required this.tid,
    required this.fid,
    required this.pid,
    required this.repository,
    this.undo = false,
    this.onDone,
    super.key,
  });

  /// Ask the window with the undoing chosen, for a choosable action ([FloorModerateAction.choosable]).
  final bool undo;

  /// Called with the window once the forum carried it out, before the dialog pops.
  final void Function(FloorModerateForm form)? onDone;

  /// The operation.
  final FloorModerateAction action;

  /// The thread.
  final String tid;

  /// The forum of the thread.
  final int fid;

  /// The floor.
  final String pid;

  /// Where the window comes from and goes to.
  final ModerateRepository repository;

  @override
  State<FloorModerateDialog> createState() => _FloorModerateDialogState();
}

class _FloorModerateDialogState extends State<FloorModerateDialog> {
  FloorModerateForm? _form;
  bool _loading = true;
  bool _sending = false;

  /// The forum's refusal, or why the window could not be had.
  String? _error;

  bool _notify = false;
  final _reason = TextEditingController();

  /// The choice of a choosable action ([FloorModerateAction.choosable]): undoing it; as the window checked it.
  bool _undoing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final answer = await widget.repository
        .fetchFloorWindow(widget.action, tid: widget.tid, fid: widget.fid, pid: widget.pid, undo: widget.undo)
        .run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      switch (answer) {
        case Right(value: FloorModerateWindowReady(:final form)):
          _form = form;
          _notify = form.notifyForced;
          _undoing = form.undo;
        case Right(value: FloorModerateWindowRefused(:final message)):
          _error = message.isNotEmpty ? message : context.t.moderate.failed;
        case Left(:final value):
          _error = value is IdentityChangedException
              ? context.t.general.accountChangedRetry
              : context.t.general.failedToLoad;
      }
    });
  }

  Future<void> _send() async {
    final form = _form;
    if (form == null) {
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final sent = form.choosing(undo: _undoing);
    final outcome = await widget.repository.submitFloor(sent, reason: _reason.text, notify: _notify).run();
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case Right(value: ModerateSucceeded(:final message)):
        widget.onDone?.call(sent);
        showSnackBar(context: context, message: message.isNotEmpty ? message : context.t.moderate.done);
        Navigator.of(context).pop(true);
      case Right(value: ModerateRefused(:final message)):
        setState(() {
          _sending = false;
          _error = message.isNotEmpty ? message : context.t.moderate.failed;
        });
      case Left(:final value):
        setState(() {
          _sending = false;
          _error = value is IdentityChangedException
              ? context.t.general.accountChangedRetry
              : context.t.moderate.failed;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final form = _form;
    final undo = widget.action.choosable ? (form == null ? widget.undo : _undoing) : form?.undo ?? false;
    final danger = widget.action == FloorModerateAction.delete;
    final canSend = form != null && !_sending;
    final tr = context.t.moderate;
    // Once sent the forum carries it out whatever the dialog does: it stays until the answer, so the page is reloaded.
    return PopScope(
      canPop: !_sending,
      child: CustomAlertDialog.sync(
        title: AppDialogTitle(
          icon: floorModerateIcon(widget.action, undo: undo),
          title: floorModerateName(context, widget.action, undo: undo),
          error: danger,
        ),
        content: _loading
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (form != null) ...[
                      if (widget.action.choosable) ...[
                        SegmentedButton<bool>(
                          showSelectedIcon: false,
                          segments: [
                            for (final undoing in const [false, true])
                              ButtonSegment(
                                value: undoing,
                                icon: Icon(floorModerateIcon(widget.action, undo: undoing)),
                                label: Text(floorModerateName(context, widget.action, undo: undoing)),
                              ),
                          ],
                          selected: {_undoing},
                          onSelectionChanged: _sending ? null : (v) => setState(() => _undoing = v.single),
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextField(
                        controller: _reason,
                        enabled: !_sending,
                        minLines: 1,
                        maxLines: 3,
                        decoration: InputDecoration(
                          labelText: tr.reason,
                          suffixIcon: form.reasons.isEmpty
                              ? null
                              : PopupMenuButton<String>(
                                  icon: const Icon(Icons.arrow_drop_down),
                                  enabled: !_sending,
                                  onSelected: (v) => _reason.text = v,
                                  itemBuilder: (_) => [
                                    for (final r in form.reasons) PopupMenuItem(value: r, child: Text(r)),
                                  ],
                                ),
                        ),
                      ),
                      if (form.canNotify)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(tr.notifyAuthor),
                          value: _notify || form.notifyForced,
                          onChanged: form.notifyForced || _sending ? null : (v) => setState(() => _notify = v ?? false),
                        ),
                    ],
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: SelectableText(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                  ],
                ),
              ),
        actions: [
          TextButton(
            onPressed: _sending ? null : () => Navigator.of(context).pop(false),
            child: Text(context.t.general.cancel),
          ),
          if (form == null && !_loading)
            TextButton(onPressed: _load, child: Text(context.t.general.retry))
          else
            TextButton(
              onPressed: canSend ? _send : null,
              child: _sending
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(
                      context.t.general.ok,
                      style: danger && canSend ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
                    ),
            ),
        ],
      ),
    );
  }
}
