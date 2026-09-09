import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

part 'topics_bloc.mapper.dart';

part 'topics_event.dart';

part 'topics_state.dart';

/// Bloc of topic.
///
/// The group list comes from the `forum.php` document shared with the homepage. Besides its own load and refresh
/// events the bloc re-parses every document published by [ForumHomeRepository] (the homepage refreshes it after a
/// login or an account switch), reloads from the server after a logout, and reloads after a forum was added to or
/// removed from favorites so the "我收藏的版块" panel follows (issues #1, #2).
class TopicsBloc extends Bloc<TopicsEvent, TopicsState> with LoggerMixin {
  /// Constructor.
  ///
  /// [authRefreshGrace] is how long the bloc waits for the homepage to publish a fresh document after the logged
  /// user changed before fetching one itself.
  TopicsBloc({
    required ForumHomeRepository forumHomeRepository,
    required AuthenticationRepository authenticationRepository,
    required FavoriteRepository favoriteRepository,
    Duration authRefreshGrace = const Duration(seconds: 5),
  }) : _forumHomeRepository = forumHomeRepository,
       _authenticationRepository = authenticationRepository,
       _favoriteRepository = favoriteRepository,
       _authRefreshGrace = authRefreshGrace,
       super(const TopicsState()) {
    on<TopicsLoadRequested>(_onTopicsLoadRequested);
    on<TopicsRefreshRequested>(_onTopicsRefreshRequested);
    on<TopicsTabSelected>(_onTopicsTabSelected);
    on<TopicsDocumentUpdated>(_onTopicsDocumentUpdated);
    on<TopicsAuthChanged>(_onTopicsAuthChanged);

    _documentSub = _forumHomeRepository.documentStream.listen((document) => add(TopicsDocumentUpdated(document)));
    _authSub = _authenticationRepository.status.pairwise().listen(
      (statuses) => add(TopicsAuthChanged(prev: statuses.first, curr: statuses.last)),
    );
    _favoriteSub = _favoriteRepository.forumFavoritesChanged.listen(
      (_) => add(const TopicsRefreshRequested(silent: true)),
    );
  }

  final ForumHomeRepository _forumHomeRepository;
  final AuthenticationRepository _authenticationRepository;
  final FavoriteRepository _favoriteRepository;
  final Duration _authRefreshGrace;

  late final StreamSubscription<uh.Document> _documentSub;
  late final StreamSubscription<List<AuthStatus>> _authSub;
  late final StreamSubscription<void> _favoriteSub;

  /// Pending fallback fetch after the logged user changed, cancelled when a document arrives in time.
  Timer? _authRefreshTimer;

  Future<void> _onTopicsLoadRequested(TopicsLoadRequested event, Emitter<TopicsState> emit) async {
    emit(state.copyWith(status: TopicsStatus.loading));
    final documentEither = await _forumHomeRepository.fetchTopicPage().run();
    if (documentEither.isLeft()) {
      handle(documentEither.unwrapErr());
      emit(state.copyWith(status: TopicsStatus.failed));
      return;
    }
    emit(_parse(documentEither.unwrap()));
  }

  Future<void> _onTopicsRefreshRequested(TopicsRefreshRequested event, Emitter<TopicsState> emit) async {
    if (!event.silent) {
      emit(state.copyWith(status: TopicsStatus.loading));
    }

    final documentEither = await _forumHomeRepository.fetchTopicPage(force: true).run();
    if (documentEither.isLeft()) {
      handle(documentEither.unwrapErr());
      if (!event.silent || !state.status.isSuccess) {
        emit(state.copyWith(status: TopicsStatus.failed));
      }
      return;
    }
    emit(_parse(documentEither.unwrap()));
  }

  void _onTopicsTabSelected(TopicsTabSelected event, Emitter<TopicsState> emit) {
    emit(state.copyWith(topicsTab: event.tabIndex));
  }

  void _onTopicsDocumentUpdated(TopicsDocumentUpdated event, Emitter<TopicsState> emit) {
    _authRefreshTimer?.cancel();
    _authRefreshTimer = null;
    emit(_parse(event.document));
  }

  void _onTopicsAuthChanged(TopicsAuthChanged event, Emitter<TopicsState> emit) {
    final curr = event.curr;
    if (curr is AuthStatusNotAuthed) {
      // Logged out: the cached document still belongs to the previous user, show the guest index.
      _authRefreshTimer?.cancel();
      _authRefreshTimer = null;
      add(const TopicsRefreshRequested(silent: true));
      return;
    }
    if (curr is AuthStatusAuthed && event.prev != curr) {
      // Logged in or switched account: the homepage refreshes the shared document and it arrives through
      // [TopicsDocumentUpdated]; fetch one here only when that does not happen in time.
      _authRefreshTimer?.cancel();
      _authRefreshTimer = Timer(_authRefreshGrace, () {
        _authRefreshTimer = null;
        if (!isClosed) {
          add(const TopicsRefreshRequested(silent: true));
        }
      });
    }
  }

  /// Parse the group list and seed the favorite forums cache from the "我收藏的版块" panel, if any.
  TopicsState _parse(uh.Document document) {
    final forumGroupList = buildGroupListFromDocument(document);
    final uid = _authenticationRepository.currentUser?.uid;
    if (uid != null) {
      final favorites = forumGroupList.where((e) => e.isFavorites).expand((e) => e.forumList);
      _favoriteRepository.seedForumFavorites(uid: uid, fids: favorites.map((e) => '${e.forumID}'));
    }
    return state.copyWith(status: TopicsStatus.success, forumGroupList: forumGroupList);
  }

  @override
  Future<void> close() async {
    _authRefreshTimer?.cancel();
    await _documentSub.cancel();
    await _authSub.cancel();
    await _favoriteSub.cancel();
    await super.close();
  }
}
