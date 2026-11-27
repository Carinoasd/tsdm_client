part of 'post_card.dart';

/// What a moderator may do with a floor, on a sheet of its own.
extension _PostCardModerateSheet on _PostCardState {
  /// The actions offered on this floor, none on a floor read back from an offline copy; the same ones under the
  /// same conditions as when the menu listed them.
  List<ActionSheetItem<_PostCardActions>> _moderateSheetItems(BuildContext context) {
    if (isOfflineFloor(context)) {
      return const [];
    }
    final colorScheme = Theme.of(context).colorScheme;
    return [
      if (widget.onModerate != null)
        // The first floor: numbered 1, or linked as the thread (the web page's default template prints 楼主).
        for (final action in floorModerateActionsFor(
          first: widget.post.postFloor == 1 || (widget.post.shareLink?.contains('mod=viewthread&') ?? false),
        ))
          if (widget.moderateActions?.contains(action) ?? true)
            ActionSheetItem(
              value: switch (action) {
                FloorModerateAction.warn => _PostCardActions.moderateWarn,
                FloorModerateAction.ban => _PostCardActions.moderateBan,
                FloorModerateAction.delete => _PostCardActions.moderateDelete,
                FloorModerateAction.stick => _PostCardActions.moderateStick,
              },
              // A floor known warned or stuck is offered taking it back (the forum's window decides all the same).
              icon: floorModerateIcon(action, undo: _knownDone(action)),
              label: floorModerateName(context, action, undo: _knownDone(action)),
              color: action == FloorModerateAction.delete ? colorScheme.error : null,
            ),
      if (widget.onModerate != null &&
          widget.canRemoveRate &&
          widget.post.rate != null &&
          _removeRateTid(context) != null)
        ActionSheetItem(
          value: _PostCardActions.moderateRemoveRate,
          icon: Symbols.remove_circle_rounded,
          label: context.t.moderateFloorOps.removeRate,
        ),
      if (widget.post.viewIpUrl != null)
        ActionSheetItem(
          value: _PostCardActions.viewIp,
          icon: Symbols.lan_rounded,
          label: context.t.moderateFloorOps.viewIp,
        ),
      if (widget.onBanAuthor != null)
        ActionSheetItem(
          value: _PostCardActions.banAuthor,
          icon: memberBanIcon(undo: widget.post.authorBanned),
          label: widget.post.authorBanned ? context.t.moderate.unbanMember : context.t.moderate.banMember,
        ),
    ];
  }

  /// Ask what to do with the floor; null when the sheet was dismissed.
  Future<_PostCardActions?> _pickModerateAction(BuildContext context) => showActionSheet<_PostCardActions>(
    context: context,
    title: [
      context.t.moderate.menu,
      if (widget.post.shownFloor case final floor?) '#$floor',
    ].join(' '),
    secondary: _moderateSheetItems(context),
  );
}
