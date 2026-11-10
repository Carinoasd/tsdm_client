import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/doing/models/doing_models.dart';
import 'package:tsdm_client/features/doing/repository/doing_repository.dart';
import 'package:tsdm_client/features/doing/utils/parse_doing.dart';
import 'package:tsdm_client/features/follow/widgets/follow_widgets.dart' show FollowAvatar;
import 'package:tsdm_client/features/image/models/gallery_image.dart';
import 'package:tsdm_client/features/image/view/image_gallery_page.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/utils/space_switches.dart';
import 'package:tsdm_client/features/space/widgets/space_social_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/network_indicator_image.dart';

/// The repository of the account in use of [context].
DoingWriteRepository doingWriteRepositoryOf(BuildContext context) {
  final auth = context.read<AuthenticationRepository>();
  return DoingWriteRepository(client: getIt.get<NetClientProvider>(), currentUid: () => auth.effectiveCurrentUid);
}

/// Write a record, or a reply ([title] and [send] say which): a text within what the forum keeps of a record
/// ([doingMaxLength], counted as the forum counts). Pops it trimmed, null when cancelled.
Future<String?> showDoingTextDialog(
  BuildContext context, {
  required IconData icon,
  required String title,
  required String send,
}) => showDialog<String>(
  context: context,
  builder: (_) => _DoingTextDialog(icon: icon, title: title, send: send),
);

class _DoingTextDialog extends StatefulWidget {
  const _DoingTextDialog({required this.icon, required this.title, required this.send});

  final IconData icon;
  final String title;
  final String send;

  @override
  State<_DoingTextDialog> createState() => _DoingTextDialogState();
}

class _DoingTextDialogState extends State<_DoingTextDialog> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = _text.text.trim();
    final length = doingLengthOf(text);
    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          AppIconTile(widget.icon, size: 36),
          sizedBoxW12H12,
          Expanded(child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
      ),
      content: TextField(
        controller: _text,
        autofocus: true,
        minLines: 3,
        maxLines: 6,
        decoration: InputDecoration(
          labelText: context.t.spacePage.doing.message,
          counterText: '$length / $doingMaxLength',
          filled: true,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
        ),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        FilledButton.icon(
          onPressed: text.isEmpty || length > doingMaxLength ? null : () => Navigator.of(context).pop(text),
          icon: const Icon(Icons.send_outlined),
          label: Text(widget.send),
        ),
      ],
    );
  }
}

/// Post a record with the [session] of a list; sent once.
///
/// True when the lists are to be read again.
Future<bool> postDoing(BuildContext context, {required SpaceSession session}) async {
  final tr = context.t.spacePage.doing;
  final message = await showDoingTextDialog(context, icon: Icons.edit_note_outlined, title: tr.post, send: tr.post);
  if (message == null || !context.mounted) return false;
  final result = await doingWriteRepositoryOf(context).post(session, message);
  if (!context.mounted) return false;
  if (spaceModuleSwitchedOff(result.message)) markSpaceModuleOff(SpaceModule.doing);
  return showSpaceWriteResult(context, result, done: tr.posted);
}

/// Delete the record [doing] with the [session] of its list, once the user confirmed; sent once.
///
/// True when the lists are to be read again: the forum answers a delete the same whether or not it took it.
Future<bool> deleteDoing(BuildContext context, {required SpaceSession session, required Doing doing}) async {
  final tr = context.t.spacePage.doing;
  final confirmed = await showQuestionDialog(
    context: context,
    title: tr.deleteDoing,
    message: doing.content.text?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '',
    dangerous: true,
  );
  if (!(confirmed ?? false) || !context.mounted) return false;
  final result = await doingWriteRepositoryOf(context).delete(session, doing.doid);
  if (!context.mounted) return false;
  return showSpaceWriteResult(context, result, done: tr.deleted);
}

