import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// What a management of the thread page changed.
enum ModerateDone {
  /// The thread is still there, changed (stuck, digested, closed, moved…): load it again.
  changed,

  /// The thread was deleted: leave it.
  deleted,
}

/// Icon of an operation.
IconData moderateOperationIcon(ModerateOperation operation) => switch (operation) {
  ModerateOperation.stick => Icons.vertical_align_top_outlined,
  ModerateOperation.digest => Icons.star_outline,
  ModerateOperation.close => Icons.lock_outline,
  ModerateOperation.open => Icons.lock_open_outlined,
  ModerateOperation.move => Icons.drive_file_move_outline,
  ModerateOperation.delete => Icons.delete_outline,
  ModerateOperation.bump => Icons.arrow_upward_outlined,
  ModerateOperation.down => Icons.arrow_downward_outlined,
};

/// Name of an operation.
String moderateOperationName(BuildContext context, ModerateOperation operation) {
  final tr = context.t.moderate;
  return switch (operation) {
    ModerateOperation.stick => tr.stick,
    ModerateOperation.digest => tr.digest,
    ModerateOperation.close => tr.close,
    ModerateOperation.open => tr.open,
    ModerateOperation.move => tr.move,
    ModerateOperation.delete => tr.delete,
    ModerateOperation.bump => tr.bump,
    ModerateOperation.down => tr.down,
  };
}

/// The operations offered on a thread: stick, digest, close or open (the one that changes it: [closed] is the lock
/// beside the title), move, and delete last.
List<ModerateOperation> moderateOperationsFor({required bool closed}) => [
  ModerateOperation.stick,
  ModerateOperation.digest,
  if (closed) ModerateOperation.open else ModerateOperation.close,
  ModerateOperation.move,
  ModerateOperation.delete,
];

/// The operations offered on several threads at once: both close and open (the threads may be either), bump and sink,
/// and delete last.
const List<ModerateOperation> moderateBatchOperations = [
  ModerateOperation.stick,
  ModerateOperation.digest,
  ModerateOperation.close,
  ModerateOperation.open,
  ModerateOperation.bump,
  ModerateOperation.down,
  ModerateOperation.move,
  ModerateOperation.delete,
];

/// Let the moderator pick one of [operations], delete last and apart.
Future<ModerateOperation?> _pickOperation(BuildContext context, List<ModerateOperation> operations) =>
    showModalBottomSheet<ModerateOperation>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final op in operations) ...[
                if (op == ModerateOperation.delete) const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    moderateOperationIcon(op),
                    color: op == ModerateOperation.delete ? Theme.of(context).colorScheme.error : null,
                  ),
                  title: Text(
                    moderateOperationName(context, op),
                    style: op == ModerateOperation.delete
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                  ),
                  onTap: () => Navigator.of(context).pop(op),
                ),
              ],
            ],
          ),
        ),
      ),
    );

/// Offer the management of threads [threads] (tid and title, in the list's order) of forum [fid] to a moderator: pick
/// an operation, fill in the forum's window of it once, send it for every thread; the threads not done are listed
/// with why. Null when nothing was sent.
Future<ModerateBatchReport?> showBatchModerateSheet(
  BuildContext context, {
  required List<(String, String)> threads,
  required int fid,
  ModerateRepository? repository,
}) async {
  final operation = await _pickOperation(context, moderateBatchOperations);
  if (operation == null || !context.mounted) {
    return null;
  }
  final report = await showDialog<ModerateBatchReport>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ModerateDialog.batch(
      operation: operation,
      tids: [for (final (tid, _) in threads) tid],
      fid: fid,
      repository: repository ?? ModerateRepository.network(),
    ),
  );
  if (report == null || !context.mounted) {
    return report;
  }
  final failed = report.failed;
  if (failed.isEmpty) {
    showSnackBar(
      context: context,
      message: context.t.moderate.batch.done(count: report.doneCount),
    );
    return report;
  }
  final titles = {for (final (tid, title) in threads) tid: title};
  await showDialog<void>(
    context: context,
    builder: (context) => CustomAlertDialog.sync(
      title: AppDialogTitle(
        icon: moderateOperationIcon(operation),
        title: context.t.moderate.batch.failed(count: failed.length),
        error: true,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (tid, failure) in failed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(titles[tid] ?? tid, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: SelectableText(switch (failure.kind) {
                  ModerateBatchFailure.refused when failure.message.isNotEmpty => failure.message,
                  ModerateBatchFailure.accountChanged => context.t.general.accountChangedRetry,
                  _ => context.t.moderate.failed,
                }),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.ok))],
    ),
  );
  return report;
}

