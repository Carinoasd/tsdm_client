import 'dart:async';
import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fpdart/fpdart.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/red_packet/repository/daily_rewards_repository.dart';
import 'package:tsdm_client/features/red_packet/repository/red_packet_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/saved_answer_store.dart';
import 'package:tsdm_client/utils/logger.dart';

/// A repository that fetches the homepage (`forum.php`) from the forum.
///
/// One instance serves the whole app: the homepage tab, the topics tab and the activities page share the same
/// `forum.php` page, so every fetch is published on [pageStream] and both tabs can re-parse it (issue #1: a favorite
/// forum added on the web only showed up after a refresh on the topics tab itself).
///
/// The page is asked in the JSON mode of the forum's app API. An answer of plugin 2.3.0 or later carries the page as
/// structured fields (`schema: 5`) and is kept as such ([ForumHomeApiPage]), its `document` never read (a lean
/// answer, `nodoc=1`, has none); any other answer (a web page from a forum without the plugin, an older plugin's
/// answer, whose `document` holds the blocks of the page) is kept as its document ([ForumHomeWebPage]), parsed as
/// the web page always was.
///
/// Callers that ask while a fetch is on its way for the same session share it ([fetchHomePage]): the homepage and the
/// topics tab loading together cost one request.
///
/// The forum's daily rewards of the account (the daily login visit, the automatic daily red packet) follow the page in
/// the background ([fetchHomePage]); when they change it, the page asked once more replaces it ([pageReplacements]).
///
/// Every structured page fetched is saved for the account it was served to ([SavedAnswerStore]); the next start shows
/// it ([savedPageOf]) while the page is asked again.
///
/// What an answer of an older plugin gives only on the web page is read from the page asked once more without
/// `nodoc=1` ([fetchPageDocument]), in the background, for the page that needs it, and that answer, which carries the
/// `document`, is published as the page:
///
/// * the "我收藏的版块" panel, in the structured answer since plugin 2.8.1 (`favorites`); before, the answer names the
///   viewer's favorite forums by id only, and the topics tab, the only page showing the panel, asks for it
///   ([requestFavoritesPanel]). The homepage never waits for it;
/// * the activity links of 活动专区, in its forum's `description_html` since plugin 2.8.2; before, the answer gives
///   the description as plain text, and the activities page asks for the page with its document.
///
/// **Need to call dispose.**
final class ForumHomeRepository with LoggerMixin {
  /// Constructor.
  ///
  /// [documentTimeout] is how long [fetchPageDocument] waits for the page with its document.
  ///
  /// [savedAnswers] keeps the pages for the next start, the app's store by default (none in tests that register none).
  ForumHomeRepository({this.documentTimeout = const Duration(seconds: 10), SavedAnswerStore? savedAnswers})
    : _savedAnswers = savedAnswers ?? SavedAnswerStore.app;

  /// How long [fetchPageDocument] waits for the page with its document before the page stays without it.
  final Duration documentTimeout;

  final SavedAnswerStore? _savedAnswers;

  final _dailyRewards = DailyRewardsRepository();

  /// Cached page of the forum homepage.
  ForumHomePage? _page;

  /// The fetch on its way, and the session it was asked with: callers asking meanwhile for the same session share it.
  Future<Either<AppException, ForumHomePage>>? _pending;
  _Session? _pendingSession;

  /// The page asked once more with its document ([fetchPageDocument]) and that request, on its way or done: asked once
  /// per page, every caller asking for the same page shares it.
  ({ForumHomeApiPage page, Future<ForumHomeApiPage?> answer})? _documentFetch;

  /// The session each page fetched was asked with.
  final _sessionOfPage = Expando<_Session>();

  /// Every page fetched from the server, the latest one replayed to new listeners.
  final _pageSubject = BehaviorSubject<ForumHomePage>();

  /// Pages replaced in the background by the page asked once more after the daily rewards.
  final _replacements = StreamController<({ForumHomePage previous, ForumHomePage page})>.broadcast();

  /// The daily rewards of the last page fetched, running in the background ([_processDailyRewards]).
  Future<void> _dailyRewardsJob = Future<void>.value();

  /// Stream of every `forum.php` page fetched from the server, in order; a new listener gets the latest one first
  /// when there is any.
  Stream<ForumHomePage> get pageStream => _pageSubject.stream;

  /// Pages the cached page was replaced with in the background, with the page each one replaced: the page asked once
  /// more after the daily login visit or the automatic daily red packet changed it (a new balance, the packet gone).
  /// A page showing `previous` shows `page` instead; it is published on [pageStream] too.
  Stream<({ForumHomePage previous, ForumHomePage page})> get pageReplacements => _replacements.stream;