/// A record: who and when, the record as the forum rendered it, its pictures; its replies behind their count, the
/// forum's own delete at the end of the line of the author.
class DoingCard extends StatelessWidget {
  /// Constructor.
  const DoingCard(this.doing, {required this.onReplies, this.onDelete, super.key});

  /// The record.
  final Doing doing;

  /// Open its replies.
  final VoidCallback onReplies;

  /// Delete it; null when the forum printed no link, or the page has no session.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage.doing;
    final theme = Theme.of(context);
    final outline = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline);
    return AppSurface(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FollowAvatar(uid: doing.uid, username: doing.username, avatarUrl: doing.avatarUrl),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(doing.username, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
                    ),
                    if (doing.time != null) ...[sizedBoxW8H8, Text(doing.time!, style: outline)],
                  ],
                ),
                sizedBoxW4H4,
                munchElement(context, doing.content),
                if (doing.imageUrls.isNotEmpty) ...[
                  sizedBoxW8H8,
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final (index, url) in doing.imageUrls.indexed)
                        InkWell(
                          onTap: () async =>
                              openImageGallery(context, [for (final e in doing.imageUrls) GalleryImage(e)], index),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(appInnerRadius),
                            child: SizedBox.square(
                              dimension: 84,
                              child: NetworkIndicatorImage(url, fit: BoxFit.cover),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (onDelete != null)
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 18),
                        tooltip: tr.deleteDoing,
                        visualDensity: VisualDensity.compact,
                        onPressed: onDelete,
                      ),
                    TextButton.icon(
                      onPressed: onReplies,
                      icon: const Icon(Icons.mode_comment_outlined, size: 18),
                      label: Text(doing.replyCount > 0 ? '${doing.replyCount}' : tr.reply),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The replies of the record [doing], in a sheet: read a page at a time, replied to (the record, or one of its
/// replies) and deleted with the [session] of the list, as the forum printed its links. [onChanged] once a reply was
/// posted or deleted: the list is to be read again.
Future<void> showDoingReplies(
  BuildContext context, {
  required Doing doing,
  required SpaceSession session,
  required VoidCallback onChanged,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  useSafeArea: true,
  builder: (_) => DoingRepliesSheet(doing: doing, session: session, onChanged: onChanged),
);

/// The replies of a record, see [showDoingReplies].
class DoingRepliesSheet extends StatefulWidget {
  /// Constructor; [repository] replaces the reader of the shared client.
  const DoingRepliesSheet({
    required this.doing,
    required this.session,
    required this.onChanged,
    this.repository = const DoingRepository(),
    super.key,
  });

  /// The record.
  final Doing doing;

  /// The account the list was served to and its form hash.
  final SpaceSession session;

  /// A reply was posted or deleted.
  final VoidCallback onChanged;

  /// Reads the replies.
  final DoingRepository repository;

  @override
  State<DoingRepliesSheet> createState() => _DoingRepliesSheetState();
}

class _DoingRepliesSheetState extends State<DoingRepliesSheet> {
  final _comments = <DoingComment>[];
  int _page = 0;
  bool _hasMore = false;
  bool _loading = true;
  LoadFailure? _failure;
  String? _message;

  /// Bumped by every reload: the answer of a page asked before is dropped.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load(reset: true));
  }

  Future<void> _load({required bool reset}) async {
    final generation = reset ? ++_generation : _generation;
    final page = reset ? 1 : _page + 1;
    // Nothing to tell on the first load: the sheet is built loading.
    if (!_loading || _failure != null) {
      setState(() {
        _loading = true;
        _failure = null;
      });
    }
    final result = await widget.repository.fetchComments(widget.doing.doid, page: page).run();
    if (!mounted || generation != _generation) return;
    setState(() {
      _loading = false;
      switch (result) {
        case Left(:final value):
          _failure = LoadFailure.of(value);
        case Right(:final value):
          if (spaceModuleSwitchedOff(value.message)) markSpaceModuleOff(SpaceModule.doing);
          _message = value.message;
          final known = reset ? <int>{} : _comments.map((e) => e.id).toSet();
          if (reset) _comments.clear();
          _comments.addAll(value.comments.where((e) => !known.contains(e.id)));
          _page = value.page;
          _hasMore = value.hasMore;
      }
    });
  }

  Future<void> _reply(SpaceSession session, {DoingComment? to}) async {
    final tr = context.t.spacePage.doing;
    final message = await showDoingTextDialog(
      context,
      icon: Icons.reply_outlined,
      title: tr.replyTo(name: to?.username ?? widget.doing.username),
      send: tr.reply,
    );
    if (message == null || !mounted) return;
    final result = await doingWriteRepositoryOf(context).comment(session, widget.doing.doid, message, docid: to?.id);
    if (!mounted) return;
    if (showSpaceWriteResult(context, result, done: tr.replied)) {
      widget.onChanged();
      unawaited(_load(reset: true));
    }
  }

  Future<void> _delete(SpaceSession session, DoingComment comment) async {
    final tr = context.t.spacePage.doing;
    final confirmed = await showQuestionDialog(
      context: context,
      title: tr.deleteReply,
      message: comment.message.text?.replaceAll(RegExp(r'\s+'), ' ').trim() ?? '',
      dangerous: true,
    );
    if (!(confirmed ?? false) || !mounted) return;
    final result = await doingWriteRepositoryOf(context).delete(session, widget.doing.doid, docid: comment.id);
    if (!mounted) return;
    if (showSpaceWriteResult(context, result, done: tr.deleted)) {
      widget.onChanged();
      unawaited(_load(reset: true));
    }
  }

  Widget _tile(BuildContext context, DoingComment comment) {
    final tr = context.t.spacePage.doing;
    final theme = Theme.of(context);
    final session = widget.session;
    return Padding(
      padding: EdgeInsets.only(left: comment.nested ? 48 : 16, right: 8, top: 6, bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FollowAvatar(uid: comment.uid, username: comment.username, avatarUrl: comment.avatarUrl),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        comment.username,
                        style: theme.textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (comment.time != null) ...[
                      sizedBoxW8H8,
                      Text(
                        comment.time!,
                        style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  ],
                ),
                sizedBoxW4H4,
                munchElement(context, comment.message),
              ],
            ),
          ),
          if (comment.canReply)
            IconButton(
              icon: const Icon(Icons.reply_outlined, size: 18),
              tooltip: tr.reply,
              visualDensity: VisualDensity.compact,
              onPressed: () async => _reply(session, to: comment),
            ),
          if (comment.canDelete)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: tr.deleteReply,
              visualDensity: VisualDensity.compact,
              onPressed: () async => _delete(session, comment),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage.doing;
    final session = widget.session;
    final Widget body;
    if (_comments.isEmpty && _loading) {
      body = const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (_comments.isEmpty && (_failure != null || _message != null)) {
      body = FailureView(
        failure: _failure ?? LoadFailure.fromMessage(_message!),
        onRetry: () async => _load(reset: true),
        scrollable: false,
      );
    } else if (_comments.isEmpty) {
      body = AppStateView(icon: Icons.mode_comment_outlined, message: tr.noReplies, scrollable: false);
    } else {
      body = ListView(
        shrinkWrap: true,
        children: [
          for (final comment in _comments) _tile(context, comment),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_hasMore || _failure != null)
            Center(
              child: TextButton(
                onPressed: () async => _load(reset: false),
                child: Text(_failure != null ? context.t.general.retry : tr.moreReplies),
              ),
            ),
        ],
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
            child: Row(
              children: [
                Expanded(child: Text(tr.replies, style: Theme.of(context).textTheme.titleMedium)),
                FilledButton.tonalIcon(
                  onPressed: () async => _reply(session),
                  icon: const Icon(Icons.reply_outlined),
                  label: Text(tr.reply),
                ),
              ],
            ),
          ),
          Flexible(child: body),
          SizedBox(height: MediaQuery.viewPaddingOf(context).bottom + 8),
        ],
      ),
    );
  }
}
