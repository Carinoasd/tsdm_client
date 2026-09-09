import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/favorite/utils/parse_favorite.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'favorite_bloc.mapper.dart';

part 'favorite_event.dart';

part 'favorite_state.dart';

/// Emitter.
typedef FavoriteEmitter = Emitter<FavoriteState>;

/// Bloc of one tab of the favorites page: the threads (`type=thread`) or the forums (`type=forum`).
final class FavoriteBloc extends Bloc<FavoriteEvent, FavoriteState> with LoggerMixin {
  /// Constructor.
  FavoriteBloc({
    required FavoriteRepository favoriteRepository,
    required AuthenticationRepository authenticationRepository,
    this.type = FavoriteType.thread,
  }) : _favoriteRepository = favoriteRepository,
       _authenticationRepository = authenticationRepository,
       super(const FavoriteState()) {
    on<FavoriteLoadRequested>(_onLoadRequested);
    on<FavoriteRefreshRequested>(_onRefreshRequested);
    on<FavoriteLoadMoreRequested>(_onLoadMoreRequested);
    on<FavoriteRemoveRequested>(_onRemoveRequested);
  }

  /// Kind of records this bloc lists.
  final FavoriteType type;

  final FavoriteRepository _favoriteRepository;
  final AuthenticationRepository _authenticationRepository;

  int? get _uid => _authenticationRepository.currentUser?.uid;

  Future<void> _onLoadRequested(FavoriteLoadRequested event, FavoriteEmitter emit) async {
    if (_uid == null) {
      emit(state.copyWith(status: FavoriteStatus.needLogin));
      return;
    }
    emit(state.copyWith(status: FavoriteStatus.loading));
    await _loadFirstPage(emit);
  }

  Future<void> _onRefreshRequested(FavoriteRefreshRequested event, FavoriteEmitter emit) async {
    if (_uid == null) {
      emit(state.copyWith(status: FavoriteStatus.needLogin, refreshing: false));
      return;
    }
    emit(state.copyWith(refreshing: true));
    await _loadFirstPage(emit);
  }

  Future<void> _loadFirstPage(FavoriteEmitter emit) async {
    switch (await _favoriteRepository.fetchListPageOf(type).run()) {
      case Left(:final value):
        handle(value);
        emit(state.copyWith(status: FavoriteStatus.failure, refreshing: false));
      case Right(:final value):
        if (value.needLogin) {
          emit(state.copyWith(status: FavoriteStatus.needLogin, refreshing: false));
          return;
        }
        final uid = _uid;
        if (uid != null) {
          _favoriteRepository.rememberAll(uid: uid, items: value.items);
        }
        emit(
          state.copyWith(
            status: FavoriteStatus.success,
            items: value.items,
            nextPageUrl: value.nextPageUrl,
            pageNumber: 1,
            refreshing: false,
            loadingMore: false,
          ),
        );
    }
  }

  Future<void> _onLoadMoreRequested(FavoriteLoadMoreRequested event, FavoriteEmitter emit) async {
    final url = state.nextPageUrl;
    if (url == null || state.loadingMore) {
      return;
    }
    emit(state.copyWith(loadingMore: true));
    switch (await _favoriteRepository.fetchListPageOf(type, url).run()) {
      case Left(:final value):
        handle(value);
        emit(state.copyWith(loadingMore: false, failureCount: state.failureCount + 1, lastFailure: value.message));
      case Right(:final value):
        final uid = _uid;
        if (uid != null) {
          _favoriteRepository.rememberAll(uid: uid, items: value.items);
        }
        // A record may show up twice when the list changed between two page loads.
        final knownFavids = state.items.map((e) => e.favid).toSet();
        emit(
          state.copyWith(
            items: [...state.items, ...value.items.where((e) => !knownFavids.contains(e.favid))],
            nextPageUrl: value.nextPageUrl,
            pageNumber: state.pageNumber + 1,
            loadingMore: false,
          ),
        );
    }
  }

  Future<void> _onRemoveRequested(FavoriteRemoveRequested event, FavoriteEmitter emit) async {
    final item = event.item;
    if (state.removing.contains(item.favid)) {
      return;
    }
    emit(state.copyWith(removing: [...state.removing, item.favid]));
    final result = await _favoriteRepository.removeFavorite(favid: item.favid, type: item.type).run();
    final removing = state.removing.where((e) => e != item.favid).toList();
    switch (result) {
      case Right(value: FavoriteRemoveResult(removed: true)):
        final uid = _uid;
        if (uid != null) {
          _favoriteRepository.forgetItem(uid: uid, item: item);
        }
        emit(
          state.copyWith(
            items: state.items.where((e) => e.favid != item.favid).toList(),
            removing: removing,
            removedCount: state.removedCount + 1,
          ),
        );
      case Right(:final value):
        emit(state.copyWith(removing: removing, failureCount: state.failureCount + 1, lastFailure: value.message));
      case Left(:final value):
        handle(value);
        emit(state.copyWith(removing: removing, failureCount: state.failureCount + 1, lastFailure: value.message));
    }
  }
}
