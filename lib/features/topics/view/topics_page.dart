import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/root/stream/scroll_to_top_stream.dart';
import 'package:tsdm_client/features/topics/bloc/topics_bloc.dart';
import 'package:tsdm_client/features/topics/widgets/group_moderators_row.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/card/forum_card.dart';
import 'package:tsdm_client/widgets/indicator.dart';

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
  late final StreamSubscription<ScrollToTopEvent> _scrollToTopSub;

  void _updateTabIndex() {
    if (tabController == null) {
      return;
    }
    final fragments = RepositoryProvider.of<FragmentsRepository>(context);
    fragments.topicsPageTabIndex = tabController!.index;
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

    // 修改：拆分级联调用，消除 cascade_invocations 警告
    final existingController = tabController;
    if (existingController != null) {
      existingController.removeListener(_updateIndexListener!);
      existingController.dispose();
    }

    final initialIndex = length == 0 || favoritesAppeared ? 0 : fragments.topicsPageTabIndex.clamp(0, length - 1);
    fragments.topicsPageTabIndex = initialIndex;
    tabController = TabController(initialIndex: initialIndex, length: length, vsync: this)
      ..addListener(_updateIndexListener!);
  }

  Widget _buildContent(BuildContext context, TopicsState state) {
    final forumGroupList = state.forumGroupList;
    _syncTabController(context, forumGroupList);

    final groupTabBodyList = forumGroupList.map((e) {
      // 修改：使用 tearoff 替代闭包，消除 unnecessary_lambdas 警告
      _tabScrollControllers.putIfAbsent(e.name, ScrollController.new);

      final head = e.moderators.isEmpty ? 0 : 1;
      return ListView.separated(
        controller: _tabScrollControllers[e.name],
        padding: edgeInsetsL12T4R12,
        itemCount: e.forumList.length + head,
        itemBuilder: (context, index) => head == 1 && index == 0
            ? GroupModeratorsRow(moderators: e.moderators)
            : ForumCard(e.forumList[index - head]),
        separatorBuilder: (context, index) => sizedBoxW4H4,
      );
    }).toList();

    // 修改：finishRefresh 返回 void，去掉 unawaited
    _refreshController.finishRefresh();

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
        final groups = context.read<TopicsBloc>().state.forumGroupList;
        if (currentIndex < groups.length) {
          final groupName = groups[currentIndex].name;
          final controller = _tabScrollControllers[groupName];
          if (controller != null && controller.hasClients && controller.offset > 0) {
            unawaited(controller.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut));
          }
        }
      }
    });
  }

  @override
  void dispose() {
    final existingController = tabController;
    if (existingController != null) {
      existingController.removeListener(_updateIndexListener ?? () {});
      existingController.dispose();
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
      child: BlocBuilder<TopicsBloc, TopicsState>(
        builder: (context, state) {
          final body = switch (state.status) {
            TopicsStatus.loading || TopicsStatus.initial => EasyRefresh(
              key: const ValueKey('loading'),
              controller: _refreshController,
              header: const MaterialHeader(),
              child: const CenteredCircularIndicator(),
            ),
            TopicsStatus.failed => buildRetryButton(context, () => context.read<TopicsBloc>().add(const TopicsRefreshRequested())),
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
    );
  }
}
