import 'dart:async';
import 'dart:math' as math;

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/widgets/checkin_button.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/widgets/guide_section.dart';
import 'package:tsdm_client/features/homepage/widgets/home_dashboard.dart';
import 'package:tsdm_client/features/homepage/widgets/user_operation_dialog.dart';
import 'package:tsdm_client/features/homepage/widgets/widgets.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/root/stream/scroll_to_top_stream.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/card/forum_card.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/notice_button.dart';

const _showFabOffset = 100;

/// Widest the homepage content grows; wider windows center it.
const _maxContentWidth = 1320.0;

/// Content width from which the side column appears.
const _wideLayoutWidth = 960.0;

/// Content width from which statistics and support sit side by side.
const _mediumLayoutWidth = 600.0;

/// Width of the side column in the wide layout.
const _railWidth = 320.0;

/// Arrangement of the homepage cards.
enum HomeLayout {
  /// One column, phone cards.
  compact,

  /// One column, statistics and support side by side.
  medium,

  /// Threads with a side column.
  wide,
}

/// Arrangement of the homepage in a content area [width] wide on [platform] (`Theme.of(context).platform`).
///
/// Phones keep the compact layout at any width: a landscape phone (feedback 111) is not a wide window, its greeting
/// card would grow a huge title badge and stack the day's actions oddly. Like the forum lists
/// ([forumCardListIsDesktop]), only desktop platforms get the medium and wide layouts.
HomeLayout homeLayoutFor(double width, TargetPlatform platform) {
  if (!forumCardListIsDesktop(platform)) {
    return HomeLayout.compact;
  }
  return width >= _wideLayoutWidth
      ? HomeLayout.wide
      : width >= _mediumLayoutWidth
      ? HomeLayout.medium
      : HomeLayout.compact;
}

/// Homepage page.
///
/// Be stateful because scrollable.
///
/// This page is in the Homepage of the app, already wrapped in a [Scaffold].
class HomepagePage extends StatefulWidget {
  /// Constructor.
  const HomepagePage({super.key});

  @override
  State<HomepagePage> createState() => _HomepagePageState();
}

class _HomepagePageState extends State<HomepagePage> {
  final _scrollController = ScrollController();
  final _refreshController = EasyRefreshController(controlFinishRefresh: true);
  late final StreamSubscription<ScrollToTopEvent> _scrollToTopSub;

  bool _fabVisible = false;

  // 状态缓存：initState 里的双击事件监听拿不到 build 中创建的 HomepageBloc，靠 BlocListener 更新
  HomepageStatus _lastStatus = HomepageStatus.initial;

  bool _handleScrollNotification(UserScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (notification.metrics.pixels <= _showFabOffset) {
      if (_fabVisible) {
        setState(() => _fabVisible = false);
      }
      return true;
    }
    if (notification.direction == ScrollDirection.forward && !_fabVisible) {
      setState(() => _fabVisible = true);
    } else if (notification.direction == ScrollDirection.reverse && _fabVisible) {
      setState(() => _fabVisible = false);
    }
    return true;
  }

  Widget? _buildFloatingActionButton(BuildContext context, HomepageState state) {
    if (state.status != HomepageStatus.success || !_fabVisible) {
      return null;
    }
    return FloatingActionButton(
      onPressed: () async => _scrollController.animateTo(0, duration: duration200, curve: Curves.easeInOut),
      child: const Icon(Icons.arrow_upward_outlined),
    );
  }

  /// Pull to refresh: the homepage, and the title badge of the current account with it.
  void _refresh(BuildContext context) {
    context.read<HomepageBloc>().add(HomepageRefreshRequested());
    final currentTitle = context.readOrNull<CurrentTitleCubit>();
    if (currentTitle != null) {
      unawaited(currentTitle.ensureLoaded(force: true));
    }
  }

