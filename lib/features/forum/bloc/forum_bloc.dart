import 'dart:math' as math;

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

part 'forum_bloc.mapper.dart';
part 'forum_event.dart';
part 'forum_state.dart';

/// Emitter
typedef ForumEmitter = Emitter<ForumState>;

/// Bloc of forum page.
class ForumBloc extends Bloc<ForumEvent, ForumState> with LoggerMixin {
  /// Constructor.
  ForumBloc({required String fid, required ForumRepository forumRepository, FilterState? filterState})
    : _forumRepository = forumRepository,
      super(ForumState(fid: fid, filterState: filterState ?? const FilterState())) {
    on<ForumLoadMoreRequested>(_onForumLoadMoreRequested);
    on<ForumRefreshRequested>(_onForumRefreshRequested);
    on<ForumJumpPageRequested>(_onForumJumpPageRequested);
    on<ForumChangeThreadFilterStateRequested>(_onForumChangeThreadFilterStateRequested);
    on<ForumRetryRequested>(_onForumRetryRequested);
  }

  final ForumRepository _forumRepository;

  /// The page asked last, which [ForumRetryRequested] asks again.
  int _askedPage = 1;

  /// Ask again the page asked last, as going on with the list: after a page failed to go on with the list, the list
  /// holds the pages before it (asking the page shown again, as before, added its threads a second time); after a
  /// refresh, a jump or a filter failed, the list is empty.
  Future<void> _onForumRetryRequested(ForumRetryRequested event, ForumEmitter emit) =>
      _onForumLoadMoreRequested(ForumLoadMoreRequested(_askedPage), emit);

  Future<void> _onForumLoadMoreRequested(ForumLoadMoreRequested event, ForumEmitter emit) async {
    _askedPage = event.pageNumber;
    if (state.status == ForumStatus.failure) {
      // Restoring from failure state.
      emit(state.copyWith(status: ForumStatus.loading, pollOfferUid: null));
    } else if (state.loadMoreFailed) {
      emit(state.copyWith(loadMoreFailed: false));
    }
    await await _forumRepository
        .fetchForum(fid: state.fid, pageNumber: event.pageNumber, filterState: state.filterState)
        .match((e) {
          handle(e);
          if (state.status == ForumStatus.success && state.normalThreadList.isNotEmpty) {
            // Going on with the list failed: the threads on screen stay, the end of the list offers the retry.
            emit(state.copyWith(loadMoreFailed: true));
            return;
          }
          emit(state.copyWith(status: ForumStatus.failure, pollOfferUid: null));
        }, (v) async => emit(_loadedMore(v, event.pageNumber).copyWith(loadMoreFailed: false)))
        .run();
  }

  /// The state with [page], the answer to page [pageNumber] asked to go on with the list.
  ///
  /// The forum shows its first page when asked past its last page or past the site's limit of pages
  /// (`threadmaxpages`), and the page tells which one it is (the web page's pagination, plugin 2.8.2's `page`): the
  /// threads of another page than the one asked are not added (the list holds them, or they belong before it), the
  /// list is at its end, and its last page is the one the forum names.
  ForumState _loadedMore(ForumPageData page, int pageNumber) {
    final answered = page.currentPage;
    if (answered == null || answered == pageNumber || state.normalThreadList.isEmpty) {
      return _mergePage(page, pageNumber);
    }
    warning('asked page $pageNumber of forum ${state.fid}, the forum answered page $answered: the list ends here');
    return state.copyWith(
      status: ForumStatus.success,
      canLoadMore: false,
      totalPages: math.min(page.totalPages ?? state.currentPage, state.currentPage),
      pollOfferUid: page.pollOfferUid,
    );
  }

  Future<void> _onForumRefreshRequested(ForumRefreshRequested event, ForumEmitter emit) async {
    _askedPage = 1;
    emit(state.copyWith(status: ForumStatus.loading, normalThreadList: [], pollOfferUid: null, loadMoreFailed: false));

    await await _forumRepository.fetchForum(fid: state.fid, filterState: state.filterState).match((e) {
      handle(e);
      error('failed to load forum page: fid=${state.fid}, pageNumber=1 : $e');
      emit(state.copyWith(status: ForumStatus.failure, pollOfferUid: null));
    }, (v) async => emit(_mergePage(v, 1))).run();
  }

  Future<void> _onForumJumpPageRequested(ForumJumpPageRequested event, ForumEmitter emit) async {
    _askedPage = event.pageNumber;
    emit(state.copyWith(status: ForumStatus.loading, normalThreadList: [], pollOfferUid: null, loadMoreFailed: false));
    await await _forumRepository
        .fetchForum(fid: state.fid, pageNumber: event.pageNumber, filterState: state.filterState)
        .match((e) {
          handle(e);
          error('failed to load forum page: fid=${state.fid}, pageNumber=1 : $e');
          emit(state.copyWith(status: ForumStatus.failure, pollOfferUid: null));
        }, (v) async => emit(_mergePage(v, event.pageNumber)))
        .run();
  }

  Future<void> _onForumChangeThreadFilterStateRequested(
    ForumChangeThreadFilterStateRequested event,
    ForumEmitter emit,
  ) async {
    _askedPage = 1;
    emit(
      state.copyWith(
        status: ForumStatus.loading,
        normalThreadList: [],
        filterState: event.filterState,
        pollOfferUid: null,
        loadMoreFailed: false,
      ),
    );
    await await _forumRepository.fetchForum(fid: state.fid, filterState: state.filterState).match((e) {
      handle(e);
      error('failed to load forum page: fid=${state.fid}, pageNumber=1 : $e');
      emit(state.copyWith(status: ForumStatus.failure, pollOfferUid: null));
    }, (v) async => emit(_mergePage(v, 1))).run();
  }

  /// The state with [page] (the page [pageNumber] the repository built, from the web page or the forum's app API)
  /// merged in. The page shown is the one the forum answered (`currentPage`, the web page's pagination; plugin
  /// 2.8.2's `page`, which is the first page when asked past the site's limit of pages), [pageNumber] only when the
  /// answer does not tell.
  ForumState _mergePage(ForumPageData page, int pageNumber) {
    final allNormalThread = [...state.normalThreadList, ...page.normalThreadList];

    var producedState = state.copyWith(
      status: ForumStatus.success,
      title: page.title,
      normalThreadList: allNormalThread,
      canLoadMore: page.canLoadMore,
      needLogin: page.needLogin,
      havePermission: page.havePermission,
      permissionDeniedMessage: page.permissionDeniedMessage,
      currentPage: page.currentPage ?? pageNumber,
      totalPages: page.totalPages ?? page.currentPage ?? pageNumber,
      filterTypeList: page.filterTypeList,
      filterSpecialTypeList: page.filterSpecialTypeList,
      filterOrderList: page.filterOrderList,
      filterDatelineList: page.filterDatelineList,
      // Always the latest page's own offer: never carried over from an earlier page or account.
      pollOfferUid: page.pollOfferUid,
    );

    if (page.stickThreadList.isNotEmpty) {
      producedState = producedState.copyWith(stickThreadList: page.stickThreadList);
    }
    if (page.rulesElement != null) {
      producedState = producedState.copyWith(rulesElement: page.rulesElement);
    }
    if (page.subredditList.isNotEmpty) {
      producedState = producedState.copyWith(subredditList: page.subredditList);
    }
    return producedState;
  }
}
