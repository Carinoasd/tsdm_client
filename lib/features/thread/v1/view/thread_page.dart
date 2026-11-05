import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart' show AuthStatus;
import 'package:tsdm_client/features/authentication/utils/account_changes.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/blocking/widgets/block_aware_post.dart';
import 'package:tsdm_client/features/editor/utils/mention_suggestions.dart';
import 'package:tsdm_client/features/editor/widgets/mention_suggestion_bar.dart';
import 'package:tsdm_client/features/favorite/utils/thread_favorite_action.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/offline_thread/repository/offline_thread_repository.dart';
import 'package:tsdm_client/features/reading_progress/cubit/reading_progress_cubit.dart';
import 'package:tsdm_client/features/reading_progress/models/reading_progress.dart';
import 'package:tsdm_client/features/replied_thread/cubit/replied_thread_cubit.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/dialog.dart';
import 'package:tsdm_client/features/thread/v1/utils/replied_thread_seed.dart';
import 'package:tsdm_client/features/thread/v1/utils/share_thread_action.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_search.dart';
import 'package:tsdm_client/features/thread/v1/widgets/collapsing_app_bar.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/features/thread/v1/widgets/reading_gestures.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/thread_open_position.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/utils/html/search_highlight.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/error_card.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/list_app_bar/list_app_bar.dart';
import 'package:tsdm_client/widgets/munched_html.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/debate_stand_selector.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

/// Page to show thread.
class ThreadPage extends StatefulWidget {
  /// Constructor.
  const ThreadPage({
    required this.threadID,
    required this.findPostID,
    required this.pageNumber,
    required this.overrideReverseOrder,
    required this.overrideWithExactOrder,
    this.title,
    this.threadType,
    this.onlyVisibleUid,
    this.lastPost = false,
    super.key,
  }) : assert(threadID != null || findPostID != null, 'MUST provide threadID or findPostID');

  /// Thread ID, tid.
  final String? threadID;

  /// Post ID to find and redirect before accessing the real thread page.
  ///
  /// In some situations we do not know the [threadID] but only a post id to
  /// find.
  /// e.g. Redirect from points statistics changelog event:
  ///
  /// * $baseUrl/forum.php?mod=redirect&goto=findpost&pid=xxx
  ///
  /// So In this situation we need to allow this type of url and assume it is
  /// thread page.
  /// With mod=redirect and goto=findpost and the pid parameter is here.
  ///
  /// This field MUST only used when [threadID] is empty.
  final String? findPostID;

  /// Thread title.
  final String? title;

  /// Thread current page number.
  final String pageNumber;

  /// Override the original post order in thread.
  ///
  /// * If `true`, force add a `ordertype` query parameter when fetching page.
  /// * If `false`, do NOT add such param so that use the original post order.
  ///
  /// This flag is used in situation that user is heading to a certain page
  /// contains a target post. If set to `true`, override order may cause going
  /// to a wrong page.
  ///
  /// Additionally, the effect has less priority compared to
  /// [overrideWithExactOrder] where the latter one is specifying the exact
  /// order type and current field only determines using the order specified by
  /// app if has.
  final bool overrideReverseOrder;

  /// Carries the exact order required by external reasons.
  ///
  /// If value is not null, the final thread order is override by the value no
  /// matter [overrideReverseOrder] is true or false.
  ///
  /// Actually this field is a patch on is the following situation:
  ///
  /// ```console
  /// ${HOST}/...&ordertype=N
  /// ```
  ///
  /// where order type is directly specified in url before dispatching, and
  /// should override any order in app settings.
  final int? overrideWithExactOrder;

  /// Thread type.
  ///
  /// Sometimes we do not know the thread type before we load it, redirect from
  /// homepage, for example. So it's a nullable String.
  final FilterType? threadType;

  /// Only watch the floors posted by the user with uid [onlyVisibleUid].
  final String? onlyVisibleUid;

  /// Open on the last floor (`goto=lastpost`): the last page, asked as a page past it ([lastPageAsked]) that the forum
  /// answers with its last page, scrolled to its last floor; [pageNumber] is not used.
  final bool lastPost;

  @override
  State<ThreadPage> createState() => _ThreadPageState();
}

/// The page asked for to open a thread on its last floor ([ThreadPage.lastPost]): past the last page of any thread,
/// the forum answers its last page and says which one it is.
const lastPageAsked = 99999;

/// Upper bound of the combined text scale (global text scale times thread content scale) applied to floors.
const threadContentMaxTextScale = 3.0;

class _ThreadPageState extends State<ThreadPage> with TickerProviderStateMixin, LoggerMixin {
  /// Controller of thread tab.
  final _listScrollController = ThreadScrollController();

  /// The list of floors, asked whether it shows the thread from its start ("back to top").
  final _postListKey = GlobalKey<PostListState>();

  /// Where the reading of this thread stopped last time, offered to go on with ("continue" banner) while the list is
  /// near the start; null when there is nothing to offer, or once taken or dismissed.
  ReadingProgress? _resumeOffer;

  /// Where the reading stopped last time, gone on with right away (the "continue where I stopped" setting).
  ReadingProgress? _resumeAt;

  /// Where the reading stopped last time while the page opened at the start of the thread (not gone on with right
  /// away): kept as the reading position until the user scrolls, goes on with it or jumps to a floor, so a page opened
  /// and left again does not put the bookmark back to the first floor.
  ReadingProgress? _heldPosition;

  /// Whether the user scrolled the list (not only the page doing it).
  bool _userScrolled = false;

  /// Waits for where the reading stopped while it is not read yet, see [_progressLoading].
  StreamSubscription<ReadingProgressState>? _progressWait;

  /// Keeps where the reading is, see [_onTopFloorChanged].
  ReadingProgressCubit? _progressCubit;

  /// The progress to keep once the list stays still ([_progressTimer]) or the page is left.
  ({int uid, int tid, ReadingProgress progress})? _pendingProgress;
  Timer? _progressTimer;

  /// The progress kept last: the same one is not written again.
  ({int uid, int tid, ReadingProgress progress})? _keptProgress;

  /// The generation of the floors the page indicator was set to the first page of.
  int? _pageInfoGeneration;

  /// The munched contents of the floors, kept for the floors built again when scrolled back to (a floor is not kept
  /// alive off screen), at most a few pages of them; gone with the page.
  final _munchCache = MunchCache();

  final _replyBarController = ReplyBarController();

  /// Searching the floors on screen: the app bar is the search bar meanwhile, and stays shown.
  bool _searching = false;
  final _searchController = TextEditingController();
  Timer? _searchDebounce;

  /// The words typed last ([_onSearchEdited]), null while the input method composes them.
  String? _searchTyped;

  /// What is searched for, once the words typed settled for a moment ([_searchDelay]); null while nothing is.
  RegExp? _searchPattern;

  /// The current hit: the one brought into view last, or the one closest to it when it is not a hit any more
  /// ([_currentHitAmong]); null only while nothing is found.
  String? _searchCurrentPid;

  /// The hits found last and what they were found in, see [_searchHits].
  ({ThreadState state, RegExp pattern, UserBlockList blocks, List<Post> hits})? _searchFound;

  /// The pages the words searched for were looked for in: a page loaded for the search ([_searchLoadSide]) is one
  /// not looked in yet, the pages on screen being at most [threadWindowPages]. The pages of the floors on screen and
  /// of the floors they go on from ([_goesOn]): another list of floors has pages of its own.
  final _searchedPages = <int>{};

  /// The floor at the top of the list, as it told last ([_onTopFloorChanged]): a new search starts from there.
  String? _topPid;

  static const _searchDelay = Duration(milliseconds: 300);

  /// Shown part of the app bar and the breadcrumbs: hidden while scrolling down the floors (the
  /// `collapseAppBarWhenScroll` setting), shown again when scrolling up.
  late final AnimationController _appBarController;
  late final AppBarCollapser _appBarCollapser;

  /// Immersive reading: the reader tapped the floors to hide the app bar and the reply bar, until tapped again. Only
  /// while on this page.
  bool _immersive = false;

  /// Shown part of the reply bar (and the banner above it): hidden while [_immersive].
  late final AnimationController _bottomBarController;

  /// Floor to scroll to when the thread reloads after a reply or edit. Read by the next
  /// [PostList] in its `initState` and forgotten right after, so later reloads do not jump back to it.
  String? _scrollToPidOnReload;

  /// Scroll to the last floor once the first load succeeds ([ThreadPage.lastPost]).
  late bool _landOnLastPost = widget.lastPost;

  /// Tid whose first page was asked for to learn who started the thread, see [_threadAuthorOf].
  String? _resolvedTid;

  /// The first page of [_resolvedTid] could not be fetched or did not name who started the thread.
  bool _authorLookupFailed = false;

  /// Bumped on every lookup, retry and dispose so that an answer arriving late is dropped.
  int _authorLookup = 0;

  /// The first page of [_resolvedTid] was read and has floors, but its first floor names no user (an anonymous or
  /// guest post has no user link and is not parsed): nobody on the block list can be the author, the thread is shown.
  bool _authorUnattributable = false;

  /// Author of [_resolvedTid] learnt from its first page, kept in case [ThreadAuthorCache] drops it later.
  int? _resolvedAuthor;

  /// Thread already shown on screen, set when [_blockedThreadBody] let it through. When somebody gets blocked while
  /// it is read, it stays on screen while its author is looked up (hiding it now would not unshow it, only lose the
  /// reading position) and is replaced only once the author is known to be blocked.
  String? _shownTid;

  /// Account whose block list let [_shownTid] through: the list of another account starts over.
  int? _shownOwner;

  /// Saves the pages loaded here while the setting is on, and reads them back without network.
  final OfflineThreadRepository _offline = appOfflineThreads;

  /// The bloc of this page, created by the provider in [build]; kept to reload the page for another account.
  ThreadBloc? _threadBloc;

  /// The page number being read, created by the provider in [build]; the reload for another account stays on it.
  JumpPageCubit? _jumpPageCubit;

