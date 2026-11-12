import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_json_pages.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The forums a page of the panel offers ([forums]) to choose one from ([onPick]).
class ModcpForumList extends StatelessWidget {
  /// Constructor.
  const ModcpForumList({required this.forums, required this.onPick, super.key});

  /// The forums.
  final List<ModcpForum> forums;

  /// One was chosen.
  final ValueChanged<ModcpForum> onPick;

  @override
  Widget build(BuildContext context) {
    if (forums.isEmpty) {
      return AppStateView(icon: Icons.forum_outlined, message: context.t.modcp.noForums);
    }
    return AppCenteredList(
      builder: (context, padding, _) => ListView(
        padding: padding.copyWith(top: 8, bottom: 8),
        children: [
          AppSurface(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final forum in forums)
                  ListTile(
                    key: ValueKey('modcp-forum-${forum.fid}'),
                    leading: const Icon(Icons.forum_outlined),
                    title: Text(context.displayText(forum.name)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => onPick(forum),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Let the moderator switch to another of [forums] ([current] marked); null when none was chosen.
Future<ModcpForum?> showModcpForumSwitch(BuildContext context, List<ModcpForum> forums, int current) =>
    showModalBottomSheet<ModcpForum>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final forum in forums)
              ListTile(
                key: ValueKey('modcp-switch-forum-${forum.fid}'),
                title: Text(context.displayText(forum.name)),
                selected: forum.fid == current,
                trailing: forum.fid == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(forum),
              ),
          ],
        ),
      ),
    );

/// Tell why a list could not be had beside the one still shown: the refusal in the forum's words, or why.
void showModcpLoadFailure(BuildContext context, Either<AppException, ModcpAnswer<Object?>> answer) => showSnackBar(
  context: context,
  message: switch (answer) {
    Right(value: ModcpRefused(:final message)) when message.isNotEmpty => context.displayText(message),
    Left(value: IdentityChangedException()) => context.t.general.accountChangedRetry,
    _ => context.t.general.failedToLoad,
  },
);

/// The name of permission [right].
String modcpAccessRightName(BuildContext context, ModcpAccessRight right) {
  final tr = context.t.modcpPages;
  return switch (right) {
    ModcpAccessRight.view => tr.view,
    ModcpAccessRight.post => tr.post,
    ModcpAccessRight.reply => tr.reply,
    ModcpAccessRight.getattach => tr.getattach,
    ModcpAccessRight.getimage => tr.getimage,
    ModcpAccessRight.postattach => tr.postattach,
    ModcpAccessRight.postimage => tr.postimage,
  };
}

/// The outcome of a form of the panel whose answer the app words itself where the forum says nothing: [done] when
/// carried out in full, [refused] (null: the forum's words or the app's "failed") when not.
String modcpPagesOutcomeText(
  BuildContext context,
  Either<AppException, ModcpWriteOutcome> outcome, {
  required String done,
  String? refused,
}) {
  final t = context.t;
  return switch (outcome) {
    Right(value: ModcpWriteDone()) => done,
    Right(value: ModcpWriteNotDone(:final remaining)) => t.modcp.notDone(count: remaining.length),
    Right(value: ModcpWriteRefused(:final message)) when message.isNotEmpty => context.displayText(message),
    Right(value: ModcpWriteRefused()) => refused ?? t.moderate.failed,
    Right(value: ModcpWriteUnknown()) => t.medalTitleTools.unconfirmed,
    Right(value: ModcpWriteSessionEnded()) => t.moderate.panelLogin,
    Left(value: IdentityChangedException()) => t.general.accountChangedRetry,
    Left() => t.medalTitleTools.unconfirmed,
  };
}

/// A date of a search (`YYYY-MM-DD`, empty for none): chosen in the date picker, cleared with its button.
class ModcpDateField extends StatelessWidget {
  /// Constructor.
  const ModcpDateField({
    required this.label,
    required this.value,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  /// The field's label.
  final String label;

  /// The date, empty for none.
  final String value;

  /// A date was chosen or cleared.
  final ValueChanged<String> onChanged;

  /// It may be changed.
  final bool enabled;

  @override
  Widget build(BuildContext context) => InputDecorator(
    decoration: InputDecoration(
      labelText: label,
      enabled: enabled,
      suffixIcon: value.isEmpty || !enabled
          ? null
          : IconButton(icon: const Icon(Icons.clear), onPressed: () => onChanged('')),
    ),
    isEmpty: value.isEmpty,
    child: InkWell(
      onTap: !enabled
          ? null
          : () async {
              final now = DateTime.now();
              final picked = await showDatePicker(
                context: context,
                initialDate: DateTime.tryParse(value) ?? now,
                firstDate: DateTime(2000),
                lastDate: DateTime(now.year + 1, 12, 31),
              );
              if (picked != null) {
                String two(int v) => v.toString().padLeft(2, '0');
                onChanged('${picked.year}-${two(picked.month)}-${two(picked.day)}');
              }
            },
      child: Text(value.isEmpty ? ' ' : value),
    ),
  );
}
