import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/remove_rate.dart';
import 'package:tsdm_client/features/moderate/repository/floor_ops_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Take rates of floor [pid] of thread [tid] back as a moderator: the forum's window listing them, the ones the
/// moderator checks sent once. True once the forum took them back; [onDone] is then called.
Future<bool> showRemoveRateDialog(
  BuildContext context, {
  required String tid,
  required String pid,
  FloorOpsRepository? repository,
  VoidCallback? onDone,
}) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => RemoveRateDialog(tid: tid, pid: pid, repository: repository ?? FloorOpsRepository.network()),
  );
  if (done ?? false) {
    onDone?.call();
  }
  return done ?? false;
}

/// The forum's window taking rates of floor [pid] back: its rates to check, a reason, the notice.
class RemoveRateDialog extends StatefulWidget {
  /// Constructor.
  const RemoveRateDialog({required this.tid, required this.pid, required this.repository, super.key});

  /// The thread.
  final String tid;

  /// The floor.
  final String pid;

  /// Where the window comes from and goes to.
  final FloorOpsRepository repository;

  @override
  State<RemoveRateDialog> createState() => _RemoveRateDialogState();
}

class _RemoveRateDialogState extends State<RemoveRateDialog> {
  RemoveRateForm? _form;
  bool _loading = true;
  bool _sending = false;

  /// The forum's refusal, or why the window could not be had or sent.
  String? _error;

  final _checked = <String>{};
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
    final answer = await widget.repository.fetchRemoveRateWindow(tid: widget.tid, pid: widget.pid).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      switch (answer) {
        case Right(value: RemoveRateWindowReady(:final form)):
          _form = form;
          _notify = form.notifyForced;
          _checked.removeWhere((id) => !form.entries.any((e) => e.logId == id));
        case Right(value: RemoveRateWindowRefused(:final message)):
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
    if (form == null || _checked.isEmpty) {
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final outcome = await widget.repository
        .removeRates(form, _checked, reason: _reason.text, notify: _notify || form.notifyForced)
        .run();
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case Right(value: FloorOpSucceeded(:final message)):
        showSnackBar(context: context, message: message.isNotEmpty ? message : context.t.moderate.done);
        Navigator.of(context).pop(true);
      case Right(value: FloorOpRefused(:final message)):
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

  Widget _entry(BuildContext context, RemoveRateEntry entry) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: _checked.contains(entry.logId),
      onChanged: _sending
          ? null
          : (v) => setState(() => (v ?? false) ? _checked.add(entry.logId) : _checked.remove(entry.logId)),
      title: Row(
        children: [
          Expanded(child: Text(entry.username, maxLines: 1, overflow: TextOverflow.ellipsis)),
          Text(entry.credit, style: textTheme.labelLarge?.copyWith(color: colorScheme.primary)),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(entry.time, style: textTheme.labelSmall?.copyWith(color: colorScheme.outline)),
          if (entry.reason.isNotEmpty) Text(entry.reason),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final form = _form;
    final tr = context.t.moderate;
    final canSend = form != null && _checked.isNotEmpty && !_sending;
    final all = form != null && form.entries.isNotEmpty && form.entries.every((e) => _checked.contains(e.logId));
    // Once sent the forum carries it out whatever the dialog does: it stays until the answer, so the page is reloaded.
    return PopScope(
      canPop: !_sending,
      child: CustomAlertDialog.sync(
        title: AppDialogTitle(icon: Icons.remove_circle_outline, title: context.t.moderateFloorOps.removeRate),
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
                      if (form.entries.length > 1)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: Text(tr.batch.selectAll),
                          value: all,
                          onChanged: _sending
                              ? null
                              : (v) => setState(() {
                                  _checked.clear();
                                  if (v ?? false) {
                                    _checked.addAll(form.entries.map((e) => e.logId));
                                  }
                                }),
                        ),
                      for (final entry in form.entries) _entry(context, entry),
                      TextField(
                        controller: _reason,
                        enabled: !_sending,
                        minLines: 1,
                        maxLines: 3,
                        decoration: InputDecoration(labelText: tr.reason),
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
                  : Text(context.t.general.ok),
            ),
        ],
      ),
    );
  }
}