  /// Follows the account in use, see [_reloadForAccount].
  StreamSubscription<AuthStatus>? _accountSub;

  /// Whether this page is the one on top, no other page or dialog above it (see [_RouteOnTopListener]).
  bool _onTop = true;

  /// The account changed while another page or a dialog covered this one: reload once it shows again.
  bool _reloadWhenShown = false;

  /// Reload the thread once the account in use changed, for example through the quick switch of the avatar menu
  /// (GitHub #184 follow-up).
  ///
  /// The page holds what the forum rendered for the account that loaded it: the reply parameters (formhash) and the
  /// actions on one's own floors. A reply sent after a switch went out with the new account's cookie and the old
  /// account's formhash, and the forum refused it. An unsent reply stays in the reply bar through the reload
  /// ([ReplyBarController]).
  ///
  /// Only the page on top reloads at once; a thread page under another page (or under the menu the switch came from)
  /// reloads when it shows again. Reloading every open thread page sent one request each, and each recorded a visit
  /// of the new account to a thread it had not opened. The reload stays on the page being read rather than the first
  /// one. A page asking to log in reloads as well: the new account may see the thread. A load still pending for the
  /// previous account (opening, refresh, jump, load more) is superseded by the reload and dropped (see [ThreadBloc]).
  void _reloadForAccount() {
    // The side chosen for a debate reply was the previous account's choice.
    _replyBarController.debateStand = null;
    final bloc = _threadBloc;
    if (!mounted || bloc == null || bloc.isClosed) {
      return;
    }
    if (!_onTop) {
      _reloadWhenShown = true;
      return;
    }
    _reloadWhenShown = false;
    final page = _jumpPageCubit?.state.currentPage ?? 1;
    if (_landOnLastPost && bloc.state.tid != null) {
      // Still opening on the last floor (the forum's message was on screen): the last page for the new account.
      bloc.add(const ThreadJumpPageRequested(lastPageAsked, pageFallback: 1));
    } else if (page > 1 && bloc.state.tid != null) {
      bloc.add(ThreadJumpPageRequested(page));
    } else {
      bloc.add(ThreadRefreshRequested());
    }
  }

  void _onTopChanged({required bool onTop}) {
    _onTop = onTop;
    if (onTop && _reloadWhenShown) {
      _reloadForAccount();
    }
  }

  bool _isUnattributable(ThreadState state) {
    final tid = state.tid ?? widget.threadID;
    return tid != null && tid == _resolvedTid && _authorUnattributable;
  }

  void _forgetAuthorLookup() {
    _authorLookup++;
    _resolvedTid = null;
    _authorLookupFailed = false;
    _authorUnattributable = false;
    _resolvedAuthor = null;
  }

  /// Uid of the user who started the thread shown in [state], null when not known.
  ///
  /// Taken from the first floor when it is on the page (not when only one user's floors are listed: the floor
  /// numbers are then not the thread's), else from what lists and earlier pages recorded (see [ThreadAuthorCache]).
  int? _threadAuthorOf(ThreadState state) {
    final tid = state.tid ?? widget.threadID;
    if (state.onlyVisibleUid == null) {
      final first = state.postList.firstWhereOrNull((e) => e.postFloor == 1);
      if (first != null) {
        ThreadAuthorCache.record(tid, first.author.uid);
      }
    }
    return ThreadAuthorCache.authorOf(tid) ?? (tid != null && tid == _resolvedTid ? _resolvedAuthor : null);
  }

  /// Fetch the first page of thread [tid] once to learn who started it.
  ///
  /// Only needed when the thread was opened on a later page, the current account blocks somebody and the page does
  /// not name the thread's author (a web page, an older plugin, an anonymous thread; the forum's app API names it with
  /// every page, `thread.authorid`).
  void _resolveThreadAuthor(BuildContext context, String tid) {
    if (_resolvedTid == tid) {
      return;
    }
    _forgetAuthorLookup();
    _resolvedTid = tid;
    final lookup = _authorLookup;
    unawaited(() async {
      int? author;
      var unattributable = false;
      try {
        // A separate repository: the page's own one remembers the url of the page shown. Oldest first, so the first
        // floor is on the first page whatever the thread's own order is.
        final result = await ThreadRepository(offline: _offline).fetchThreadFirstPage(tid: tid).run();
        result.match((e) => error('failed to learn the author of thread $tid: $e'), (v) {
          final page = v.page;
          final first = page.postList.firstWhereOrNull((e) => e.postFloor == 1);
          ThreadAuthorCache.record(tid, first?.author.uid);
          author = ThreadAuthorCache.authorOf(tid);
          unattributable = author == null && page.havePermission && !page.needLogin && v.firstFloorNamesNoUser;
          if (author == null && !unattributable) {
            error('first page of thread $tid does not name its author');
          }
        });
      } on Object catch (e, st) {
        handleRaw(e, st);
      }
      // Dropped when the page is gone, retried or now shows another thread.
      if (!mounted || lookup != _authorLookup || _resolvedTid != tid) {
        return;
      }
      setState(() {
        _resolvedAuthor = author;
        _authorUnattributable = unattributable;
        _authorLookupFailed = author == null && !unattributable;
      });
      // The visit was not recorded while the author was unknown.
      if (context.mounted) {
        _recordVisitHistory(context, context.read<ThreadBloc>().state);
      }
    }());
  }

  /// Ask the first page again after a failed lookup.
  void _retryThreadAuthor() {
    setState(_forgetAuthorLookup);
  }

  /// What the local block list does to the thread in [state]: null to show it, or the app bar title and the body
  /// shown instead of the whole thread (title, floors and reply bar).
  ({String title, Widget body})? _blockedThreadBody(BuildContext context, ThreadState state) {
    final owner = currentBlockList(context).ownerUid;
    if (owner != _shownOwner) {
      // Shown under the list of another account (switched, logged out): that account's own rules apply again.
      _shownTid = null;
    }
    final held = _holdBack(context, state);
    if (held == null && state.status == ThreadStatus.success) {
      _shownTid = state.tid ?? widget.threadID;
      _shownOwner = owner;
    }
    return held;
  }

  ({String title, Widget body})? _holdBack(BuildContext context, ThreadState state) {
    final list = currentBlockList(context);
    if (list.uids.isEmpty && list.isKnown) {
      return null;
    }
    // A page the forum refused (login, no permission, deleted thread) or without any floor shows nothing of anybody:
    // its login page, reason or retry stay as they are.
    if (state.status == ThreadStatus.success && (state.needLogin || !state.havePermission || state.postList.isEmpty)) {
      return null;
    }
    final authorUid = _threadAuthorOf(state);
    final username = state.postList.firstWhereOrNull((e) => e.postFloor == 1)?.author.name ?? 'UID ${authorUid ?? ''}';
    // Not known to be blocked: a neutral title, never the thread's own one.
    final neutral = context.t.threadPage.title;
    if (!list.isKnown) {
      // The list of the current account is not read yet (or failed): hold the thread back, do not show it early.
      return (
        title: neutral,
        body: BlockedThreadNotice(
          uid: authorUid ?? 0,
          username: username,
          pending: true,
          failed: list.status == UserBlockListStatus.failed,
        ),
      );
    }
    if (authorUid != null) {
      if (!list.hides(authorUid)) {
        return null;
      }
      return (
        title: context.t.userBlock.threadHiddenTitle,
        body: BlockedThreadNotice(uid: authorUid, username: username),
      );
    }
    // Somebody is blocked and the author is not known yet (a later page, a `findpost` link, still loading): hold the
    // whole thread back until the first floor tells who started it.
    final tid = state.tid ?? widget.threadID;
    if (tid != _resolvedTid) {
      // Another thread than the one looked up (a `findpost` link learnt its tid): forget the old lookup.
      _forgetAuthorLookup();
    }
    if (tid != null && tid == _resolvedTid && _authorUnattributable) {
      return null;
    }
    if (tid != null && tid == _shownTid) {
      // Already on screen: keep it there while the author is looked up, when the lookup fails, and while the page
      // reloads or fails to load more (it keeps its floors and says so itself).
      if (state.status == ThreadStatus.success) {
        _resolveThreadAuthor(context, tid);
      }
      return null;
    }
    switch (state.status) {
      case ThreadStatus.initial || ThreadStatus.loading:
        return (title: neutral, body: const CenteredCircularIndicator());
      case ThreadStatus.failure:
        // The page itself failed: its retry, without the title given by the caller.
        return (
          title: neutral,
          body: _AuthorLookupFailure(
            onRetry: () => context.read<ThreadBloc>().add(_retryLoad(state)),
          ),
        );
      case ThreadStatus.success:
        if (tid == null) {
          return (
            title: neutral,
            body: _AuthorLookupFailure(onRetry: () => context.read<ThreadBloc>().add(ThreadRefreshRequested())),
          );
        }
        _resolveThreadAuthor(context, tid);
        if (_authorLookupFailed) {
          return (title: neutral, body: _AuthorLookupFailure(onRetry: _retryThreadAuthor));
        }
        return (title: neutral, body: const CenteredCircularIndicator());
    }
  }

