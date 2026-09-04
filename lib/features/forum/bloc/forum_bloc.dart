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
  }

  final ForumRepository _forumRepository;

  Future<void> _onForumLoadMoreRequested(ForumLoadMoreRequested event, ForumEmitter emit) async {
    if (state.status == ForumStatus.failure) {
      // Restoring from failure state.
      emit(state.copyWith(status: ForumStatus.loading));
    }
    await await _forumRepository
        .fetchForum(fid: state.fid, pageNumber: event.pageNumber, filterState: state.filterState)
        .match((e) {
          handle(e);
          emit(state.copyWith(status: ForumStatus.failure));
        }, (v) async => emit(await _parseFromDocument(v, event.pageNumber)))
        .run();
  }

  Future<void> _onForumRefreshRequested(ForumRefreshRequested event, ForumEmitter emit) async {
    emit(state.copyWith(status: ForumStatus.loading, normalThreadList: []));

    await await _forumRepository.fetchForum(fid: state.fid, filterState: state.filterState).match((e) {
      handle(e);
      error('failed to load forum page: fid=${state.fid}, pageNumber=1 : $e');
      emit(state.copyWith(status: ForumStatus.failure));
    }, (v) async => emit(await _parseFromDocument(v, 1))).run();
  }

  Future<void> _onForumJumpPageRequested(ForumJumpPageRequested event, ForumEmitter emit) async {
    emit(state.copyWith(status: ForumStatus.loading, normalThreadList: []));
    await await _forumRepository
        .fetchForum(fid: state.fid, pageNumber: event.pageNumber, filterState: state.filterState)
        .match((e) {
          handle(e);
          error('failed to load forum page: fid=${state.fid}, pageNumber=1 : $e');
          emit(state.copyWith(status: ForumStatus.failure));
        }, (v) async => emit(await _parseFromDocument(v, event.pageNumber)))
        .run();
  }

  Future<void> _onForumChangeThreadFilterStateRequested(
    ForumChangeThreadFilterStateRequested event,
    ForumEmitter emit,
  ) async {
    emit(state.copyWith(status: ForumStatus.loading, normalThreadList: [], filterState: event.filterState));
    await await _forumRepository.fetchForum(fid: state.fid, filterState: state.filterState).match((e) {
      handle(e);
      error('failed to load forum page: fid=${state.fid}, pageNumber=1 : $e');
      emit(state.copyWith(status: ForumStatus.failure));
    }, (v) async => emit(await _parseFromDocument(v, 1))).run();
  }

  Future<ForumState> _parseFromDocument(uh.Document document, int pageNumber) async {
    final page = parseForumPage(document, state.fid);

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
