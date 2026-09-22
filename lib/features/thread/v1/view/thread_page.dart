import 'dart:async';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/blocking/widgets/block_aware_post.dart';
import 'package:tsdm_client/features/favorite/utils/thread_favorite_action.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/need_login/view/need_login_page.dart';
import 'package:tsdm_client/features/replied_thread/cubit/replied_thread_cubit.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/dialog.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/replied_thread_seed.dart';
import 'package:tsdm_client/features/thread/v1/utils/share_thread_action.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/card/error_card.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/list_app_bar/list_app_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';
import 'package:universal_html/html.dart' as uh;

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

  @override
  State<ThreadPage> createState() => _ThreadPageState();
}

/// The first floor on the thread page [document] names no user: an anonymous or guest post, whose author has no user
/// link (the post parser skips such floors). Nobody on a block list can be its author. Links in the post body are
/// not looked at; a page without a first floor is not such a thread.
bool _firstFloorNamesNoUser(uh.Document document) {
  final first = document
      .querySelectorAll('div#postlist div[id^="post_"]')
      .firstWhereOrNull((e) => e.querySelector('div.pi strong em')?.text?.trim() == '1');
  return first != null && first.querySelector('td.pls a[href*="uid="], div.authi a[href*="uid="]') == null;
}

class _ThreadPageState extends State<ThreadPage> with SingleTickerProviderStateMixin, LoggerMixin {
  /// Controller of thread tab.
  final _listScrollController = ScrollController();

  final _replyBarController = ReplyBarController();