  /// Record the visit of the thread in [state] and mark it replied when the user has a floor on the page.
  void _recordVisitHistory(BuildContext context, ThreadState state) {
    // Floors read back from an offline copy are no visit of the forum: the history and the replied marks stay.
    if (state.status != ThreadStatus.success || state.isOffline) {
      return;
    }
    // Record thread visit history.
    final currentUser = context.read<AuthenticationRepository>().currentUser;
    if (currentUser == null) {
      // Do nothing if not logged in.
      return;
    }
    final uid = currentUser.uid;
    final username = currentUser.username;
    if (uid == null || username == null) {
      unreachable(
        'intend to record thread visit history but '
        'user info is incomplete: uid=$uid, username=$username',
      );
      return;
    }
    // A floor of the current user on this page: mark the thread as replied (issue #21).
    unawaited(
      seedRepliedThreadFromPosts(
        storageProvider: getIt.get<StorageProvider>(),
        uid: uid,
        tid: state.tid,
        fid: state.fid,
        posts: state.postList,
      ),
    );
    if (state.tid == null || state.title == null || state.fid == null || state.forumName == null) {
      info('not prepared to save visit history yet');
      return;
    }
    if (!_mayKeepVisit(context, state)) {
      return;
    }
    debug('save thread visit history tid=${state.tid}');
    context.read<ThreadVisitHistoryBloc>().add(
      ThreadVisitHistoryUpdateRequested(
        ThreadVisitHistoryModel(
          uid: uid,
          threadId: int.parse(state.tid!),
          forumId: state.fid!,
          username: username,
          threadTitle: state.title!,
          forumName: state.forumName!,
          visitTime: DateTime.now(),
        ),
      ),
    );
  }

  /// Whether the visit of the thread in [state] may be kept: the history (and the reading progress kept with it) would
  /// list the title of a thread the user blocked the author of, or might have.
  bool _mayKeepVisit(BuildContext context, ThreadState state) {
    final blockList = currentBlockList(context, listen: false);
    final author = _threadAuthorOf(state);
    return blockList.isKnown &&
        !(blockList.uids.isNotEmpty && author == null && !_isUnattributable(state)) &&
        !blockList.hides(author);
  }

  /// Where the reading of this thread stopped, when the page opens it from a list (no page, floor or author asked) for
  /// an account that read it past its first screen.
  ReadingProgress? _savedProgress() {
    final tid = _opensFromList();
    final cubit = _progressCubit;
    final uid = context.read<AuthenticationRepository>().currentUser?.uid;
    if (tid == null || cubit == null || uid == null || cubit.state.uid != uid) {
      return null;
    }
    final progress = cubit.state.of(tid);
    return progress != null && progress.pastFirstScreen && progress.floor != null ? progress : null;
  }

  /// The thread id when the page opens the thread from a list (no page, floor or author asked), else null.
  int? _opensFromList() {
    final tid = int.tryParse(widget.threadID ?? '');
    if (tid == null ||
        widget.findPostID != null ||
        widget.lastPost ||
        widget.onlyVisibleUid != null ||
        (int.tryParse(widget.pageNumber) ?? 1) != 1) {
      return null;
    }
    return tid;
  }

  /// Whether where the reading stopped is not read yet for the account in use (a page opened from a link as the app
  /// starts): nothing is offered or kept before it is.
  bool _progressLoading() {
    final cubit = _progressCubit;
    final uid = context.read<AuthenticationRepository>().currentUser?.uid;
    return cubit != null && uid != null && !(cubit.state.uid == uid && cubit.state.loaded);
  }

  /// Go with where the reading stopped ([progress]) as the setting says, as the page opens ([atOpen]) or once read.
  void _takeSavedProgress(ReadingProgress progress, {required bool atOpen}) {
    switch (getIt.get<SettingsRepository>().currentSettings.openPosition) {
      case ThreadOpenPosition.fromStart:
        _heldPosition = progress;
      case ThreadOpenPosition.ask:
        _resumeOffer = progress;
        _heldPosition = progress;
      case ThreadOpenPosition.resume:
        if (atOpen) {
          _resumeAt = progress;
        } else {
          _threadBloc?.add(
            ThreadJumpToFloorRequested(progress.floor ?? 1, pid: progress.pid?.toString(), page: progress.page),
          );
        }
    }
  }

  /// The first load of the page: the last page for the last floor, where the reading stopped when going on with it
  /// right away, else the page asked for.
  ThreadEvent _initialEvent() {
    if (widget.lastPost) {
      // A web page without a pager is the only page of the thread.
      return const ThreadLoadMoreRequested(lastPageAsked, pageFallback: 1);
    }
    if (_resumeAt case final progress?) {
      return ThreadJumpToFloorRequested(progress.floor ?? 1, pid: progress.pid?.toString(), page: progress.page);
    }
    return ThreadLoadMoreRequested(int.tryParse(widget.pageNumber) ?? 1);
  }

  /// The list told the floor at its top ([post]): the page goes on from there next time, see [ReadingProgress].
  ///
  /// Kept once the list stays still for a second, and when the page is left. Only for an account, for every author's
  /// floors (one author's floors are not where the thread is), floors from the forum (not an offline copy), and a
  /// thread whose visit is kept ([_mayKeepVisit]).
  void _onTopFloorChanged(Post post, {required bool atThreadTop}) {
    _topPid = post.postID;
    final offer = _resumeOffer;
    if (offer != null && (!atThreadTop || (post.shownFloor ?? 0) >= (offer.floor ?? 0))) {
      // Read on from the start, or got there: nothing to offer any more.
      setState(() => _resumeOffer = null);
    }
    final bloc = _threadBloc;
    final uid = context.read<AuthenticationRepository>().currentUser?.uid;
    if (bloc == null || bloc.isClosed || uid == null) {
      return;
    }
    final state = bloc.state;
    final tid = int.tryParse(state.tid ?? '');
    if (tid == null ||
        _progressLoading() ||
        state.status != ThreadStatus.success ||
        state.isOffline ||
        state.onlyVisibleUid != null ||
        !_mayKeepVisit(context, state)) {
      return;
    }
    // The replies as the thread counts them (a rush thread's deleted floors are not replies), as the lists do.
    final seenReplies = state.replyCount ?? state.paginationReplies;
    final ReadingProgress progress;
    if (_heldPosition case final held?) {
      // Not scrolled yet: where the reading stopped stays, the replies seen are the thread's now.
      progress = ReadingProgress(page: held.page, pid: held.pid, floor: held.floor, seenReplies: seenReplies);
    } else if (atThreadTop) {
      progress = ReadingProgress(page: 1, floor: 1, seenReplies: seenReplies);
    } else {
      // A hot reply is a copy of a later floor shown on the first page: the floor read on to is the closest one
      // around it in the thread's order.
      final read = readFloorAround(state.postList, post);
      final floor = read.shownFloor;
      final ppp = state.postsPerPage;
      progress = ReadingProgress(
        // The page oldest floor first, whatever the order shown.
        page: !state.shownNewestFirst ? read.page : (floor != null && ppp != null ? (floor - 1) ~/ ppp + 1 : null),
        pid: int.tryParse(read.postID),
        floor: floor,
        seenReplies: seenReplies,
      );
    }
    final pending = (uid: uid, tid: tid, progress: progress);
    if (_pendingProgress == pending || (_pendingProgress == null && _keptProgress == pending)) {
      return;
    }
    _pendingProgress = pending;
    _progressTimer?.cancel();
    _progressTimer = Timer(const Duration(seconds: 1), _keepProgress);
  }

  /// Keep the reading progress told last ([_onTopFloorChanged]).
  void _keepProgress() {
    _progressTimer?.cancel();
    _progressTimer = null;
    final pending = _pendingProgress;
    _pendingProgress = null;
    if (pending == null || pending == _keptProgress) {
      return;
    }
    _keptProgress = pending;
    unawaited(_progressCubit?.save(uid: pending.uid, tid: pending.tid, progress: pending.progress));
  }

  /// Scrolling of the list: the app bar follows it, and a scroll of the user's own lets the reading position go
  /// ([_heldPosition]).
  ///
  /// What the bar does with the scroll, the first that holds: searching, the search bar stays shown
  /// ([AppBarCollapser.enabled] is false then, set in the build); immersive reading, the bars stay hidden
  /// ([AppBarCollapser.held]); else the bar follows the list. The two never hold at once: opening the search ends
  /// immersive reading ([_openSearch]) and refuses it while it lasts ([_setImmersive]).
  bool _onScrollNotification(ScrollNotification notification) {
    if (notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle &&
        notification.metrics.axis == Axis.vertical) {
      _heldPosition = null;
      _userScrolled = true;
    }
    return _appBarCollapser.onNotification(notification);
  }

  /// Hide the bars for immersive reading ([hidden]), or show them again. Never hidden while searching: the search bar
  /// is the app bar then and stays shown (see [_onScrollNotification] for the order of the two).
  void _setImmersive({required bool hidden}) {
    if (hidden == _immersive || !mounted || (hidden && _searching)) {
      return;
    }
    setState(() => _immersive = hidden);
    if (hidden) {
      _appBarCollapser.hold();
      unawaited(_bottomBarController.reverse());
    } else {
      _appBarCollapser.release();
      unawaited(_bottomBarController.forward());
    }
  }

  /// A tap on the floors nothing in them took: the bars go, or come back. Not while searching (the search bar stays),
  /// nor while a reply is being written: the tap leaves the editor.
  void _toggleImmersive() {
    if (_searching) {
      return;
    }
    final editing =
        _replyBarController.showingEditor ||
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() != null;
    if (editing && !_immersive) {
      return;
    }
    _setImmersive(hidden: !_immersive);
  }

  /// A swipe across the floors (the `threadSwipePaging` setting): the page after the one in view, or the one before;
  /// nothing past the first or the last page, or while a page loads.
  void _swipePage(ThreadSwipe swipe) {
    final bloc = _threadBloc;
    final pages = _jumpPageCubit;
    if (!mounted || bloc == null || bloc.isClosed || pages == null) {
      return;
    }
    final state = bloc.state;
    if (state.status != ThreadStatus.success || !pages.state.canJumpPage) {
      return;
    }
    final page = pages.state.currentPage + (swipe == ThreadSwipe.next ? 1 : -1);
    if (page < 1 || page > state.totalPages) {
      return;
    }
    _heldPosition = null;
    pages.markLoading();
    bloc.add(ThreadJumpPageRequested(page));
  }

  /// Whether the body shows the floors of [state] (or is about to): else nothing could bring the hidden bars back.
  static bool _showsFloors(ThreadState state) =>
      !state.needLogin &&
      state.havePermission &&
      (state.status == ThreadStatus.initial || state.status == ThreadStatus.loading || state.postList.isNotEmpty);

