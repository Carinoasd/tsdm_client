import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/features/follow/models/follow_models.dart';
import 'package:tsdm_client/features/follow/repository/follow_repository.dart';
import 'package:tsdm_client/features/follow/utils/parse_follow.dart';
import 'package:tsdm_client/features/follow/widgets/follow_widgets.dart';
import 'package:tsdm_client/features/space/cubit/space_list_cubit.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/space/utils/space_switches.dart';
import 'package:tsdm_client/features/space/view/space_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// The broadcasts (`home.php?mod=follow`): of the members the account follows and of everyone, a tab each; or those
/// of the member [uid] alone. A broadcast opens its thread; the forum's own relay and delete are in its menu.
class FollowFeedPage extends StatefulWidget {
  /// Constructor.
  const FollowFeedPage({this.uid, this.username, super.key});

  /// The member whose broadcasts are shown; the lists of the account in use without one.
  final int? uid;

  /// Their name, for the title.
  final String? username;

  @override
  State<FollowFeedPage> createState() => _FollowFeedPageState();
}

class _FollowFeedPageState extends State<FollowFeedPage> {
  late final bool _member = (widget.uid ?? 0) > 0;
  late final List<SpaceListCubit<FollowFeed>> _feeds = [
    if (_member)
      _cubit(followFeedUrl(uid: widget.uid))
    else
      for (final view in FollowFeedView.values) _cubit(followFeedUrl(view: view)),
  ];

  static SpaceListCubit<FollowFeed> _cubit(String url) => SpaceListCubit<FollowFeed>(
    firstPageUrl: url,
    fetch: const FollowRepository().fetchFeed,
    keyOf: (e) => e.feedId,
  );

  @override
  void initState() {
    super.initState();
    for (final feed in _feeds) {
      unawaited(feed.load());
    }
  }

  @override
  void dispose() {
    for (final feed in _feeds) {
      unawaited(feed.close());
    }
    super.dispose();
  }

  void _refreshAll() {
    for (final feed in _feeds) {
      unawaited(feed.refresh());
    }
  }

  Future<void> _relay(SpaceSession session, FollowFeed feed) async {
    if (await showRelayDialog(context, session: session, feed: feed) && mounted) _refreshAll();
  }

  Future<void> _delete(SpaceSession session, FollowFeed feed) async {
    if (await deleteFollowFeed(context, session: session, feed: feed) && mounted) _refreshAll();
  }

  Widget _list(SpaceListCubit<FollowFeed> cubit) {
    final tr = context.t.spacePage.follow;
    return BlocProvider.value(
      value: cubit,
      child: BlocListener<SpaceListCubit<FollowFeed>, SpaceListState<FollowFeed>>(
        listenWhen: (prev, curr) => curr.status == SpaceLoadStatus.notice && prev.status != curr.status,
        listener: (context, state) {
          if (spaceModuleSwitchedOff(state.message)) markSpaceModuleOff(SpaceModule.broadcast);
        },
        child: SpaceListView<FollowFeed>(
          emptyIcon: Icons.dynamic_feed_outlined,
          emptyMessage: tr.emptyFeed,
          itemBuilder: (context, feed) {
            final session = context.read<SpaceListCubit<FollowFeed>>().state.session;
            return FollowFeedCard(
              feed,
              onRelay: session != null && feed.canRelay ? () async => _relay(session, feed) : null,
              onDelete: session != null && feed.canDelete ? () async => _delete(session, feed) : null,
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage.follow;
    if (_member) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.username ?? tr.broadcasts)),
        body: SafeArea(bottom: false, child: _list(_feeds.single)),
      );
    }
    return DefaultTabController(
      length: _feeds.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr.feed),
          actions: [
            // The members followed and the followers of the account; switched off apart from the broadcasts.
            ValueListenableBuilder(
              valueListenable: spaceModulesOff,
              builder: (context, off, _) => off.contains(SpaceModule.follow)
                  ? const SizedBox.shrink()
                  : IconButton(
                      icon: const Icon(Icons.people_outline),
                      tooltip: tr.following,
                      onPressed: () async => context.pushNamed(ScreenPaths.followMembers),
                    ),
            ),
          ],
          bottom: TabBar(
            tabs: [
              Tab(text: tr.following),
              Tab(text: tr.hall),
            ],
          ),
        ),
        body: SafeArea(
          bottom: false,
          child: TabBarView(children: [for (final feed in _feeds) _list(feed)]),
        ),
      ),
    );
  }
}