  /// Floor to scroll to when the thread reloads after a reply or edit. Read by the next
  /// [PostList] in its `initState` and forgotten right after, so later reloads do not jump back to it.
  String? _scrollToPidOnReload;

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
  /// Only needed when the thread was opened on a later page and the current account blocks somebody.
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
        final result = await ThreadRepository().fetchThread(tid: tid, reverseOrder: false).run();
        result.match((e) => error('failed to learn the author of thread $tid: $e'), (doc) {
          final page = parseThreadDocument(doc, 1);
          final first = page.postList.firstWhereOrNull((e) => e.postFloor == 1);
          ThreadAuthorCache.record(tid, first?.author.uid);
          author = ThreadAuthorCache.authorOf(tid);
          unattributable = author == null && page.havePermission && !page.needLogin && _firstFloorNamesNoUser(doc);
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
            onRetry: () => context.read<ThreadBloc>().add(ThreadLoadMoreRequested(state.currentPage)),
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
    if (state.status != ThreadStatus.success) {
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
    // The history would list the title of a thread the user blocked the author of, or might have.
    final blockList = currentBlockList(context, listen: false);
    final author = _threadAuthorOf(state);
    if (!blockList.isKnown ||
        (blockList.uids.isNotEmpty && author == null && !_isUnattributable(state)) ||
        blockList.hides(author)) {
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

  Widget _buildBreadcrumbsRow(ThreadState state, double extraHeight, {required bool replied}) {
    final infoTextStyle = Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.outline);

    final infoTextHighlightStyle = Theme.of(
      context,
    ).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary);

    final breadFrags = state.breadcrumbs
        .map(
          (e) => [
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
                child: Text(e.description, style: infoTextHighlightStyle),
              ),
            ),
            const Text(' > '),
          ],
        )
        .flattenedToList;

    return Padding(
      padding: edgeInsetsL12R12.add(edgeInsetsB4),
      child: DefaultTextStyle.merge(
        style: infoTextStyle,
        child: SizedBox(
          height: 20 + extraHeight,
          child: ListView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            children: <Widget>[
              ...breadFrags,
              if (state.threadType?.typeID != null && state.fid != null)
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () async => context.pushNamed(
                      ScreenPaths.forum,
                      pathParameters: {'fid': '${state.fid}'},
                      queryParameters: {
                        'threadTypeName': state.threadType?.name,
                        'threadTypeID': '${state.threadType?.typeID}',
                      },
                    ),
                    child: Text('[${state.threadType!.name}]', style: infoTextHighlightStyle),
                  ),
                ),
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () async {
                    final id = state.tid ?? widget.threadID;
                    final title = state.title ?? widget.title;
                    await showCopyThreadInfoDialog(context: context, tid: id, title: title);
                  },
                  child: Text('[${context.t.threadPage.title} ${state.tid ?? ""}]', style: infoTextHighlightStyle),
                ),
              ),
              if (state.viewCount != null || state.replyCount != null)
                Text('[${context.t.threadPage.statistics(view: state.viewCount ?? 0, reply: state.replyCount ?? 0)}]'),
              if (state.isDraft) Text('[${context.t.threadPage.draft}]'),
              // The current account replied in this thread (local mark, issue #21).
              if (replied)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.reply_outlined, size: 16, color: Theme.of(context).colorScheme.tertiary),
                    sizedBoxW4H4,
                    Text(
                      context.t.threadPage.repliedMark,
                      style: infoTextStyle?.copyWith(color: Theme.of(context).colorScheme.tertiary),
                    ),
                  ],
                ),
            ].reversed.toList(),
          ),
        ),
      ),
    );
  }

  Future<void> replyPostCallback(User user, int? postFloor, String? replyAction) async {
    if (replyAction == null) {
      return;
    }

    _replyBarController
      ..replyAction = replyAction
      ..setHintText(
        '${context.t.threadPage.sendReplyHint} ${user.name} '
        '${postFloor == null ? "" : "#$postFloor"}',
      )
      ..requestFocus();
  }

  Widget _buildContent(BuildContext context, ThreadState state) {
    final tr = context.t.threadPage;
    if (_scrollToPidOnReload != null) {
      // Consumed by the PostList created in this build.
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPidOnReload = null);
    }

    return Column(
      children: [
        Expanded(
          child: PostList(
            threadID: state.tid ?? widget.threadID,
            title: state.title ?? widget.title,
            pageNumber: context.read<JumpPageCubit>().state.currentPage,
            initialPostID: (_scrollToPidOnReload ?? widget.findPostID)?.parseToInt(),
            scrollController: _listScrollController,
            // Posts of locally blocked users become placeholders in place, the floors keep their positions.
            widgetBuilder: (context, post) => BlockAwarePost(
              post: post,
              postList: state.postList,
              builder: (context, post) => PostCard(
                post,
                replyCallback: replyPostCallback,
                onEdited: () => _scrollToPidOnReload = post.postID,
              ),
            ),
            useDivider: true,
            postList: state.postList,
            canLoadMore: state.canLoadMore,
            latestModAct: state.latestModAct,
          ),
        ),
        if (state.threadSoftClosed && !state.threadClosed)
          ColoredBox(
            color: Theme.of(context).colorScheme.secondaryContainer,
            child: Padding(
              padding: edgeInsetsL12T4R12B4,
              child: Row(
                children: [
                  Icon(Icons.lock_outline, size: 16, color: Theme.of(context).colorScheme.onSecondaryContainer),
                  sizedBoxW4H4,
                  Expanded(
                    child: Text(
                      tr.softCloseHint,
                      style: TextStyle(color: Theme.of(context).colorScheme.onSecondaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
        _buildReplyBar(context, state),
      ],
    );
  }

  Widget _buildBody(BuildContext context, ThreadState state) {
    if (state.needLogin) {
      return NeedLoginPage(
        backUri: GoRouterState.of(context).uri,
        needPop: true,
        popCallback: (context) {
          context.read<ThreadBloc>().add(ThreadRefreshRequested());
        },
      );
    } else if (!state.havePermission) {
      if (state.permissionDeniedMessage != null) {
        return ErrorCard(child: munchElement(context, state.permissionDeniedMessage!));
      } else {
        return Center(child: Text(context.t.general.noPermission));
      }
    }

    return switch (state.status) {
      ThreadStatus.initial || ThreadStatus.loading => const CenteredCircularIndicator(),
      // A failed reload keeps the previous posts (see ThreadBloc); only an empty page gets the retry button.
      ThreadStatus.failure when state.postList.isNotEmpty => _buildContent(context, state),
      ThreadStatus.failure => buildRetryButton(context, () {
        context.read<ThreadBloc>().add(ThreadLoadMoreRequested(state.currentPage));
      }),
      ThreadStatus.success => _buildContent(context, state),
    };
  }

  Widget _buildReplyBar(BuildContext context, ThreadState state) {
    if (state.postList.isEmpty) {
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
  void dispose() {
    _authorLookup++;
    _listScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final threadReverseOrder = getIt.get<SettingsRepository>().currentSettings.threadReverseOrder;

    return MultiBlocProvider(
      providers: [
        RepositoryProvider<ThreadRepository>(create: (_) => ThreadRepository()),
        RepositoryProvider<ReplyRepository>(create: (_) => const ReplyRepository()),
        BlocProvider(
          create: (context) => ThreadBloc(
            tid: widget.threadID,
            pid: widget.findPostID,
            onlyVisibleUid: widget.onlyVisibleUid,
            threadRepository: context.repo(),
            reverseOrder: widget.overrideReverseOrder ? threadReverseOrder : null,
            exactOrder: widget.overrideWithExactOrder,
          )..add(ThreadLoadMoreRequested(int.tryParse(widget.pageNumber) ?? 1)),
        ),
        BlocProvider(
          create: (context) => ReplyBloc(
            replyRepository: context.repo(),
            storageProvider: getIt.get<StorageProvider>(),
            authenticationRepository: context.repo(),
          ),
        ),
        BlocProvider(create: (context) => JumpPageCubit()),
      ],
      child: MultiBlocListener(
        listeners: [
          BlocListener<ThreadBloc, ThreadState>(
            listener: (context, state) {
              if (state.status == ThreadStatus.failure && state.postList.isNotEmpty) {
                // A reload (for example after a reply) failed: the posts stay on screen, only tell the user.
                showSnackBar(context: context, message: context.t.general.failedToLoad);
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
              }
            },
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
                  message: state.networkFailure ? tr.replyFailedNetwork : tr.replyFailed(err: state.failedReason ?? ''),
                  // The editor and the keyboard stay open on failure and this page does not resize for the keyboard
                  // (`resizeToAvoidBottomInset: false`), so lift the hint above it.
                  bottomInset: MediaQuery.viewInsetsOf(context).bottom,
                );
              }
            },
          ),
        ],
        child: BlocBuilder<ThreadBloc, ThreadState>(
          builder: (context, state) {
            // Update jump page state.
            context.read<JumpPageCubit>().setPageInfo(totalPages: state.totalPages, currentPage: state.currentPage);
            final textScaleExtraBreadHeight = context.select<SettingsBloc, double>(
              (bloc) => 1 * math.max(0, (bloc.state.settingsMap.textScaleFactor - 1) / 0.1),
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

            return Scaffold(
              // Required by chat_bottom_container in the reply bar.
              resizeToAvoidBottomInset: false,
              appBar: ListAppBar(
                title: title,
                bottom: PreferredSize(
                  preferredSize: Size.fromHeight(20 + textScaleExtraBreadHeight),
                  child: _buildBreadcrumbsRow(state, textScaleExtraBreadHeight, replied: replied),
                ),
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
                onBackToTop: () async =>
                    _listScrollController.animateTo(0, curve: Curves.ease, duration: const Duration(milliseconds: 500)),
                onReverseOrder: () => context.readOrNull<ThreadBloc>()?.add(const ThreadChangeViewOrderRequested()),
                customMenuItems: [
                  if (state.tid != null) ...[
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
                    if (context.read<AuthenticationRepository>().effectiveCurrentUid != null)
                      MenuCustomItem(
                        icon: Icons.forward_to_inbox_outlined,
                        description: context.t.threadPage.shareToFriend.title,
                        onSelected: () async => shareThreadToFriend(context, tid: state.tid!, title: state.title ?? ''),
                      ),
                    MenuCustomItem(
                      icon: Icons.numbers_outlined,
                      description: context.t.threadPage.copyTid(tid: state.tid!),
                      onSelected: () async => copyToClipboard(context, state.tid!),
                    ),
                  ],
                ],
              ),
              body: SafeArea(bottom: false, child: _buildBody(context, state)),
            );
          },
        ),
      ),
    );
  }
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
    return Center(
      child: Padding(
        padding: edgeInsetsL12T12R12B12,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            sizedBoxW8H8,
            Text(context.t.general.failedToLoad, textAlign: TextAlign.center),
            sizedBoxW8H8,
            Wrap(
              spacing: 8,
              children: [
                if (Navigator.of(context).canPop())
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(context.t.userBlock.goBack),
                  ),
                FilledButton(onPressed: onRetry, child: Text(context.t.general.retry)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
