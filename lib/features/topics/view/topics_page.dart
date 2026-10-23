import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/multi_user/widgets/current_account_avatar.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/root/stream/scroll_to_top_stream.dart';
import 'package:tsdm_client/features/topics/bloc/topics_bloc.dart';
import 'package:tsdm_client/features/topics/widgets/group_moderators_row.dart';
import 'package:tsdm_client/features/topics/widgets/topics_placeholder.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/forum_card.dart';
import 'package:tsdm_client/widgets/failure_view.dart';

/// Widest the rows of the topics page grow on desktop windows, shared with every forum list: [forumCardListMaxWidth].
const double topicsPageMaxWidth = forumCardListMaxWidth;

/// Width the topics page must really have to show its forum cards large on desktop: [forumCardListLargeWidth].
const double topicsPageLargeCardWidth = forumCardListLargeWidth;

/// Whether the topics page shows large cards in a page of [width] on [platform] (desktop only).
bool topicsPageUsesLargeCards(double width, TargetPlatform platform) => forumCardListUsesLargeCards(width, platform);

/// App topic page.
class TopicsPage extends StatefulWidget {
  /// Constructor.
  const TopicsPage({super.key});

  @override
  State<TopicsPage> createState() => _TopicsPageState();
}

class _TopicsPageState extends State<TopicsPage> with TickerProviderStateMixin {
  TabController? tabController;
  VoidCallback? _updateIndexListener;
  bool _hadFavorites = false;
  final _refreshController = EasyRefreshController(controlFinishRefresh: true);

  // 按分组名称维护 ScrollController，防止 Tab 索引错位
  final Map<String, ScrollController> _tabScrollControllers = {};

  // 安全缓存：通过 BlocListener 更新，供 initState 的双击事件安全读取
  List<ForumGroup> _currentGroups = [];

  late final StreamSubscription<ScrollToTopEvent> _scrollToTopSub;

  void _updateTabIndex() {
    if (tabController == null) {
      return;
    }
    RepositoryProvider.of<FragmentsRepository>(context).topicsPageTabIndex = tabController!.index;
  }

  void _syncTabController(BuildContext context, List<ForumGroup> groups) {
    final length = groups.length;
    final hasFavorites = groups.isNotEmpty && groups.first.isFavorites;
    final fragments = RepositoryProvider.of<FragmentsRepository>(context);

    _updateIndexListener ??= _updateTabIndex;

    if (tabController != null && tabController!.length == length) {
      _hadFavorites = hasFavorites;
      return;
    }
    final favoritesAppeared = tabController != null && hasFavorites && !_hadFavorites;
    _hadFavorites = hasFavorites;

    final existingController = tabController;
    if (existingController != null) {
      existingController
        ..removeListener(_updateIndexListener!)
        ..dispose();
    }

    final initialIndex = length == 0 || favoritesAppeared ? 0 : fragments.topicsPageTabIndex.clamp(0, length - 1);
    fragments.topicsPageTabIndex = initialIndex;
    tabController = TabController(initialIndex: initialIndex, length: length, vsync: this)
      ..addListener(_updateIndexListener!);
  }

  Widget _buildContent(BuildContext context, TopicsState state) {
    final forumGroupList = state.forumGroupList;
    _syncTabController(context, forumGroupList);

    // 先清理掉已经不在当前分组列表里的 ScrollController（如切换账号、收藏变化导致分组消失）
    final currentGroupNames = forumGroupList.map((e) => e.name).toSet();
    final keysToRemove = _tabScrollControllers.keys.where((key) => !currentGroupNames.contains(key)).toList();
    for (final key in keysToRemove) {
      _tabScrollControllers[key]?.dispose();
      _tabScrollControllers.remove(key);
    }

    final groupTabBodyList = forumGroupList.map((e) {
      _tabScrollControllers.putIfAbsent(e.name, ScrollController.new);

      final head = e.moderators.isEmpty ? 0 : 1;
      final forums = e.forumList;
      // One column on phones, two on wide windows; rows stay centered. Desktop windows get a wider content area
      // with large cards, see forumCardListLayout; phones keep the compact cards at any width.
      return AppCenteredList(
        builder: (context, _, width) {
          final layout = forumCardListLayout(width, Theme.of(context).platform);
          final large = layout.large;
          return ListView.separated(
            controller: _tabScrollControllers[e.name],
            padding: layout.side.copyWith(top: large ? 16 : 8, bottom: large ? 24 : 16),
            itemCount: appRowCount(forums.length, layout.columns) + head,
            itemBuilder: (context, index) => head == 1 && index == 0
                ? GroupModeratorsRow(moderators: e.moderators, large: large)
                : AppColumnsRow(
                    row: index - head,
                    columns: layout.columns,
                    count: forums.length,
                    gap: layout.gap,
                    itemBuilder: (_, i) => ForumCard(forums[i], large: large),
                  ),
            separatorBuilder: (context, index) => layout.separator,
          );
        },
      );
    }).toList();

    if (!state.refreshing) {
      _refreshController.finishRefresh();
    }

    return EasyRefresh(
      key: const ValueKey('success'),
      controller: _refreshController,
      header: const MaterialHeader(),
      onRefresh: () => context.read<TopicsBloc>().add(const TopicsRefreshRequested()),
      child: TabBarView(key: ValueKey(tabController), controller: tabController, children: groupTabBodyList),
    );
  }

