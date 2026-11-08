part of 'thread_bloc.dart';

/// Status of thread.
enum ThreadStatus {
  /// Initial.
  initial,

  /// Loading date for the first time.
  loading,

  /// Load succeed.
  success,

  /// Load failed.
  failure,
}

/// Status of a page loaded at an end of the floors on screen ([ThreadState.nextStatus],
/// [ThreadState.previousStatus]): the floors stay on screen whatever it is.
enum ThreadEdgeStatus {
  /// Nothing asked, or the last one asked arrived.
  idle,

  /// The page is being loaded.
  loading,

  /// The page could not be loaded: the end of the floors offers to try again.
  failed,
}

/// Pages of a thread kept in [ThreadState.postList] at most: reading on, the farthest pages are dropped and loaded
/// again when scrolled back to, so a long thread read for a while does not keep every floor it went through.
const threadWindowPages = 10;

/// State of thread.
@MappableClass()
class ThreadState with ThreadStateMappable {
  /// Constructor.
  const ThreadState({
    this.tid,
    this.pid,
    this.status = ThreadStatus.initial,
    this.title,
    this.fid,
    this.forumName,
    this.canLoadMore = false,
    this.currentPage = 1,
    this.firstPage = 1,
    this.totalPages = 1,
    this.havePermission = true,
    this.permissionDeniedMessage,
    this.needLogin = false,
    this.threadSoftClosed = false,
    this.threadClosed = false,
    this.postList = const [],
    this.replyParameters,
    this.threadType,
    this.onlyVisibleUid,
    this.reverseOrder,
    this.exactOrder,
    this.isDraft = false,
    this.latestModAct,
    this.breadcrumbs = const [],
    this.postMedals = const [],
    this.viewCount,
    this.replyCount,
    this.paginationReplies,
    this.postsPerPage,
    this.offlineSavedAt,
    this.floorsUid,
    this.generation = 0,
    this.nextStatus = ThreadEdgeStatus.idle,
    this.previousStatus = ThreadEdgeStatus.idle,
    this.scrollTargetPid,
    this.scrollTargetSerial = 0,
    this.jumpFloorMissed,
    this.newRepliesSerial = 0,
    this.newRepliesCount = 0,
    this.newestFirst = false,
  });

  /// Status.
  final ThreadStatus status;

  /// Thread id.
  final String? tid;

  /// Post id.
  ///
  /// Use this when "mod=redirect&goto=findpost&pid=[pid]".
  ///
  /// Necessary info that always be parsed in thread page.
  /// May be null at the beginning of state but will be set shortly after it.
  final String? pid;

  /// Thread title.
  ///
  /// Necessary info that always be parsed in thread page.
  /// May be null at the beginning of state but will be set shortly after it.
  final String? title;

  /// Forum id.
  ///
  /// Necessary info that always be parsed in thread page.
  /// May be null at the beginning of state but will be set shortly after it.
  final int? fid;

  /// Forum name.
  ///
  /// Necessary info that always be parsed in thread page.
  /// May be null at the beginning of state but will be set shortly after it.
  final String? forumName;

  /// Flag indicating can load more pages or not: [currentPage] is not the last page of the thread.
  final bool canLoadMore;

  /// The last page of the floors on screen ([postList] holds [firstPage] to it).
  final int currentPage;

  /// The first page of the floors on screen: above it the thread goes on with the pages before, loaded when scrolled
  /// to ([canLoadPrevious]).
  final int firstPage;

  /// Total pages number in the thread.
  final int totalPages;

  /// Flag indicating current user has permission to see this page or not.
  ///
  /// Only works with logged user. If no user logged in, use [needLogin] flag
  /// instead.
  final bool havePermission;

  /// Message showed from server when have no permission.
  final uh.Element? permissionDeniedMessage;

  /// Flag indicating whether need to login to see this page or not.
  ///
  /// Only works when no user logged.
  final bool needLogin;

  /// A soft closed state only means the thread is locked.
  ///
  /// Like soft lock, soft closed is a state where the thread is closed but the user may still has write permission
  /// (For example, user is the moderator of current subreddit).
  ///
  /// In this state we shall keep the post functionality as the prerequisites are still satisfied, but give a tip that
  /// the thread is closed and maybe it's not proper to post again.
  final bool threadSoftClosed;

