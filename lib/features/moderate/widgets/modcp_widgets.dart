import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_panel_login.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// A page of the panel as it came: a spinner while [loading], the panel's login when it asks the password, [builder]
/// with what the page holds, or the refusal in the forum's words.
class ModcpAnswerView<T> extends StatelessWidget {
  /// Constructor.
  const ModcpAnswerView({
    required this.repository,
    required this.loading,
    required this.answer,
    required this.onReload,
    required this.builder,
    super.key,
  });

  /// The panel (its login).
  final ModcpRepository repository;

  /// The page is being asked.
  final bool loading;

  /// What the panel answered, null before.
  final Either<AppException, ModcpAnswer<T>>? answer;

  /// Ask the page again.
  final Future<void> Function() onReload;

  /// The page read.
  final Widget Function(BuildContext context, T value) builder;

  @override
  Widget build(BuildContext context) {
    if (loading || answer == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return switch (answer) {
      Right(value: ModcpNeedsLogin(:final formHash)) => ModeratePanelLoginView(
        login: (password) => repository.loginPanel(formHash: formHash, password: password),
        onLoggedIn: onReload,
      ),
      Right(value: ModcpReady(:final value)) => builder(context, value),
      final other => modcpErrorView(context, other, onRetry: onReload),
    };
  }
}

/// What to tell of [outcome]: done, partly done, the forum's refusal, or why nothing could be told.
String modcpOutcomeText(BuildContext context, Either<AppException, ModcpWriteOutcome> outcome) {
  final t = context.t;
  return switch (outcome) {
    Right(value: ModcpWriteDone(:final count)) when count > 1 => t.modcp.done(count: count),
    Right(value: ModcpWriteDone(:final message)) when message.isNotEmpty => message,
    Right(value: ModcpWriteDone()) => t.moderate.done,
    Right(value: ModcpWriteNotDone(:final remaining)) => t.modcp.notDone(count: remaining.length),
    Right(value: ModcpWriteRefused(:final message)) when message.isNotEmpty => message,
    Right(value: ModcpWriteUnknown()) => t.moderate.batch.unknown,
    Left(value: IdentityChangedException()) => t.general.accountChangedRetry,
    _ => t.moderate.failed,
  };
}

/// Whether [outcome] is a change carried out in full.
bool modcpDone(Either<AppException, ModcpWriteOutcome> outcome) => switch (outcome) {
  Right(value: ModcpWriteDone()) => true,
  _ => false,
};

/// Ask the reason of [title] on [count] items (empty allowed); null when cancelled.
Future<String?> showModcpReasonDialog(
  BuildContext context, {
  required String title,
  required IconData icon,
  required int count,
  bool destructive = false,
}) => showDialog<String>(
  context: context,
  builder: (_) => _ReasonDialog(title: title, icon: icon, count: count, destructive: destructive),
);

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({required this.title, required this.icon, required this.count, required this.destructive});

  final String title;
  final IconData icon;
  final int count;
  final bool destructive;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomAlertDialog.sync(
    title: AppDialogTitle(icon: widget.icon, title: widget.title, error: widget.destructive),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.t.modcp.selected(count: widget.count)),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('modcp-reason'),
          controller: _reason,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(labelText: context.t.moderate.reason),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
      TextButton(
        key: const ValueKey('modcp-reason-confirm'),
        onPressed: () => Navigator.of(context).pop(_reason.text),
        child: Text(
          context.t.general.ok,
          style: widget.destructive ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
        ),
      ),
    ],
  );
}

/// The bar under a list of items picked several at a time: all or none, how many, and the [actions].
class ModcpPickBar extends StatelessWidget {
  /// Constructor.
  const ModcpPickBar({
    required this.picked,
    required this.allPicked,
    required this.onPickAll,
    required this.sending,
    required this.actions,
    super.key,
  });

  /// How many are picked.
  final int picked;

  /// All are picked.
  final bool allPicked;

  /// Pick all, or none when [allPicked]; null while sending.
  final VoidCallback? onPickAll;

  /// A change is being sent.
  final bool sending;

  /// The buttons.
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainer,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
        child: Row(
          children: [
            Checkbox(
              key: const ValueKey('modcp-pick-all'),
              value: allPicked,
              onChanged: onPickAll == null ? null : (_) => onPickAll!(),
            ),
            Expanded(child: Text(context.t.modcp.selected(count: picked))),
            if (sending)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            for (final (i, action) in actions.indexed) ...[if (i > 0) const SizedBox(width: 4), action],
          ],
        ),
      ),
    ),
  );
}

/// A card of a list whose items are picked several at a time: its box (none when it can not be picked) and [child].
class ModcpPickCard extends StatelessWidget {
  /// Constructor.
  const ModcpPickCard({required this.picked, required this.onChanged, required this.child, this.onTap, super.key});

  /// Picked.
  final bool picked;

  /// Pick or unpick; null when it can not be (no box shown when [onTap] is null too, else a box disabled).
  final ValueChanged<bool>? onChanged;

  /// Open it; picking it when null.
  final VoidCallback? onTap;

  /// The content.
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    shape: appSurfaceShape(context),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap ?? (onChanged == null ? null : () => onChanged!(!picked)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(value: picked, onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false)),
            Expanded(
              child: Padding(padding: const EdgeInsets.only(top: 12), child: child),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The muted line of a card: [parts] that are not empty, joined.
Widget modcpMutedLine(BuildContext context, List<String> parts) {
  final theme = Theme.of(context);
  return Text(
    parts.where((e) => e.isNotEmpty && e != '-').join(' · '),
    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
  );
}
