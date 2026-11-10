import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_social_repository.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/utils/space_switches.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';

/// The repository of the account in use of [context].
SpaceSocialRepository spaceSocialRepositoryOf(BuildContext context) {
  final auth = context.read<AuthenticationRepository>();
  return SpaceSocialRepository(client: getIt.get<NetClientProvider>(), currentUid: () => auth.effectiveCurrentUid);
}

/// Tell what [result] of a post is: the forum's words, else the app's; [done] when the forum said nothing.
///
/// True when the forum may have done it (done, or not known): the list is to be read again.
bool showSpaceWriteResult(BuildContext context, SpaceWriteResult result, {required String done}) {
  final tr = context.t.spacePage;
  final message = switch (result.outcome) {
    SpaceWriteOutcome.done => result.message ?? done,
    SpaceWriteOutcome.rejected => result.message ?? tr.sendFailed,
    SpaceWriteOutcome.unconfirmed => tr.unconfirmed,
    SpaceWriteOutcome.loginRequired => result.message ?? context.t.general.needLogin,
    SpaceWriteOutcome.identityChanged => tr.identityChanged,
  };
  showSnackBar(context: context, message: message);
  return result.outcome == SpaceWriteOutcome.done || result.outcome == SpaceWriteOutcome.unconfirmed;
}

/// Write a message on the wall of [ownerUid] with the [session] of its page, or a reply to [replyTo]; sent once.
///
/// True when the wall is to be read again.
Future<bool> showWallMessageDialog(
  BuildContext context, {
  required SpaceSession session,
  required int ownerUid,
  SpaceBlogComment? replyTo,
}) async {
  final tr = context.t.spacePage.wall;
  final message = await showDialog<String>(
    context: context,
    builder: (_) => _TextDialog(
      icon: replyTo == null ? Icons.edit_note_outlined : Icons.reply_outlined,
      title: replyTo == null ? tr.post : tr.replyTo(name: replyTo.author),
      label: tr.message,
      send: replyTo == null ? tr.post : tr.reply,
      maxLines: 6,
    ),
  );
  if (message == null || !context.mounted) return false;
  final result = await spaceSocialRepositoryOf(
    context,
  ).postWall(session, ownerUid, message, replyTo: replyTo?.cid);
  if (!context.mounted) return false;
  return showSpaceWriteResult(context, result, done: tr.sent);
}

/// Delete the wall message [comment] with the [session] of its page, once the user confirmed; sent once.
///
/// True when the wall is to be read again.
Future<bool> deleteWallMessage(
  BuildContext context, {
  required SpaceSession session,
  required SpaceBlogComment comment,
}) async {
  final tr = context.t.spacePage.wall;
  final confirmed = await showQuestionDialog(
    context: context,
    title: tr.delete,
    message: comment.message.text?.trim() ?? '',
    dangerous: true,
  );
  if (!(confirmed ?? false) || !context.mounted) return false;
  final result = await spaceSocialRepositoryOf(context).deleteWall(session, comment.cid);
  if (!context.mounted) return false;
  return showSpaceWriteResult(context, result, done: tr.deleted);
}

/// Greet [uid] the way the forum's popup does: load the form (the forum refuses here already for the account itself,
/// without the permission, with friends switched off), pick a greeting, say a word, send once and show the forum's
/// answer. [reply] greets back a greeting received.
///
/// True when the greeting was sent, or may have been.
Future<bool> showPokeDialog(BuildContext context, {required int uid, String? username, bool reply = false}) async {
  final tr = context.t.spacePage.poke;
  final repository = spaceSocialRepositoryOf(context);
  final load = await repository.loadPokeForm(uid, reply: reply);
  if (!context.mounted) return false;
  final PokeForm form;
  switch (load.kind) {
    case SpaceFormLoadKind.ready:
      form = load.form!;
    case SpaceFormLoadKind.denied:
      if (spaceModuleSwitchedOff(load.message)) markSpaceModuleOff(SpaceModule.poke);
      showSnackBar(context: context, message: load.message!);
      return false;
    case SpaceFormLoadKind.loginRequired:
      showSnackBar(context: context, message: context.t.general.needLogin);
      return false;
    case SpaceFormLoadKind.identityChanged:
      showSnackBar(context: context, message: context.t.spacePage.identityChanged);
      return false;
    case SpaceFormLoadKind.failed:
      showSnackBar(context: context, message: tr.loadFailed);
      return false;
  }
  final choice = await showDialog<({String iconId, String note})>(
    context: context,
    builder: (_) => _PokeDialog(form: form, username: username ?? form.targetName ?? '$uid'),
  );
  if (choice == null || !context.mounted) return false;
  final result = await repository.sendPoke(form, choice.iconId, choice.note);
  if (!context.mounted) return false;
  return showSpaceWriteResult(context, result, done: tr.sent);
}

/// A dialog asking for one text; pops it trimmed, or null when cancelled.
class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.icon,
    required this.title,
    required this.label,
    required this.send,
    this.maxLines = 1,
  });

  final IconData icon;
  final String title;
  final String label;
  final String send;
  final int maxLines;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          AppIconTile(widget.icon, size: 36),
          sizedBoxW12H12,
          Expanded(child: Text(widget.title)),
        ],
      ),
      content: TextField(
        controller: _text,
        autofocus: true,
        minLines: widget.maxLines > 1 ? 3 : 1,
        maxLines: widget.maxLines,
        decoration: InputDecoration(
          labelText: widget.label,
          filled: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
        ),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton.icon(
          onPressed: _text.text.trim().isEmpty ? null : () => Navigator.of(context).pop(_text.text.trim()),
          icon: const Icon(Icons.send_outlined),
          label: Text(widget.send),
        ),
      ],
    );
  }
}

/// The greetings of the form and a word; pops the choice, or null when cancelled.
class _PokeDialog extends StatefulWidget {
  const _PokeDialog({required this.form, required this.username});

  final PokeForm form;
  final String username;

  @override
  State<_PokeDialog> createState() => _PokeDialogState();
}

class _PokeDialogState extends State<_PokeDialog> {
  final _note = TextEditingController();
  late String _iconId = widget.form.selected;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _submit() => Navigator.of(context).pop((iconId: _iconId, note: _note.text.trim()));

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage.poke;
    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          const AppIconTile(Icons.waving_hand_outlined, size: 36),
          sizedBoxW12H12,
          Expanded(child: Text(tr.title(name: widget.username))),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final icon in widget.form.icons)
                ChoiceChip(
                  avatar: icon.imageUrl == null
                      ? null
                      : Image(image: CachedImageProvider(icon.imageUrl!), width: 20, height: 20),
                  label: Text(icon.label),
                  selected: icon.id == _iconId,
                  onSelected: (_) => setState(() => _iconId = icon.id),
                ),
            ],
          ),
          sizedBoxW12H12,
          TextField(
            controller: _note,
            decoration: InputDecoration(
              labelText: tr.note,
              filled: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton.icon(onPressed: _submit, icon: const Icon(Icons.send_outlined), label: Text(tr.send)),
      ],
    );
  }
}
