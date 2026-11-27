part of 'post_card.dart';

/// Actions in post context menu.
///
/// * State of [viewTheAuthor] and [viewAllAuthors] are thread level state so
///   this state is stored by the parent thread. Disable these actions when
///   there is no available thread above current post in the widget tree.
enum _PostCardActions {
  reply,

  /// Start picking floors to quote in one reply.
  addQuote,
  rate,

  /// Comment on the floor (点评), where the forum lets this account ([Post.commentAction]).
  comment,

  /// Only view posts published by current author.
  viewTheAuthor,

  /// View all authors.
  viewAllAuthors,

  /// Open the other threads of the floor's author (the member's "TA的主题" list), for another member's floor.
  authorThreads,

  /// Edit the post.
  ///
  /// Only available when the current user is the author of post.
  edit,

  /// Bookmark the floor, or change or remove its bookmark (on this device, carried by the cross-device sync).
  bookmark,

  /// Share the post.
  ///
  /// Share with thread and post id, and 'fromuid=$UID'.
  share,

  /// Render the floor to a picture to save or share ([ShareFloorImagePage]).
  shareAsImage,

  /// Save every picture of the floor, or of its page.
  saveImages,

  /// Open the post link in browser.
  ///
  /// Use the anchor not works on mobile UI no matter it always is or originally was `findpost`.
  openInBrowser,

  /// Open the dialog to copy contents.
  openAndCopy,

  /// Copy the content as plain text.
  copyAsPlainText,

  /// Copy the content as Markdown.
  copyAsMarkdown,

  /// Copy every online storage link of the floor with its codes.
  copyNetdisk,

  /// Copy post id.
  copyPid,

  /// Report the post to the forum.
  ///
  /// Only available when the forum offered the report link of this floor to the account that read the page (#127).
  report,

  /// Warn the author for the floor, or take it back (moderators, [PostCard.onModerate]).
  moderateWarn,

  /// Hide the floor, or show it again (moderators).
  moderateBan,

  /// Delete the reply (moderators, not the first floor).
  moderateDelete,

  /// Stick the reply under the first floor, or unstick it (moderators, not the first floor).
  moderateStick,

  /// Take rates of the floor back (moderators, a floor rated: the forum's 撤销评分 beside 评分).
  moderateRemoveRate,

  /// Ban the floor's author from posting, or lift the ban ([PostCard.onBanAuthor]).
  banAuthor,

  /// The poster's IP of the floor (moderators the forum lets see it, [Post.viewIpUrl]).
  viewIp,

  /// Open the sheet of the ways to share and copy the floor; what is picked there is one of the actions above.
  shareAndCopy,

  /// Open the sheet of what a moderator may do with the floor; what is picked there is one of the actions above.
  moderate,
}

/// The menu of a floor.
extension _PostCardMenu on _PostCardState {
  List<PopupMenuEntry<_PostCardActions>> _buildContextMenuEntries(BuildContext context) {
    final threadBloc = context.readOrNull<ThreadBloc>();
    final onlyVisibleUid = threadBloc?.state.onlyVisibleUid;
    // Read back from an offline copy: nothing that needs the network.
    final online = !isOfflineFloor(context);
    final colorScheme = Theme.of(context).colorScheme;

    PopupMenuItem<_PostCardActions> item(
      _PostCardActions value,
      IconData icon,
      String text, {
      Color? color,
      double? fill,
    }) => PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, color: color, fill: fill),
          sizedBoxPopupMenuItemIconSpacing,
          Flexible(
            child: Text(text, style: color == null ? null : TextStyle(color: color)),
          ),
        ],
      ),
    );

    // Answer the floor, change what is shown (author filter, edit), then one way each to the sheets of sharing and
    // copying and of moderating (their actions and conditions are what the menu listed before), and report on its
    // own in the error color.
    final groups = <List<PopupMenuEntry<_PostCardActions>>>[
      [
        if (online) item(_PostCardActions.reply, Symbols.reply_rounded, context.t.postCard.reply),
        if (online && _quotable)
          item(_PostCardActions.addQuote, Symbols.format_quote_rounded, context.t.postCard.addQuote),
        if (online && widget.post.rateAction != null)
          item(_PostCardActions.rate, Symbols.rate_review_rounded, context.t.postCard.rate),
        if (online && widget.post.commentAction != null)
          item(_PostCardActions.comment, Symbols.add_comment_rounded, context.t.postComment.menu),
      ],
      [
        if (_bookmarkTarget(context) != null)
          if (_bookmarkOf(context, listen: false) == null)
            item(_PostCardActions.bookmark, Symbols.turned_in_not_rounded, context.t.floorBookmark.add)
          else
            item(_PostCardActions.bookmark, Symbols.turned_in_rounded, context.t.floorBookmark.edit, fill: 1),
      ],
      [
        // Viewing all authors, can switch to only view current author mode.
        if (threadBloc != null && onlyVisibleUid == null && widget.post.author.uid != null)
          item(_PostCardActions.viewTheAuthor, Symbols.person_rounded, context.t.postCard.onlyViewAuthor),
        // Viewing specified author now, can switch to view all authors mode.
        if (threadBloc != null && onlyVisibleUid != null)
          item(_PostCardActions.viewAllAuthors, Symbols.group_rounded, context.t.postCard.viewAllAuthors),
        if (online && _otherAuthorUid(context) != null)
          item(_PostCardActions.authorThreads, Symbols.topic_rounded, context.t.postCard.authorThreads),
        if (online && widget.post.editUrl != null)
          item(_PostCardActions.edit, Symbols.edit_rounded, context.t.postCard.edit),
      ],
      [
        if (_shareSheetOffered)
          item(_PostCardActions.shareAndCopy, Symbols.ios_share_rounded, context.t.postCard.shareAndCopy),
      ],
      [
        if (_moderateSheetItems(context).isNotEmpty)
          item(
            _PostCardActions.moderate,
            Symbols.admin_panel_settings_rounded,
            context.t.moderate.menu,
          ),
      ],
      [
        if (online && widget.post.reportTarget != null)
          item(_PostCardActions.report, Symbols.flag_rounded, context.t.postReport.menu, color: colorScheme.error),
      ],
    ];

    return [
      // Which floor the menu acts on.
      PopupMenuItem<_PostCardActions>(
        enabled: false,
        height: 32,
        child: Text(
          [
            widget.post.author.name.truncate(10, ellipsis: true),
            if (widget.post.shownFloor case final floor?) '#$floor',
          ].join(' '),
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
            color: colorScheme.secondary,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      for (final group in groups.where((e) => e.isNotEmpty)) ...[const PopupMenuDivider(height: 8), ...group],
    ];
  }
}
