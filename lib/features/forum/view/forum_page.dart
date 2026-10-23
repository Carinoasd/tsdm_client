import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/list.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/widgets/account_reload_scope.dart';
import 'package:tsdm_client/features/favorite/utils/forum_favorite_action.dart';
import 'package:tsdm_client/features/forum/bloc/forum_bloc.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/widgets/thread_filter_chip.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/forum_card.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/list_app_bar/list_app_bar.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';
import 'package:tsdm_client/widgets/post_layout_html.dart';

const _tabsCount = 3;
const _pinnedTabIndex = 0;
const _threadTabIndex = 1;
const _subredditTabIndex = 2;

const Cubic _backToTopCurve = Curves.ease;
const Duration _backToTopAnimationDuration = duration500;

/// Page to show all forum status.
class ForumPage extends StatefulWidget {
  /// Constructor.
  const ForumPage({required this.fid, this.title, this.threadType, super.key})
    : forumUrl = '$baseUrl/forum.php?mod=forumdisplay&fid=$fid';

  /// Forum ID.
  final String fid;

  /// Forum title.
  final String? title;

  /// The url is used to provide features like "open in external browser".
  final String forumUrl;

  /// Optional thread type filter.
  ///
  /// The opened page will apply a "filter=typeid&typeid=$threadType" filter on the page.
  final FilterType? threadType;

  @override
  State<ForumPage> createState() => _ForumPageState();
}

class _ForumPageState extends State<ForumPage> with SingleTickerProviderStateMixin, LoggerMixin {
  final _pinnedScrollController = ScrollController();
  final _pinnedRefreshController = EasyRefreshController(controlFinishRefresh: true);

  final _subredditScrollController = ScrollController();
  final _subredditRefreshController = EasyRefreshController(controlFinishRefresh: true);

  /// Controller of thread tab.
  final _threadScrollController = ScrollController();

  /// Controller of the [EasyRefresh] in thread tab.
  ///
  /// The next page is asked by the end of the list ([ListFooter]), the controller only finishes the pull to refresh.
  final _threadRefreshController = EasyRefreshController(controlFinishRefresh: true);

  /// Controller of current tab: thread, subreddit.
  late TabController tabController;

  /// Visibility of FAB.
  bool _fabVisible = true;

  /// The post button shows its label; scrolling the list down folds it to its icon, scrolling up unfolds it.
  bool _fabExtended = true;

  /// The bloc of this page, created by the provider in [build]. Created again for another account (see
  /// [AccountReloadScope]); the new one keeps the filter of this one.
  ForumBloc? _forumBloc;

  void _updateFabVisibilityByTabIndex() {
    if (tabController.index == _threadTabIndex) {
      setState(() {
        _fabVisible = true;
      });
    } else {
      setState(() {
        _fabVisible = false;
      });
    }
  }

