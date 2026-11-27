part of 'thread_page.dart';

/// The "more" menu of the thread page.
extension _ThreadPageMenu on _ThreadPageState {
  /// Every item of the page's menu, in groups: finding one's way in the thread, keeping it, sharing and copying it
  /// (one item, the ways are on a sheet), reading tools, and moderating.
  ///
  /// Made each time the menu opens, from what is true then (the thread favorited or put aside meanwhile, the batch
  /// rating answered): everything is read, nothing watched, and no item needs the page built again to say the right
  /// thing. [context] is the page's, under its blocs; it outlives the menu.
  ///
  /// The conditions are what they were when the items stood in one list: nothing that needs the network on floors
  /// read back offline, nothing of the account without one.
  List<MenuCustomItem> _pageMenuItems(BuildContext context, String threadUrl) {
    final bloc = context.read<ThreadBloc>();
    final state = bloc.state;
    final t = context.t;
    final tid = state.tid;
    final hasFloors = state.postList.isNotEmpty;
    final uid = context.read<AuthenticationRepository>().effectiveCurrentUid;
    final online = !state.isOffline;
    final title = state.title ?? widget.title ?? '';

    final find = [
      if (hasFloors)
        MenuCustomItem(
          id: 'search',
          icon: Icons.search,
          description: t.threadPage.search.menu,
          onSelected: _openSearch,
        ),
      // Floor numbers are where the floors are only when every author's floors are listed.
      if (tid != null && state.onlyVisibleUid == null && hasFloors)
        MenuCustomItem(
          id: 'jump-to-floor',
          icon: Icons.format_list_numbered_outlined,
          description: t.threadPage.jumpToFloor.menu,
          onSelected: () async => _askJumpToFloor(context, state),
        ),
      // The floors of this thread the account bookmarked.
      if (tid != null)
        if (_threadBookmarks(context, state) case final bookmarks when bookmarks.isNotEmpty)
          MenuCustomItem(
            id: 'bookmarks',
            icon: Icons.turned_in_not_outlined,
            description: t.floorBookmark.title,
            onSelected: () async => _showBookmarks(context, bookmarks),
          ),
      MenuCustomItem(
        id: 'reverse-order',
        icon: state.shownNewestFirst ? Icons.align_vertical_bottom_outlined : Icons.align_vertical_top_outlined,
        description: state.shownNewestFirst ? t.networkList.actionForwardOrder : t.networkList.actionReverseOrder,
        onSelected: () => bloc.add(const ThreadChangeViewOrderRequested()),
      ),
      MenuCustomItem(
        id: 'back-to-top',
        icon: Icons.vertical_align_top_outlined,
        description: t.networkList.actionBackToTop,
        onSelected: () async => _backToTop(context),
      ),
      MenuCustomItem(
        id: 'refresh',
        icon: Icons.refresh_outlined,
        description: t.networkList.actionRefresh,
        onSelected: () => bloc.add(_refreshEvent()),
      ),
    ];

    final keep = tid == null
        ? const <MenuCustomItem>[]
        : [
            // Favorite needs the network: not offered on floors read back offline.
            if (online)
              MenuCustomItem(
                id: 'favorite',
                icon: isThreadFavorited(context, tid: tid)
                    ? Icons.bookmark_remove_outlined
                    : Icons.bookmark_add_outlined,
                description: isThreadFavorited(context, tid: tid)
                    ? t.threadPage.favorite.remove
                    : t.threadPage.favorite.add,
                onSelected: () async => toggleThreadFavorite(context, tid: tid),
              ),
            // Not on one author's floors: their count is not the thread's.
            if (online &&
                state.onlyVisibleUid == null &&
                uid != null &&
                context.readOrNull<FollowedThreadsCubit>() != null)
              MenuCustomItem(
                id: 'follow',
                icon: _follows(context, tid) ? Icons.notifications_off_outlined : Icons.notifications_active_outlined,
                description: _follows(context, tid) ? t.threadPage.follow.remove : t.threadPage.follow.add,
                onSelected: () async => _toggleFollow(context, state),
              ),
            // Put aside on this device for the account in use: offline floors can be too.
            if (context.readOrNull<ReadLaterCubit>()?.state.uid != null)
              MenuCustomItem(
                id: 'read-later',
                icon: _putAside(context, tid) ? Icons.watch_later : Icons.watch_later_outlined,
                description: _putAside(context, tid) ? t.readLater.remove : t.readLater.add,
                onSelected: () async => _toggleReadLater(context, state),
              ),
            // The forum's 淘帖: put the thread in collections of the account.
            if (int.tryParse(tid) case final id? when id > 0 && online && uid != null)
              MenuCustomItem(
                id: 'collect',
                icon: Icons.collections_bookmark_outlined,
                description: t.collection.collect,
                onSelected: () async => showCollectThreadSheet(context, tid: id),
              ),
          ];

    final share = [
      MenuCustomItem(
        id: 'share-and-copy',
        icon: Icons.ios_share_outlined,
        description: t.postCard.shareAndCopy,
        onSelected: () async => _shareAndCopy(context, state, threadUrl: threadUrl, title: title),
      ),
    ];

    final tools = tid == null
        ? const <MenuCustomItem>[]
        : [
            if (state.fid case final fid? when !_immersiveForums(context).all)
              MenuCustomItem(
                id: 'immersive-forum',
                icon: _immersiveForums(context).picks(fid) ? Icons.check_box_outlined : Icons.check_box_outline_blank,
                description: t.threadPage.immersiveForum,
                onSelected: () => _toggleImmersiveForum(context, fid, picked: !_immersiveForums(context).picks(fid)),
              ),
            if (hasFloors)
              MenuCustomItem(
                id: 'export',
                icon: Icons.file_download_outlined,
                description: t.threadExport.menu,
                onSelected: () async => exportThread(context, state),
              ),
            if (hasFloors && _ThreadPageState._canSpeak)
              MenuCustomItem(
                id: 'tts',
                icon: Icons.record_voice_over_outlined,
                description: t.threadTts.menu,
                onSelected: () async => _startTts(state),
              ),
            if (_batchRateFor(context, state) case final info?)
              MenuCustomItem(
                id: 'batch-rate',
                icon: Icons.thumbs_up_down_outlined,
                description: t.batchRate.title,
                onSelected: () async => _openBatchRate(context, state, info),
              ),
          ];

    final moderate = [
      if (tid != null &&
          (_threadOperations(state).isNotEmpty ||
              (online &&
                  state.fid != null &&
                  (state.perms?.adminActions(formsKnown: threadAdminFormsKnown()).isNotEmpty ?? false))))
        MenuCustomItem(
          id: 'moderate',
          icon: Icons.admin_panel_settings_outlined,
          description: t.moderate.menu,
          onSelected: () async => _moderate(context, state),
        ),
    ];

    return [
      for (final group in [find, keep, share, tools, moderate])
        for (final (index, item) in group.indexed)
          index == 0
              ? MenuCustomItem(
                  id: item.id,
                  icon: item.icon,
                  description: item.description,
                  onSelected: item.onSelected,
                  dividerBefore: true,
                )
              : item,
    ];
  }

