import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/post_comment/models/post_comment.dart';
import 'package:tsdm_client/features/post_comment/repository/post_comment_repository.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';

/// The repository above [context] (tests), else one on the app's client.
PostCommentRepository _repositoryOf(BuildContext context) =>
    context.readOrNull<PostCommentRepository>() ?? PostCommentRepository.network(getIt.get<NetClientProvider>());

/// The account in use, null for a guest.
int? _currentUid(BuildContext context) => context.readOrNull<AuthenticationRepository>()?.effectiveCurrentUid;

/// Whether [form] may still be sent: the account in use is [uid], the one the window was opened for, and the window
/// was served to it when its answer says.
bool _sameAccount(BuildContext context, int uid, PostCommentForm form) =>
    _currentUid(context) == uid && (form.uid == null || form.uid == uid);

/// The comments of a floor under its content ([Post.comments]), with the pages after the first on demand and the
/// moderators' delete.
///
/// [tid] is the floor's thread, null outside a thread page (no more pages, no delete); [onReload] reloads the floor's
/// page after a delete, null where nothing is sent (a floor read back from an offline copy, the post of a notice).
class PostCommentSection extends StatefulWidget {
  /// Constructor.
  const PostCommentSection(this.post, {this.tid, this.onReload, super.key});

  /// The floor.
  final Post post;

  /// The floor's thread.
  final String? tid;

  /// Reload the floor's page.
  final VoidCallback? onReload;

  @override
  State<PostCommentSection> createState() => _PostCommentSectionState();
}

class _PostCommentSectionState extends State<PostCommentSection> {
  /// The comments of the pages loaded after the first.
  final _more = <PostComment>[];

  /// The last page loaded.
  int _page = 1;

  late bool _hasMore = widget.post.moreComments;
  bool _loading = false;

  @override
  void didUpdateWidget(PostCommentSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.post.comments, widget.post.comments)) {
      _more.clear();
      _page = 1;
      _hasMore = widget.post.moreComments;
      _loading = false;
    }
  }

  Future<void> _loadMore() async {
    final tid = widget.tid;
    if (_loading || tid == null) {
      return;
    }
    setState(() => _loading = true);
    final comments = widget.post.comments;
    final page = await _repositoryOf(context).fetchMore(tid: tid, pid: widget.post.postID, page: _page + 1);
    if (!mounted || !identical(comments, widget.post.comments)) {
      return;
    }
    if (page == null) {
      setState(() => _loading = false);
      showSnackBar(context: context, message: context.t.postComment.loadFailed);
      return;
    }
    final known = {
      for (final c in [...widget.post.comments, ..._more])
        if (c.id != null) c.id!,
    };
    setState(() {
      _loading = false;
      _page++;
      _more.addAll(page.comments.where((c) => c.id == null || !known.contains(c.id)));
      _hasMore = page.hasMore && page.comments.isNotEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tid = widget.tid;
    final reload = widget.onReload;
    final comments = [...widget.post.comments, ..._more];
    return Padding(
      padding: edgeInsetsL16R16,
      child: AppEmbedCard(
        icon: Icons.reviews_outlined,
        title: context.t.postComment.title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, comment) in comments.indexed) ...[
              if (i > 0) sizedBoxW12H12,
              PostCommentTile(
                comment,
                onDelete: comment.canDelete && tid != null && reload != null
                    ? () async => showPostCommentDeleteDialog(context, tid: tid, comment: comment, onDone: reload)
                    : null,
              ),
            ],
            if (_hasMore && tid != null)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  key: const ValueKey('post-comment-more'),
                  onPressed: _loading ? null : _loadMore,
                  icon: _loading
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.expand_more),
                  label: Text(context.t.postComment.more),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One comment: the author's avatar and name, the time, the text, and its delete ([onDelete]) where offered.
class PostCommentTile extends StatelessWidget {
  /// Constructor.
  const PostCommentTile(this.comment, {this.onDelete, super.key});

  /// The comment.
  final PostComment comment;

  /// Delete it; null where the forum does not offer it.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final uid = comment.authorUid;
    Future<void> openAuthor() async => context.dispatchAsUrl('$baseUrl/home.php?mod=space&uid=$uid');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: uid == null ? null : openAuthor,
          child: CircleAvatar(
            radius: 14,
            backgroundImage: CachedImageProvider(
              comment.avatarUrl ?? noAvatarUrl,
              fallbackImageUrl: noAvatarUrl,
              usage: ImageUsageInfoUserAvatar(comment.authorName),
            ),
          ),
        ),
        sizedBoxW8H8,
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: comment.authorName,
                      style: textTheme.labelLarge?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold),
                    ),
                    if (comment.time case final time?)
                      TextSpan(
                        text: '  $time',
                        style: textTheme.labelSmall?.copyWith(color: colorScheme.outline),
                      ),
                  ],
                ),
              ),
              SelectableText(comment.content, style: textTheme.bodyMedium),
            ],
          ),
        ),
        if (onDelete != null)
          IconButton(
            key: ValueKey('post-comment-delete-${comment.id}'),
            visualDensity: VisualDensity.compact,
            tooltip: context.t.postComment.delete,
            icon: Icon(Icons.delete_outline, size: 20, color: colorScheme.outline),
            onPressed: onDelete,
          ),
      ],
    );
  }
}

