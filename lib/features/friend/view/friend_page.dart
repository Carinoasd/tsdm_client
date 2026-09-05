import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/friend/bloc/friend_bloc.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/features/friend/widgets/friend_card.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Page listing the friends of a user.
///
/// The user is located by [uid] (preferred) or [username]; when both are null the current user's list is shown.
class FriendPage extends StatefulWidget {
  /// Constructor.
  const FriendPage({this.uid, this.username, super.key});

  /// Uid of the user whose friends are listed.
  final String? uid;

  /// Username of the user whose friends are listed.
  final String? username;

  @override
  State<FriendPage> createState() => _FriendPageState();
}

class _FriendPageState extends State<FriendPage> {
  final _refreshController = EasyRefreshController(controlFinishRefresh: true, controlFinishLoad: true);
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _refreshController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Widget _buildCenteredText(BuildContext context, String text) => Center(
    child: Padding(
      padding: edgeInsetsL24R24,
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.outline),
      ),
    ),
  );

  Widget _buildList(BuildContext context, FriendState state) {
    final tr = context.t.friendPage;
    if (!state.refreshing) {
      _refreshController.finishRefresh();
    }
    if (!state.loadingMore) {
      _refreshController.finishLoad(state.nextPageUrl == null ? IndicatorResult.noMore : IndicatorResult.success);
    }
    return EasyRefresh.builder(
      controller: _refreshController,
      scrollController: _scrollController,
      header: const MaterialHeader(),
      footer: const MaterialFooter(),
      onRefresh: () => context.read<FriendBloc>().add(const FriendRefreshRequested()),
      onLoad: () {
        if (state.nextPageUrl == null) {
          _refreshController.finishLoad(IndicatorResult.noMore);
          return;
        }
        context.read<FriendBloc>().add(const FriendLoadMoreRequested());
      },
      childBuilder: (context, physics) {
        if (state.items.isEmpty) {
          return ListView(
            physics: physics,
            controller: _scrollController,
            padding: edgeInsetsL12T4R12.add(context.safePadding()),
            children: [sizedBoxW32H32, _buildCenteredText(context, tr.empty)],
          );
        }
        return ListView.separated(
          physics: physics,
          controller: _scrollController,
          padding: edgeInsetsL12T4R12.add(context.safePadding()),
          itemCount: state.items.length,
          itemBuilder: (context, index) => FriendCard(state.items[index]),
          separatorBuilder: (context, index) => sizedBoxW4H4,
        );
      },
    );
  }

  Widget _buildBody(BuildContext context, FriendState state) => switch (state.status) {
    FriendStatus.initial || FriendStatus.loading => const CenteredCircularIndicator(),
    FriendStatus.needLogin => NeedLoginPage(
      backUri: GoRouterState.of(context).uri,
      needPop: true,
      popCallback: (context) => context.read<FriendBloc>().add(const FriendLoadRequested()),
    ),
    FriendStatus.notice => _buildCenteredText(context, state.message ?? ''),
    FriendStatus.failure => buildRetryButton(context, () => context.read<FriendBloc>().add(const FriendLoadRequested())),
    FriendStatus.success => _buildList(context, state),
  };

  Widget _buildTitle(BuildContext context, FriendState state) {
    final tr = context.t.friendPage;
    final name = state.ownerName ?? widget.username;
    final count = state.totalCount;
    final String? subtitle;
    if (name == null) {
      subtitle = count == null ? null : tr.subtitleCountOnly(count: count);
    } else {
      subtitle = count == null ? name : tr.subtitle(name: name, count: count);
    }
    if (subtitle == null) {
      return Text(tr.title);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(tr.title),
        Text(subtitle, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.friendPage;
    // No target given: show the current user's list.
    final selfUid = context.read<AuthenticationRepository>().currentUser?.uid;
    final uid = widget.uid ?? (widget.username == null ? selfUid?.toString() : null);
    if (uid == null && widget.username == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.title)),
        body: NeedLoginPage(backUri: GoRouterState.of(context).uri, needPop: true),
      );
    }
    return MultiRepositoryProvider(
      providers: [RepositoryProvider(create: (_) => const FriendRepository())],
      child: BlocProvider(
        create: (context) =>
            FriendBloc(
                friendRepository: context.repo(),
                firstPageUrl: FriendRepository.listUrl(uid: uid, username: widget.username),
              )
              ..add(const FriendLoadRequested()),
        child: BlocListener<FriendBloc, FriendState>(
          listenWhen: (prev, curr) => prev.failureCount != curr.failureCount,
          listener: (context, state) => showFailedToLoadSnackBar(context),
          child: BlocBuilder<FriendBloc, FriendState>(
            builder: (context, state) => Scaffold(
              appBar: AppBar(title: _buildTitle(context, state)),
              body: SafeArea(bottom: false, child: _buildBody(context, state)),
            ),
          ),
        ),
      ),
    );
  }
}
