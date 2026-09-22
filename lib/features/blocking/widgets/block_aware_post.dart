import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/blocking/widgets/user_block_button.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// Shows [post] through [builder], or a placeholder keeping its floor when the author is blocked locally.
///
/// The placeholder has no "show anyway" action: the content only comes back by unblocking. While the block list of
/// the current account is not known yet, posts of identified authors wait behind a neutral placeholder instead of
/// being shown for a moment. Quotes of posts in [postList] written by blocked users are replaced with a notice;
/// quotes of posts not loaded here can not be attributed and are kept.
class BlockAwarePost extends StatelessWidget {
  /// Constructor.
  const BlockAwarePost({required this.post, required this.postList, required this.builder, super.key});

  /// The post.
  final Post post;

  /// Posts loaded on the page, to attribute quotes.
  final List<Post> postList;

  /// Builds the normal card.
  final Widget Function(BuildContext context, Post post) builder;

  @override
  Widget build(BuildContext context) {
    final list = currentBlockList(context);
    final authorUid = int.tryParse(post.author.uid ?? '');
    if (list.hides(authorUid)) {
      return BlockedPostPlaceholder(
        uid: authorUid!,
        username: post.author.name,
        floor: post.postFloor,
        pending: !list.isKnown,
        failed: list.status == UserBlockListStatus.failed,
      );
    }
    if (list.uids.isEmpty) {
      return builder(context, post);
    }
    // Remembered with the post: a rebuild of the page does not parse every kept post with a quote again.
    final data = redactBlockedQuotesOf(
      post,
      blockedUids: list.uids,
      authorOfPost: (pid) => int.tryParse(postList.where((e) => e.postID == '$pid').firstOrNull?.author.uid ?? ''),
      placeholder: context.t.userBlock.quotePlaceholder,
    );
    return builder(context, identical(data, post.data) ? post : post.copyWith(data: data));
  }
}

/// Placeholder of a post from a locally blocked user.
class BlockedPostPlaceholder extends StatelessWidget {
  /// Constructor.
  const BlockedPostPlaceholder({
    required this.uid,
    required this.username,
    this.floor,
    this.pending = false,
    this.failed = false,
    super.key,
  });

  /// Author uid.
  final int uid;

  /// Author name.
  final String username;

  /// Floor number, kept so the floors around stay in place.
  final int? floor;

  /// The block list is not known yet (loading or failed): the post is held back, not known as blocked.
  final bool pending;

  /// With [pending]: reading the block list failed, said so instead of "reading".
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.userBlock;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: edgeInsetsL12T12R12B12,
        child: Row(
          children: [
            Text(floor == null ? '#' : '#$floor', style: Theme.of(context).textTheme.labelMedium),
            sizedBoxW8H8,
            Icon(_pendingIcon(pending: pending, failed: failed), size: 18),
            sizedBoxW8H8,
            Expanded(child: Text(pending ? _pendingText(tr, failed: failed) : tr.postPlaceholder)),
            if (pending)
              TextButton(
                onPressed: () async => context.read<UserBlockCubit>().reload(),
                child: Text(context.t.general.retry),
              )
            else
              TextButton(
                onPressed: () async => unblockUser(context, uid: uid, username: username),
                child: Text(tr.unblock),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shown instead of a whole thread whose first post is written by a locally blocked user.
///
/// Nothing of the thread (title, first post, replies) is shown; the user can go back or unblock the author.
class BlockedThreadNotice extends StatelessWidget {
  /// Constructor.
  const BlockedThreadNotice({
    required this.uid,
    required this.username,
    this.pending = false,
    this.failed = false,
    super.key,
  });

  /// Uid of the thread author.
  final int uid;

  /// Name of the thread author.
  final String username;

  /// The block list is not known yet: the thread is held back, not known as blocked.
  final bool pending;

  /// With [pending]: reading the block list failed, said so instead of "reading".
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.userBlock;
    return Center(
      child: Padding(
        padding: edgeInsetsL12T12R12B12,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_pendingIcon(pending: pending, failed: failed), size: 48),
            sizedBoxW8H8,
            Text(pending ? _pendingText(tr, failed: failed) : tr.threadHidden, textAlign: TextAlign.center),
            sizedBoxW8H8,
            Wrap(
              spacing: 8,
              children: [
                if (Navigator.of(context).canPop())
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(tr.goBack),
                  ),
                if (pending)
                  FilledButton(
                    onPressed: () async => context.read<UserBlockCubit>().reload(),
                    child: Text(context.t.general.retry),
                  )
                else
                  FilledButton(
                    onPressed: () async => unblockUser(context, uid: uid, username: username),
                    child: Text(tr.unblock),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

IconData _pendingIcon({required bool pending, required bool failed}) => switch ((pending, failed)) {
  (false, _) => Icons.block_outlined,
  (true, false) => Icons.hourglass_empty_outlined,
  (true, true) => Icons.error_outline,
};

/// Text of content held back while the block list is unknown: still being read, or [failed] to be read.
String _pendingText(TranslationsUserBlockEn tr, {required bool failed}) => failed ? tr.loadFailed : tr.listPending;
