import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'topics_bloc.mapper.dart';

part 'topics_event.dart';

part 'topics_state.dart';

/// Bloc of topic.
///
/// The group list comes from the `forum.php` page shared with the homepage: the web page parsed as before
/// ([buildGroupListFromDocument]), or the structured answer of the forum's app API (plugin 2.3.0, `schema: 5`) built
/// from its categories ([forumGroupsFromApi]). Besides its own load and refresh events the bloc re-parses every page
/// published by [ForumHomeRepository] (the homepage refreshes it after a login or an account switch), reloads from
/// the server after a logout, and reloads after a forum was added to or removed from favorites so the "我收藏的版块"
/// panel follows (issues #1, #2).
///
/// The shared page is trusted only when it was served to the current user (the user node in the header of the web
/// page, the `uid` of the structured answer): the cache and the stream replay may still hold the previous account's
/// page after a switch or a logout, and that page must neither be shown nor seed the favorite forums of the new
/// user.
///
/// The "我收藏的版块" panel of a plugin before 2.8.1 is only on the web page: the bloc asks the repository for it
/// ([ForumHomeRepository.requestFavoritesPanel]) for the pages it loads itself, and the page with the panel arrives
/// on the stream. A page another one fetched (the homepage refreshed it, checked the daily red packet, the activities
/// page) shows the panel last read for the account instead while it names the same favorites, so those cost no
/// request for the panel.
class TopicsBloc extends Bloc<TopicsEvent, TopicsState> with LoggerMixin {
  /// Constructor.
  ///
  /// [authRefreshGrace] is how long the bloc waits for the homepage to publish a fresh page after the logged user
  /// changed before fetching one itself.
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
    on<TopicsPageUpdated>(_onTopicsPageUpdated);
    on<TopicsAuthChanged>(_onTopicsAuthChanged);

    _pageSub = _forumHomeRepository.pageStream.listen((page) => add(TopicsPageUpdated(page)));
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

  late final StreamSubscription<ForumHomePage> _pageSub;
  late final StreamSubscription<List<AuthStatus>> _authSub;
  late final StreamSubscription<void> _favoriteSub;

  /// Pending fallback fetch after the logged user changed, cancelled when a page arrives in time.
  Timer? _authRefreshTimer;

  /// The page the current group list was parsed from.
  ///
  /// A fetch of this bloc returns the page and publishes the same instance on the stream: parse it once.
  ForumHomePage? _shownPage;

  /// The page ignored for belonging to another user, for which one forced fetch was issued.
  ///
  /// The cache and the stream replay hand out the same instance, so it is recognised when it comes again. Another
  /// page that still does not match is shown (never seeded) instead of fetching forever; the next auth transition
  /// allows one more.
  ForumHomePage? _stalePage;

  /// The "我收藏的版块" panel last read from the web page (plugin before 2.8.1) and the account it was served to, see
  /// [TopicsBloc].
  ({int uid, ForumGroup panel})? _pagePanel;

  Future<void> _onTopicsLoadRequested(TopicsLoadRequested event, Emitter<TopicsState> emit) async {
    emit(state.copyWith(status: TopicsStatus.loading, failure: null));
    final pageEither = await _forumHomeRepository.fetchTopicPage().run();
    if (pageEither.isLeft()) {
      final e = pageEither.unwrapErr();
      handle(e);
      emit(state.copyWith(status: TopicsStatus.failed, failure: LoadFailure.of(e)));
      return;
    }
    _emitParsed(pageEither.unwrap(), emit, own: true);
  }

  Future<void> _onTopicsRefreshRequested(TopicsRefreshRequested event, Emitter<TopicsState> emit) async {
    // A refresh the user asked for keeps the groups on screen while it runs, and when it fails (the page says so).
    final shown = state.status.isSuccess && state.forumGroupList.isNotEmpty;
    if (!event.silent) {
      emit(
        shown
            ? state.copyWith(refreshing: true, failure: null)
            : state.copyWith(status: TopicsStatus.loading, failure: null),
      );
    }

    final pageEither = await _forumHomeRepository.fetchTopicPage(force: true).run();
    if (pageEither.isLeft()) {
      final e = pageEither.unwrapErr();
      handle(e);
      if (!event.silent && shown) {
        emit(state.copyWith(refreshing: false, failure: LoadFailure.of(e)));
      } else if (!event.silent || !state.status.isSuccess) {
        emit(state.copyWith(status: TopicsStatus.failed, refreshing: false, failure: LoadFailure.of(e)));
      }
      return;
    }
    if (!_emitParsed(pageEither.unwrap(), emit, own: true) && !event.silent && state.refreshing) {
      // The page belonged to another account and is asked again silently: the pull itself is over.
      emit(state.copyWith(refreshing: false));
    }
  }

  void _onTopicsTabSelected(TopicsTabSelected event, Emitter<TopicsState> emit) {
    emit(state.copyWith(topicsTab: event.tabIndex));
  }

  void _onTopicsPageUpdated(TopicsPageUpdated event, Emitter<TopicsState> emit) {
    if (identical(event.page, _shownPage)) {
      return;
    }
    if (_emitParsed(event.page, emit, own: false)) {
      _authRefreshTimer?.cancel();
      _authRefreshTimer = null;
    }
  }

