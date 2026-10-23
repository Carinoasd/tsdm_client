import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/utils/load_failure.dart';
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

  /// Bumped by every load of the first page: a next page asked for the list before is dropped instead of being
  /// added to the new one.
  int _generation = 0;

  Future<void> _onLoadRequested(FriendLoadRequested event, FriendEmitter emit) async {
    emit(state.copyWith(status: FriendStatus.loading, failure: null, loadingMore: false, loadMoreFailed: false));
    await _loadFirstPage(emit);
  }

  Future<void> _onRefreshRequested(FriendRefreshRequested event, FriendEmitter emit) async {
    emit(state.copyWith(refreshing: true, loadingMore: false, loadMoreFailed: false, failure: null));
    await _loadFirstPage(emit);
  }

  Future<void> _loadFirstPage(FriendEmitter emit) async {
    final generation = ++_generation;
    // A refresh of a list on screen keeps it when it fails (the page says so).
    final shown = state.status == FriendStatus.success && state.items.isNotEmpty;
    final result = await _friendRepository.fetchPage(_firstPageUrl).run();
    if (generation != _generation) {
      return;
    }
    switch (result) {
      case Left(:final value):
        handle(value);
        if (shown) {
          emit(state.copyWith(refreshing: false, failure: LoadFailure.of(value)));
          return;
        }
        emit(state.copyWith(status: FriendStatus.failure, refreshing: false, failure: LoadFailure.of(value)));
      case Right(:final value):
        if (value.needLogin) {
          emit(state.copyWith(status: FriendStatus.needLogin, refreshing: false, loadingMore: false));
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
              loadingMore: false,
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
            loadMoreFailed: false,
            failure: null,
          ),
        );
    }
  }

  Future<void> _onLoadMoreRequested(FriendLoadMoreRequested event, FriendEmitter emit) async {
    final url = state.nextPageUrl;
    if (url == null || state.loadingMore || state.refreshing) {
      return;
    }
    final generation = _generation;
    emit(state.copyWith(loadingMore: true, loadMoreFailed: false));
    final result = await _friendRepository.fetchPage(url).run();
    if (generation != _generation) {
      return;
    }
    switch (result) {
      case Left(:final value):
        handle(value);
        // The friends loaded before stay, the end of the list tells the failure and retries.
        emit(state.copyWith(loadingMore: false, loadMoreFailed: true, failure: LoadFailure.of(value)));
      case Right(:final value):
        final knownUids = state.items.map((e) => e.uid).toSet();
        emit(
          state.copyWith(
            items: [...state.items, ...value.items.where((e) => !knownUids.contains(e.uid))],
            nextPageUrl: value.nextPageUrl,
            totalCount: value.totalCount ?? state.totalCount,
            pageNumber: state.pageNumber + 1,
            loadingMore: false,
            failure: null,
          ),
        );
    }
  }
}
