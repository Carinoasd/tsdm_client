import 'dart:async';

import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/ranklist/cubit/ranklist_cubit.dart';
import 'package:tsdm_client/features/ranklist/models/ranklist.dart';
import 'package:tsdm_client/features/ranklist/repository/ranklist_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';
import 'package:tsdm_client/widgets/two_pane.dart';

/// The forum's rankings: members by credits, posts and online time, and the hot threads.
class RanklistPage extends StatelessWidget {
  /// Constructor.
  const RanklistPage({this.repository, super.key});

  /// Repository override (tests); the real one is used when null.
  final RanklistRepository? repository;

  @override
  Widget build(BuildContext context) {
    // A wide window shows the thread tapped on the right of the rankings.
    return TwoPaneLayout(list: _buildPage(context));
  }

  Widget _buildPage(BuildContext context) {
    final tr = context.t.ranklistPage;
    return RepositoryProvider(
      create: (_) => repository ?? RanklistRepository(),
      child: DefaultTabController(
        length: RanklistKind.values.length,
        child: Scaffold(
          appBar: AppBar(
            title: Text(tr.title),
            bottom: TabBar(
              tabs: [
                for (final kind in RanklistKind.values)
                  Tab(
                    text: switch (kind) {
                      RanklistKind.credit => tr.tabs.credit,
                      RanklistKind.post => tr.tabs.post,
                      RanklistKind.online => tr.tabs.online,
                      RanklistKind.thread => tr.tabs.thread,
                    },
                  ),
              ],
            ),
          ),
          body: SafeArea(
            bottom: false,
            child: TabBarView(
              children: [for (final kind in RanklistKind.values) _RanklistTab(kind, key: ValueKey(kind))],
            ),
          ),
        ),
      ),
    );
  }
}

/// One ranking, kept while the other tabs are shown.
class _RanklistTab extends StatefulWidget {
  const _RanklistTab(this.kind, {super.key});

  final RanklistKind kind;

  @override
  State<_RanklistTab> createState() => _RanklistTabState();
}