  void _onTopicsAuthChanged(TopicsAuthChanged event, Emitter<TopicsState> emit) {
    final curr = event.curr;
    if (event.prev != curr) {
      // The cached page belongs to the previous user (or guest): a bloc created from now on must go to the server
      // instead of showing it.
      _forumHomeRepository.invalidate();
      _stalePage = null;
      _pagePanel = null;
    }
    if (curr is AuthStatusNotAuthed) {
      // Logged out: the cached page still belongs to the previous user, show the guest index.
      _authRefreshTimer?.cancel();
      _authRefreshTimer = null;
      add(const TopicsRefreshRequested(silent: true));
      return;
    }
    if (curr is AuthStatusAuthed && event.prev != curr) {
      // Logged in or switched account: the homepage refreshes the shared page and it arrives through
      // [TopicsPageUpdated]; fetch one here only when that does not happen in time.
      _authRefreshTimer?.cancel();
      _authRefreshTimer = Timer(_authRefreshGrace, () {
        _authRefreshTimer = null;
        if (!isClosed) {
          add(const TopicsRefreshRequested(silent: true));
        }
      });
    }
  }

  /// Show [page] when it belongs to the current user, otherwise ignore it and fetch a fresh one once. [own] tells a
  /// page the bloc loaded itself from one another one fetched.
  ///
  /// Returns whether the page was shown.
  bool _emitParsed(ForumHomePage page, Emitter<TopicsState> emit, {required bool own}) {
    final currentUid = _authenticationRepository.currentUser?.uid;
    final pageUid = page.servedUid;
    if (pageUid != currentUid) {
      if (identical(page, _stalePage)) {
        return false;
      }
      if (_stalePage == null) {
        info('forum index of user $pageUid ignored, current user is $currentUid: fetching again');
        _stalePage = page;
        add(const TopicsRefreshRequested(silent: true));
        return false;
      }
      warning('forum index of user $pageUid shown to user $currentUid, favorite forums not seeded');
    }
    _shownPage = page;
    emit(_parse(page, seedUid: pageUid, own: own));
    return true;
  }

  /// Parse the group list and seed the favorite forums cache of [seedUid] from the "我收藏的版块" panel, if any.
  ///
  /// The web page: the panel's forums are the favorites. The structured answer: `favorite_forums` names every
  /// favorite, among them one the panel may not list (its `favorites` since plugin 2.8.1, before that read from the
  /// page or looked up among the categories, [forumGroupsFromApi]).
  TopicsState _parse(ForumHomePage page, {required int? seedUid, required bool own}) {
    final trusted = seedUid != null && seedUid == _authenticationRepository.currentUser?.uid;
    final List<ForumGroup> forumGroupList;
    final Iterable<int> favorites;
    final bool panelInPage;
    switch (page) {
      case ForumHomeWebPage(:final document):
        forumGroupList = buildGroupListFromDocument(document);
        favorites = forumGroupList.where((e) => e.isFavorites).expand((e) => e.forumList).map((e) => e.forumID);
        // Enough to tell "the server did not render the panel" from "the parser missed it" from a log alone (#1).
        panelInPage = document.querySelector('div#ct')?.innerHtml?.contains('do=favorite&amp;type=forum') ?? false;
      case ForumHomeApiPage(:final json):
        final groups = forumGroupsFromApi(json);
        forumGroupList = trusted ? _withPagePanel(page, groups, uid: seedUid, own: own) : groups;
        favorites = favoriteForumIdsOf(json);
        panelInPage = favorites.isNotEmpty;
    }
    debug(
      'forum index parsed: ${forumGroupList.length} groups ${forumGroupList.map((e) => e.name).toList()}, '
      'favorite forums $favorites, favorites panel in page: $panelInPage',
    );
    if (trusted) {
      _favoriteRepository.seedForumFavorites(uid: seedUid, fids: favorites.map((e) => '$e'));
    }
    return state.copyWith(
      status: TopicsStatus.success,
      forumGroupList: forumGroupList,
      refreshing: false,
      failure: null,
    );
  }

  /// The [groups] of the structured [page] served to the current user [uid], with the "我收藏的版块" panel of a plugin
  /// before 2.8.1, which is only on the web page ([favoritesPanelNeedsDocument]):
  ///
  /// * a page with its document (the repository read the panel from it) is kept as the account's panel;
  /// * a page without it shows the panel kept for the account while it names the same favorites in the same order
  ///   (otherwise the panel looked up among the categories), and asks the repository for its own when the bloc loaded
  ///   the page itself ([own]) or no kept panel fits.
  List<ForumGroup> _withPagePanel(
    ForumHomeApiPage page,
    List<ForumGroup> groups, {
    required int uid,
    required bool own,
  }) {
    final json = page.json;
    if (!favoritesPanelNeedsDocument(json)) {
      if (json['document'] is String && !json.containsKey('favorites')) {
        final panel = groups.firstWhereOrNull((e) => e.isFavorites);
        _pagePanel = panel == null ? null : (uid: uid, panel: panel);
      }
      return groups;
    }
    final kept = _pagePanel;
    final fits =
        kept != null &&
        kept.uid == uid &&
        const ListEquality<int>().equals(kept.panel.forumList.map((e) => e.forumID).toList(), favoriteForumIdsOf(json));
    if (own || !fits) {
      unawaited(_forumHomeRepository.requestFavoritesPanel(page));
    }
    if (!fits) {
      return groups;
    }
    return [kept.panel, ...groups.where((e) => !e.isFavorites)];
  }

  @override
  Future<void> close() async {
    _authRefreshTimer?.cancel();
    await _pageSub.cancel();
    await _authSub.cancel();
    await _favoriteSub.cancel();
    await super.close();
  }
}