  @override
  void initState() {
    super.initState();
    _scrollToTopSub = scrollToTopStream.stream.listen((event) {
      if (event.tabIndex == 1 && tabController != null && mounted) {
        final currentIndex = tabController!.index;
        // 使用 _currentGroups 缓存，彻底避免 context.read 崩溃
        if (currentIndex >= 0 && currentIndex < _currentGroups.length) {
          final groupName = _currentGroups[currentIndex].name;
          final controller = _tabScrollControllers[groupName];
          if (controller != null && controller.hasClients) {
            if (controller.offset > 0) {
              unawaited(controller.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut));
            } else {
              // 已在顶部时双击：触发下拉刷新 (#99)；controller 有 clients 说明当前正显示成功加载的列表
              unawaited(_refreshController.callRefresh());
            }
          }
        }
      }
    });
  }

  @override
  void dispose() {
    final existingController = tabController;
    if (existingController != null) {
      existingController
        ..removeListener(_updateIndexListener ?? () {})
        ..dispose();
    }
    _refreshController.dispose();
    unawaited(_scrollToTopSub.cancel());
    for (final controller in _tabScrollControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => TopicsBloc(
        forumHomeRepository: RepositoryProvider.of<ForumHomeRepository>(context),
        authenticationRepository: RepositoryProvider.of<AuthenticationRepository>(context),
        favoriteRepository: RepositoryProvider.of<FavoriteRepository>(context),
      )..add(TopicsLoadRequested()),
      child: MultiBlocListener(
        listeners: [
          BlocListener<TopicsBloc, TopicsState>(
            // 监听状态，一旦成功拿到数据，就安全更新缓存
            listenWhen: (prev, curr) => curr.status == TopicsStatus.success,
            listener: (context, state) {
              _currentGroups = state.forumGroupList;
            },
          ),
          // A refresh that failed keeps the groups on screen and says so.
          BlocListener<TopicsBloc, TopicsState>(
            listenWhen: (prev, curr) => prev.refreshing && !curr.refreshing && curr.failure != null,
            listener: (context, state) {
              final bloc = context.read<TopicsBloc>();
              showRefreshFailedSnackBar(
                context,
                state.failure,
                onRetry: () {
                  if (!bloc.isClosed) {
                    bloc.add(const TopicsRefreshRequested());
                  }
                },
              );
            },
          ),
        ],
        child: BlocBuilder<TopicsBloc, TopicsState>(
          builder: (context, state) {
            final body = switch (state.status) {
              // The shape of the forum list to come instead of a spinner over the whole page.
              TopicsStatus.loading || TopicsStatus.initial => const TopicsPlaceholder(key: ValueKey('loading')),
              TopicsStatus.failed => FailureView(
                key: const ValueKey('failed'),
                failure: state.failure,
                onRetry: () => context.read<TopicsBloc>().add(const TopicsRefreshRequested()),
              ),
              TopicsStatus.success when state.forumGroupList.isNotEmpty => _buildContent(context, state),
              TopicsStatus.success => NeedLoginPage(
                backUri: GoRouterState.of(context).uri,
                needPop: true,
                popCallback: (context) => context.read<TopicsBloc>().add(const TopicsRefreshRequested()),
              ),
            };

            final PreferredSizeWidget tabBar;
            if (state.status == TopicsStatus.success) {
              tabBar = TabBar(
                controller: tabController,
                tabs: state.forumGroupList.map((e) => Tab(text: e.name)).toList(),
                isScrollable: true,
                tabAlignment: TabAlignment.start,
              );
            } else {
              tabBar = const PreferredSize(preferredSize: Size(40, 40), child: SizedBox.shrink());
            }

            return Scaffold(
              appBar: AppBar(
                title: Text(context.t.navigation.topics),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.search_outlined),
                    tooltip: context.t.searchPage.title,
                    onPressed: () async => context.pushNamed(ScreenPaths.search),
                  ),
                  // Which account browses the forums, with more than one saved account (GitHub #184).
                  const CurrentAccountAvatarButton(lastAction: true),
                ],
                bottom: state.forumGroupList.isNotEmpty ? tabBar : null,
              ),
              body: SafeArea(
                left: false,
                top: false,
                child: AnimatedSwitcher(duration: duration200, child: body),
              ),
            );
          },
        ),
      ),
    );
  }
}