  /// Search the floors on screen: the app bar turns into the search bar. Immersive reading ends first: the bars come
  /// back and stay while searching (a tap on the floors hides nothing then, [_toggleImmersive]).
  void _openSearch() {
    _setImmersive(hidden: false);
    setState(() => _searching = true);
    _appBarCollapser.show();
  }

  /// Back to the app bar, nothing marked any more. The bars stay shown: immersive reading, ended when the search
  /// opened, is not taken up again.
  void _closeSearch() {
    _searchController.clear();
    _searchDebounce?.cancel();
    _searchTyped = null;
    _searchedPages.clear();
    setState(() {
      _searching = false;
      _searchPattern = null;
      _searchCurrentPid = null;
      _searchFound = null;
    });
  }

  /// Back closes the search first, the page stays: only while it is the page on top (not under a dialog or a page
  /// opened from it).
  Future<bool> _onBackPressed() async {
    if (!_searching || !mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return false;
    }
    _closeSearch();
    return true;
  }

  /// Whether the input method is still composing the words in [value] (a pinyin or a kana not chosen yet).
  static bool _composing(TextEditingValue value) => value.composing.isValid && !value.composing.isCollapsed;

  /// The search field changed: the words are searched for once they settled for a moment ([_searchDelay]), not
  /// while the input method composes them.
  void _onSearchEdited() {
    final value = _searchController.value;
    if (_composing(value)) {
      _searchDebounce?.cancel();
      _searchTyped = null;
      return;
    }
    if (value.text == _searchTyped) {
      // Only the cursor moved.
      return;
    }
    final text = _searchTyped = value.text;
    _searchDebounce?.cancel();
    _searchDebounce = Timer(_searchDelay, () => _applySearch(text));
  }

  /// Search for [text] from now on, and bring its first hit from the floor at the top of the list on into view.
  void _applySearch(String text) {
    _searchDebounce?.cancel();
    final bloc = _threadBloc;
    final pattern = threadSearchPattern(text);
    // The same words in another case find the same hits: the search goes on from the current hit.
    if (!mounted || !_searching || bloc == null || _sameSearch(pattern, _searchPattern)) {
      return;
    }
    _searchedPages.clear();
    setState(() {
      _searchPattern = pattern;
      _searchCurrentPid = null;
    });
    final hits = _searchHits(context, bloc.state, listen: false);
    if (hits.isEmpty) {
      return;
    }
    _revealHit(_hitFromTop(hits, bloc.state.postList));
  }

  /// Whether [a] and [b] search for the same words: the words in any case ([threadSearchPattern]).
  static bool _sameSearch(RegExp? a, RegExp? b) => a?.pattern.toLowerCase() == b?.pattern.toLowerCase();

  /// The search field was submitted: the words typed at once, else the next hit; nothing while they are composed.
  void _onSearchSubmitted(String text) {
    if (_composing(_searchController.value)) {
      return;
    }
    if (_searchDebounce?.isActive ?? false) {
      _applySearch(text);
      return;
    }
    _stepHit(1);
  }

  /// The floors of [state] the search finds, in the order they are shown, the floors of blocked users and the quotes
  /// of their floors left out as on screen ([BlockAwarePost]); none while nothing is searched.
  ///
  /// The current hit ([_searchCurrentPid]) is kept among them ([_currentHitAmong]): the hits found are kept
  /// ([_searchFound]), and a build reads them once, at its start, for the search bar and the floors alike.
  List<Post> _searchHits(BuildContext context, ThreadState state, {bool listen = true}) {
    final pattern = _searchPattern;
    if (!_searching || pattern == null) {
      return const [];
    }
    final blocks = currentBlockList(context, listen: listen);
    final found = _searchFound;
    if (found != null &&
        identical(found.state.postList, state.postList) &&
        found.pattern == pattern &&
        identical(found.blocks, blocks)) {
      return found.hits;
    }
    final posts = state.postList;
    final String Function(Post post)? shownData;
    if (blocks.uids.isEmpty) {
      shownData = null;
    } else {
      final placeholder = context.t.userBlock.quotePlaceholder;
      final authors = {for (final post in posts) post.postID: post.author.uid};
      shownData = (post) => redactBlockedQuotesOf(
        post,
        blockedUids: blocks.uids,
        authorOfPost: (pid) => int.tryParse(authors['$pid'] ?? ''),
        placeholder: placeholder,
      );
    }
    final hits = threadSearchHits(
      posts,
      pattern,
      hidden: (post) => blocks.hidesString(post.author.uid),
      shownData: shownData,
    );
    if (found != null && !_goesOn(found.state, state)) {
      _searchedPages.clear();
    }
    _searchedPages.addAll([
      for (final post in posts)
        if (!post.hot) post.page,
    ]);
    _searchCurrentPid = _currentHitAmong(hits, found?.pattern == pattern ? found?.hits : null, posts);
    _searchFound = (state: state, pattern: pattern, blocks: blocks, hits: hits);
    return hits;
  }

  /// Whether the floors of [to] go on from the floors of [from]: a page loaded after or before them keeps them as they
  /// are. Another list of floors (one author's floors or every author's again from a floor's menu, another order,
  /// another page jumped to, the thread reloaded) is read anew, and has pages of its own: its page 2 is not the page 2
  /// searched before, which said it was ([_searchedPages]) and let no more page be loaded for the search until the
  /// search was closed and opened again.
  static bool _goesOn(ThreadState from, ThreadState to) {
    if (from.onlyVisibleUid != to.onlyVisibleUid || from.reverseOrder != to.reverseOrder) {
      return false;
    }
    final before = Set<Post>.identity()..addAll(from.postList);
    return to.postList.any(before.contains);
  }

  /// The current hit among [hits]: the same floor while it is one; when it is not any more (its page dropped, its
  /// author blocked), the closest one of the hits before ([previous]) that still is, else the first from the floor at
  /// the top of the list on. Never none while something is found: the count never says "0 / N".
  String? _currentHitAmong(List<Post> hits, List<Post>? previous, List<Post> posts) {
    if (hits.isEmpty) {
      return null;
    }
    final current = _searchCurrentPid;
    final pids = {for (final post in hits) post.postID};
    if (current == null) {
      return _hitFromTop(hits, posts).postID;
    }
    if (pids.contains(current)) {
      return current;
    }
    final at = previous?.indexWhere((e) => e.postID == current) ?? -1;
    if (previous != null && at >= 0) {
      for (var distance = 1; distance < previous.length; distance++) {
        for (final index in [at + distance, at - distance]) {
          if (index >= 0 && index < previous.length && pids.contains(previous[index].postID)) {
            return previous[index].postID;
          }
        }
      }
    }
    return _hitFromTop(hits, posts).postID;
  }

  /// The first of [hits] from the floor at the top of the list on, else the first one.
  Post _hitFromTop(List<Post> hits, List<Post> posts) {
    final top = posts.indexWhere((e) => e.postID == _topPid);
    return hits.firstWhere((hit) => posts.indexWhere((e) => identical(e, hit)) >= top, orElse: () => hits.first);
  }

  /// Bring the hit [step] hits after the current one into view (before it when negative), round the hits.
  void _stepHit(int step) {
    final bloc = _threadBloc;
    if (bloc == null) {
      return;
    }
    final hits = _searchHits(context, bloc.state, listen: false);
    if (hits.isEmpty) {
      return;
    }
    final at = hits.indexWhere((e) => e.postID == _searchCurrentPid);
    _revealHit(hits[at < 0 ? (step > 0 ? 0 : hits.length - 1) : (at + step) % hits.length]);
  }

  void _revealHit(Post post) {
    _heldPosition = null;
    setState(() => _searchCurrentPid = post.postID);
    _postListKey.currentState?.revealPost(post.postID);
  }

  /// Where a page loaded for the search goes: after the floors on screen (true), before them (false), or nowhere
  /// (null). Only a page not looked in yet ([_searchedPages]) is loaded.
  ///
  /// With [threadWindowPages] pages on screen, a page loaded after them drops the first one and a page loaded before
  /// them drops the last one: never the page of the current hit or of the floor at the top of the list (the floors
  /// read), so the other side is taken, or none.
  bool? _searchLoadSide(ThreadState state) {
    final full = state.currentPage - state.firstPage + 1 >= threadWindowPages;
    final kept = <int>{
      if (full)
        for (final post in state.postList)
          if (post.postID == _searchCurrentPid || post.postID == _topPid) post.page,
    };
    if (state.canLoadMore && !_searchedPages.contains(state.currentPage + 1) && !kept.contains(state.firstPage)) {
      return true;
    }
    if (state.canLoadPrevious && !_searchedPages.contains(state.firstPage - 1) && !kept.contains(state.currentPage)) {
      return false;
    }
    return null;
  }

  /// Load a page for the search to look in too, where [_searchLoadSide] says.
  void _loadMoreForSearch(ThreadState state) {
    final bloc = _threadBloc;
    if (bloc == null || bloc.isClosed) {
      return;
    }
    switch (_searchLoadSide(state)) {
      case true:
        bloc.add(ThreadLoadMoreRequested(state.currentPage + 1));
      case false:
        bloc.add(const ThreadLoadPreviousRequested());
      case null:
        break;
    }
  }