/// Comment on a floor through the forum's window [commentAction] ([Post.commentAction]): the window is read first (a
/// refusal is said before anything is typed), the comment is sent once, and [onDone] reloads the floor's page when
/// the forum took it (or may have).
Future<void> showPostCommentDialog(BuildContext context, String commentAction, {VoidCallback? onDone}) async {
  final uid = _currentUid(context);
  if (uid == null) {
    showSnackBar(context: context, message: context.t.general.needLogin);
    return;
  }
  final outcome = await showDialog<PostCommentOutcome>(
    context: context,
    builder: (_) => RootPage(
      DialogPaths.postComment,
      _PostCommentDialog(repository: _repositoryOf(context), commentAction: commentAction, uid: uid),
    ),
  );
  if (!context.mounted || outcome == null) {
    return;
  }
  final tr = context.t.postComment;
  switch (outcome) {
    case PostCommentDone(:final message):
      showSnackBar(context: context, message: message.isEmpty ? tr.done : message);
      onDone?.call();
    case PostCommentRefused(:final message):
      showSnackBar(context: context, message: message.isEmpty ? tr.refused : message);
    case PostCommentUnknown():
      showSnackBar(context: context, message: tr.unknown);
      onDone?.call();
  }
}

class _PostCommentDialog extends StatefulWidget {
  const _PostCommentDialog({required this.repository, required this.commentAction, required this.uid});

  final PostCommentRepository repository;
  final String commentAction;
  final int uid;

  @override
  State<_PostCommentDialog> createState() => _PostCommentDialogState();
}