/// Offer the management of thread [tid] in forum [fid] to a moderator: pick an operation, fill in the forum's window
/// of it, send it. Null when nothing was done.
Future<ModerateDone?> showThreadModerateSheet(
  BuildContext context, {
  required String tid,
  required int fid,
  required bool closed,
  ModerateRepository? repository,
}) async {
  final operation = await _pickOperation(context, moderateOperationsFor(closed: closed));
  if (operation == null || !context.mounted) {
    return null;
  }
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => ModerateDialog(
      operation: operation,
      tid: tid,
      fid: fid,
      repository: repository ?? ModerateRepository.network(),
    ),
  );
  if (done != true) {
    return null;
  }
  return operation == ModerateOperation.delete ? ModerateDone.deleted : ModerateDone.changed;
}

/// The window of [operation] on thread [tid] in forum [fid]: loads the forum's window, lets the moderator choose and
/// sends it. Pops true once the forum carried it out.
class ModerateDialog extends StatefulWidget {
  /// Constructor.
  const ModerateDialog({
    required this.operation,
    required this.tid,
    required this.fid,
    required this.repository,
    super.key,
  }) : tids = null;

  /// The window of [operation] on threads [tids] of forum [fid]: the forum's window of them, sent for every thread
  /// ([ModerateRepository.runBatch]). Pops the [ModerateBatchReport] once sent.
  ModerateDialog.batch({
    required this.operation,
    required List<String> this.tids,
    required this.fid,
    required this.repository,
    super.key,
  }) : tid = tids.first;

  /// The operation.
  final ModerateOperation operation;

  /// The thread, the first of [tids] for several.
  final String tid;

  /// The threads of a management of several threads; null for one thread.
  final List<String>? tids;

  /// The forum of the thread.
  final int fid;

  /// Where the window comes from and goes to.
  final ModerateRepository repository;

  @override
  State<ModerateDialog> createState() => _ModerateDialogState();
}

class _ModerateDialogState extends State<ModerateDialog> {
  ModerateForm? _form;

  /// The window of the threads, for several.
  ModerateBatchForm? _batch;
  bool _loading = true;
  bool _sending = false;

  /// The forum's refusal, or why the window could not be had.
  String? _error;

