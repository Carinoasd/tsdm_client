part of 'post_card.dart';

/// The ways to share and copy a floor, on a sheet of their own.
extension _PostCardShareSheet on _PostCardState {
  /// Whether the sheet has anything to offer: pictures to save (a floor without a link has them too), or the link
  /// the other actions need.
  bool get _shareSheetOffered => galleryImagesOfPost(widget.post).isNotEmpty || widget.post.shareLink != null;

  /// Ask which way to share or copy the floor; null when the sheet was dismissed.
  Future<_PostCardActions?> _pickShareAction(BuildContext context) {
    final linked = widget.post.shareLink != null;
    return showActionSheet<_PostCardActions>(
      context: context,
      title: context.t.postCard.shareAndCopy,
      primary: [
        if (linked) ...[
          ActionSheetItem(value: _PostCardActions.share, icon: Symbols.share_rounded, label: context.t.postCard.share),
          ActionSheetItem(
            value: _PostCardActions.shareAsImage,
            icon: Symbols.image_rounded,
            label: context.t.postCard.shareAsImage,
          ),
          ActionSheetItem(
            value: _PostCardActions.openAndCopy,
            icon: Symbols.content_copy_rounded,
            label: context.t.postCard.copyText,
          ),
          ActionSheetItem(
            value: _PostCardActions.openInBrowser,
            icon: Symbols.open_in_browser_rounded,
            label: context.t.postCard.openInBrowser,
          ),
        ],
      ],
      secondary: [
        if (linked) ...[
          ActionSheetItem(
            value: _PostCardActions.copyAsPlainText,
            icon: Symbols.notes_rounded,
            label: context.t.threadExport.copyPlain,
          ),
          ActionSheetItem(
            value: _PostCardActions.copyAsMarkdown,
            icon: Symbols.code_rounded,
            label: context.t.threadExport.copyMarkdown,
          ),
          if (_netdiskLinks().isNotEmpty)
            ActionSheetItem(
              value: _PostCardActions.copyNetdisk,
              icon: Symbols.cloud_download_rounded,
              label: context.t.netdisk.copyAll,
            ),
        ],
        if (galleryImagesOfPost(widget.post).isNotEmpty)
          ActionSheetItem(
            value: _PostCardActions.saveImages,
            icon: Symbols.download_for_offline_rounded,
            label: context.t.imageBottomSheet.saveAllImages,
          ),
        if (linked)
          ActionSheetItem(
            value: _PostCardActions.copyPid,
            icon: Symbols.numbers_rounded,
            label: context.t.postCard.copyPid(pid: widget.post.postID),
          ),
      ],
    );
  }
}