class _PostCommentDialogState extends State<_PostCommentDialog> {
  final _controller = TextEditingController();
  PostCommentForm? _form;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
    unawaited(_open());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final window = await widget.repository.openComment(widget.commentAction);
    if (!mounted) {
      return;
    }
    switch (window) {
      case PostCommentWindowForm(:final form):
        if (form.uid != null && form.uid != widget.uid) {
          Navigator.of(context).pop(PostCommentRefused(context.t.postComment.accountChanged));
          return;
        }
        setState(() => _form = form);
      case PostCommentWindowRefused(:final message):
        Navigator.of(context).pop(PostCommentRefused(message));
      case PostCommentWindowFailed():
        Navigator.of(context).pop(PostCommentRefused(context.t.postComment.loadFailed));
    }
  }

  Future<void> _send() async {
    final form = _form;
    final text = _controller.text.trim();
    if (form == null || text.isEmpty || _sending) {
      return;
    }
    if (!_sameAccount(context, widget.uid, form)) {
      Navigator.of(context).pop(PostCommentRefused(context.t.postComment.accountChanged));
      return;
    }
    setState(() => _sending = true);
    final outcome = await widget.repository.sendComment(form, text);
    if (!mounted) {
      return;
    }
    if (outcome is PostCommentRefused) {
      // The forum's words, the text kept to send again (too soon after the last post, a word it does not take…).
      setState(() => _sending = false);
      showSnackBar(
        context: context,
        message: outcome.message.isEmpty ? context.t.postComment.refused : outcome.message,
      );
      return;
    }
    Navigator.of(context).pop(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.postComment;
    final form = _form;
    return AlertDialog(
      icon: const Icon(Icons.add_comment_outlined),
      title: Text(tr.title),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 320),
        child: form == null
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            : TextField(
                key: const ValueKey('post-comment-input'),
                controller: _controller,
                autofocus: true,
                enabled: !_sending,
                minLines: 2,
                maxLines: 5,
                maxLength: form.maxLength,
                decoration: InputDecoration(
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
                ),
              ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        TextButton(
          key: const ValueKey('post-comment-send'),
          onPressed: form == null || _sending || _controller.text.trim().isEmpty ? null : _send,
          child: Text(tr.send),
        ),
      ],
    );
  }
}

/// Delete [comment] of thread [tid] as a moderator (the forum's `modaction('delcomment', ID)`): asked first with the
/// forum's optional reason, then its window is read and its form sent once; [onDone] reloads the floor's page when
/// the forum did it (or may have).
Future<void> showPostCommentDeleteDialog(
  BuildContext context, {
  required String tid,
  required PostComment comment,
  required VoidCallback onDone,
}) async {
  final id = comment.id;
  final uid = _currentUid(context);
  if (id == null || uid == null) {
    return;
  }
  final repository = _repositoryOf(context);
  final reason = await showDialog<String>(
    context: context,
    builder: (_) => RootPage(DialogPaths.postCommentDelete, _PostCommentDeleteDialog(comment)),
  );
  if (reason == null || !context.mounted) {
    return;
  }
  final tr = context.t.postComment;
  final window = await repository.openDelete(tid: tid, commentId: id);
  if (!context.mounted) {
    return;
  }
  final PostCommentOutcome outcome;
  switch (window) {
    case PostCommentWindowForm(:final form):
      if (!_sameAccount(context, uid, form)) {
        showSnackBar(context: context, message: tr.accountChanged);
        return;
      }
      outcome = await repository.sendDelete(form, reason);
    case PostCommentWindowRefused(:final message):
      outcome = PostCommentRefused(message);
    case PostCommentWindowFailed():
      showSnackBar(context: context, message: tr.loadFailed);
      return;
  }
  if (!context.mounted) {
    return;
  }
  switch (outcome) {
    case PostCommentDone(:final message):
      showSnackBar(context: context, message: message.isEmpty ? tr.deleted : message);
      onDone();
    case PostCommentRefused(:final message):
      showSnackBar(context: context, message: message.isEmpty ? tr.refused : message);
    case PostCommentUnknown():
      showSnackBar(context: context, message: tr.unknown);
      onDone();
  }
}

class _PostCommentDeleteDialog extends StatefulWidget {
  const _PostCommentDeleteDialog(this.comment);

  final PostComment comment;

  @override
  State<_PostCommentDeleteDialog> createState() => _PostCommentDeleteDialogState();
}

class _PostCommentDeleteDialogState extends State<_PostCommentDeleteDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.postComment;
    final colorScheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.delete_outline, color: colorScheme.error),
      title: Text(tr.deleteTitle),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PostCommentTile(widget.comment),
            sizedBoxW16H16,
            TextField(
              key: const ValueKey('post-comment-delete-reason'),
              controller: _reason,
              decoration: InputDecoration(
                labelText: tr.reason,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        TextButton(
          key: const ValueKey('post-comment-delete-confirm'),
          onPressed: () => Navigator.of(context).pop(_reason.text.trim()),
          child: Text(tr.delete, style: TextStyle(color: colorScheme.error)),
        ),
      ],
    );
  }
}
