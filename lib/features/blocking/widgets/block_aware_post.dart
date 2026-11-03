import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/blocking/widgets/user_block_button.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/post_card/floor_label.dart';

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
        hot: post.hot,
        hotFloor: post.hotFloor,
        pending: !list.isKnown,
        failed: list.status == UserBlockListStatus.failed,
      );
    }
    // Content of a keyword the current account blocked: the floor and its author stay, its body and signature do not
    // show. The first floor too, the rest of the thread stays readable.
    if (keywordHidesPost(post, currentKeywordBlockList(context))) {
      return KeywordBlockedPostPlaceholder(
        username: post.author.name,
        floor: post.postFloor,
        hot: post.hot,
        hotFloor: post.hotFloor,
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
    // A redacted floor drops its bbcode as well: the app renderer would draw the blocked quote from it.
    return builder(
      context,
      identical(data, post.data)
          ? post
          : post.copyWith(data: data, messageBbcode: null, messageReason: 'blocked-quote'),
    );
  }
}

/// Placeholder of a post from a locally blocked user.
class BlockedPostPlaceholder extends StatelessWidget {
  /// Constructor.
  const BlockedPostPlaceholder({
    required this.uid,
    required this.username,
    this.floor,
    this.hot = false,
    this.hotFloor,
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

  /// A hot reply: "推荐" in place of the floor number, with [hotFloor] when known, as the card says.
  final bool hot;

  /// The floor a [hot] reply really is, when known.
  final int? hotFloor;

  /// The block list is not known yet (loading or failed): the post is held back, not known as blocked.
  final bool pending;

  /// With [pending]: reading the block list failed, said so instead of "reading".
  final bool failed;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.userBlock;
    final action = pending
        ? TextButton(
            onPressed: () async => context.read<UserBlockCubit>().reload(),
            child: Text(context.t.general.retry),
          )
        : TextButton(
            onPressed: () async => unblockUser(context, uid: uid, username: username),
            child: Text(tr.unblock),
          );
    return _PostPlaceholderCard(
      floor: floor,
      hot: hot,
      hotFloor: hotFloor,
      icon: _pendingIcon(pending: pending, failed: failed),
      error: pending && failed,
      text: pending ? _pendingText(tr, failed: failed) : tr.postPlaceholder,
      action: action,
    );
  }
}

/// Placeholder of a post containing a keyword blocked locally.
///
/// Only the content is hidden, the author is still named. Like [BlockedPostPlaceholder] it has no "show anyway"
/// action: the content comes back by removing the keyword.
class KeywordBlockedPostPlaceholder extends StatelessWidget {
  /// Constructor.
  const KeywordBlockedPostPlaceholder({required this.username, this.floor, this.hot = false, this.hotFloor, super.key});

  /// Author name, shown beside the floor number.
  final String username;

  /// Floor number, kept so the floors around stay in place.
  final int? floor;

  /// A hot reply, see [BlockedPostPlaceholder.hot].
  final bool hot;

  /// The floor a [hot] reply really is, when known.
  final int? hotFloor;

  @override
  Widget build(BuildContext context) => _PostPlaceholderCard(
    floor: floor,
    hot: hot,
    hotFloor: hotFloor,
    icon: Icons.filter_alt_off_outlined,
    author: username,
    text: context.t.userBlock.keyword.postPlaceholder,
  );
}

/// A muted, compact floor: the floor number keeps its place, the content is replaced by one line and an optional
/// action.
class _PostPlaceholderCard extends StatelessWidget {
  const _PostPlaceholderCard({
    required this.floor,
    required this.hot,
    required this.hotFloor,
    required this.icon,
    required this.text,
    this.author,
    this.error = false,
    this.action,
  });

  final int? floor;
  final String? author;
  final bool hot;
  final int? hotFloor;
  final IconData icon;
  final String text;
  final bool error;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final action = this.action;
    return Card(
      margin: EdgeInsets.zero,
      color: colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // The action beside the text only when it leaves the text a readable width: on a narrow phone or with a
            // large font the button would squeeze the message to a word per line, so it moves under the message.
            final scale = MediaQuery.textScalerOf(context).scale(1);
            final besideText = constraints.maxWidth >= 420 * scale;
            final texts = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text.rich(
                  TextSpan(
                    text: postFloorLabel(context.t, floor: floor, hot: hot, hotFloor: hotFloor),
                    children: [
                      if (author != null && author!.isNotEmpty)
                        TextSpan(
                          text: '  $author',
                          style: TextStyle(color: colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600),
                        ),
                    ],
                  ),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(color: colorScheme.outline),
                ),
                Text(
                  text,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
                if (action != null && !besideText) Align(alignment: AlignmentDirectional.centerEnd, child: action),
              ],
            );
            return Row(
              crossAxisAlignment: besideText || action == null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
              children: [
                AppIconTile(
                  icon,
                  size: 32,
                  color: error ? colorScheme.errorContainer : colorScheme.surfaceContainerHighest,
                  foregroundColor: error ? colorScheme.onErrorContainer : colorScheme.outline,
                ),
                sizedBoxW12H12,
                Expanded(child: texts),
                if (action != null && besideText) action,
              ],
            );
          },
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
    return AppStateView(
      icon: _pendingIcon(pending: pending, failed: failed),
      error: pending && failed,
      message: pending ? _pendingText(tr, failed: failed) : tr.threadHidden,
      action: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
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