  /// The app bar while searching: the words and where the current hit is among the hits, the pages not searched yet
  /// once the hits on screen are gone through; as tall as the app bar it stands for, the forum path under it kept
  /// ([bottom]).
  PreferredSizeWidget _buildSearchBar(
    BuildContext context,
    ThreadState state,
    PreferredSizeWidget bottom,
    List<Post> hits,
  ) {
    final tr = context.t.threadPage.search;
    final at = hits.indexWhere((e) => e.postID == _searchCurrentPid);
    final side = _searchLoadSide(state);
    // Offered at the end of the hits the way the page would be added (after them, or before them).
    final atEdge = hits.isEmpty || (side == false ? at == 0 : at == hits.length - 1);
    final loading = switch (side) {
      false => state.previousStatus == ThreadEdgeStatus.loading,
      _ => state.nextStatus == ThreadEdgeStatus.loading,
    };
    return AppBar(
      automaticallyImplyLeading: false,
      title: TextField(
        key: const ValueKey('thread-search-field'),
        controller: _searchController,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: tr.hint,
          border: InputBorder.none,
          suffix: _searchPattern == null
              ? null
              : Text(
                  tr.count(n: at + 1, total: hits.length),
                  key: const ValueKey('thread-search-count'),
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
        ),
        // Enter goes to the next hit, the field keeps the focus (and the keyboard stays up).
        onEditingComplete: () {},
        onSubmitted: _onSearchSubmitted,
      ),
      actions: [
        if (_searchPattern != null && atEdge && (state.canLoadMore || state.canLoadPrevious))
          loading
              ? const SizedBox.square(
                  dimension: 48,
                  child: Center(
                    child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  ),
                )
              : IconButton(
                  key: const ValueKey('thread-search-load-more'),
                  tooltip: tr.loadMore,
                  icon: const Icon(Icons.playlist_add),
                  onPressed: side == null ? null : () => _loadMoreForSearch(state),
                ),
        IconButton(
          key: const ValueKey('thread-search-previous'),
          tooltip: tr.previous,
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: hits.isEmpty ? null : () => _stepHit(-1),
        ),
        IconButton(
          key: const ValueKey('thread-search-next'),
          tooltip: tr.next,
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: hits.isEmpty ? null : () => _stepHit(1),
        ),
        IconButton(
          key: const ValueKey('thread-search-close'),
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          icon: const Icon(Icons.close),
          onPressed: _closeSearch,
        ),
      ],
      bottom: bottom,
    );
  }