  String? _level;
  DateTime? _expiration;
  String? _moveTo;
  bool _redirect = false;
  bool _notify = false;
  final _reason = TextEditingController();

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
    if (widget.tids case final tids?) {
      final answer = await widget.repository.fetchBatchWindow(widget.operation, tids: tids, fid: widget.fid).run();
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        switch (answer) {
          case Right(value: ModerateBatchWindowReady(:final form)):
            _batch = form;
            _form = form.window;
            _level = form.window.currentLevel?.value;
            _notify = form.window.notifyForced;
          case Right(value: ModerateBatchWindowRefused(:final message)):
            _error = message.isNotEmpty ? message : context.t.moderate.failed;
          case Left(:final value):
            _error = _failure(value);
        }
      });
      return;
    }
    final answer = await widget.repository.fetchWindow(widget.operation, tid: widget.tid, fid: widget.fid).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      switch (answer) {
        case Right(value: ModerateWindowReady(:final form)):
          _form = form;
          _level = form.currentLevel?.value;
          _notify = form.notifyForced;
        case Right(value: ModerateWindowRefused(:final message)):
          _error = message.isNotEmpty ? message : context.t.moderate.failed;
        case Left(:final value):
          _error = _failure(value);
      }
    });
  }

  String _failure(AppException e) =>
      e is IdentityChangedException ? context.t.general.accountChangedRetry : context.t.general.failedToLoad;

  ModerateRequest _request() => ModerateRequest(
    operation: _operation,
    level: _level,
    expiration: _expiration,
    moveTo: _moveTo,
    redirect: _redirect,
    reason: _reason.text,
    notify: _notify,
  );

  /// The operation done: the one picked, or the one the window checks (close and open).
  ModerateOperation get _operation => _form?.operation ?? widget.operation;

  bool get _canSend =>
      _form != null &&
      !_sending &&
      (_form!.levels.isEmpty || _level != null) &&
      (_operation != ModerateOperation.move || (_moveTo ?? '').isNotEmpty);

  Future<void> _send() async {
    final form = _form;
    if (form == null) {
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    if (_batch case final batch?) {
      final report = await widget.repository.runBatch(batch, _request(), tids: widget.tids!, fid: widget.fid);
      if (mounted) {
        Navigator.of(context).pop(report);
      }
      return;
    }
    final outcome = await widget.repository.submit(form, _request()).run();
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case Right(value: ModerateSucceeded(:final message)):
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

  Future<void> _pickExpiration() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // The forum takes a day after today and at most 180 days ahead (`checkexpiration`).
    final first = today.add(const Duration(days: 1));
    final picked = await showDatePicker(
      context: context,
      firstDate: first,
      lastDate: today.add(const Duration(days: 180)),
      initialDate: _expiration ?? first,
    );
    if (picked != null && mounted) {
      setState(() => _expiration = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final danger = _operation == ModerateOperation.delete;
    final form = _form;
    final dialog = CustomAlertDialog.sync(
      title: AppDialogTitle(
        icon: moderateOperationIcon(_operation),
        title: widget.tids == null
            ? moderateOperationName(context, _operation)
            : context.t.moderate.batch.title(
                operation: moderateOperationName(context, _operation),
                count: widget.tids!.length,
              ),
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
                  if (form != null) ..._fields(context, form),
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
          // Several threads are sent one window after another: not left half way.
          onPressed: _sending && widget.tids != null
              ? null
              : () => Navigator.of(context).pop(widget.tids == null ? false : null),
          child: Text(context.t.general.cancel),
        ),
        if (form == null && !_loading)
          TextButton(onPressed: _load, child: Text(context.t.general.retry))
        else
          TextButton(
            onPressed: _canSend ? _send : null,
            child: _sending
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(
                    context.t.general.ok,
                    style: danger && _canSend ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
                  ),
          ),
      ],
    );
    return widget.tids == null ? dialog : PopScope(canPop: !_sending, child: dialog);
  }

  List<Widget> _fields(BuildContext context, ModerateForm form) {
    final tr = context.t.moderate;
    final hasLevel = (int.tryParse(_level ?? '') ?? 0) > 0;
    return [
      if (form.levels.isNotEmpty)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final level in form.levels)
              ChoiceChip(
                label: Text(level.label),
                selected: _level == level.value,
                onSelected: _sending ? null : (_) => setState(() => _level = level.value),
              ),
          ],
        ),
      if (form.levels.isNotEmpty && hasLevel)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event_outlined),
          title: Text(tr.expiration),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _expiration == null
                    ? tr.noExpiration
                    : MaterialLocalizations.of(context).formatCompactDate(_expiration!),
              ),
              if (_expiration != null)
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _sending ? null : () => setState(() => _expiration = null),
                ),
            ],
          ),
          onTap: _sending ? null : _pickExpiration,
        ),
      if (_operation == ModerateOperation.move) ...[
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: _moveTo,
          decoration: InputDecoration(labelText: tr.moveTo),
          items: _forumItems(context, form.forums),
          onChanged: _sending ? null : (v) => setState(() => _moveTo = v),
        ),
        if (form.canRedirect)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text(tr.moveNormal)),
                ButtonSegment(value: true, label: Text(tr.moveRedirect)),
              ],
              selected: {_redirect},
              onSelectionChanged: _sending ? null : (v) => setState(() => _redirect = v.first),
            ),
          ),
      ],
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextField(
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
                    itemBuilder: (_) => [for (final r in form.reasons) PopupMenuItem(value: r, child: Text(r))],
                  ),
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
    ];
  }

  /// The forums to move to, each category a header that can not be picked.
  List<DropdownMenuItem<String>> _forumItems(BuildContext context, List<ModerateChoice> forums) {
    final items = <DropdownMenuItem<String>>[];
    String? group;
    for (final forum in forums) {
      if (forum.group != null && forum.group != group) {
        group = forum.group;
        items.add(
          DropdownMenuItem(
            enabled: false,
            child: Text(group!, style: Theme.of(context).textTheme.labelMedium),
          ),
        );
      }
      items.add(
        DropdownMenuItem(
          value: forum.value,
          child: Padding(
            padding: EdgeInsets.only(left: 12.0 + forum.depth * 12),
            child: Text(forum.label, overflow: TextOverflow.ellipsis),
          ),
        ),
      );
    }
    return items;
  }
}