  bool _follows(BuildContext context, String tid) {
    final id = int.tryParse(tid);
    return id != null && context.readOrNull<FollowedThreadsCubit>()?.state.of(id) != null;
  }

  bool _putAside(BuildContext context, String tid) {
    final id = int.tryParse(tid);
    return id != null && (context.readOrNull<ReadLaterCubit>()?.state.contains(id) ?? false);
  }

  /// Put the thread aside to read later, or take it off the list.
  Future<void> _toggleReadLater(BuildContext context, ThreadState state) async {
    // Before the list changes: nothing may take it off in between.
    final tid = int.tryParse(state.tid!);
    if (tid != null && !(context.readOrNull<ReadLaterCubit>()?.state.contains(tid) ?? false)) {
      _readLaterAddedHere = tid;
    }
    final added = await toggleReadLater(
      context,
      tid: state.tid!,
      title: state.title ?? widget.title ?? '',
      author: state.postList.firstWhereOrNull((e) => e.postFloor == 1)?.author.name,
      forumName: state.forumName,
    );
    _readLaterAddedHere = added ? tid : null;
  }

  /// The sheet of the ways to share and copy the thread, then what was picked on it: the sheet is closed by then,
  /// a dialog or a page opens from the page's [context].
  Future<void> _shareAndCopy(
    BuildContext context,
    ThreadState state, {
    required String threadUrl,
    required String title,
  }) async {
    final tid = state.tid;
    final signedIn = context.read<AuthenticationRepository>().effectiveCurrentUid != null;
    final pin = tid == null ? null : pinToHomeMenuItem(context, PinnedThread.tryParse(tid), title);
    final picked = await showThreadShareSheet(
      context,
      tid: tid,
      offered: {
        ThreadShareAction.copyLink,
        ThreadShareAction.openInBrowser,
        if (tid != null) ...{
          ThreadShareAction.copyShareText,
          ThreadShareAction.qrCode,
          ThreadShareAction.copyTid,
          // Needs the network and an account.
          if (!state.isOffline && signedIn) ThreadShareAction.toFriend,
          if (pin != null) ThreadShareAction.pinToHome,
        },
      },
    );
    if (picked == null || !context.mounted) {
      return;
    }
    switch (picked) {
      case ThreadShareAction.copyLink:
        await copyToClipboard(context, shortThreadUrl(threadUrl));
      case ThreadShareAction.openInBrowser:
        await context.dispatchAsUrl(threadUrl, external: true);
      case ThreadShareAction.copyShareText:
        await copyToClipboard(context, threadShareText(context, title: title, url: shortThreadUrl(threadUrl)));
      case ThreadShareAction.qrCode:
        await showShareQrDialog(context, url: shareQrThreadUrl(tid!), title: title, fileName: 'tsdm-thread-$tid');
      case ThreadShareAction.toFriend:
        await shareThreadToFriend(context, tid: tid!, title: state.title ?? '');
      case ThreadShareAction.pinToHome:
        await pin?.onSelected();
      case ThreadShareAction.copyTid:
        await copyToClipboard(context, tid!);
    }
  }
}
