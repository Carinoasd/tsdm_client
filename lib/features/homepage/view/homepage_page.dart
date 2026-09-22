import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/checkin/widgets/checkin_button.dart';
import 'package:tsdm_client/features/home/cubit/home_cubit.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/widgets/guide_section.dart';
import 'package:tsdm_client/features/homepage/widgets/user_operation_dialog.dart';
import 'package:tsdm_client/features/homepage/widgets/widgets.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/red_packet/widgets/daily_red_packet_button.dart';
import 'package:tsdm_client/features/root/stream/scroll_to_top_stream.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/notice_button.dart';

const _showFabOffset = 100;

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
                onRefresh: () => context.read<HomepageBloc>().add(HomepageRefreshRequested()),
                childBuilder: (context, physics) => ListView(
                  physics: physics,
                  controller: _scrollController,
                  padding: edgeInsetsL12T12R12.add(context.safePadding()),
                  children: [
                    WelcomeSection(
                      forumStatus: state.forumStatus,
                      loggedUserInfo: state.loggedUserInfo,
                      swiperUrlList: state.swiperUrlList,
                    ),
                    sizedBoxW12H12,
                    PinSection(state.pinnedThreadGroupList),
                    sizedBoxW12H12,
                    const GuideSection(),
                  ],
                ),
              ),
            };

            _refreshController.finishRefresh();
            final username = state.loggedUserInfo?.username;
            final avatarUrl = state.loggedUserInfo?.avatarUrl;

            return Scaffold(
              appBar: AppBar(
                title: Text(context.t.homepage.title),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.event_outlined),
                    tooltip: context.t.activitiesPage.title,
                    onPressed: () async => context.pushNamed(ScreenPaths.activities),
                  ),
                  if (username != null) ...[
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
                    if (state.dailyRedPacket != null && state.formHash != null)
                      DailyRedPacketButton(
                        key: ValueKey('dailyRedPacket-${state.dailyRedPacket!.dateFlag}'),
                        config: state.dailyRedPacket!,
                        formHash: state.formHash!,
                      ),
                    const NoticeButton(),
                    const CheckinButton(enableSnackBar: true),
                  ],
                  IconButton(
                    icon: const Icon(Icons.search_outlined),
                    tooltip: context.t.searchPage.title,
                    onPressed: () async => context.pushNamed(ScreenPaths.search),
                  ),
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