  PreferredSizeWidget _buildListAppBar(BuildContext context, ForumState state) {
    return ListAppBar(
      title: widget.title ?? state.title,
      bottom: state.permissionDeniedMessage == null
          ? TabBar(
              controller: tabController,
              tabs: [
                Tab(child: Text(context.t.forumPage.stickThreadTab.title)),
                Tab(child: Text(context.t.forumPage.threadTab.title)),
                Tab(child: Text(context.t.forumPage.subredditTab.title)),
              ],
              onTap: (index) async {
                // Here we want to scroll the current tab to the top.
                // Only scroll to top when user taps on the current
                // tab, which means index is not changing.
                if (tabController.indexIsChanging) {
                  // Do nothing because user tapped another index
                  // and want to switch to it.
                  return;
                }
                const duration = Duration(milliseconds: 300);
                const curve = Curves.ease;
                switch (tabController.index) {
                  case _pinnedTabIndex:
                    if (_pinnedScrollController.hasClients) {
                      await _pinnedScrollController.animateTo(0, duration: duration, curve: curve);
                    }
                  case _threadTabIndex:
                    if (_threadScrollController.hasClients) {
                      await _threadScrollController.animateTo(0, duration: duration, curve: curve);
                    }
                  case _subredditTabIndex:
                    if (_subredditScrollController.hasClients) {
                      await _subredditScrollController.animateTo(0, duration: duration, curve: curve);
                    }
                }
              },
            )
          : null,
      onSearch: () async => context.pushNamed(ScreenPaths.search, queryParameters: {'fid': widget.fid}),
      onJumpPage: (pageNumber) async {
        if (!mounted) {
          return;
        }
        // Mark loading here.
        // Mark state will be removed when
        // loading finishes (next build).
        context.read<JumpPageCubit>().markLoading();
        context.read<ForumBloc>().add(ForumJumpPageRequested(pageNumber));
      },
      onRefresh: () async => switch (tabController.index) {
        _pinnedTabIndex => await _pinnedRefreshController.callRefresh(),
        _threadTabIndex => await _threadRefreshController.callRefresh(),
        _subredditTabIndex => await _subredditRefreshController.callRefresh(),
        _ => context.mounted ? context.read<ForumBloc>().add(ForumRefreshRequested()) : null,
      },
      onCopyUrl: () async => copyToClipboard(context, widget.forumUrl),
      onOpenInBrowser: () async => context.dispatchAsUrl(widget.forumUrl, external: true),
      onBackToTop: () async => await switch (tabController.index) {
        _pinnedTabIndex when _pinnedScrollController.hasClients => _pinnedScrollController,
        _threadTabIndex when _threadScrollController.hasClients => _threadScrollController,
        _subredditTabIndex when _subredditScrollController.hasClients => _subredditScrollController,
        _ => null,
      }?.animateTo(0, curve: _backToTopCurve, duration: _backToTopAnimationDuration),
      customMenuItems: [
        MenuCustomItem(
          icon: isForumFavorited(context, fid: widget.fid)
              ? Icons.bookmark_remove_outlined
              : Icons.bookmark_add_outlined,
          description: isForumFavorited(context, fid: widget.fid)
              ? context.t.forumPage.favorite.remove
              : context.t.forumPage.favorite.add,
          onSelected: () async {
            final changed = await toggleForumFavorite(context, fid: widget.fid);
            if (changed && mounted) {
              // Relabel the menu item.
              setState(() {});
            }
          },
        ),
        MenuCustomItem(
          icon: Icons.numbers_outlined,
          description: context.t.forumPage.copyFid(fid: widget.fid),
          onSelected: () async => copyToClipboard(context, widget.fid),
        ),
      ],
    );
  }