  /// The loaded homepage, arranged for the available [width].
  ///
  /// * Wide: threads on the left, statistics, tools and the support entry in a side column.
  /// * Medium: one column, statistics and support side by side above the threads.
  /// * Compact: one column; the greeting carries the day's actions and the today count, the threads come right after
  ///   it and the utility cards follow them, so no tall card pushes the threads down.
  Widget _buildDashboard(BuildContext context, HomepageState state, double width) {
    final layout = homeLayoutFor(width, Theme.of(context).platform);
    final hasStatus = state.forumStatus != const ForumStatus.empty();
    final greeting = HomeGreetingCard(
      username: state.loggedUserInfo?.username ?? '',
      uid: context.read<AuthenticationRepository>().currentUser?.uid,
      forumStatus: state.forumStatus,
      dailyRedPacket: state.dailyRedPacket,
      formHash: state.formHash,
      compact: layout == HomeLayout.compact,
      // The red packet entry checks the packet alone: tapping it used to reload the whole homepage (feedback 110).
      // Pull to refresh stays the way to reload everything.
      onCheckDailyRedPacket: () => context.read<HomepageBloc>().add(const HomepageDailyRedPacketCheckRequested()),
      checkingDailyRedPacket: state.checkingDailyRedPacket,
    );
    // The swiper block of the forum homepage is gone since Discuz! X5; kept in case it comes back.
    final swiper = state.swiperUrlList.isEmpty
        ? null
        : WelcomeSection(
            forumStatus: state.forumStatus,
            loggedUserInfo: state.loggedUserInfo,
            swiperUrlList: state.swiperUrlList,
          );
    final pinned = state.pinnedThreadGroupList.isEmpty ? null : PinSection(state.pinnedThreadGroupList);
    // The guide owns the fetch of the guide index page. It keeps its place in the tree (first child of the main
    // column's Expanded, found by key among its siblings) in every layout, so a window resize or a rotation moves the
    // loaded guide instead of fetching it again.
    const guide = GuideSection(key: ValueKey('homepage-guide'));
    const support = HomeSupportCard();

    List<Widget> spaced(List<Widget?> children, double gap) => [
      for (final (i, child) in children.whereType<Widget>().indexed) ...[if (i > 0) SizedBox(height: gap), child],
    ];

    final List<Widget?> main;
    List<Widget?>? rail;
    switch (layout) {
      case HomeLayout.wide:
        main = [greeting, swiper, pinned, guide];
        rail = [
          if (hasStatus) HomeForumStatsCard(state.forumStatus),
          const HomeToolsCard(columns: 2),
          support,
        ];
      case HomeLayout.medium:
        main = [
          greeting,
          if (hasStatus)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: HomeForumStatsCard(state.forumStatus)),
                const SizedBox(width: 16),
                const Expanded(child: support),
              ],
            )
          else
            support,
          swiper,
          pinned,
          guide,
          const HomeToolsCard(columns: 4),
        ];
      case HomeLayout.compact:
        main = [
          greeting,
          swiper,
          pinned,
          guide,
          if (hasStatus) HomeForumStatsCard(state.forumStatus),
          const HomeToolsCard(columns: 2),
          support,
        ];
    }
    final gap = layout == HomeLayout.compact ? 12.0 : 16.0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced(main, gap)),
        ),
        if (rail != null) ...[
          const SizedBox(width: 24),
          SizedBox(
            width: _railWidth,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: spaced(rail, gap)),
          ),
        ],
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _scrollToTopSub = scrollToTopStream.stream.listen((event) {
      if (event.tabIndex != 0 || !mounted || !_scrollController.hasClients) {
        return;
      }
      if (_scrollController.offset > 0) {
        unawaited(_scrollController.animateTo(0, duration: duration200, curve: Curves.easeInOut));
      } else if (_lastStatus == HomepageStatus.success) {
        // 已在顶部时双击：触发下拉刷新 (#99)
        unawaited(_refreshController.callRefresh());
      }
    });
  }

  @override
  void dispose() {
    unawaited(_scrollToTopSub.cancel());
    _scrollController.dispose();
    _refreshController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (context) => HomepageBloc(
        authenticationRepository: RepositoryProvider.of<AuthenticationRepository>(context),
        forumHomeRepository: RepositoryProvider.of<ForumHomeRepository>(context),
        profileRepository: RepositoryProvider.of<ProfileRepository>(context),
      )..add(HomepageLoadRequested()),
      child: MultiBlocListener(
        listeners: [
          BlocListener<HomepageBloc, HomepageState>(listener: (context, state) => _lastStatus = state.status),
          BlocListener<HomeCubit, HomeState>(
            listener: (context, state) {
              if (state.inHome ?? false) {
                context.read<HomepageBloc>().add(const HomepageResumeSwiper());
              } else if (state.inHome == false) {
                context.read<HomepageBloc>().add(const HomepagePauseSwiper());
              }
            },
          ),
          BlocListener<HomepageBloc, HomepageState>(
            listenWhen: (prev, curr) => prev.status == HomepageStatus.loading && curr.status == HomepageStatus.success,
            listener: (context, state) {
              // The header notice count is a raw forum total and the personal message flag an aggregate without
              // sender: merge them only while nothing can be hidden or muted locally, otherwise keep the filtered
              // badge until the sync requested below recounts it.
              final allowHint = noticeHintAllowed(
                currentBlockList(context, listen: false),
                currentUid: context.read<AuthenticationRepository>().effectiveCurrentUid,
              );
              context.read<NotificationInfoRepository>().applyServerHint(
                noticeCount: allowHint ? state.unreadNoticeCount : null,
                hasPersonalMessage: allowHint ? state.hasUnreadMessage : null,
              );
              context.read<NotificationBloc>().add(NotificationUpdateAllRequested());
              // The greeting card shows whether this account checked in today, from the record of this app.
              context.read<CheckinBloc>().add(const CheckinStatusRequested());
            },
          ),
        ],
        child: BlocBuilder<HomepageBloc, HomepageState>(
          builder: (context, state) {
            final body = switch (state.status) {
              HomepageStatus.initial || HomepageStatus.loading => EasyRefresh(
                key: const ValueKey('loading'),
                scrollController: _scrollController,
                controller: _refreshController,
                header: const MaterialHeader(),
                onRefresh: () => context.read<HomepageBloc>().add(HomepageRefreshRequested()),
                child: const CenteredCircularIndicator(),
              ),
              HomepageStatus.needLogin => NeedLoginPage(
                backUri: GoRouterState.of(context).uri,
                needPop: true,
                popCallback: (context) => context.read<HomepageBloc>().add(HomepageRefreshRequested()),
              ),
              HomepageStatus.failure => buildRetryButton(
                context,
                () => context.read<HomepageBloc>().add(HomepageRefreshRequested()),
              ),
              HomepageStatus.success => EasyRefresh.builder(
                key: const ValueKey('success'),
                scrollController: _scrollController,
                controller: _refreshController,
                header: const MaterialHeader(),
                onRefresh: () => _refresh(context),
                childBuilder: (context, physics) => LayoutBuilder(
                  builder: (context, constraints) => ListView(
                    physics: physics,
                    controller: _scrollController,
                    padding: edgeInsetsL12T12R12.add(context.safePadding()),
                    children: [
                      Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: _maxContentWidth),
                          child: _buildDashboard(
                            context,
                            state,
                            math.min(constraints.maxWidth - 24, _maxContentWidth),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            };

            _refreshController.finishRefresh();
            final username = state.loggedUserInfo?.username;
            final avatarUrl = state.loggedUserInfo?.avatarUrl;

            // Check-in, the daily red packet and activities moved into the greeting card of the loaded page. Only a
            // failed load, which has no greeting card, keeps them reachable here. While the page loads or refreshes
            // the bar stays as it is around it (search, and the account actions once known) instead of flashing the
            // old activity entry for the length of the refresh (feedback 110).
            final showDailyActionsInBar = state.status == HomepageStatus.failure;

            return Scaffold(
              appBar: AppBar(
                title: Text(context.t.homepage.title),
                actions: [
                  if (showDailyActionsInBar)
                    IconButton(
                      icon: const Icon(Icons.event_outlined),
                      tooltip: context.t.activitiesPage.title,
                      onPressed: () async => context.pushNamed(ScreenPaths.activities),
                    ),
                  IconButton(
                    icon: const Icon(Icons.search_outlined),
                    tooltip: context.t.searchPage.title,
                    onPressed: () async => context.pushNamed(ScreenPaths.search),
                  ),
                  if (username != null) ...[
                    if (showDailyActionsInBar) const CheckinButton(enableSnackBar: true),
                    const NoticeButton(),
                    IconButton(
                      icon: const Icon(Icons.catching_pokemon),
                      tooltip: context.t.pokemon.title,
                      onPressed: () async => context.pushNamed(ScreenPaths.pokemon),
                    ),
                    IconButton(
                      icon: SizedBox(
                        width: 32,
                        height: 32,
                        child: HeroUserAvatar(username: username, avatarUrl: avatarUrl, heroTag: username),
                      ),
                      tooltip: context.t.homepage.showMoreUserOperationsTip,
                      onPressed: () async => showHeroDialog(
                        context,
                        (context, _, _) => UserOperationDialog(
                          username: username,
                          avatarUrl: avatarUrl,
                          heroTag: username,
                          latestThreadUrl: state.loggedUserInfo?.relatedLinkPairList.lastOrNull?.$2,
                        ),
                      ),
                    ),
                  ],
                  sizedBoxW4H4,
                ],
              ),
              body: SafeArea(
                left: false,
                top: false,
                bottom: false,
                child: NotificationListener<UserScrollNotification>(
                  onNotification: _handleScrollNotification,
                  child: AnimatedSwitcher(duration: duration200, child: body),
                ),
              ),
              floatingActionButton: _buildFloatingActionButton(context, state),
            );
          },
        ),
      ),
    );
  }
}
