import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
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
///
/// The shared document is trusted only when it was served to the current user (the user node in its header says
/// so): the cache and the stream replay may still hold the previous account's page after a switch or a logout, and
/// that page must neither be shown nor seed the favorite forums of the new user.
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

  /// The document the current group list was parsed from.
  ///
  /// A fetch of this bloc returns the document and publishes the same instance on the stream: parse it once.
  uh.Document? _shownDocument;

  /// The document ignored for belonging to another user, for which one forced fetch was issued.
  ///
  /// The cache and the stream replay hand out the same instance, so it is recognised when it comes again. Another
  /// document that still does not match is shown (never seeded) instead of fetching forever; the next auth
  /// transition allows one more.
  uh.Document? _staleDocument;

  Future<void> _onTopicsLoadRequested(TopicsLoadRequested event, Emitter<TopicsState> emit) async {
    emit(state.copyWith(status: TopicsStatus.loading));
    final documentEither = await _forumHomeRepository.fetchTopicPage().run();
    if (documentEither.isLeft()) {
      handle(documentEither.unwrapErr());
      emit(state.copyWith(status: TopicsStatus.failed));
      return;
    }
    _emitParsed(documentEither.unwrap(), emit);
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
    _emitParsed(documentEither.unwrap(), emit);
  }

  void _onTopicsTabSelected(TopicsTabSelected event, Emitter<TopicsState> emit) {
    emit(state.copyWith(topicsTab: event.tabIndex));
  }

  void _onTopicsDocumentUpdated(TopicsDocumentUpdated event, Emitter<TopicsState> emit) {
    if (identical(event.document, _shownDocument)) {
      return;
    }
    if (_emitParsed(event.document, emit)) {
      _authRefreshTimer?.cancel();
      _authRefreshTimer = null;
    }
  }

  void _onTopicsAuthChanged(TopicsAuthChanged event, Emitter<TopicsState> emit) {
    final curr = event.curr;
    if (event.prev != curr) {
      // The cached document belongs to the previous user (or guest): a bloc created from now on must go to the
      // server instead of showing it.
      _forumHomeRepository.invalidate();
      _staleDocument = null;
    }
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

  /// Show [document] when it belongs to the current user, otherwise ignore it and fetch a fresh one once.
  ///
  /// Returns whether the document was shown.
  bool _emitParsed(uh.Document document, Emitter<TopicsState> emit) {
    final currentUid = _authenticationRepository.currentUser?.uid;
    final documentUid = parseLoggedUidFromDocument(document);
    if (documentUid != currentUid) {
      if (identical(document, _staleDocument)) {
        return false;
      }
      if (_staleDocument == null) {
        info('forum index of user $documentUid ignored, current user is $currentUid: fetching again');
        _staleDocument = document;
        add(const TopicsRefreshRequested(silent: true));
        return false;
      }
      warning('forum index of user $documentUid shown to user $currentUid, favorite forums not seeded');
    }
    _shownDocument = document;
    emit(_parse(document, seedUid: documentUid));
    return true;
  }

  /// Parse the group list and seed the favorite forums cache of [seedUid] from the "我收藏的版块" panel, if any.
  TopicsState _parse(uh.Document document, {required int? seedUid}) {
    final forumGroupList = buildGroupListFromDocument(document);
    // Enough to tell "the server did not render the panel" from "the parser missed it" from a log alone (#1).
    final favorites = forumGroupList.where((e) => e.isFavorites).expand((e) => e.forumList).map((e) => e.forumID);
    final panelInPage = document.querySelector('div#ct')?.innerHtml?.contains('do=favorite&amp;type=forum') ?? false;
    debug(
      'forum index parsed: ${forumGroupList.length} groups ${forumGroupList.map((e) => e.name).toList()}, '
      'favorite forums $favorites, favorites panel in page: $panelInPage',
    );
    if (seedUid != null && seedUid == _authenticationRepository.currentUser?.uid) {
      final favorites = forumGroupList.where((e) => e.isFavorites).expand((e) => e.forumList);
      _favoriteRepository.seedForumFavorites(uid: seedUid, fids: favorites.map((e) => '${e.forumID}'));
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