  /// Completes when the daily rewards of the last page fetched are done (tests).
  @visibleForTesting
  Future<void> get dailyRewardsDone => _dailyRewardsJob;

  /// Check has cached [_page] or not.
  bool hasCache() => _page != null;

  /// Get the cached [_page].
  ForumHomePage? getCache() => _page;

  /// The homepage saved at the last fetch for the account [uid] (null for a guest) and when it was saved, to show while
  /// the page is asked again: null when none is saved, it is older than a day, of an older format, or not served to
  /// [uid] ([SavedAnswerStore]).
  Future<({ForumHomeApiPage page, DateTime savedAt})?> savedPageOf(int? uid) async {
    final saved = await _savedAnswers?.load(SavedAnswerKind.homepage, uid: uid);
    if (saved == null) {
      return null;
    }
    final json = indexApiAnswerOf(saved.answer);
    if (json == null || json['ok'] != 1) {
      return null;
    }
    final page = ForumHomeApiPage(json);
    if (page.servedUid != (uid != null && uid > 0 ? uid : null)) {
      return null;
    }
    return (page: page, savedAt: saved.savedAt);
  }

  /// Save [page], fetched with [session], for the next start: the structured answer of the account it was served to,
  /// without its `document`. A guest page or a login prompt while an account is in use says that account's session is
  /// dead: what was saved for it must not show again.
  void _savePage(ForumHomePage page, _Session session) {
    final store = _savedAnswers;
    if (store == null || page is! ForumHomeApiPage) {
      return;
    }
    final json = page.json;
    final account = session.uid;
    if (json['ok'] == 1) {
      store.save(SavedAnswerKind.homepage, Map.of(json)..remove('document'));
      if (page.servedUid == null && account != null && account > 0) {
        store.forget(account);
      }
    } else if (json['login'] == 1 && account != null && account > 0) {
      store.forget(account);
    }
  }

  /// Drop the cached page so the next fetch goes to the server, and let no later caller share a fetch on its way.
  void invalidate() {
    _page = null;
    _pending = null;
    _pendingSession = null;
    _documentFetch = null;
  }

  /// Release the stream.
  Future<void> dispose() async {
    await _pageSubject.close();
    await _replacements.close();
  }

  /// Fetch the home page of app from server.
  ///
  /// Without [force], the cached page, or the fetch on its way for the session in use now when there is one. A
  /// forced fetch always asks the server: it may follow a change (a favorite added) that a fetch on its way missed.
  ///
  /// The page is answered as soon as it is fetched; the daily rewards of the account follow in the background
  /// ([_processDailyRewards]).
  AsyncEither<ForumHomePage> fetchHomePage({bool force = false}) => AsyncEither(() async {
    debug('fetch home page');
    if (!force && _page != null) {
      debug('use cached home page');
      return right(_page!);
    }
    final session = _sessionNow();
    final pending = _pending;
    if (!force && pending != null && _pendingSession == session) {
      debug('join the home page fetch on its way');
      return pending;
    }
    final fetch = _fetchAndKeep(session);
    _pending = fetch;
    _pendingSession = session;
    try {
      return await fetch;
    } finally {
      if (identical(_pending, fetch)) {
        _pending = null;
        _pendingSession = null;
      }
    }
  });

  /// Fetch the page asked with [session], then keep, publish and save it; the daily rewards of the account follow in
  /// the background.
  ///
  /// # Exception
  ///
  /// * [HttpHandshakeFailedException] if GET request failed.
  /// * [IdentityChangedException] when the account in use changed while the page was asked.
  Future<Either<AppException, ForumHomePage>> _fetchAndKeep(_Session session) async {
    // Keep every follow-up on the same identity-bound client, including after an account switch.
    final client = getIt.get<NetClientProvider>();
    final cookie = getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>() : null;
    final uid = cookie?.userLoginInfo.uid;
    // JSON mode of the forum's app API when the forum has it (see TsdmAppApi); the web page otherwise.
    final pageEither = await _askPage(client);
    final ForumHomePage page;
    switch (pageEither) {
      case Left():
        return pageEither;
      case Right(:final value):
        page = value;
    }
    if (cookie?.userLoginInfo.uid != uid) {
      return left(IdentityChangedException());
    }
    _page = page;
    _sessionOfPage[page] = session;
    if (!_pageSubject.isClosed) {
      _pageSubject.add(page);
    }
    debug('use fetched home page');
    _savePage(page, session);
    _dailyRewardsJob = _processDailyRewards(page, client: client, cookie: cookie, uid: uid, session: session);
    return pageEither;
  }

