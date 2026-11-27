import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/editor/repository/mention_repository.dart';
import 'package:tsdm_client/features/editor/widgets/mention_picker.dart';
import 'package:tsdm_client/features/floor_bookmark/cubit/floor_bookmark_cubit.dart';
import 'package:tsdm_client/features/floor_bookmark/models/floor_bookmark.dart';
import 'package:tsdm_client/features/quick_open/models/quick_open_candidate.dart';
import 'package:tsdm_client/features/read_later/cubit/read_later_cubit.dart';
import 'package:tsdm_client/features/share_receive/share_dispatcher.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';

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

/// Hands one loaded source of the box over; the others stay as they were.
typedef QuickOpenSourcesArrived =
    void Function({
      List<QuickOpenForum>? forums,
      List<QuickOpenThread>? threads,
      List<QuickOpenUser>? users,
      List<QuickOpenThread>? readLater,
      List<QuickOpenBookmark>? bookmarks,
    });

/// The threads put aside to read later, newest first as the list holds them.
List<QuickOpenThread> quickOpenReadLaterOf(List<ReadLaterItem> items) => [
  for (final item in items)
    if (item.title.isNotEmpty) (tid: item.tid, title: item.title),
];

/// The floors bookmarked, the ones removed left out.
List<QuickOpenBookmark> quickOpenBookmarksOf(List<FloorBookmark> items) => [
  for (final item in items)
    if (!item.deleted && (item.threadTitle.isNotEmpty || item.note.isNotEmpty))
      (pid: item.pid, title: item.threadTitle, note: item.note, floor: item.floor),
];

/// Loads each source of the box on its own and hands it to [onLoaded] as it arrives; a source that fails stays empty.
///
/// The users come from the repository the mention picker uses, so the two share one cache. [isActive] tells whether the box is still open, so a closed box asks nothing more.
Future<void> loadQuickOpenSources(
  BuildContext context, {
  required QuickOpenSourcesArrived onLoaded,
  required bool Function() isActive,
}) async {
  // A source the page above does not provide stays empty, as one that fails to load does.
  final historyRepository = context.readOrNull<ThreadVisitHistoryRepo>();
  final forumRepository = context.readOrNull<ForumHomeRepository>();
  final selfUid = context.read<AuthenticationRepository?>()?.currentUser?.uid?.toString();

  // What the account put aside and bookmarked is on the device already (their lists keep it loaded): handed over at
  // once, nothing is read for it.
  final readLater = context.readOrNull<ReadLaterCubit>()?.state.items;
  final bookmarks = context.readOrNull<FloorBookmarkCubit>()?.state.items;
  if (readLater != null || bookmarks != null) {
    onLoaded(
      readLater: readLater == null ? null : quickOpenReadLaterOf(readLater),
      bookmarks: bookmarks == null ? null : quickOpenBookmarksOf(bookmarks),
    );
  }

  Future<void> history() async {
    if (historyRepository == null) {
      return;
    }
    final result = await historyRepository.fetchAllHistory().run();
    if (isActive()) {
      result.fold((_) {}, (value) => onLoaded(threads: quickOpenThreadsOf(value)));
    }
  }

  Future<void> forums() async {
    if (forumRepository == null) {
      return;
    }
    final groups = await loadForumGroups(forumRepository);
    if (isActive()) {
      onLoaded(forums: quickOpenForumsOf(groups));
    }
  }

  Future<void> users() async {
    if (selfUid == null) {
      return;
    }
    final result = await sharedMentionRepository().loadCandidates(selfUid: selfUid).run();
    if (isActive()) {
      result.fold((_) {}, (value) => onLoaded(users: quickOpenUsersOf(value)));
    }
  }

  await Future.wait([history(), forums(), users()]);
}
