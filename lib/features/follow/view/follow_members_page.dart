import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
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

/// The members a member follows and their followers (`home.php?mod=follow&do=following|follower`), a tab each: of
/// the member [uid], or of the account in use.
///
/// The account's own lists carry the forum's follow links (no longer follow a member, follow a follower back) and, on
/// the members followed, the name noted for them.
class FollowMembersPage extends StatefulWidget {
  /// Constructor.
  const FollowMembersPage({this.uid, this.username, this.followers = false, super.key});

  /// The member; the account in use without one.
  final int? uid;

  /// Their name, for the title.
  final String? username;

  /// The followers are shown first.
  final bool followers;

  @override
  State<FollowMembersPage> createState() => _FollowMembersPageState();
}

class _FollowMembersPageState extends State<FollowMembersPage> {
  late final SpaceListCubit<FollowUser> _following = _cubit(followers: false);
  late final SpaceListCubit<FollowUser> _followers = _cubit(followers: true);

  SpaceListCubit<FollowUser> _cubit({required bool followers}) => SpaceListCubit<FollowUser>(
    firstPageUrl: followListUrl(followers: followers, uid: widget.uid),
    fetch: const FollowRepository().fetchList,
    keyOf: (e) => e.uid,
  );

  @override
  void initState() {
    super.initState();
    unawaited(_following.load());
    unawaited(_followers.load());
  }

  @override
  void dispose() {
    unawaited(_following.close());
    unawaited(_followers.close());
    super.dispose();
  }

  void _refreshAll() {
    unawaited(_following.refresh());
    unawaited(_followers.refresh());
  }

  Future<void> _toggle(SpaceSession session, FollowUser user) async {
    final done = await sendFollow(
      context,
      session: session,
      uid: user.uid,
      username: user.username,
      unfollow: user.following ?? false,
    );
    if (done && mounted) _refreshAll();
  }

  Future<void> _remark(SpaceSession session, FollowUser user) async {
    final kept = await editFollowRemark(
      context,
      session: session,
      uid: user.uid,
      username: user.username,
      current: user.remark,
    );
    if (kept != null && mounted) unawaited(_following.refresh());
  }

  Widget _list(SpaceListCubit<FollowUser> cubit, String emptyMessage) => BlocProvider.value(
    value: cubit,
    child: BlocListener<SpaceListCubit<FollowUser>, SpaceListState<FollowUser>>(
      listenWhen: (prev, curr) => curr.status == SpaceLoadStatus.notice && prev.status != curr.status,
      listener: (context, state) {
        if (spaceModuleSwitchedOff(state.message)) markSpaceModuleOff(SpaceModule.follow);
      },
      child: SpaceListView<FollowUser>(
        emptyIcon: Icons.people_outline,
        emptyMessage: emptyMessage,
        itemBuilder: (context, user) {
          final session = context.read<SpaceListCubit<FollowUser>>().state.session;
          return FollowUserTile(
            user,
            onToggleFollow: session != null && user.following != null ? () async => _toggle(session, user) : null,
            onRemark: session != null && user.canRemark ? () async => _remark(session, user) : null,
          );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final tr = context.t.spacePage.follow;
    return DefaultTabController(
      length: 2,
      initialIndex: widget.followers ? 1 : 0,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.username ?? tr.members),
          bottom: TabBar(
            tabs: [
              Tab(text: tr.following),
              Tab(text: tr.followers),
            ],
          ),
        ),
        body: SafeArea(
          bottom: false,
          child: TabBarView(
            children: [
              _list(_following, tr.emptyFollowing),
              _list(_followers, tr.emptyFollowers),
            ],
          ),
        ),
      ),
    );
  }
}
