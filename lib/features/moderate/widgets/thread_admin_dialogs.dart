import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/features/moderate/models/thread_admin_forms.dart';
import 'package:tsdm_client/features/moderate/repository/thread_admin_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

String _failure<T>(BuildContext context, Either<AppException, ThreadAdminWindow<T>> answer) => switch (answer) {
  Right(value: ThreadAdminWindowRefused(:final message)) when message.isNotEmpty => context.displayText(message),
  Right(value: ThreadAdminWindowRefused()) => context.t.moderate.failed,
  Left(value: IdentityChangedException()) => context.t.general.accountChangedRetry,
  _ => context.t.general.failedToLoad,
};

/// Show the poster's IP of floor [pid] (its `urls.viewip` [url]) to a moderator the forum lets see it; the IP is
/// copied on a long press.
Future<void> showFloorIpDialog(
  BuildContext context, {
  required String url,
  required int pid,
  ThreadAdminRepository? repository,
}) => showDialog<void>(
  context: context,
  builder: (_) => FloorIpDialog(url: url, pid: pid, repository: repository ?? ThreadAdminRepository.network()),
);

/// The poster's IP of a floor, see [showFloorIpDialog].
class FloorIpDialog extends StatefulWidget {
  /// Constructor.
  const FloorIpDialog({required this.url, required this.pid, required this.repository, super.key});

  /// The floor's `urls.viewip`.
  final String url;

  /// The floor.
  final int pid;

  /// Where it comes from.
  final ThreadAdminRepository repository;

  @override
  State<FloorIpDialog> createState() => _FloorIpDialogState();
}

class _FloorIpDialogState extends State<FloorIpDialog> {
  Either<AppException, ThreadAdminWindow<FloorIp>>? _answer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _answer = null);
    final answer = await widget.repository.fetchFloorIp(widget.url, pid: widget.pid);
    if (mounted) setState(() => _answer = answer);
  }

  @override
  Widget build(BuildContext context) {
    final answer = _answer;
    final theme = Theme.of(context);
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.lan_outlined, title: context.t.moderateFloorOps.viewIp),
      content: switch (answer) {
        null => const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
        Right(value: ThreadAdminWindowReady(value: final ip)) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (ip.author.isNotEmpty) Text(ip.author, style: theme.textTheme.labelLarge),
            ListTile(
              key: const ValueKey('floor-ip'),
              contentPadding: EdgeInsets.zero,
              title: Text(
                ip.ip.isEmpty ? '-' : ip.ip,
                style: theme.textTheme.titleLarge?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
              ),
              subtitle: Text(
                [
                  if (ip.port > 0) ':${ip.port}',
                  if (ip.location.isNotEmpty) context.displayText(ip.location),
                ].join(' · '),
              ),
              onLongPress: ip.ip.isEmpty ? null : () => unawaited(copyToClipboard(context, ip.ip)),
            ),
          ],
        ),
        final failed => SelectableText(_failure(context, failed), style: TextStyle(color: theme.colorScheme.error)),
      },
      actions: [
        if (answer != null && answer.getRight().toNullable() is! ThreadAdminWindowReady<FloorIp>)
          TextButton(onPressed: _load, child: Text(context.t.general.retry)),
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.ok)),
      ],
    );
  }
}

/// The name of [action].
String threadAdminActionName(BuildContext context, ThreadAdminAction action) => switch (action) {
  ThreadAdminAction.removeReward => context.t.moderate.removeReward,
  ThreadAdminAction.refund => context.t.moderate.refund,
};

/// The icon of [action].
IconData threadAdminActionIcon(ThreadAdminAction action) => switch (action) {
  ThreadAdminAction.removeReward => Icons.money_off_outlined,
  ThreadAdminAction.refund => Icons.currency_exchange_outlined,
};