class _RanklistTabState extends State<_RanklistTab> with AutomaticKeepAliveClientMixin {
  late final EasyRefreshController _refreshController;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _refreshController = EasyRefreshController(controlFinishRefresh: true);
  }

  @override
  void dispose() {
    _refreshController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return BlocProvider(
      create: (context) {
        final cubit = RanklistCubit(kind: widget.kind, repository: context.read<RanklistRepository>());
        unawaited(cubit.load());
        return cubit;
      },
      child: BlocConsumer<RanklistCubit, RanklistState>(
        // A refresh that failed keeps the ranking on screen and says so.
        listenWhen: (prev, curr) => prev.refreshing && !curr.refreshing && curr.failure != null,
        listener: (context, state) {
          final cubit = context.read<RanklistCubit>();
          showRefreshFailedSnackBar(
            context,
            state.failure,
            onRetry: () {
              if (!cubit.isClosed) {
                unawaited(cubit.load());
              }
            },
          );
        },
        builder: (context, state) {
          final cubit = context.read<RanklistCubit>();
          if (!state.refreshing) {
            _refreshController.finishRefresh();
          }
          final body = switch (state.status) {
            RanklistStatus.loading => const ThreadListSkeleton(),
            RanklistStatus.failed => FailureView(failure: state.failure, onRetry: cubit.load),
            RanklistStatus.success => _buildList(context, state),
          };
          // A ranking the forum turned off answers so in every order: nothing to choose then.
          final turnedOff =
              state.status == RanklistStatus.failed &&
              const {LoadFailureKind.forumMessage, LoadFailureKind.noPermission}.contains(state.failure?.kind);
          if (widget.kind != RanklistKind.thread || turnedOff) {
            return body;
          }
          return Column(
            children: [
              _ThreadViewBar(selected: state.threadView, onSelected: cubit.changeThreadView),
              Expanded(child: body),
            ],
          );
        },
      ),
    );
  }

  Widget _buildList(BuildContext context, RanklistState state) {
    final page = state.page!;
    final cubit = context.read<RanklistCubit>();
    final tr = context.t.ranklistPage;
    final updated = switch ((page.lastUpdate, page.nextUpdate)) {
      (final last?, final next?) => tr.updated(last: last, next: next),
      _ => page.notice,
    };
    final rows = <Widget>[
      for (final member in page.members)
        _MemberTile(
          member,
          value: switch (widget.kind) {
            RanklistKind.online => switch (ranklistOnlineMinutes(member.value)) {
              final minutes? => tr.minutes(n: minutes),
              null => member.value,
            },
            _ => member.value,
          },
        ),
      for (final thread in page.threads) _ThreadTile(thread),
    ];
    return EasyRefresh.builder(
      controller: _refreshController,
      header: const MaterialHeader(),
      onRefresh: cubit.load,
      childBuilder: (context, physics) => page.isEmpty
          ? AppScrollableStateView(
              physics: physics,
              child: AppStateView(icon: Icons.leaderboard_outlined, message: tr.empty, scrollable: false),
            )
          : AppCenteredList(
              builder: (context, side, _) => ListView(
                physics: physics,
                padding: side.copyWith(top: 8, bottom: 8).add(context.safePadding()),
                children: [
                  ...rows,
                  if (updated != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Text(
                        updated,
                        key: const ValueKey('ranklist-updated'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

/// The orders of the thread ranking.
class _ThreadViewBar extends StatelessWidget {
  const _ThreadViewBar({required this.selected, required this.onSelected});

  final RanklistThreadView selected;

  final ValueChanged<RanklistThreadView> onSelected;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.ranklistPage.threadViews;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        spacing: 8,
        children: [
          for (final view in RanklistThreadView.values)
            ChoiceChip(
              key: ValueKey('ranklist-view-${view.name}'),
              label: Text(switch (view) {
                RanklistThreadView.replies => tr.replies,
                RanklistThreadView.views => tr.views,
                RanklistThreadView.favtimes => tr.favtimes,
                RanklistThreadView.heats => tr.heats,
              }),
              selected: view == selected,
              onSelected: (_) => onSelected(view),
            ),
        ],
      ),
    );
  }
}

/// The place in a ranking, the first three in the primary color.
class _Rank extends StatelessWidget {
  const _Rank(this.rank);

  final int rank;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 32,
      child: Text(
        '$rank',
        textAlign: TextAlign.center,
        style: theme.textTheme.titleMedium?.copyWith(
          fontWeight: rank <= 3 ? FontWeight.bold : null,
          color: rank <= 3 ? theme.colorScheme.primary : theme.colorScheme.outline,
        ),
      ),
    );
  }
}

/// The value ranked, at the end of a row.
class _Value extends StatelessWidget {
  const _Value(this.value);

  final String value;

  @override
  Widget build(BuildContext context) => Text(
    value,
    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
  );
}

class _MemberTile extends StatelessWidget {
  const _MemberTile(this.member, {required this.value});

  final RanklistMember member;

  /// The value shown.
  final String value;

  @override
  Widget build(BuildContext context) => ListTile(
    key: ValueKey('ranklist-member-${member.uid}'),
    leading: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        _Rank(member.rank),
        HeroUserAvatar(username: member.username, avatarUrl: avatarUrlOfUid(member.uid), disableHero: true),
      ],
    ),
    title: Text(member.username, maxLines: 1, overflow: TextOverflow.ellipsis),
    subtitle: member.groupName == null ? null : Text(member.groupName!, maxLines: 1, overflow: TextOverflow.ellipsis),
    trailing: _Value(value),
    onTap: () => context.pushNamed(ScreenPaths.profile, queryParameters: {'uid': member.uid}),
  );
}

class _ThreadTile extends StatelessWidget {
  const _ThreadTile(this.thread);

  final RanklistThread thread;

  @override
  Widget build(BuildContext context) {
    final info = [?thread.forumName, ?thread.author].join(' · ');
    return ListTile(
      key: ValueKey('ranklist-thread-${thread.tid}'),
      leading: _Rank(thread.rank),
      title: Text(thread.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: info.isEmpty ? null : Text(info, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _Value(thread.value),
      onTap: () => openThread(context, threadID: thread.tid, title: thread.title),
    );
  }
}
