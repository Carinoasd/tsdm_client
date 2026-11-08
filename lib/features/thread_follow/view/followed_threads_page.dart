import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/thread_follow/cubit/followed_threads_cubit.dart';
import 'package:tsdm_client/features/thread_follow/models/followed_thread.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The url opening the last floor of thread [tid].
String followedThreadLastPostUrl(int tid) => '$baseUrl/forum.php?mod=redirect&tid=$tid&goto=lastpost';

/// The threads the account in use follows ([FollowedThreadsCubit]): title, new replies, time of the newest floor.
///
/// A tap opens the last floor of the thread and clears its new replies; a long press stops following it (the snack
/// bar can undo).
class FollowedThreadsPage extends StatefulWidget {
  /// Constructor.
  const FollowedThreadsPage({super.key});

  @override
  State<FollowedThreadsPage> createState() => _FollowedThreadsPageState();
}

class _FollowedThreadsPageState extends State<FollowedThreadsPage> {
  @override
  void initState() {
    super.initState();
    // The background service may have found new replies since the list was read.
    unawaited(context.read<FollowedThreadsCubit>().reload());
  }

  Future<void> _open(BuildContext context, FollowedThread thread) async {
    final cubit = context.read<FollowedThreadsCubit>();
    final uid = cubit.state.uid;
    if (uid != null) {
      unawaited(cubit.markRead(uid: uid, tid: thread.tid, replies: thread.knownReplies));
    }
    await context.dispatchAsUrl(followedThreadLastPostUrl(thread.tid));
  }

  Future<void> _unfollow(BuildContext context, FollowedThread thread) async {
    final cubit = context.read<FollowedThreadsCubit>();
    final tr = context.t.followedThreads;
    await cubit.unfollow(thread.tid);
    if (!context.mounted) {
      return;
    }
    showSnackBar(
      context: context,
      message: tr.unfollowed,
      clearPrevious: true,
      action: SnackBarAction(label: tr.undo, onPressed: () => unawaited(cubit.restore(thread))),
    );
  }

  Widget _buildItem(BuildContext context, FollowedThread thread) {
    final tr = context.t.followedThreads;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final fresh = thread.newReplies;
    final last = thread.lastReplyAt;
    return AppSurface(
      key: ValueKey('followed-thread-${thread.tid}'),
      onTap: () async => _open(context, thread),
      onLongPress: () async => _unfollow(context, thread),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  thread.title.isEmpty ? '${thread.tid}' : thread.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleSmall,
                ),
                if (last != null) ...[
                  sizedBoxW4H4,
                  Text(
                    last.elapsedTillNow(context),
                    style: textTheme.labelSmall?.copyWith(color: colorScheme.outline),
                  ),
                ],
              ],
            ),
          ),
          if (fresh > 0) ...[
            sizedBoxW12H12,
            Text(
              tr.newReplies(n: fresh),
              key: ValueKey('followed-thread-new-${thread.tid}'),
              style: textTheme.labelLarge?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.followedThreads;
    final state = context.watch<FollowedThreadsCubit>().state;
    final Widget body;
    if (state.uid == null) {
      body = AppStateView(icon: Icons.login_outlined, message: tr.needLogin);
    } else if (!state.loaded) {
      body = const CenteredCircularIndicator();
    } else if (state.threads.isEmpty) {
      body = AppStateView(icon: Icons.notifications_none_outlined, message: tr.empty);
    } else {
      final threads = state.threads;
      body = RefreshIndicator(
        onRefresh: () => context.read<FollowedThreadsCubit>().reload(),
        child: AppCenteredList(
          builder: (context, side, _) => ListView.separated(
            padding: side.copyWith(top: 12, bottom: 12),
            itemCount: threads.length,
            separatorBuilder: (_, _) => appListSeparator,
            itemBuilder: (context, index) => _buildItem(context, threads[index]),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr.title)),
      body: SafeArea(bottom: false, child: body),
    );
  }
}