/// Do [action] on thread [tid] of forum [fid]: the forum's window (what the bounty or the sales are, a reason, the
/// notice), confirmed, sent once. True once the forum did it.
Future<bool> showThreadAdminDialog(
  BuildContext context, {
  required ThreadAdminAction action,
  required int fid,
  required int tid,
  ThreadAdminRepository? repository,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => ThreadAdminDialog(
        action: action,
        fid: fid,
        tid: tid,
        repository: repository ?? ThreadAdminRepository.network(),
      ),
    ) ??
    false;

/// The window of a [ThreadAdminAction], see [showThreadAdminDialog].
class ThreadAdminDialog extends StatefulWidget {
  /// Constructor.
  const ThreadAdminDialog({
    required this.action,
    required this.fid,
    required this.tid,
    required this.repository,
    super.key,
  });

  /// Which operation.
  final ThreadAdminAction action;

  /// The forum.
  final int fid;

  /// The thread.
  final int tid;

  /// Where the window comes from and goes to.
  final ThreadAdminRepository repository;

  @override
  State<ThreadAdminDialog> createState() => _ThreadAdminDialogState();
}

class _ThreadAdminDialogState extends State<ThreadAdminDialog> {
  Either<AppException, ThreadAdminWindow<ThreadAdminForm>>? _answer;
  final _reason = TextEditingController();
  bool _notify = false;
  bool _sending = false;
  String? _error;

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
      _answer = null;
      _error = null;
    });
    final answer = await widget.repository.fetchForm(widget.action, fid: widget.fid, tid: widget.tid);
    if (mounted) setState(() => _answer = answer);
  }

  String _amount(ThreadAdminForm form, int value) => [
    '$value',
    if (form.creditUnit.isNotEmpty) context.displayText(form.creditUnit),
    if (form.creditTitle.isNotEmpty) context.displayText(form.creditTitle),
  ].join(' ');

  List<String> _facts(ThreadAdminForm form) {
    final tr = context.t.moderate;
    return switch (form.action) {
      ThreadAdminAction.removeReward => [tr.rewardPrice(amount: _amount(form, form.price)), if (form.solved) tr.solved],
      ThreadAdminAction.refund => [
        tr.salePrice(amount: _amount(form, form.price)),
        tr.payers(n: form.payers),
        tr.income(amount: _amount(form, form.income)),
      ],
    };
  }

  Future<void> _send(ThreadAdminForm form) async {
    final tr = context.t.moderate;
    final reason = _reason.text.trim();
    if (form.reasonRequired && reason.isEmpty) {
      setState(() => _error = tr.reasonRequired);
      return;
    }
    final name = threadAdminActionName(context, widget.action);
    final ok = await showToolsConfirm(
      context,
      title: name,
      confirm: name,
      destructive: true,
      content: [
        Text(context.displayText(form.subject)),
        if (reason.isNotEmpty) ...[const SizedBox(height: 8), Text(reason)],
      ],
    );
    if (!ok || !mounted) return;
    setState(() {
      _sending = true;
      _error = null;
    });
    final outcome = await widget.repository.submit(form, reason: reason, notify: _notify);
    if (!mounted) return;
    switch (outcome) {
      case Right(value: (done: true, :final message)):
        showSnackBar(context: context, message: message.isNotEmpty ? context.displayText(message) : tr.done);
        Navigator.of(context).pop(true);
      case Right(value: (done: false, :final message)):
        setState(() {
          _sending = false;
          _error = message.isNotEmpty ? context.displayText(message) : tr.failed;
        });
      case Left(:final value):
        setState(() {
          _sending = false;
          _error = value is IdentityChangedException ? context.t.general.accountChangedRetry : tr.failed;
        });
    }
  }

  Widget _form(ThreadAdminForm form) {
    final theme = Theme.of(context);
    final tr = context.t.moderate;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.displayText(form.subject), style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        for (final f in _facts(form)) Text(f, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 12),
        if (form.reasons.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final r in form.reasons)
                ActionChip(
                  label: Text(context.displayText(r)),
                  onPressed: _sending ? null : () => _reason.text = r,
                ),
            ],
          ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('thread-admin-reason'),
          controller: _reason,
          enabled: !_sending,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(labelText: tr.reason, border: const OutlineInputBorder()),
        ),
        if (form.notifyField.isNotEmpty)
          CheckboxListTile(
            key: const ValueKey('thread-admin-notify'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(tr.notifyAuthor),
            value: _notify || form.notifyForced,
            onChanged: form.notifyForced || _sending ? null : (v) => setState(() => _notify = v ?? false),
          ),
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SelectableText(error, style: TextStyle(color: theme.colorScheme.error)),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final answer = _answer;
    final form = switch (answer) {
      Right(value: ThreadAdminWindowReady(:final value)) => value,
      _ => null,
    };
    return PopScope(
      canPop: !_sending,
      child: CustomAlertDialog.sync(
        title: AppDialogTitle(
          icon: threadAdminActionIcon(widget.action),
          title: threadAdminActionName(context, widget.action),
        ),
        content: switch (answer) {
          null => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          _ when form != null => SingleChildScrollView(child: _form(form)),
          final failed => SelectableText(
            _failure(context, failed),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        },
        actions: [
          TextButton(
            onPressed: _sending ? null : () => Navigator.of(context).pop(false),
            child: Text(context.t.general.cancel),
          ),
          if (form != null)
            TextButton(
              key: const ValueKey('thread-admin-submit'),
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              onPressed: _sending ? null : () => _send(form),
              child: _sending
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(threadAdminActionName(context, widget.action)),
            )
          else if (answer != null)
            TextButton(onPressed: _load, child: Text(context.t.general.retry)),
        ],
      ),
    );
  }
}
