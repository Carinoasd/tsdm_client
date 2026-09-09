import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/topics/bloc/topics_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/card/forum_card.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// App topic page.
///
/// Contains most subreddits in homepage of server.
///
class TopicsPage extends StatefulWidget {
  /// Constructor.
  const TopicsPage({super.key});

  // /// Group of forums.
  // final List<ForumGroup> forumGroupList;

  @override
  State<TopicsPage> createState() => _TopicsPageState();
}

/// State of homepage.
class _TopicsPageState extends State<TopicsPage> with TickerProviderStateMixin {
  /// Constructor.
  _TopicsPageState();

  TabController? tabController;

  VoidCallback? _updateIndexListener;

  /// Whether the groups shown last time started with the "我收藏的版块" panel.
  bool _hadFavorites = false;

  final _refreshController = EasyRefreshController(controlFinishRefresh: true);

  /// Make sure [tabController] exists and has exactly one tab per entry of [groups].
  ///
  /// The group count changes when the "我收藏的版块" panel appears or disappears (first favorite forum added,
  /// last one removed, another account logged in): a controller with the old length makes the TabBar throw
  /// "Controller's length property does not match the number of tabs" (issue #1), so it is rebuilt with the
  /// saved tab index clamped into the new range.
  void _syncTabController(BuildContext context, List<ForumGroup> groups) {
    final length = groups.length;
    final hasFavorites = groups.isNotEmpty && groups.first.isFavorites;
    final fragments = RepositoryProvider.of<FragmentsRepository>(context);
    // Capture `context` and wrap in a void callback.
    _updateIndexListener ??= () {
      if (tabController == null) {
        return;
      }
      fragments.topicsPageTabIndex = tabController!.index;
    };

    if (tabController != null && tabController!.length == length) {
      _hadFavorites = hasFavorites;
      return;
    }
    // The panel just showed up in front (favorite added on the web, account switched): select it, otherwise the
    // saved index keeps the previous tab selected and the new first tab may sit outside the scrollable tab bar.
    final favoritesAppeared = tabController != null && hasFavorites && !_hadFavorites;
    _hadFavorites = hasFavorites;
    tabController
      ?..removeListener(_updateIndexListener!)
      ..dispose();
    final initialIndex = length == 0 || favoritesAppeared ? 0 : fragments.topicsPageTabIndex.clamp(0, length - 1);
    fragments.topicsPageTabIndex = initialIndex;
    tabController = TabController(initialIndex: initialIndex, length: length, vsync: this)
      ..addListener(_updateIndexListener!);
  }

  Widget _buildContent(BuildContext context, TopicsState state) {
    final forumGroupList = state.forumGroupList;
    _syncTabController(context, forumGroupList);

    final groupTabBodyList = forumGroupList
        .map(
          (e) => ListView.separated(
            padding: edgeInsetsL12T4R12,
            itemCount: e.forumList.length,
            itemBuilder: (context, index) => ForumCard(e.forumList[index]),
            separatorBuilder: (context, index) => sizedBoxW4H4,
          ),
        )
        .toList();

    _refreshController.finishRefresh();

    return EasyRefresh(
      key: const ValueKey('success'),
      controller: _refreshController,
      header: const MaterialHeader(),
      onRefresh: () {
        context.read<TopicsBloc>().add(const TopicsRefreshRequested());
      },
      // A new controller gets a fresh page view: the old one may report its previous page while the children
      // change and would drag the new controller's index along with it.
      child: TabBarView(key: ValueKey(tabController), controller: tabController, children: groupTabBodyList),
    );
  }

  @override
  void dispose() {
    if (tabController != null) {
      tabController!
        ..removeListener(_updateIndexListener ?? () {})
        ..dispose();
    }
    _refreshController.dispose();
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
            TopicsStatus.failed => buildRetryButton(context, () {
              context.read<TopicsBloc>().add(const TopicsRefreshRequested());
            }),
            TopicsStatus.success when state.forumGroupList.isNotEmpty => _buildContent(context, state),
            // Some server enforced situation.
            TopicsStatus.success => NeedLoginPage(
              backUri: GoRouterState.of(context).uri,
              needPop: true,
              popCallback: (context) {
                context.read<TopicsBloc>().add(const TopicsRefreshRequested());
              },
            ),
          };

          final PreferredSizeWidget tabBar;
          if (state.status == TopicsStatus.success) {
            // `_buildContent` above already made the controller match the tab count.
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
                  onPressed: () async {
                    await context.pushNamed(ScreenPaths.search);
                  },
                ),
              ],
              // Some server enforced situation.
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