  /// The daily login visit and the automatic daily red packet of [page], fetched for the account [uid] with [client]
  /// in [session], in the background: the homepage waited for them before (the visit, the claim and a reload of the
  /// page, three more requests before anything showed).
  ///
  /// When the forum credited the visit or the packet was claimed, the page is asked once more and, while the session
  /// is still the one in use and [page] still the cached page, replaces it ([pageReplacements], [pageStream]). Nothing
  /// is visited, claimed or replaced once the account in use changed, and [page] is no longer cached then. Failures are
  /// logged: the page stays.
  Future<void> _processDailyRewards(
    ForumHomePage page, {
    required NetClientProvider client,
    required CookieProvider? cookie,
    required int? uid,
    required _Session session,
  }) async {
    bool isCurrent() => cookie?.userLoginInfo.uid == uid;
    try {
      final refresh = await _dailyRewards.processFields(
        servedUid: page.servedUid,
        visitUri: page.dailyVisitUri,
        packet: page.dailyRedPacket,
        formHash: page.formHash,
        uid: uid,
        isCurrent: isCurrent,
        autoClaimEnabled: () =>
            getIt.isRegistered<SettingsRepository>() &&
            getIt.get<SettingsRepository>().currentSettings.autoDailyRedPacket,
        visit: (uri) async {
          final result = await client.getUri(uri).run();
          return result.fold(
            (_) => false,
            // Stock checknewpm answers an empty JavaScript response. A login/error page is not a successful visit.
            (response) => response.statusCode == 200 && '${response.data ?? ''}'.trim().isEmpty,
          );
        },
        claim: (formHash) async =>
            (await const RedPacketRepository().claimDaily(formHash: formHash, client: client).run()).fold(
              (_) => null,
              (value) => value,
            ),
      );
      if (!isCurrent()) {
        // The account changed while the rewards ran: its page is not handed to the next one (it was not even cached
        // when the page waited for the rewards).
        if (identical(_page, page)) {
          _page = null;
        }
        return;
      }
      if (!refresh) {
        return;
      }
      // Not recursive: one best-effort reload updates the balance and removes the claimed packet entry.
      final updated = await _askPage(client);
      if (updated case Right(value: final next)
          when isCurrent() && next.servedUid == uid && _sessionNow() == session && identical(_page, page)) {
        _page = next;
        _sessionOfPage[next] = session;
        if (!_pageSubject.isClosed) {
          _pageSubject.add(next);
        }
        if (!_replacements.isClosed) {
          _replacements.add((previous: page, page: next));
        }
        _savePage(next, session);
        debug('use home page reloaded after the daily rewards');
      }
    } on Object catch (e) {
      warning('daily rewards homepage reload failed; keep the original page: $e');
    }
  }

  /// Read the "我收藏的版块" panel of [page] from the web page, in the background: for the topics tab, when [page] is an
  /// answer of plugin 2.3.0 to 2.8.0 that names favorite forums without their panel ([favoritesPanelNeedsDocument]).
  ///
  /// The page with its document is asked ([fetchPageDocument]); published on [pageStream], the topics tab reads the
  /// panel from it (`forumGroupsFromApi`). When it fails, [page] stays, and its panel is looked up among the
  /// categories. Nothing is asked for any other page, nor for one that is not the cached page any more (the panel of
  /// the page shown since is asked for that page).
  Future<void> requestFavoritesPanel(ForumHomePage page) async {
    if (page is! ForumHomeApiPage || !favoritesPanelNeedsDocument(page.json) || !identical(page, _page)) {
      return;
    }
    debug('favorite forums without their panel (plugin before 2.8.1): asking the homepage with its document');
    await fetchPageDocument(page);
  }

