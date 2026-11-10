import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/collection/models/collection.dart';
import 'package:tsdm_client/features/collection/repository/collection_repository.dart';
import 'package:tsdm_client/features/collection/widgets/collection_dialogs.dart';
import 'package:tsdm_client/features/collection/widgets/collection_pager.dart';
import 'package:tsdm_client/features/collection/widgets/collection_tiles.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/list_footer.dart';

/// The forum's collections (淘专辑): the recommended ones, all of them (in an order to pick), and for an account its
/// own ones and the ones it subscribed to. A tap opens the collection; the account creates one from the app bar.
class CollectionListPage extends StatefulWidget {
  /// Constructor.
  const CollectionListPage({this.initialTab, this.repository, super.key});

  /// The tab shown first.
  final CollectionListTab? initialTab;

  /// Repository override (tests).
  final CollectionRepository? repository;

  @override
  State<CollectionListPage> createState() => _CollectionListPageState();
}

class _CollectionListPageState extends State<CollectionListPage> {
  late final CollectionRepository _repository = widget.repository ?? CollectionRepository.network();
  final _tabKeys = <CollectionListTab, GlobalKey<_CollectionTabState>>{
    for (final tab in CollectionListTab.values) tab: GlobalKey(),
  };
  CollectionOrder _order = CollectionOrder.dateline;

  /// Notified when a tab loaded a page.
  final _loaded = ValueNotifier<int>(0);

  @override
  void dispose() {
    _loaded.dispose();
    super.dispose();
  }

  List<CollectionListTab> _tabs(bool loggedIn) =>
      loggedIn ? CollectionListTab.values : const [CollectionListTab.recommended, CollectionListTab.all];

  String _tabName(BuildContext context, CollectionListTab tab) {
    final tr = context.t.collection.tabs;
    return switch (tab) {
      CollectionListTab.recommended => tr.recommended,
      CollectionListTab.all => tr.all,
      CollectionListTab.mine => tr.mine,
      CollectionListTab.subscribed => tr.subscribed,
    };
  }

  String _orderName(BuildContext context, CollectionOrder order) {
    final tr = context.t.collection.order;
    return switch (order) {
      CollectionOrder.dateline => tr.dateline,
      CollectionOrder.threadnum => tr.threadnum,
      CollectionOrder.commentnum => tr.commentnum,
      CollectionOrder.follownum => tr.follownum,
    };
  }

  /// A page of the list loaded for the account: the form hash of the session and whether the forum offers to create
  /// a collection are on every page; null before one loaded.
  CollectionListResult? _loadedPage() => _tabKeys.values.map((k) => k.currentState?._pager.first).nonNulls.firstOrNull;

  Future<void> _create(BuildContext context, CollectionListResult page) async {
    final fields = await showCollectionEditDialog(context);
    if (fields == null || !context.mounted) {
      return;
    }
    final outcome = await _repository.create(
      viewerUid: page.viewerUid ?? 0,
      formHash: page.formHash,
      title: fields.title,
      description: fields.description,
      keywords: fields.keywords,
    );
    if (!context.mounted) {
      return;
    }
    final done = await reportCollectionOutcome(context, outcome);
    if (done) {
      collectionChanges.value++;
    }
    if (!context.mounted) {
      return;
    }
    if (createdCtid(outcome) case final ctid? when done) {
      await context.pushNamed(ScreenPaths.collectionDetail, pathParameters: {'ctid': '$ctid'});
    }
  }