  /// Filter bar pinned above the threads: opaque with a hairline under it, the chips start at the edge of the
  /// centered column of cards and scroll sideways when they do not fit. Its height follows the chips, so a large font
  /// is not clipped.
  Widget _buildNormalThreadFilterRow(BuildContext context, ForumState state) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(bottom: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.6))),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: appCenteredPadding(constraints.maxWidth).copyWith(top: 4, bottom: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              // Decorative lead of the bar, every chip carries its own label.
              ExcludeSemantics(child: Icon(Icons.tune_outlined, size: 20, color: colorScheme.primary)),
              if (state.filterTypeList.isNotEmpty) const ThreadTypeChip(),
              if (state.filterSpecialTypeList.isNotEmpty) const ThreadSpecialTypeChip(),
              if (state.filterDatelineList.isNotEmpty) const ThreadDatelineChip(),
              if (state.filterOrderList.isNotEmpty) const ThreadOrderChip(),
              const ThreadDigestChip(),
              const ThreadRecommendedChip(),
            ].insertBetween(sizedBoxW8H8),
          ),
        ),
      ),
    );
  }

  Widget _buildStickThreadTab(BuildContext context, ForumState state) {
    if (state.stickThreadList.isEmpty && state.rulesElement == null) {
      return AppStateView(icon: Icons.push_pin_outlined, message: context.t.forumPage.stickThreadTab.noThread);
    }
    late final Widget content;
    if (state.rulesElement == null) {
      content = AppCenteredList(
        builder: (context, side, _) => ListView.separated(
          controller: _pinnedScrollController,
          padding: side.copyWith(top: 8).add(context.safePadding()),
          itemCount: state.stickThreadList.length,
          itemBuilder: (context, index) => NormalThreadCard(state.stickThreadList[index]),
          separatorBuilder: (context, index) => appListSeparator,
        ),
      );
    } else {
      content = AppCenteredList(
        builder: (context, side, _) => ListView.separated(
          controller: _pinnedScrollController,
          padding: side.copyWith(top: 8).add(context.safePadding()),
          itemCount: state.stickThreadList.length + 1,
          itemBuilder: (context, index) {
            // TODO: Do NOT add leading rules card by checking index value.
            if (index == 0) {
              // Forum rules: a titled surface above the pinned threads, the forum's own markup inside.
              return AppSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppSectionHeader(
                      context.t.forumPage.rulesTab.title,
                      icon: Icons.gavel_outlined,
                      padding: const EdgeInsets.only(bottom: 8),
                    ),
                    // Laid out for reading as a post is: the rules are long text.
                    PostLayoutHtml(state.rulesElement!),
                  ],
                ),
              );
            } else {
              return NormalThreadCard(state.stickThreadList[index - 1]);
            }
          },
          separatorBuilder: (context, index) => appListSeparator,
        ),
      );
    }

    return EasyRefresh(
      scrollBehaviorBuilder: (physics) => ERScrollBehavior(physics).copyWith(physics: physics, scrollbars: false),
      header: const MaterialHeader(),
      controller: _pinnedRefreshController,
      scrollController: _pinnedScrollController,
      onRefresh: () async {
        if (!mounted) {
          return;
        }
        context.read<ForumBloc>().add(ForumRefreshRequested());
      },
      child: content,
    );
  }

  Widget _buildNormalThreadTab(BuildContext context, List<NormalThread> normalThreadList, ForumState state) {
    Future<void> refresh() async {
      if (!mounted) {
        return;
      }
      context.read<ForumBloc>().add(ForumRefreshRequested());
    }

    // Use _haveNoThread to ensure we parsed the web page and there really
    // no thread in the forum.
    if (normalThreadList.isEmpty) {
      final filtering = state.filterState.isFiltering();
      final tr = context.t.forumPage.threadTab;
      // "Nothing here" and "nothing left by the filters" are told apart: the latter offers to clear the filters.
      final emptyContentHint = EasyRefresh.builder(
        scrollBehaviorBuilder: (physics) => ERScrollBehavior(physics).copyWith(physics: physics, scrollbars: false),
        header: const MaterialHeader(),
        controller: _threadRefreshController,
        onRefresh: refresh,
        childBuilder: (context, physics) => AppScrollableStateView(
          physics: physics,
          child: AppStateView(
            key: ValueKey(filtering ? 'forum-empty-filtered' : 'forum-empty'),
            icon: filtering ? Icons.filter_alt_off_outlined : Icons.forum_outlined,
            message: filtering ? tr.noFilteredThread : tr.noThread,
            scrollable: false,
            action: filtering
                ? FilledButton.tonalIcon(
                    icon: const Icon(Icons.filter_alt_off_outlined),
                    label: Text(tr.clearFilter),
                    onPressed: () => context.read<ForumBloc>().add(
                      const ForumChangeThreadFilterStateRequested(FilterState()),
                    ),
                  )
                : null,
          ),
        ),
      );
      if (filtering) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildNormalThreadFilterRow(context, state),
            Expanded(child: emptyContentHint),
          ],
        );
      }
      return emptyContentHint;
    }

    final bloc = context.read<ForumBloc>();
    return EasyRefresh.builder(
      scrollBehaviorBuilder: (physics) => ERScrollBehavior(physics).copyWith(physics: physics, scrollbars: false),
      header: const MaterialHeader(),
      controller: _threadRefreshController,
      scrollController: _threadScrollController,
      onRefresh: refresh,
      childBuilder: (context, physics) => AppCenteredList(
        builder: (context, side, _) => CustomScrollView(
          controller: _threadScrollController,
          physics: physics,
          slivers: [
            PinnedHeaderSliver(child: _buildNormalThreadFilterRow(context, state)),
            const SliverPadding(padding: edgeInsetsT8),
            // The end of the list is its last item: built when it comes near, it asks the next page.
            SliverList.separated(
              itemCount: normalThreadList.length + 1,
              itemBuilder: (context, index) => index < normalThreadList.length
                  ? Padding(padding: side, child: NormalThreadCard(normalThreadList[index]))
                  : ListFooter(
                      status: listFooterStatus(
                        hasMore: state.canLoadMore && state.currentPage < state.totalPages,
                        loading: state.loadingMore || state.refreshing,
                        failed: state.loadMoreFailed,
                      ),
                      itemCount: normalThreadList.length,
                      failure: state.failure,
                      onLoadMore: () => bloc.add(ForumLoadMoreRequested(state.currentPage + 1)),
                      onRetry: () => bloc.add(const ForumRetryRequested()),
                    ),
              separatorBuilder: (context, index) => appListSeparator,
            ),
            SliverPadding(padding: context.safePadding()),
          ],
        ),
      ),
    );
  }

  Widget _buildSuccessContent(BuildContext context, ForumState state) {
    if (state.needLogin) {
      return NeedLoginPage(
        backUri: GoRouterState.of(context).uri,
        needPop: true,
        popCallback: (context) {
          context.read<ForumBloc>().add(ForumRefreshRequested());
        },
      );
    } else if (!state.havePermission) {
      // The forum's own words, as it wrote them, under the sentence telling what they are about.
      return FailureView(
        failure: LoadFailure(LoadFailureKind.noPermission),
        message: state.permissionDeniedMessage == null ? null : munchElement(context, state.permissionDeniedMessage!),
        onRetry: () => context.read<ForumBloc>().add(ForumRefreshRequested()),
      );
    } else {
      return TabBarView(
        controller: tabController,
        children: [
          _buildStickThreadTab(context, state),
          _buildNormalThreadTab(context, state.normalThreadList, state),
          _buildSubredditTab(context, state.subredditList),
        ],
      );
    }
  }

  Widget _buildBody(BuildContext context, ForumState state) {
    if (!state.refreshing) {
      // A refresh keeps the tabs on screen: their pulls end when it does.
      _pinnedRefreshController.finishRefresh();
      _threadRefreshController.finishRefresh();
      _subredditRefreshController.finishRefresh();
    }
    return switch (state.status) {
      // The shape of the threads to come instead of a spinner over the whole page.
      ForumStatus.initial || ForumStatus.loading => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.filterState.isFiltering()) _buildNormalThreadFilterRow(context, state),
          const Expanded(child: ThreadListSkeleton()),
        ],
      ),
      ForumStatus.failure => FailureView(
        failure: state.failure,
        onRetry: () => context.read<ForumBloc>().add(const ForumRetryRequested()),
      ),
      ForumStatus.success => _buildSuccessContent(context, state),
    };
  }

  Widget _buildSubredditTab(BuildContext context, List<Forum> subredditList) {
    if (subredditList.isEmpty) {
      return AppStateView(icon: Icons.folder_outlined, message: context.t.forumPage.subredditTab.noSubreddit);
    }

    return EasyRefresh(
      scrollBehaviorBuilder: (physics) => ERScrollBehavior(physics).copyWith(physics: physics, scrollbars: false),
      header: const MaterialHeader(),
      controller: _subredditRefreshController,
      scrollController: _subredditScrollController,
      onRefresh: () async {
        if (!mounted) {
          return;
        }
        context.read<ForumBloc>().add(ForumRefreshRequested());
      },
      // One column on phones, two on wide windows; large cards in a wider area on desktop windows, like the topics
      // page (phones keep the compact cards at any width). The width is measured inside the page's SafeArea, so side
      // insets are already excluded.
      child: AppCenteredList(
        builder: (context, _, width) {
          final layout = forumCardListLayout(width, Theme.of(context).platform);
          return ListView.separated(
            controller: _subredditScrollController,
            padding: layout.side
                .copyWith(top: layout.large ? 16 : 8, bottom: layout.large ? 20 : 0)
                .add(context.safePadding()),
            itemCount: appRowCount(subredditList.length, layout.columns),
            itemBuilder: (context, row) => AppColumnsRow(
              row: row,
              columns: layout.columns,
              count: subredditList.length,
              gap: layout.gap,
              itemBuilder: (_, index) => ForumCard(subredditList[index], large: layout.large),
            ),
            separatorBuilder: (context, index) => layout.separator,
          );
        },
      ),
    );
  }

  Widget? _buildFloatingActionButton(BuildContext context, ForumState state) {
    if (state.status != ForumStatus.success || !_fabVisible) {
      return null;
    }

    // Offer poll creation only when this page linked to it for the account still in use.
    final pollOfferUid = state.pollOfferUid;
    final canCreatePoll =
        pollOfferUid != null && pollOfferUid == context.read<AuthenticationRepository>().effectiveCurrentUid;
    // Wide windows have room for labelled buttons; phones keep the compact round ones over the list.
    final wide = MediaQuery.sizeOf(context).width >= 600;
    Future<void> openNewThread() async {
      // A guest needs an account first. The page saying the account may not post is only a hint (the plugin reads the
      // user group, the forum also has its own permissions): told, with the editor still offered.
      final loggedIn = context.readOrNull<AuthenticationRepository>()?.effectiveCurrentUid != null;
      if (!loggedIn || state.postAllowed == false) {
        final openAnyway = await showNewThreadUnavailableDialog(context, guest: !loggedIn);
        if (!openAnyway || !context.mounted) {
          return;
        }
      }
      await context.pushNamed(
        ScreenPaths.editPost,
        pathParameters: {'editType': '${PostEditType.newThread.index}', 'fid': widget.fid},
        queryParameters: {if (canCreatePoll) 'poll': '1'},
      );
    }

    Future<void> openPoll() async => context.pushNamed(ScreenPaths.createPoll, pathParameters: {'fid': widget.fid});
    // Always labelled, so the way to post is plain to see; folded to its icon while the list is scrolled down (the
    // wide windows keep the label, they have the room).
    final newThread = FloatingActionButton.extended(
      key: const ValueKey('forum-new-thread'),
      onPressed: openNewThread,
      tooltip: context.t.forumPage.tooltip.fab,
      isExtended: wide || _fabExtended,
      icon: const Icon(Icons.edit_outlined),
      label: Text(context.t.forumPage.newThread.label),
    );
    if (!canCreatePoll) return newThread;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (wide)
          FloatingActionButton.extended(
            heroTag: 'forum_create_poll_fab',
            onPressed: openPoll,
            tooltip: context.t.pollCreate.entry,
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
            icon: const Icon(Icons.poll_outlined),
            label: Text(context.t.pollCreate.entry),
          )
        else
          FloatingActionButton.small(
            heroTag: 'forum_create_poll_fab',
            onPressed: openPoll,
            tooltip: context.t.pollCreate.entry,
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
            child: const Icon(Icons.poll_outlined),
          ),
        sizedBoxW12H12,
        newThread,
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    tabController = TabController(initialIndex: _threadTabIndex, length: _tabsCount, vsync: this)
      ..addListener(_updateFabVisibilityByTabIndex);
  }

  bool _onBodyScrollNotification(UserScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) {
      return false;
    }

    // Fold the post button while scrolling down, unfold it when scrolling up: it stays in reach. Nothing to do on the
    // tabs without it.
    if (!_fabVisible) {
      return false;
    }
    if (notification.direction == ScrollDirection.forward && !_fabExtended) {
      setState(() => _fabExtended = true);
    } else if (notification.direction == ScrollDirection.reverse && _fabExtended) {
      setState(() => _fabExtended = false);
    }
    return true;
  }

  @override
  void dispose() {
    _pinnedScrollController.dispose();
    _pinnedRefreshController.dispose();
    _threadScrollController.dispose();
    _threadRefreshController.dispose();
    _subredditScrollController.dispose();
    _subredditRefreshController.dispose();
    tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The threads, sub forums and actions shown are the ones the account in use may see: loaded again for another
    // account.
    return AccountReloadScope(child: _buildPage(context));
  }

  /// The page, under the [AccountReloadScope] of [build].
  Widget _buildPage(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        BlocProvider(
          create: (context) {
            final FilterState? filterState;
            if (_forumBloc case final previous?) {
              // Loaded again for another account: the threads stay filtered as chosen.
              filterState = previous.state.filterState;
            } else if (widget.threadType != null) {
              filterState = FilterState(
                filter: 'typeid',
                filterType: FilterType(
                  // Name now only used in ThreadChip to show available filters, fine to keep empty here.
                  name: widget.threadType!.name,
                  typeID: widget.threadType!.typeID,
                ),
              );
            } else {
              filterState = null;
            }

            return _forumBloc = ForumBloc(
              fid: widget.fid,
              forumRepository: RepositoryProvider.of<ForumRepository>(context),
              filterState: filterState,
            )..add(const ForumLoadMoreRequested(1));
          },
        ),
        BlocProvider(create: (context) => JumpPageCubit()),
      ],
      child: MultiBlocListener(
        listeners: [
          // A forum without threads opens its sub forums tab. Switched from a listener, once per loaded state:
          // switching in the builder notified the tab listener (setState) during the build, and forced the tab back on
          // every rebuild.
          BlocListener<ForumBloc, ForumState>(
            listenWhen: (_, state) =>
                state.status == ForumStatus.success &&
                state.normalThreadList.isEmpty &&
                // Do not switch tab if filtering but filtering non result left.
                !state.filterState.isFiltering(),
            listener: (context, state) {
              if (!mounted || tabController.index == _subredditTabIndex) {
                return;
              }
              tabController.animateTo(_subredditTabIndex, duration: const Duration(milliseconds: 500));
            },
          ),
          // A refresh that failed keeps the threads on screen and says so.
          BlocListener<ForumBloc, ForumState>(
            listenWhen: (prev, curr) => prev.refreshing && !curr.refreshing && curr.failure != null,
            listener: (context, state) {
              final bloc = context.read<ForumBloc>();
              showRefreshFailedSnackBar(
                context,
                state.failure,
                onRetry: () {
                  if (!bloc.isClosed) {
                    bloc.add(ForumRefreshRequested());
                  }
                },
              );
            },
          ),
        ],
        child: BlocBuilder<ForumBloc, ForumState>(
          builder: (context, state) {
            // Update jump page state.
            context.read<JumpPageCubit>().setPageInfo(currentPage: state.currentPage, totalPages: state.totalPages);

            // Reset jump page state when every build.
            if (state.status == ForumStatus.initial || state.status == ForumStatus.loading) {
              context.read<JumpPageCubit>().markLoading();
            } else {
              context.read<JumpPageCubit>().markSuccess();
            }

            return Scaffold(
              // appBar: PreferredSize(preferredSize: const Size.fromHeight(145), child: _buildListAppBar(context, state)),
              appBar: _buildListAppBar(context, state),
              body: NotificationListener<UserScrollNotification>(
                onNotification: _onBodyScrollNotification,
                child: SafeArea(bottom: false, child: _buildBody(context, state)),
              ),
              floatingActionButton: _buildFloatingActionButton(context, state),
            );
          },
        ),
      ),
    );
  }
}

/// Tell why the post button of a forum may not lead anywhere: a [guest] needs to log in (offered here); otherwise the
/// forum's page said the account may not post in it, which may be wrong (the forum's own permissions of the forum and
/// of the member decide), so the editor is still offered and the forum answers there.
///
/// True when the editor is to be opened anyway.
Future<bool> showNewThreadUnavailableDialog(BuildContext context, {required bool guest}) async {
  final tr = context.t.forumPage.newThread;
  final choice = await showDialog<bool>(
    context: context,
    builder: (context) => CustomAlertDialog.sync(
      title: AppDialogTitle(
        icon: guest ? Icons.login_outlined : Icons.lock_outline,
        title: guest ? tr.guestTitle : tr.noPermissionTitle,
      ),
      content: Text(guest ? tr.guestMessage : tr.noPermissionMessage),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.t.general.cancel)),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(guest ? context.t.loginPage.login : tr.openAnyway),
        ),
      ],
    ),
  );
  if (!(choice ?? false) || !context.mounted) {
    return false;
  }
  if (guest) {
    await context.pushNamed(ScreenPaths.login);
    return false;
  }
  return true;
}