  /// Indicating current thread is closed or not.
  final bool threadClosed;

  /// The floors on screen: pages [firstPage] to [currentPage] in the order shown, at most [threadWindowPages] pages.
  final List<Post> postList;

  /// Parameters used to reply to another post in the same thread.
  ///
  /// Save in state and should pass to reply bar.
  final ReplyParameters? replyParameters;

  /// Thread type.
  ///
  /// Usually a thread belongs to a fixed of list of thread types in the current subreddit. But some are not.
  final FilterType? threadType;

  /// Indicating only show posts published by the user who has the given uid
  /// in current thread.
  ///
  /// Show all posts if value is null;
  final String? onlyVisibleUid;

  /// View posts in current thread in forward order or reverse order.
  ///
  /// * Force set to desc order if `true`.
  /// * Force set to asc order if `false`.
  /// * Not force order if `null`.
  final bool? reverseOrder;

  /// The exact thread order in state.
  ///
  /// Specify this field if want to override with the app one.
  final int? exactOrder;

  /// Indicating current thread is a draft or not.
  final bool isDraft;

  /// Latest modification log.
  final String? latestModAct;

  /// All breadcrumbs that describe the position of current thread.
  ///
  /// It's ordered so held by a list and more right side more deep.
  final List<ThreadBreadcrumb> breadcrumbs;

  /// The medal menus of the pages on screen (each page prints those of its own floors).
  final List<PostMedalMenuItem> postMedals;

  /// Total count of views on current thread.
  final int? viewCount;

  /// Total count of replies in thread.
  final int? replyCount;

  /// The replies the forum paginated the floors on screen by (the forum's app API `thread.replies`: one author's
  /// floors only, the highest floor of a rush thread…), [replyCount] when the page does not tell.
  final int? paginationReplies;

  /// Floors per page of the thread for the account (the forum's app API `ppp`, else worked out from a full page);
  /// null while not known.
  final int? postsPerPage;

  /// Floors on screen came from the offline copies because the forum could not be reached: when the oldest of those
  /// pages was loaded. Null while every floor came from the forum. Actions that need the network are not offered then.
  final DateTime? offlineSavedAt;

  /// Whether floors on screen came from the offline copies ([offlineSavedAt]).
  bool get isOffline => offlineSavedAt != null;

  /// The account the floors on screen were loaded for (null: a guest). A load for another account that fails never
  /// puts them back on screen, nor appends to them.
  final int? floorsUid;

  /// Bumped by every load that replaces the floors on screen (refresh, jump, one author's floors, order): the list
  /// starts over instead of keeping its place among floors that are gone.
  final int generation;

  /// The page after [currentPage] being loaded, or failed to.
  final ThreadEdgeStatus nextStatus;

  /// The page before [firstPage] being loaded, or failed to.
  final ThreadEdgeStatus previousStatus;

  /// A floor to bring into view (a jump to a floor), told once per [scrollTargetSerial].
  final String? scrollTargetPid;

  /// Bumped with every [scrollTargetPid] asked for, the same floor included.
  final int scrollTargetSerial;

  /// The floor a jump asked for when the thread does not have it (a deleted floor of a rush thread, past the last one):
  /// the jump went to the closest one ([scrollTargetPid]). Null otherwise.
  final int? jumpFloorMissed;

  /// Bumped every time the last page was asked again for new replies ([newRepliesCount] of them).
  final int newRepliesSerial;

  /// Floors the last ask for new replies added ([newRepliesSerial]).
  final int newRepliesCount;

  /// Whether the thread goes on above the floors on screen.
  bool get canLoadPrevious => firstPage > 1;

  /// The last page loaded came in the newest first order ([ThreadPageInfo.newestFirst]): asked so, or the order the
  /// thread's author set.
  final bool newestFirst;

  /// Whether the floors are shown newest first, page 1 holding the latest replies: asked so (the reverse order), or
  /// the thread's author set it ([newestFirst]).
  bool get shownNewestFirst => newestFirst || exactOrder == 1 || (exactOrder == null && (reverseOrder ?? false));
}