  @override
  Widget build(BuildContext context) {
    // The account the thread page offers its "淘帖" to as well.
    final loggedIn = context.readOrNull<AuthenticationRepository>()?.effectiveCurrentUid != null;
    final tabs = _tabs(loggedIn);
    final initial = tabs.indexOf(widget.initialTab ?? CollectionListTab.recommended);
    return DefaultTabController(
      length: tabs.length,
      initialIndex: initial < 0 ? 0 : initial,
      child: Builder(
        builder: (context) {
          final controller = DefaultTabController.of(context);
          return Scaffold(
            appBar: AppBar(
              title: Text(context.t.collection.title),
              actions: [
                ListenableBuilder(
                  listenable: controller,
                  builder: (context, _) => tabs[controller.index] != CollectionListTab.all
                      ? sizedBoxEmpty
                      : PopupMenuButton<CollectionOrder>(
                          key: const ValueKey('collection-order'),
                          icon: const Icon(Icons.sort),
                          initialValue: _order,
                          onSelected: (order) {
                            setState(() => _order = order);
                            unawaited(_tabKeys[CollectionListTab.all]?.currentState?._pager.refresh());
                          },
                          itemBuilder: (context) => [
                            for (final order in CollectionOrder.values)
                              CheckedPopupMenuItem(
                                value: order,
                                checked: order == _order,
                                child: Text(_orderName(context, order)),
                              ),
                          ],
                        ),
                ),
                // Offered as the forum's page offers it, once a page of the list loaded.
                if (loggedIn)
                  ListenableBuilder(
                    listenable: _loaded,
                    builder: (context, _) => switch (_loadedPage()) {
                      final page? when page.canCreate && (page.viewerUid ?? 0) > 0 => IconButton(
                        key: const ValueKey('collection-create'),
                        icon: const Icon(Icons.add),
                        tooltip: context.t.collection.create,
                        onPressed: () async => _create(context, page),
                      ),
                      _ => sizedBoxEmpty,
                    },
                  ),
              ],
              bottom: TabBar(tabs: [for (final tab in tabs) Tab(text: _tabName(context, tab))]),
            ),
            body: SafeArea(
              bottom: false,
              child: TabBarView(
                children: [
                  for (final tab in tabs)
                    _CollectionTab(
                      key: _tabKeys[tab],
                      tab: tab,
                      repository: _repository,
                      order: () => _order,
                      onLoaded: () => _loaded.value++,
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CollectionTab extends StatefulWidget {
  const _CollectionTab({
    required this.tab,
    required this.repository,
    required this.order,
    required this.onLoaded,
    super.key,
  });

  final CollectionListTab tab;
  final CollectionRepository repository;
  final CollectionOrder Function() order;
  final VoidCallback onLoaded;

  @override
  State<_CollectionTab> createState() => _CollectionTabState();
}

class _CollectionTabState extends State<_CollectionTab> with AutomaticKeepAliveClientMixin {
  late final _pager = CollectionPager<CollectionListResult, CollectionSummary>(
    fetch: (page) => widget.repository.fetchList(widget.tab, order: widget.order(), page: page),
    itemsOf: (page) => page.items,
    pagesOf: (page) => page.totalPages,
  );

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    collectionChanges.addListener(_onChanged);
    _pager.addListener(_onPager);
    unawaited(_pager.refresh());
  }

  /// Any load that brought a page (the first, a retry, a refresh) tells the page: its app bar reads the page.
  void _onPager() {
    if (_pager.first != null) {
      widget.onLoaded();
    }
  }

  /// A collection was changed in the app: this list may show it otherwise now.
  void _onChanged() => unawaited(_pager.refresh());

  @override
  void dispose() {
    collectionChanges.removeListener(_onChanged);
    _pager
      ..removeListener(_onPager)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: _pager,
      builder: (context, _) {
        if (_pager.first == null) {
          if (_pager.loading || _pager.failure == null) {
            return const CenteredCircularIndicator();
          }
          return FailureView(failure: _pager.failure, onRetry: _pager.refresh);
        }
        final items = _pager.items;
        return RefreshIndicator(
          onRefresh: _pager.refresh,
          child: items.isEmpty
              ? AppScrollableStateView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: AppStateView(
                    icon: Icons.collections_bookmark_outlined,
                    message: context.t.collection.empty,
                    scrollable: false,
                  ),
                )
              : AppCenteredList(
                  builder: (context, side, _) => ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: side.copyWith(top: 12, bottom: 24).add(context.safePadding()),
                    itemCount: items.length + 1,
                    separatorBuilder: (_, _) => appListSeparator,
                    itemBuilder: (context, index) {
                      if (index == items.length) {
                        return ListFooter(
                          status: listFooterStatus(
                            hasMore: _pager.hasMore,
                            loading: _pager.loadingMore,
                            failed: _pager.moreFailed,
                          ),
                          itemCount: items.length,
                          failure: _pager.failure,
                          onLoadMore: _pager.loadMore,
                          onRetry: _pager.loadMore,
                        );
                      }
                      return CollectionSummaryCard(items[index]);
                    },
                  ),
                ),
        );
      },
    );
  }
}
