import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/editor/repository/mention_repository.dart';
import 'package:tsdm_client/features/quick_open/models/quick_open_candidate.dart';
import 'package:tsdm_client/features/share_receive/share_dispatcher.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';

/// Where the friends and the users mentioned recently come from; kept for the run so reopening the box is quick.
final MentionRepository _mentionRepository = MentionRepository();

/// The forums of [groups], unique by id in the order of the index; the forums that only redirect elsewhere are left
/// out as they have no page of their own.
List<QuickOpenForum> quickOpenForumsOf(List<ForumGroup> groups) {
  final seen = <int>{};
  return [
    for (final group in groups)
      for (final forum in group.forumList)
        if (forum.redirectUrl == null && forum.name.isNotEmpty && seen.add(forum.forumID))
          (fid: forum.forumID, name: forum.name),
  ];
}

/// The threads of [history] newest visit first, one per thread.
List<QuickOpenThread> quickOpenThreadsOf(List<ThreadVisitHistoryModel> history) {
  final sorted = [...history]..sort((a, b) => b.visitTime.compareTo(a.visitTime));
  final seen = <int>{};
  return [
    for (final item in sorted)
      if (item.threadTitle.isNotEmpty && seen.add(item.threadId)) (tid: item.threadId, title: item.threadTitle),
  ];
}

/// The users of the mention candidates: the ones mentioned recently first, then the friends, unique by uid.
List<QuickOpenUser> quickOpenUsersOf(MentionCandidates candidates) {
  final seen = <String>{};
  return [
    for (final user in [...candidates.recent, ...candidates.friends])
      if (user.username.isNotEmpty && seen.add(user.uid)) (uid: user.uid, name: user.username),
  ];
}

/// Loads each source of the box on its own and hands it to [onLoaded] as it arrives; a source that fails stays empty.
///
/// [isActive] tells whether the box is still open, so a closed box asks nothing more.
Future<void> loadQuickOpenSources(
  BuildContext context, {
  required void Function({List<QuickOpenForum>? forums, List<QuickOpenThread>? threads, List<QuickOpenUser>? users})
  onLoaded,
  required bool Function() isActive,
}) async {
  final historyRepository = context.read<ThreadVisitHistoryRepo>();
  final forumRepository = context.read<ForumHomeRepository>();
  final selfUid = context.read<AuthenticationRepository?>()?.currentUser?.uid?.toString();

  Future<void> history() async {
    final result = await historyRepository.fetchAllHistory().run();
    if (isActive()) {
      result.fold((_) {}, (value) => onLoaded(threads: quickOpenThreadsOf(value)));
    }
  }

  Future<void> forums() async {
    final groups = await loadForumGroups(forumRepository);
    if (isActive()) {
      onLoaded(forums: quickOpenForumsOf(groups));
    }
  }

  Future<void> users() async {
    if (selfUid == null) {
      return;
    }
    final result = await _mentionRepository.loadCandidates(selfUid: selfUid).run();
    if (isActive()) {
      result.fold((_) {}, (value) => onLoaded(users: quickOpenUsersOf(value)));
    }
  }

  await Future.wait([history(), forums(), users()]);
}
