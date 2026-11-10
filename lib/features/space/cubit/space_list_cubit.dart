import 'package:bloc/bloc.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Where a page of the space is.
enum SpaceLoadStatus {
  /// Loading the first page.
  loading,

  /// Shown.
  success,

  /// The forum printed its words instead (the privacy notice, a password, a missing blog).
  notice,

  /// The forum asks to log in.
  needLogin,

  /// The first page failed to load.
  failure,
}

const _keep = Object();

/// State of [SpaceListCubit].
final class SpaceListState<T> {
  /// Constructor.
  const SpaceListState({
    this.status = SpaceLoadStatus.loading,
    this.items = const [],
    this.nextPageUrl,
    this.title,
    this.totalCount,
    this.hiddenNote,
    this.message,
    this.passwordRequired = false,
    this.refreshing = false,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.failure,
    this.session,
    this.canPost = false,
  });

  /// Where the page is.
  final SpaceLoadStatus status;

  /// The items loaded so far, page after page.
  final List<T> items;

  /// The next page, null after the last one.
  final String? nextPageUrl;

  /// The name of the album (its pictures only).
  final String? title;

  /// The number of pictures of the album (its pictures only).
  final int? totalCount;

  /// The forum's note on blogs kept from the viewer, of the first page.
  final String? hiddenNote;

  /// The forum's words, for [SpaceLoadStatus.notice].
  final String? message;

  /// The forum asks for a password ([SpaceLoadStatus.notice]).
  final bool passwordRequired;

  /// Loading the first page again with the items on screen.
  final bool refreshing;

  /// Loading the next page.
  final bool loadingMore;

  /// The next page failed.
  final bool loadMoreFailed;

  /// Why the last load failed.
  final LoadFailure? failure;

  /// The account the first page was served to and its form hash (the wall, the greetings received).
  final SpaceSession? session;

  /// The first page of a wall printed its message box.
  final bool canPost;

  /// Copy with the given fields.
  SpaceListState<T> copyWith({
    SpaceLoadStatus? status,
    List<T>? items,
    Object? nextPageUrl = _keep,
    Object? title = _keep,
    Object? totalCount = _keep,
    Object? hiddenNote = _keep,
    Object? message = _keep,
    bool? passwordRequired,
    bool? refreshing,
    bool? loadingMore,
    bool? loadMoreFailed,
    Object? failure = _keep,
  }) => SpaceListState<T>(
    status: status ?? this.status,
    items: items ?? this.items,
    nextPageUrl: nextPageUrl == _keep ? this.nextPageUrl : nextPageUrl as String?,
    title: title == _keep ? this.title : title as String?,
    totalCount: totalCount == _keep ? this.totalCount : totalCount as int?,
    hiddenNote: hiddenNote == _keep ? this.hiddenNote : hiddenNote as String?,
    message: message == _keep ? this.message : message as String?,
    passwordRequired: passwordRequired ?? this.passwordRequired,
    refreshing: refreshing ?? this.refreshing,
    loadingMore: loadingMore ?? this.loadingMore,
    loadMoreFailed: loadMoreFailed ?? this.loadMoreFailed,
    failure: failure == _keep ? this.failure : failure as LoadFailure?,
    // Kept as they are: they come with the first page only.
    session: session,
    canPost: canPost,
  );
}

/// A list of a member's space, page after page: the blogs, the albums, the pictures of an album.
final class SpaceListCubit<T> extends Cubit<SpaceListState<T>> with LoggerMixin {
  /// Constructor; [fetch] loads a page, [keyOf] tells an item already on screen (a page that moved on while the list
  /// was read).
  SpaceListCubit({
    required String firstPageUrl,
    required AsyncEither<SpaceListPage<T>> Function(String url) fetch,
    required Object Function(T item) keyOf,
  }) : _firstPageUrl = firstPageUrl,
       _fetch = fetch,
       _keyOf = keyOf,
       super(SpaceListState<T>());

  final String _firstPageUrl;
  final AsyncEither<SpaceListPage<T>> Function(String url) _fetch;
  final Object Function(T item) _keyOf;

  /// Bumped by every load of the first page: a next page asked for the list before is dropped.
  int _generation = 0;

  /// Load the first page, the list starting over.
  Future<void> load() async {
    emit(SpaceListState<T>());
    await _loadFirst();
  }

  /// Load the first page again; the items on screen stay when it fails.
  Future<void> refresh() async {
    emit(state.copyWith(refreshing: true, loadingMore: false, loadMoreFailed: false, failure: null));
    await _loadFirst();
  }

  Future<void> _loadFirst() async {
    final generation = ++_generation;
    final shown = state.status == SpaceLoadStatus.success && state.items.isNotEmpty;
    final result = await _fetch(_firstPageUrl).run();
    if (isClosed || generation != _generation) return;
    switch (result) {
      case Left(:final value):
        handle(value);
        emit(
          shown
              ? state.copyWith(refreshing: false, failure: LoadFailure.of(value))
              : state.copyWith(status: SpaceLoadStatus.failure, refreshing: false, failure: LoadFailure.of(value)),
        );
      case Right(:final value) when value.needLogin:
        emit(SpaceListState<T>(status: SpaceLoadStatus.needLogin, title: value.title));
      case Right(:final value) when value.message != null && value.items.isEmpty:
        emit(
          SpaceListState<T>(
            status: SpaceLoadStatus.notice,
            title: value.title,
            message: value.message,
            passwordRequired: value.passwordRequired,
          ),
        );
      case Right(:final value):
        emit(
          SpaceListState<T>(
            status: SpaceLoadStatus.success,
            items: value.items,
            nextPageUrl: value.nextPageUrl,
            title: value.title,
            totalCount: value.totalCount,
            hiddenNote: value.hiddenNote,
            session: value.session,
            canPost: value.canPost,
          ),
        );
    }
  }

  /// Load the next page, when there is one and nothing else loads.
  Future<void> loadMore() async {
    final url = state.nextPageUrl;
    if (url == null || state.loadingMore || state.refreshing || state.status != SpaceLoadStatus.success) return;
    final generation = _generation;
    emit(state.copyWith(loadingMore: true, loadMoreFailed: false));
    final result = await _fetch(url).run();
    if (isClosed || generation != _generation) return;
    switch (result) {
      case Left(:final value):
        handle(value);
        emit(state.copyWith(loadingMore: false, loadMoreFailed: true, failure: LoadFailure.of(value)));
      case Right(:final value):
        final known = state.items.map(_keyOf).toSet();
        emit(
          state.copyWith(
            items: [...state.items, ...value.items.where((e) => !known.contains(_keyOf(e)))],
            nextPageUrl: value.nextPageUrl,
            loadingMore: false,
            failure: null,
          ),
        );
    }
  }
}