  /// [card] of [post], marked as a hit of the search when it is one: a line at its side, the words in its content.
  /// [hits] holds the floor keys ([floorKeyOf]) of the hits: the copy of a floor as a hot reply is not marked with
  /// the floor (it is not a hit of its own).
  ///
  /// The card is always under the same widgets, a hit or not: it keeps its state when a search starts or ends. The
  /// words are marked the same in every hit, only the line tells the current one: going from hit to hit changes
  /// nothing the content was munched from, so no floor is munched again (the marks are part of the munched content).
  Widget _markSearchHit(BuildContext context, Post post, Set<String> hits, Widget card) {
    final hit = _searchPattern != null && hits.contains(floorKeyOf(post));
    final colorScheme = Theme.of(context).colorScheme;
    final current = hit && post.postID == _searchCurrentPid;
    return SearchHighlightScope(
      pattern: hit ? _searchPattern : null,
      background: colorScheme.primaryContainer,
      foreground: colorScheme.onPrimaryContainer,
      child: Stack(
        // The card is laid out as without the mark.
        fit: StackFit.passthrough,
        children: [
          card,
          if (hit)
            Positioned(
              key: ValueKey('thread-search-hit-${post.postID}'),
              left: 0,
              top: 12,
              bottom: 12,
              width: current ? 4 : 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: current ? colorScheme.primary : colorScheme.primary.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Ask for a floor to go to, and go there.
  Future<void> _askJumpToFloor(BuildContext context, ThreadState state) async {
    final floors = _floorCountOf(state);
    final floor = await showDialog<int>(
      context: context,
      builder: (_) => RootPage(DialogPaths.jumpToFloor, _JumpToFloorDialog(max: floors)),
    );
    if (floor == null || !context.mounted) {
      return;
    }
    _heldPosition = null;
    context.read<ThreadBloc>().add(ThreadJumpToFloorRequested(floor));
  }

  /// Go on reading where it stopped last time ([_resumeOffer]).
  void _resume() {
    final offer = _resumeOffer;
    _heldPosition = null;
    setState(() => _resumeOffer = null);
    if (offer == null) {
      return;
    }
    _threadBloc?.add(ThreadJumpToFloorRequested(offer.floor ?? 1, pid: offer.pid?.toString(), page: offer.page));
  }

  /// Floors of the thread: its highest floor, or the replies plus the first floor; null when filtered by author (the
  /// count is that author's) or not known.
  int? _floorCountOf(ThreadState state) {
    if (state.onlyVisibleUid != null) {
      return null;
    }
    final highest = state.postList.map((e) => e.postFloor ?? 0).fold(0, math.max);
    final replies = state.paginationReplies ?? state.replyCount;
    final count = math.max(highest, replies == null ? 0 : replies + 1);
    return count > 0 ? count : null;
  }

  /// Open the reply bar for a reply to the thread (the end card's "reply").
  void _replyToThread() {
    if (_threadBloc?.state.isOffline ?? true) {
      return;
    }
    _setImmersive(hidden: false);
    _replyBarController
      ..replyAction = null
      ..setHintText(context.t.threadPage.sendReplyHint)
      ..requestFocus();
  }

  /// Height of the breadcrumb row under the app bar for the extra height of large text.
  static double _breadcrumbsHeight(double extraHeight) => 26 + extraHeight;

  /// Forum path (links separated by chevrons) followed by small pills: thread type, thread id (copy dialog),
  /// statistics, draft and the local replied mark. Scrolls horizontally and starts scrolled to the end, where the
  /// thread's own information is.
  Widget _buildBreadcrumbsRow(ThreadState state, double extraHeight, {required bool replied}) {
    final colorScheme = Theme.of(context).colorScheme;
    final infoTextStyle = Theme.of(context).textTheme.labelLarge?.copyWith(color: colorScheme.outline);
    final infoTextHighlightStyle = Theme.of(context).textTheme.labelLarge?.copyWith(color: colorScheme.primary);

    Widget pill(String label, {IconData? icon, Color? color, VoidCallback? onTap}) {
      final foreground = color ?? colorScheme.onSurfaceVariant;
      final content = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[Icon(icon, size: 14, color: foreground), sizedBoxW4H4],
            Text(label, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: foreground)),
          ],
        ),
      );
      return Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Material(
          color: colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(appInnerRadius),
          clipBehavior: Clip.antiAlias,
          child: onTap == null
              ? Center(child: content)
              : InkWell(
                  onTap: onTap,
                  child: Center(child: content),
                ),
        ),
      );
    }

    final breadFrags = <Widget>[
      for (final (index, e) in state.breadcrumbs.indexed) ...[
        if (index > 0) Icon(Icons.chevron_right, size: 16, color: colorScheme.outline),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () async {
              final gid = e.link.tryGetQueryParameters()?['gid'];
              if (gid != null) {
                await context.pushNamed(
                  ScreenPaths.forumGroup,
                  pathParameters: {'gid': gid},
                  queryParameters: {'title': e.description},
                );
                return;
              }
              await context.dispatchAsUrl(e.link.toString());
            },
            child: Center(child: Text(e.description, style: infoTextHighlightStyle)),
          ),
        ),
      ],
      if (state.breadcrumbs.isNotEmpty) sizedBoxW4H4,
    ];

    return Padding(
      padding: edgeInsetsL12R12.add(edgeInsetsB4),
      child: DefaultTextStyle.merge(
        style: infoTextStyle,
        child: SizedBox(
          height: _breadcrumbsHeight(extraHeight) - 4,
          child: ListView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            children: <Widget>[
              ...breadFrags,
              if (state.threadType?.typeID != null && state.fid != null)
                pill(
                  state.threadType!.name,
                  icon: Icons.label_outline,
                  color: colorScheme.primary,
                  onTap: () async => context.pushNamed(
                    ScreenPaths.forum,
                    pathParameters: {'fid': '${state.fid}'},
                    queryParameters: {
                      'threadTypeName': state.threadType?.name,
                      'threadTypeID': '${state.threadType?.typeID}',
                    },
                  ),
                ),
              pill(
                '${context.t.threadPage.title} ${state.tid ?? ""}',
                icon: Icons.tag,
                color: colorScheme.primary,
                onTap: () async {
                  final id = state.tid ?? widget.threadID;
                  final title = state.title ?? widget.title;
                  await showCopyThreadInfoDialog(context: context, tid: id, title: title);
                },
              ),
              if (state.viewCount != null || state.replyCount != null)
                pill(
                  context.t.threadPage.statistics(view: state.viewCount ?? 0, reply: state.replyCount ?? 0),
                  icon: Icons.bar_chart_outlined,
                ),
              if (state.isDraft) pill(context.t.threadPage.draft, icon: Icons.edit_note_outlined),
              // The current account replied in this thread (local mark, issue #21).
              if (replied)
                pill(context.t.threadPage.repliedMark, icon: Icons.reply_outlined, color: colorScheme.tertiary),
            ].reversed.toList(),
          ),
        ),
      ),
    );
  }

  Future<void> replyPostCallback(User user, int? postFloor, String? replyAction) async {
    // No reply bar on floors read back offline.
    if (replyAction == null || (_threadBloc?.state.isOffline ?? false)) {
      return;
    }
    _setImmersive(hidden: false);

    _replyBarController
      ..replyAction = replyAction
      ..setHintText(
        '${context.t.threadPage.sendReplyHint} ${user.name} '
        '${postFloor == null ? "" : "#$postFloor"}',
      )
      ..requestFocus();
  }

  /// Reply to the thread on side [stand] of the debate (the debate card's "加入正方／反方"): the reply bar with the side
  /// chosen, as the page's "加入" opens the reply window with it.
  void _joinDebate(int stand) {
    _setImmersive(hidden: false);
    _replyBarController
      ..replyAction = null
      ..debateStand = stand
      ..setHintText(context.t.specialThread.debate.joinHint(side: debateSideName(context, stand)))
      ..requestFocus();
  }

  /// The floors of [state], [hits] the hits of the search among them ([_searchHits]).
  Widget _buildContent(BuildContext context, ThreadState state, List<Post> hits) {
    final tr = context.t.threadPage;
    final swipePaging = context.select<SettingsBloc, bool>((bloc) => bloc.state.settingsMap.threadSwipePaging);
    final searchHits = {for (final post in hits) floorKeyOf(post)};
    if (_scrollToPidOnReload != null) {
      // Consumed by the PostList created in this build.
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPidOnReload = null);
    }

    // The posts keep the safe area; the soft close banner and the reply bar paint their background to the screen
    // edges and pad the side insets themselves (feedback 110: a blank strip beside the bar in landscape).
    return Column(
      children: [
        // Floors read back from the offline copies: say so, and when they were saved.
        if (state.offlineSavedAt case final savedAt?)
          SafeArea(
            top: false,
            bottom: false,
            child: Padding(
              padding: edgeInsetsL12T8R12,
              child: AppContentWidth(
                maxWidth: appReadingMaxWidth,
                child: AppNoticeBanner(
                  key: const ValueKey('thread-offline-banner'),
                  tone: AppNoticeTone.warning,
                  icon: Icons.cloud_off_outlined,
                  message: tr.offlineBanner(time: savedAt.yyyyMMDDHHMM()),
                ),
              ),
            ),
          ),
        Expanded(
          // Floors get the extra thread content scale on top of the global text scale (GitHub #137); the app bar,
          // the hints below and the reply bar keep the global scale.
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: _threadContentScaler(context)),
            child: SafeArea(
              // The reply bar below keeps the floors off the bottom inset (the gesture bar of the system); hidden,
              // the floors keep off it themselves.
              bottom: _immersive,
              // One line width for all the floors, measured in the width they have (the safe area left out), taken
              // once the width settles.
              child: PostLineWidth(
                child: MunchCacheScope(
                  cache: _munchCache,
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onScrollNotification,
                    child: Stack(
                      children: [
                        ThreadReadingGestures(
                          onTap: _toggleImmersive,
                          onSwipe: swipePaging ? _swipePage : null,
                          child: PostList(
                            key: _postListKey,
                            threadID: state.tid ?? widget.threadID,
                            title: state.title ?? widget.title,
                            pageNumber: context.read<JumpPageCubit>().state.currentPage,
                            initialPostID: (_scrollToPidOnReload ?? state.scrollTargetPid ?? widget.findPostID)
                                ?.parseToInt(),
                            scrollController: _listScrollController,
                            // Posts of locally blocked users become placeholders in place, the floors keep their
                            // positions.
                            widgetBuilder: (context, post) => BlockAwarePost(
                              post: post,
                              postList: state.postList,
                              builder: (context, post) => _markSearchHit(
                                context,
                                post,
                                searchHits,
                                PostCard(
                                  post,
                                  replyCallback: replyPostCallback,
                                  onEdited: () => _scrollToPidOnReload = post.postID,
                                  onJoinDebate: state.replyParameters == null || state.threadClosed
                                      ? null
                                      : _joinDebate,
                                ),
                              ),
                            ),
                            useDivider: true,
                            postList: state.postList,
                            canLoadMore: state.canLoadMore,
                            latestModAct: state.latestModAct,
                            generation: state.generation,
                            firstPage: state.firstPage,
                            lastPage: state.currentPage,
                            nextStatus: state.nextStatus,
                            previousStatus: state.previousStatus,
                            scrollTargetPid: state.scrollTargetPid,
                            scrollTargetSerial: state.scrollTargetSerial,
                            onTopFloorChanged: _onTopFloorChanged,
                            newestFirst: state.shownNewestFirst,
                            endOfThread: ThreadEndCard(
                              floors: _floorCountOf(state),
                              status: state.nextStatus,
                              newestFirst: state.shownNewestFirst,
                              onReply: state.replyParameters == null || state.threadClosed || state.isOffline
                                  ? null
                                  : _replyToThread,
                              // Newest floors first, the new replies are at the top: pulled down there.
                              onLoadNewReplies: state.shownNewestFirst || state.isOffline
                                  ? null
                                  : () => context.read<ThreadBloc>().add(const ThreadLoadNewRepliesRequested()),
                            ),
                          ),
                        ),
                        // Not for one author's floors: the reading position is the whole thread's.
                        if (_resumeOffer case final offer? when state.onlyVisibleUid == null)
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: 12,
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 560),
                                child: _ResumeBanner(
                                  floor: offer.floor ?? 1,
                                  onResume: _resume,
                                  onClose: () => setState(() => _resumeOffer = null),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Hidden with the app bar for immersive reading; kept built (the reply written stays).
        AnimatedBuilder(
          animation: _bottomBarController,
          builder: (context, child) => ClipRect(
            key: const ValueKey('thread-bottom-bars'),
            child: Align(alignment: Alignment.topCenter, heightFactor: _bottomBarController.value, child: child),
          ),
          child: ExcludeFocus(
            excluding: _immersive,
            child: IgnorePointer(
              ignoring: _immersive,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Replies are still accepted but the thread is about to close: a banner right above the reply box,
                  // in the reading column.
                  if (state.threadSoftClosed && !state.threadClosed && !state.isOffline)
                    ColoredBox(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      child: SafeArea(
                        top: false,
                        bottom: false,
                        child: Padding(
                          padding: edgeInsetsL12T8R12,
                          child: AppContentWidth(
                            maxWidth: appReadingMaxWidth,
                            child: AppNoticeBanner(
                              tone: AppNoticeTone.warning,
                              icon: Icons.lock_clock_outlined,
                              message: tr.softCloseHint,
                            ),
                          ),
                        ),
                      ),
                    ),
                  _buildReplyBar(context, state),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Text scaler of the floors: global text scale times the thread content scale setting, capped at
  /// [threadContentMaxTextScale].
  TextScaler _threadContentScaler(BuildContext context) {
    final threadScale = context.select<SettingsBloc, double>((bloc) => bloc.state.settingsMap.threadContentScale);
    final globalScale = MediaQuery.textScalerOf(context).scale(1);
    return TextScaler.linear(math.min(globalScale * threadScale, threadContentMaxTextScale));
  }

  /// Reload the floors where a reply that may have been stored would be, and land on the newest floor: the first page
  /// of a thread shown newest first, otherwise its last page (asked past it: the reply may have opened a new one) on
  /// its last floor ([_landOnLastPost]). With the floors of one author only, the reply may not be among them: said.
  void _reloadToCheckReply() {
    final threadBloc = _threadBloc;
    if (!mounted || threadBloc == null || threadBloc.isClosed) {
      return;
    }
    final threadState = threadBloc.state;
    if (threadState.onlyVisibleUid != null) {
      showSnackBar(context: context, message: context.t.threadPage.replyCheckFiltered);
    }
    final newestFirst =
        threadState.newestFirst ||
        threadState.exactOrder == 1 ||
        (threadState.exactOrder == null && (threadState.reverseOrder ?? false));
    if (newestFirst) {
      threadBloc.add(ThreadRefreshRequested());
    } else {
      _landOnLastPost = true;
      threadBloc.add(const ThreadJumpPageRequested(lastPageAsked, pageFallback: 1));
    }
  }

  /// Ask the page that failed to load again: the last page while the page still opens on the last floor.
  ThreadLoadMoreRequested _retryLoad(ThreadState state) => _landOnLastPost
      ? const ThreadLoadMoreRequested(lastPageAsked, pageFallback: 1)
      : ThreadLoadMoreRequested(state.currentPage);

  /// Body of the page; everything but the content (which handles the insets per part) stays in the safe area.
  /// The body of the page for [state], [hits] the hits of the search ([_searchHits]).
  Widget _buildBody(BuildContext context, ThreadState state, List<Post> hits) {
    Widget safe(Widget child) => SafeArea(bottom: false, child: child);
    if (state.needLogin) {
      return safe(
        NeedLoginPage(
          backUri: GoRouterState.of(context).uri,
          needPop: true,
          popCallback: (context) {
            // Reloads by itself after its login: the reload kept for when this page shows again would be a second.
            _reloadWhenShown = false;
            // Still opening on the last floor: its page again, not the first one.
            context.read<ThreadBloc>().add(_landOnLastPost ? _retryLoad(state) : ThreadRefreshRequested());
          },
        ),
      );
    } else if (!state.havePermission) {
      if (state.permissionDeniedMessage != null) {
        return safe(ErrorCard(child: munchElement(context, state.permissionDeniedMessage!)));
      } else {
        return safe(AppStateView(icon: Icons.lock_outline, message: context.t.general.noPermission));
      }
    }

    return switch (state.status) {
      ThreadStatus.initial || ThreadStatus.loading => const CenteredCircularIndicator(),
      // A failed reload keeps the previous posts (see ThreadBloc); only an empty page gets the retry button.
      ThreadStatus.failure when state.postList.isNotEmpty => _buildContent(context, state, hits),
      ThreadStatus.failure => safe(
        buildRetryButton(context, () {
          context.read<ThreadBloc>().add(_retryLoad(state));
        }),
      ),
      ThreadStatus.success => _buildContent(context, state, hits),
    };
  }

  Widget _buildReplyBar(BuildContext context, ThreadState state) {
    // Nothing to reply to, or floors read back offline: a reply needs the network (and a fresh form hash).
    if (state.postList.isEmpty || state.isOffline) {
      return const SizedBox.shrink();
    }
    return ReplyBar(
      controller: _replyBarController,
      replyType: ReplyTypes.thread,
      fullScreen: isDesktop,
      disabledEditorFeatures: defaultEditorDisabledFeatures,
      fullScreenDisabledEditorFeatures: defaultFullScreenDisabledEditorFeatures,
    );
  }

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchEdited);
    _progressCubit = context.readOrNull<ReadingProgressCubit>();
    if (_savedProgress() case final progress?) {
      _takeSavedProgress(progress, atOpen: true);
    } else if (_opensFromList() != null && _progressLoading()) {
      // Read in a moment: offered (or gone on with) then, unless the user scrolled already.
      _progressWait = _progressCubit?.stream.listen((_) {
        if (!mounted || _progressLoading()) {
          return;
        }
        unawaited(_progressWait?.cancel());
        _progressWait = null;
        if (_savedProgress() case final progress? when !_userScrolled) {
          setState(() => _takeSavedProgress(progress, atOpen: false));
        }
      });
    }
    // Created here, not lazily: a page that never shows the bar (a blocked thread) still disposes it.
    _appBarController = AnimationController(vsync: this, duration: duration200, value: 1);
    _appBarCollapser = AppBarCollapser(_appBarController);
    _bottomBarController = AnimationController(vsync: this, duration: duration200, value: 1);
    _accountSub = listenAccountChanges(
      context.read<AuthenticationRepository>(),
      // Nothing to clear: the floors stay readable while logging in.
      onLoggingIn: () {},
      onChanged: _reloadForAccount,
    );
  }

  @override
  void dispose() {
    // Where the reading is when leaving the page.
    _keepProgress();
    _munchCache.clear();
    _authorLookup++;
    unawaited(_accountSub?.cancel());
    unawaited(_progressWait?.cancel());
    _listScrollController.dispose();
    _appBarController.dispose();
    _bottomBarController.dispose();
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _RouteOnTopListener(onChanged: _onTopChanged, child: _buildPage(context));

  /// The page, under the [_RouteOnTopListener] of [build].
  Widget _buildPage(BuildContext context) {
    final threadReverseOrder = getIt.get<SettingsRepository>().currentSettings.threadReverseOrder;

    return MultiBlocProvider(
      providers: [
        RepositoryProvider<ThreadRepository>(create: (_) => ThreadRepository(offline: _offline)),
        RepositoryProvider<ReplyRepository>(create: (_) => const ReplyRepository()),
        BlocProvider(
          create: (context) => _threadBloc = ThreadBloc(
            tid: widget.threadID,
            pid: widget.findPostID,
            onlyVisibleUid: widget.onlyVisibleUid,
            threadRepository: context.repo(),
            reverseOrder: widget.overrideReverseOrder ? threadReverseOrder : null,
            exactOrder: widget.overrideWithExactOrder,
          )..add(_initialEvent()),
        ),
        BlocProvider(
          create: (context) => ReplyBloc(
            replyRepository: context.repo(),
            storageProvider: getIt.get<StorageProvider>(),
            authenticationRepository: context.repo(),
          ),
        ),
        BlocProvider(create: (context) => _jumpPageCubit = JumpPageCubit()),
      ],
      child: MultiBlocListener(
        listeners: [
          BlocListener<ThreadBloc, ThreadState>(
            listener: (context, state) {
              if (state.status == ThreadStatus.failure && state.postList.isNotEmpty) {
                // A reload (for example after a reply) failed: the posts stay on screen, only tell the user.
                showSnackBar(context: context, message: context.t.general.failedToLoad);
                // Nor land on the last floor at a later load of other floors (a pull to refresh, a jump): the check
                // after a reply that failed is over.
                _landOnLastPost = false;
              }
              if (state.status == ThreadStatus.loading && state.postList.isEmpty) {
                // A reload starts the floors over from the top: with the bar (not while immersive).
                _appBarCollapser.show();
              }
              if (!_showsFloors(state)) {
                // A message, a login, a retry instead of the floors: with its bars.
                _setImmersive(hidden: false);
              }

              // Update reply parameters to reply bar.
              context.read<ReplyBloc>().add(ReplyParametersUpdated(state.replyParameters));

              // Update thread closed state to reply bar.
              if (state.threadClosed) {
                context.read<ReplyBloc>().add(const ReplyThreadClosed(closed: true));
              } else {
                context.read<ReplyBloc>().add(const ReplyThreadClosed(closed: false));
              }

              if (state.status == ThreadStatus.success) {
                _recordVisitHistory(context, state);
                // Not on a page without floors (a message, no permission): a later load (after logging in) still
                // lands on the last floor.
                if (_landOnLastPost && state.postList.isNotEmpty) {
                  _landOnLastPost = false;
                  if (!state.newestFirst) {
                    // Read by the post list built for this state, see [_scrollToPidOnReload].
                    _scrollToPidOnReload = state.postList.lastOrNull?.postID;
                  } else if (state.currentPage != 1) {
                    // Its author shows the thread newest first: the last floor is at the top of the first page, the
                    // page past the last one holds the oldest floors.
                    context.read<ThreadBloc>().add(const ThreadJumpPageRequested(1));
                  }
                }
              }
            },
          ),
          // A jump to a floor (asked, a hot reply going to its floor) goes from where the reading stopped: the floor
          // jumped to is where it is now, not scrolled to by the user's own hand ([_heldPosition]).
          BlocListener<ThreadBloc, ThreadState>(
            listenWhen: (prev, curr) => prev.scrollTargetSerial != curr.scrollTargetSerial,
            listener: (context, state) => _heldPosition = null,
          ),
          // A jump to a floor the thread does not have went to the closest one.
          BlocListener<ThreadBloc, ThreadState>(
            listenWhen: (prev, curr) =>
                prev.scrollTargetSerial != curr.scrollTargetSerial && curr.jumpFloorMissed != null,
            listener: (context, state) => showSnackBar(
              context: context,
              message: context.t.threadPage.jumpToFloor.missed(floor: state.jumpFloorMissed!),
            ),
          ),
          // The last page asked again for new replies.
          BlocListener<ThreadBloc, ThreadState>(
            listenWhen: (prev, curr) => prev.newRepliesSerial != curr.newRepliesSerial,
            listener: (context, state) => showSnackBar(
              context: context,
              message: state.newRepliesCount > 0
                  ? context.t.threadPage.newRepliesLoaded(count: state.newRepliesCount)
                  : context.t.threadPage.noNewReplies,
            ),
          ),
          BlocListener<ReplyBloc, ReplyState>(
            listenWhen: (prev, curr) => prev.status != curr.status,
            listener: (context, state) {
              if (!mounted) {
                return;
              }
              if (state.status == ReplyStatus.success) {
                showSnackBar(context: context, message: context.t.threadPage.replySuccess);
                // Close the reply bar when sent success. Through the controller, never `context.pop()`: the reload
                // below disposes the reply bar and its own close would then pop this page.
                _replyBarController.closeEditor();
                // Reload and land on the floor just posted. The success hook names the new post and its page;
                // newest-first threads show it at the top of page 1, otherwise load that page (the page count held
                // here is stale when the reply opened a new page) and scroll to the post.
                final threadBloc = context.read<ThreadBloc>();
                final threadState = threadBloc.state;
                _scrollToPidOnReload = state.postedPid.isEmpty ? null : state.postedPid;
                final newestFirst =
                    threadState.exactOrder == 1 ||
                    (threadState.exactOrder == null && (threadState.reverseOrder ?? false));
                final page = state.postedPage > 0 ? state.postedPage : threadState.totalPages;
                if (!newestFirst && page > 1) {
                  threadBloc.add(ThreadJumpPageRequested(page));
                } else {
                  threadBloc.add(ThreadRefreshRequested());
                }
              } else if (state.status == ReplyStatus.failure) {
                final tr = context.t.threadPage;
                showSnackBar(
                  context: context,
                  message: state.maybeSent
                      ? tr.replyMaybeSent
                      : state.networkFailure
                      ? tr.replyFailedNetwork
                      : tr.replyFailed(err: state.failedReason ?? ''),
                  // The editor and the keyboard stay open on failure and this page does not resize for the keyboard
                  // (`resizeToAvoidBottomInset: false`), so lift the hint above it.
                  bottomInset: MediaQuery.viewInsetsOf(context).bottom,
                  // The reply may be on the forum already: look before sending it again.
                  action: state.maybeSent
                      ? SnackBarAction(label: tr.refreshToCheck, onPressed: _reloadToCheckReply)
                      : replyInBrowserAction(context, state.browserUrl),
                );
              }
            },
          ),
        ],
        child: BlocBuilder<ThreadBloc, ThreadState>(
          builder: (context, state) {
            // Update jump page state: the page in view is the list's to tell, from the first page of new floors on.
            final jumpPage = context.read<JumpPageCubit>()..setPageInfo(totalPages: state.totalPages);
            if (state.status == ThreadStatus.success && state.generation != _pageInfoGeneration) {
              _pageInfoGeneration = state.generation;
              jumpPage.setPageInfo(currentPage: state.firstPage);
            }
            // The text scale in effect: the system font size times the app's own scale (appTextScaler).
            final textScaleExtraBreadHeight = math.max<double>(
              0,
              (MediaQuery.textScalerOf(context).scale(14) / 14 - 1) / 0.1,
            );

            // A thread started by a locally blocked user shows nothing of it, not even the title; neither does a
            // thread whose author is still unknown while somebody is blocked.
            final blocked = _blockedThreadBody(context, state);
            if (blocked != null) {
              return Scaffold(
                appBar: AppBar(title: Text(blocked.title)),
                body: SafeArea(child: blocked.body),
              );
            }

            final title = widget.title ?? state.title;
            final replied = isThreadReplied(context, state.tid ?? widget.threadID);
            // Reset jump page state when every build.
            if (state.status == ThreadStatus.loading || state.status == ThreadStatus.initial) {
              context.read<JumpPageCubit>().markLoading();
            } else {
              context.read<JumpPageCubit>().markSuccess();
            }

            var threadUrl = RepositoryProvider.of<ThreadRepository>(context).threadUrl;
            if (widget.threadID != null) {
              threadUrl ??=
                  '$baseUrl/forum.php?mod=viewthread&'
                  'tid=${widget.threadID}&extra=page%3D1';
            } else {
              // Here we don;t have threadID, thus the findPostID is
              // definitely not null.
              threadUrl ??=
                  '$baseUrl/forum.php?mode=redirect&goto=findpost&'
                  'pid=${widget.findPostID}';
            }

            // The search bar stays while searching (the order with immersive reading: [_onScrollNotification]).
            _appBarCollapser.enabled =
                context.select<SettingsBloc, bool>((bloc) => bloc.state.settingsMap.collapseAppBarWhenScroll) &&
                !_searching;
            if (!_appBarCollapser.enabled && !_appBarCollapser.held && _appBarController.value < 1) {
              // Turned off while the bar was hidden: show it again, not from inside this build.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _appBarCollapser.show();
              });
            }
            final breadcrumbs = PreferredSize(
              preferredSize: Size.fromHeight(_breadcrumbsHeight(textScaleExtraBreadHeight)),
              child: _buildBreadcrumbsRow(state, textScaleExtraBreadHeight, replied: replied),
            );
            // The hits of the search, found once for the search bar and the floors.
            final searchHits = _searchHits(context, state);
            // The search bar is as tall as the app bar: the floors do not move when it opens or closes.
            final appBar = _searching
                ? _buildSearchBar(context, state, breadcrumbs, searchHits)
                : ListAppBar(
                    title: title,
                    bottom: breadcrumbs,
                    showReverseOrderAction: true,
                    onJumpPage: (pageNumber) async {
                      if (!mounted) {
                        return;
                      }
                      // Mark loading here.
                      // Mark state will be removed when loading finishes
                      // in next build.
                      context.read<JumpPageCubit>().markLoading();
                      context.read<ThreadBloc>().add(ThreadJumpPageRequested(pageNumber));
                    },
                    onRefresh: () => context.read<ThreadBloc>().add(ThreadRefreshRequested()),
                    onCopyUrl: () async => copyToClipboard(context, threadUrl!),
                    onOpenInBrowser: () async => context.dispatchAsUrl(threadUrl!, external: true),
                    onBackToTop: () async {
                      _appBarCollapser.show();
                      final bloc = context.read<ThreadBloc>();
                      // Pages above the floors on screen are not loaded (or were dropped): open the thread at its start.
                      if (bloc.state.canLoadPrevious || !(_postListKey.currentState?.startsAtThreadTop ?? true)) {
                        bloc.add(const ThreadJumpPageRequested(1));
                        return;
                      }
                      if (!_listScrollController.hasClients) {
                        return;
                      }
                      await _listScrollController.animateTo(
                        _listScrollController.position.minScrollExtent,
                        curve: Curves.ease,
                        duration: const Duration(milliseconds: 500),
                      );
                    },
                    onReverseOrder: () => context.readOrNull<ThreadBloc>()?.add(const ThreadChangeViewOrderRequested()),
                    customMenuItems: [
                      if (state.postList.isNotEmpty)
                        MenuCustomItem(
                          icon: Icons.search,
                          description: context.t.threadPage.search.menu,
                          onSelected: _openSearch,
                        ),
                      if (state.tid != null) ...[
                        // Favorite and share need the network: not offered on floors read back offline.
                        if (!state.isOffline)
                          MenuCustomItem(
                            icon: isThreadFavorited(context, tid: state.tid!)
                                ? Icons.bookmark_remove_outlined
                                : Icons.bookmark_add_outlined,
                            description: isThreadFavorited(context, tid: state.tid!)
                                ? context.t.threadPage.favorite.remove
                                : context.t.threadPage.favorite.add,
                            onSelected: () async {
                              final changed = await toggleThreadFavorite(context, tid: state.tid!);
                              if (changed && mounted) {
                                // Relabel the menu item.
                                setState(() {});
                              }
                            },
                          ),
                        if (!state.isOffline && context.read<AuthenticationRepository>().effectiveCurrentUid != null)
                          MenuCustomItem(
                            icon: Icons.forward_to_inbox_outlined,
                            description: context.t.threadPage.shareToFriend.title,
                            onSelected: () async =>
                                shareThreadToFriend(context, tid: state.tid!, title: state.title ?? ''),
                          ),
                        // Floor numbers are where the floors are only when every author's floors are listed.
                        if (state.onlyVisibleUid == null && state.postList.isNotEmpty)
                          MenuCustomItem(
                            icon: Icons.format_list_numbered_outlined,
                            description: context.t.threadPage.jumpToFloor.menu,
                            onSelected: () async => _askJumpToFloor(context, state),
                          ),
                        MenuCustomItem(
                          icon: Icons.numbers_outlined,
                          description: context.t.threadPage.copyTid(tid: state.tid!),
                          onSelected: () async => copyToClipboard(context, state.tid!),
                        ),
                      ],
                    ],
                  );
            _appBarCollapser.barHeight = appBar.preferredSize.height;
            // Read the body's MediaQuery after Scaffold has consumed the app bar's top inset.
            // The content's text-scale override must not restore the outer status-bar padding.
            final body = Builder(builder: (bodyContext) => _buildBody(bodyContext, state, searchHits));
            // The authors of the loaded floors, for a typed `@` in the reply bar (a bottom sheet of this scaffold).
            final self = context.read<AuthenticationRepository>().currentUser;
            final mentionSuggestions = threadMentionSuggestions(
              state.postList,
              selfUid: self?.uid,
              selfName: self?.username,
            );
            // Only the scaffold follows the bar's animation: the same app bar and body widgets are laid out again,
            // not rebuilt.
            // Back closes the search first. Not a `PopScope`: the page stays one that may be closed on its own
            // (`canCloseQuietly`), and the back swipe still closes it.
            return MentionSuggestionsScope(
              suggestions: mentionSuggestions,
              child: BackButtonListener(
                onBackButtonPressed: _onBackPressed,
                child: AnimatedBuilder(
                  animation: _appBarController,
                  builder: (context, _) => Scaffold(
                    // Required by chat_bottom_container in the reply bar.
                    resizeToAvoidBottomInset: false,
                    appBar: CollapsingAppBar(shown: _appBarController.value, child: appBar),
                    body: body,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Tells [onChanged] whether the route of this widget is the one on top, first when built and then whenever that
/// changes (a page or a dialog pushed above it, or gone again), without rebuilding [child].
///
/// The thread page depends on it through this widget rather than in its own state: that would rebuild the whole page
/// for every page, dialog or menu opened above it.
class _RouteOnTopListener extends StatefulWidget {
  const _RouteOnTopListener({required this.onChanged, required this.child});

  final void Function({required bool onTop}) onChanged;

  final Widget child;

  @override
  State<_RouteOnTopListener> createState() => _RouteOnTopListenerState();
}

class _RouteOnTopListenerState extends State<_RouteOnTopListener> {
  bool? _onTop;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Depends on this part of the route only.
    final onTop = ModalRoute.isCurrentOf(context) ?? true;
    if (onTop != _onTop) {
      _onTop = onTop;
      widget.onChanged(onTop: onTop);
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Shown instead of a thread whose author could not be learnt while the current account blocks somebody.
///
/// Neutral: the thread is not known to be blocked, only not shown until its author is known.
class _AuthorLookupFailure extends StatelessWidget {
  const _AuthorLookupFailure({required this.onRetry});

  /// Try again.
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return AppStateView(
      error: true,
      icon: Icons.error_outline,
      message: context.t.general.failedToLoad,
      action: Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          if (Navigator.of(context).canPop())
            OutlinedButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: Text(context.t.userBlock.goBack),
            ),
          FilledButton(onPressed: onRetry, child: Text(context.t.general.retry)),
        ],
      ),
    );
  }
}

/// Asks for a floor of the thread to go to ([max] floors when known).
class _JumpToFloorDialog extends StatefulWidget {
  const _JumpToFloorDialog({required this.max});

  final int? max;

  @override
  State<_JumpToFloorDialog> createState() => _JumpToFloorDialogState();
}

class _JumpToFloorDialogState extends State<_JumpToFloorDialog> {
  final _controller = TextEditingController();
  bool _invalid = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final floor = int.tryParse(_controller.text.trim());
    if (floor == null || floor < 1) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.of(context).pop(floor);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadPage.jumpToFloor;
    return AlertDialog(
      title: Text(tr.title),
      content: TextField(
        key: const ValueKey('jump-to-floor-field'),
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textInputAction: TextInputAction.go,
        decoration: InputDecoration(
          labelText: tr.label,
          hintText: widget.max == null ? null : tr.hint(max: widget.max!),
          errorText: _invalid ? tr.invalid : null,
          prefixText: '#',
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        TextButton(key: const ValueKey('jump-to-floor-go'), onPressed: _submit, child: Text(tr.go)),
      ],
    );
  }
}

/// Offers to go on reading where it stopped last time, floating above the floors (it moves none of them).
class _ResumeBanner extends StatelessWidget {
  const _ResumeBanner({required this.floor, required this.onResume, required this.onClose});

  final int floor;

  final VoidCallback onResume;

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadPage.resume;
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      key: const ValueKey('thread-resume-banner'),
      elevation: 3,
      color: colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(appInnerRadius * 2),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        child: Row(
          children: [
            Icon(Icons.bookmark_outline, size: 20, color: colorScheme.onSecondaryContainer),
            sizedBoxW8H8,
            Expanded(
              child: Text(
                tr.message(floor: floor),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSecondaryContainer),
              ),
            ),
            TextButton(key: const ValueKey('thread-resume-go'), onPressed: onResume, child: Text(tr.action)),
            IconButton(
              key: const ValueKey('thread-resume-close'),
              tooltip: tr.close,
              icon: const Icon(Icons.close),
              color: colorScheme.onSecondaryContainer,
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}

/// [post], or for a hot reply the closest floor of the thread around it in [posts]: the next one, else the one
/// before it: the floor the reading is at when a hot reply is at the top of the list.
@visibleForTesting
Post readFloorAround(List<Post> posts, Post post) {
  if (!post.hot) {
    return post;
  }
  final at = posts.indexOf(post);
  if (at < 0) {
    return post;
  }
  for (var i = at + 1; i < posts.length; i++) {
    if (!posts[i].hot) {
      return posts[i];
    }
  }
  for (var i = at - 1; i >= 0; i--) {
    if (!posts[i].hot) {
      return posts[i];
    }
  }
  return post;
}
