import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'friend_bloc.mapper.dart';

part 'friend_event.dart';

part 'friend_state.dart';

/// Emitter.
typedef FriendEmitter = Emitter<FriendState>;

/// Bloc of a friends list page.
final class FriendBloc extends Bloc<FriendEvent, FriendState> with LoggerMixin {
  /// Constructor.
  ///
  /// [firstPageUrl] is the url of the first page, see [FriendRepository.listUrl].
  FriendBloc({required FriendRepository friendRepository, required String firstPageUrl})
    : _friendRepository = friendRepository,
      _firstPageUrl = firstPageUrl,
      super(const FriendState()) {
    on<FriendLoadRequested>(_onLoadRequested);
    on<FriendRefreshRequested>(_onRefreshRequested);
    on<FriendLoadMoreRequested>(_onLoadMoreRequested);
  }

  final FriendRepository _friendRepository;
  final String _firstPageUrl;

  Future<void> _onLoadRequested(FriendLoadRequested event, FriendEmitter emit) async {
    emit(state.copyWith(status: FriendStatus.loading));
    await _loadFirstPage(emit);
  }

  Future<void> _onRefreshRequested(FriendRefreshRequested event, FriendEmitter emit) async {
    emit(state.copyWith(refreshing: true));
    await _loadFirstPage(emit);
  }

  Future<void> _loadFirstPage(FriendEmitter emit) async {
    switch (await _friendRepository.fetchPage(_firstPageUrl).run()) {
      case Left(:final value):
        handle(value);
        emit(state.copyWith(status: FriendStatus.failure, refreshing: false));
      case Right(:final value):
        if (value.needLogin) {
          emit(state.copyWith(status: FriendStatus.needLogin, refreshing: false));
          return;
        }
        if (value.message != null) {
          emit(
            state.copyWith(
              status: FriendStatus.notice,
              items: const [],
              message: value.message,
              ownerName: value.ownerName,
              refreshing: false,
            ),
          );
          return;
        }
        emit(
          state.copyWith(
            status: FriendStatus.success,
            items: value.items,
            nextPageUrl: value.nextPageUrl,
            totalCount: value.totalCount,
            ownerName: value.ownerName,
            pageNumber: 1,
            refreshing: false,
            loadingMore: false,
          ),
        );
    }
  }

  Future<void> _onLoadMoreRequested(FriendLoadMoreRequested event, FriendEmitter emit) async {
    final url = state.nextPageUrl;
    if (url == null || state.loadingMore) {
      return;
    }
    emit(state.copyWith(loadingMore: true));
    switch (await _friendRepository.fetchPage(url).run()) {
      case Left(:final value):
        handle(value);
        emit(state.copyWith(loadingMore: false, failureCount: state.failureCount + 1));
      case Right(:final value):
        final knownUids = state.items.map((e) => e.uid).toSet();
        emit(
          state.copyWith(
            items: [...state.items, ...value.items.where((e) => !knownUids.contains(e.uid))],
            nextPageUrl: value.nextPageUrl,
            totalCount: value.totalCount ?? state.totalCount,
            pageNumber: state.pageNumber + 1,
            loadingMore: false,
          ),
        );
    }
  }
}
