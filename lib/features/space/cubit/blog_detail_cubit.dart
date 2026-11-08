import 'package:bloc/bloc.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/space/cubit/space_list_cubit.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/logger.dart';

/// State of [BlogDetailCubit].
final class BlogDetailState {
  /// Constructor.
  const BlogDetailState({
    this.status = SpaceLoadStatus.loading,
    this.blog,
    this.comments = const [],
    this.nextCommentsUrl,
    this.loadingMore = false,
    this.loadMoreFailed = false,
    this.failure,
  });

  /// Where the page is.
  final SpaceLoadStatus status;

  /// The blog as its first page gave it; its [SpaceBlogDetail.message] for [SpaceLoadStatus.notice].
  final SpaceBlogDetail? blog;

  /// The comments loaded so far, page after page.
  final List<SpaceBlogComment> comments;

  /// The next page of comments, null after the last one.
  final String? nextCommentsUrl;

  /// Loading the next page of comments.
  final bool loadingMore;

  /// The next page of comments failed.
  final bool loadMoreFailed;

  /// Why the last load failed.
  final LoadFailure? failure;
}

/// A blog and its comments, page after page.
final class BlogDetailCubit extends Cubit<BlogDetailState> with LoggerMixin {
  /// Constructor.
  BlogDetailCubit({required String url, required AsyncEither<SpaceBlogDetail> Function(String url) fetch})
    : _url = url,
      _fetch = fetch,
      super(const BlogDetailState());

  final String _url;
  final AsyncEither<SpaceBlogDetail> Function(String url) _fetch;
  int _generation = 0;

  /// Load the blog and its first page of comments.
  Future<void> load() async {
    final generation = ++_generation;
    final shown = state.status == SpaceLoadStatus.success;
    if (!shown) emit(const BlogDetailState());
    final result = await _fetch(_url).run();
    if (isClosed || generation != _generation) return;
    switch (result) {
      case Left(:final value):
        handle(value);
        emit(
          BlogDetailState(
            status: shown ? SpaceLoadStatus.success : SpaceLoadStatus.failure,
            blog: shown ? state.blog : null,
            comments: shown ? state.comments : const [],
            nextCommentsUrl: shown ? state.nextCommentsUrl : null,
            failure: LoadFailure.of(value),
          ),
        );
      case Right(:final value) when value.needLogin:
        emit(BlogDetailState(status: SpaceLoadStatus.needLogin, blog: value));
      case Right(:final value) when value.content == null:
        emit(BlogDetailState(status: SpaceLoadStatus.notice, blog: value));
      case Right(:final value):
        emit(
          BlogDetailState(
            status: SpaceLoadStatus.success,
            blog: value,
            comments: value.comments,
            nextCommentsUrl: value.nextCommentsUrl,
          ),
        );
    }
  }

  /// Load the next page of comments.
  Future<void> loadMore() async {
    final url = state.nextCommentsUrl;
    if (url == null || state.loadingMore || state.status != SpaceLoadStatus.success) return;
    final generation = _generation;
    emit(_with(loadingMore: true));
    final result = await _fetch(url).run();
    if (isClosed || generation != _generation) return;
    switch (result) {
      case Left(:final value):
        handle(value);
        emit(_with(loadMoreFailed: true, failure: LoadFailure.of(value)));
      case Right(:final value):
        final known = state.comments.map((e) => e.cid).toSet();
        emit(
          BlogDetailState(
            status: SpaceLoadStatus.success,
            blog: state.blog,
            comments: [...state.comments, ...value.comments.where((e) => !known.contains(e.cid))],
            nextCommentsUrl: value.nextCommentsUrl,
          ),
        );
    }
  }

  BlogDetailState _with({bool loadingMore = false, bool loadMoreFailed = false, LoadFailure? failure}) =>
      BlogDetailState(
        status: state.status,
        blog: state.blog,
        comments: state.comments,
        nextCommentsUrl: state.nextCommentsUrl,
        loadingMore: loadingMore,
        loadMoreFailed: loadMoreFailed,
        failure: failure,
      );
}