  /// The structured [page] once more with its `document`, for what an answer of an older plugin gives only on the web
  /// page: the "我收藏的版块" panel before plugin 2.8.1 ([requestFavoritesPanel]), the activity links of 活动专区 before
  /// 2.8.2 (`activitiesNeedDocument`). [page] itself when it has its document already.
  ///
  /// The page is asked once more without `nodoc=1` with the client of the session in use, waiting at most
  /// [documentTimeout]; asked once per page: callers asking for the same page share the request, on its way or done.
  /// The answer is given only when it is the structured page served to the account [page] was served to and the
  /// session [page] was asked with is still the one in use; null otherwise, when it fails, and without asking when
  /// the session changed since [page] was fetched (or [page] was not fetched here). A page another fetch replaced
  /// meanwhile in the same session (the homepage refreshed while the activities page was loading) is asked for all
  /// the same; only when [page] is still the cached page is the answer cached and published on [pageStream] in its
  /// place.
  Future<ForumHomeApiPage?> fetchPageDocument(ForumHomeApiPage page) {
    if (page.json['document'] is String) {
      return Future.value(page);
    }
    final asked = _documentFetch;
    if (asked != null && identical(asked.page, page)) {
      return asked.answer;
    }
    final session = _sessionNow();
    if (_sessionOfPage[page] != session) {
      return Future.value();
    }
    final answer = _askPageDocument(page, session);
    _documentFetch = (page: page, answer: answer);
    return answer;
  }

  /// Ask the page with its document for [page], asked with [session], see [fetchPageDocument].
  Future<ForumHomeApiPage?> _askPageDocument(ForumHomeApiPage page, _Session session) async {
    final Either<AppException, ForumHomePage> answer;
    try {
      answer = await _askPage(getIt.get<NetClientProvider>(), withDocument: true).timeout(documentTimeout);
    } on TimeoutException {
      warning('homepage with its document timed out');
      return null;
    } on Object catch (e) {
      warning('homepage with its document failed: $e');
      return null;
    }
    final ForumHomeApiPage full;
    switch (answer) {
      case Right(value: final ForumHomeApiPage value) when value.json['ok'] == 1 && value.servedUid == page.servedUid:
        full = value;
      case Right(:final value):
        warning('homepage with its document is another page (served to ${value.servedUid}), not taken');
        return null;
      case Left(:final value):
        warning('homepage with its document failed: $value');
        return null;
    }
    if (_sessionNow() != session) {
      debug('homepage with its document dropped: the session changed meanwhile');
      return null;
    }
    _sessionOfPage[full] = session;
    if (identical(page, _page)) {
      _page = full;
      if (!_pageSubject.isClosed) {
        _pageSubject.add(full);
      }
    }
    return full;
  }

  /// Fetch the topic page of app from server.
  ///
  /// The topics tab shows the same `forum.php` as the homepage, so this is the same cache and the same fetch.
  AsyncEither<ForumHomePage> fetchTopicPage({bool force = false}) => fetchHomePage(force: force);

  /// The [homePage] asked in the JSON mode without [tsdmAppNodocQuery]: the answer keeps its `document`.
  static const _homePageWithDocument = '$homePage?$tsdmAppJsonQuery';

  /// Ask [client] for the [homePage] once: the structured answer of plugin 2.3.0 ([indexApiAnswerOf]), or the
  /// document of any other answer. Lean (`nodoc=1`), or with its `document` when [withDocument].
  ///
  /// An answer without a page ([tsdmAppAnswerWithoutPage]: the plugin failed to build it, or an empty body) is a
  /// failed request, not a forum without boards.
  static Future<Either<AppException, ForumHomePage>> _askPage(
    NetClientProvider client, {
    bool withDocument = false,
  }) async {
    switch (await client.get(withDocument ? _homePageWithDocument : withTsdmAppJson(homePage)).run()) {
      case Left(:final value):
        return left(value);
      case Right(:final value):
        if (value.statusCode != HttpStatus.ok) {
          return left(HttpRequestFailedException(value.statusCode));
        }
        final api = indexApiAnswerOf(value.data);
        if (api != null) {
          return right(ForumHomeApiPage(api));
        }
        if (tsdmAppAnswerWithoutPage(value.data)) {
          return left(HttpRequestFailedException(value.statusCode));
        }
        // A JSON answer kept as its document (an older plugin's, the cached guest index of plugin 2.3.0) may name
        // the checknewpm script its blocks do not hold.
        final checknewpm = tsdmAppAnswerJson(value.data)?['checknewpm'];
        return right(
          ForumHomeWebPage(tsdmAppPageDocument(value.data), checknewpm: checknewpm is String ? checknewpm : null),
        );
    }
  }
}

/// The account the global cookie names and the session of it it holds ([CookieProvider.generation]); null fields
/// without a cookie provider (tests).
typedef _Session = ({int? uid, int? generation});

/// The session in use now.
_Session _sessionNow() {
  final cookie = getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>() : null;
  return (uid: cookie?.userLoginInfo.uid, generation: cookie?.generation);
}
