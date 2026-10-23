import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:collection/collection.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/homepage/models/models.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/profile/utils/parse_profile.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

part 'homepage_bloc.mapper.dart';
part 'homepage_event.dart';
part 'homepage_state.dart';
part 'homepage_state_from_api.dart';

/// What a page was asked as: the account the global cookie named and the identity epoch
/// (`AuthenticationRepository.identityEpoch`) when it was asked.
typedef _AskedAs = ({int? uid, int epoch});

/// Bloc for the homepage of the app.
class HomepageBloc extends Bloc<HomepageEvent, HomepageState> with LoggerMixin {
  /// Constructor.
  HomepageBloc({
    required ForumHomeRepository forumHomeRepository,
    required ProfileRepository profileRepository,
    required AuthenticationRepository authenticationRepository,
  }) : _forumHomeRepository = forumHomeRepository,
       _profileRepository = profileRepository,
       _authenticationRepository = authenticationRepository,
       super(
         forumHomeRepository.hasCache()
             ? _parseState(
                 forumHomeRepository.getCache()!,
                 authenticationRepository.currentUser?.username,
                 avatarUrl: profileRepository.getCache()?.avatarUrl,
               )
             : const HomepageState(),
       ) {
    on<HomepageLoadRequested>(_onHomepageLoadRequested);
    on<HomepageRefreshRequested>(_onHomepageRefreshRequested);
    on<HomepageDailyRedPacketCheckRequested>(_onDailyRedPacketCheckRequested);
    on<HomepageAuthChanged>(_onHomepageAuthChanged);
    on<HomepagePauseSwiper>(_onHomepagePauseSwiper);
    on<HomepageResumeSwiper>(_onHomepageResumeSwiper);

    // Every status from now on, the first one too (a switch may be the first status of the run: the stored login of
    // the account the app started with was never verified); the one the stream replays to this new listener ended
    // before, it is no change.
    final replayed = _authenticationRepository.latestStatus;
    var previous = replayed;
    var first = true;
    _authStatusSub = _authenticationRepository.status.listen((status) {
      final isReplay = first && replayed != null && identical(status, replayed);
      first = false;
      if (isReplay) {
        return;
      }
      add(HomepageAuthChanged(prev: previous, curr: status));
      previous = status;
    });
  }

  final ForumHomeRepository _forumHomeRepository;
  final ProfileRepository _profileRepository;

  /// Do not dispose this repo because it is not the owner.
  final AuthenticationRepository _authenticationRepository;
  late final StreamSubscription<AuthStatus> _authStatusSub;

  /// Bumped whenever the whole page is loaded again or the account changes; a load, a refresh or a daily red packet
  /// check that finishes under another generation is stale: what it brings is dropped, the newer one shows.
  int _pageGeneration = 0;

  /// The account the page is loaded (or being loaded) for: the account whose cookie asked for it, then the account it
  /// was served to. A login of another account (an account switch, the first status of the run included) reloads the
  /// page; a login of this one (the page's own record of its account) does not.
  int? _loadedFor;

  /// Build the swiper picture list from the `Kahrpba` plugin block.
  ///
  /// The plugin is gone since Discuz X5 so the node is usually null, returns an empty list silently.
  static List<String?> _buildKahrpbaPicUrlList(uh.Element? styleNode) {
    if (styleNode == null) {
      return [];
    }

    return styleNode
        .innerHtmlEx()
        .split('\n')
        .where((e) => e.startsWith('.Kahrpba_pic_') && !e.contains('ctrlbtn'))
        .map((e) => e.split('(').lastOrNull?.split(')').firstOrNull)
        .toList();
  }

  /// Build the swiper link list from the `Kahrpba` plugin block.
  ///
  /// The plugin is gone since Discuz X5 so the node is usually null, returns an empty list silently.
  static List<String?> _buildKahrpbaPicHrefList(uh.Element? scriptNode) {
    if (scriptNode == null) {
      return [];
    }

    return scriptNode
        .innerHtmlEx()
        .split('\n')
        .where((e) => e.contains("window.location='"))
        .map((e) => e.split("window.location='").lastOrNull?.split("'").firstOrNull?.replaceFirst('&amp;', '&'))
        .toList();
  }

  /// The tabs of the homepage block of the `Kahrpba` plugin read from the web page: [parsePinnedThreadGroups] of
  /// the homepage API helpers, kept here for the tests of the page parser.
  static List<PinnedThreadGroup> parsePinnedThreadGroups(uh.Document document) =>
      parsePinnedThreadGroupsFromDocument(document);

  /// Tell the authentication repository the account [page] was served to, as `loginWithDocument` reads it from
  /// the web page: the structured answer names it in `user`. [asked] is the account whose cookie asked for it and the
  /// identity epoch then ([_askedAs] before the fetch): a page that arrives after the session changed (a switch, a
  /// login, a logout) records nothing ([IdentityChangedException]); the page is loaded again.
  AsyncVoidEither _loginWithPage(ForumHomePage page, {required _AskedAs asked}) => switch (page) {
    ForumHomeWebPage(:final document) => _authenticationRepository.loginWithDocument(
      document,
      fetchedAs: asked.uid,
      epoch: asked.epoch,
    ),
    ForumHomeApiPage(:final json) => _authenticationRepository.loginWithServedUser(
      servedUserOf(json),
      guest: indexAnswerIsGuest(json),
      fetchedAs: asked.uid,
      epoch: asked.epoch,
    ),
  };

  /// The account the global cookie names now (null when none, or no provider in tests) and the identity epoch now: what
  /// a page asked now is asked as.
  _AskedAs _askedAs() => (
    uid: getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>().userLoginInfo.uid : null,
    epoch: _authenticationRepository.identityEpoch,
  );

  /// The account [page] was served to, null for a guest or when it does not tell.
  static int? _servedUidOf(ForumHomePage page) => switch (page) {
    ForumHomeWebPage(:final document) => parseLoggedUidFromDocument(document),
    ForumHomeApiPage(:final json) => servedUserOf(json)?.uid,
  };

  /// Record the account [page] was served to, [asked] as an account and under an identity epoch ([_askedAs]), for the
  /// load of [generation]; false when the page must not be shown: the session changed since it was asked
  /// ([IdentityChangedException]) or a newer load took over. On a change no newer load picked up yet, a refresh for the account in use now is asked here: the page never
  /// stays loading.
  Future<bool> _recordAccountOf(ForumHomePage page, {required _AskedAs asked, required int generation}) async {
    if (generation == _pageGeneration) {
      _loadedFor = _servedUidOf(page) ?? asked.uid;
    }
    final login = await _loginWithPage(page, asked: asked).run();
    if (login case Left(value: IdentityChangedException())) {
      debug('homepage served to the previous account, dropped');
      if (generation == _pageGeneration) {
        add(HomepageRefreshRequested());
      }
      return false;
    }
    login.mapLeft(handle);
    return generation == _pageGeneration;
  }

  Future<void> _onHomepageLoadRequested(HomepageLoadRequested event, Emitter<HomepageState> emit) async {
    final generation = ++_pageGeneration;
    if (_forumHomeRepository.hasCache()) {
      final s = _parseState(
        _forumHomeRepository.getCache()!,
        _authenticationRepository.currentUser?.username,
        avatarUrl: state.loggedUserInfo?.avatarUrl,
      );
      emit(s);
      return;
    }
    // Clear data.
    emit(const HomepageState(status: HomepageStatus.loading));
    var needLogin = false;
    // A request dropped: the account or its session changed while it was on its way (a login with the password of
    // the same account too, which reloads nothing by itself).
    var identityChanged = false;
    AppException? failed;
    final asked = _askedAs();
    _loadedFor = asked.uid;
    final respList = (await Future.wait([
      _forumHomeRepository.fetchHomePage().mapLeft((e) {
        if (e case HttpHandshakeFailedException(:final statusCode)) {
          if (statusCode == 200) {
            needLogin = true;
          }
        } else if (e case LoginUserInfoNotFoundException()) {
          needLogin = true;
        } else if (e case IdentityChangedException()) {
          identityChanged = true;
        } else {
          failed ??= e;
          handle(e);
        }
      }).run(),
      _profileRepository.fetchAvatarUrl().mapLeft((e) {
        switch (e) {
          case LoginUserInfoNotFoundException() || ProfileNeedLoginException():
            needLogin = true;
          case IdentityChangedException():
            identityChanged = true;
          default:
            failed ??= e;
            handle(e);
        }
      }).run(),
    ])).where((e) => e.isRight()).map((e) => e.unwrap()).toList();
    if (generation != _pageGeneration) {
      // A newer load (an account change) took over: it shows the page.
      return;
    }
    if (identityChanged) {
      // Load it for the session in use now.
      add(HomepageRefreshRequested());
      return;
    }
    if (respList.length != 2) {
      if (_authenticationRepository.currentUser == null && needLogin) {
        emit(state.copyWith(status: HomepageStatus.needLogin));
        return;
      } else {
        emit(state.copyWith(status: HomepageStatus.failure, failure: LoadFailure.of(failed)));
        return;
      }
    }
    final page = respList[0] as ForumHomePage;
    final avatarUrl = respList[1] as String;
    if (!await _recordAccountOf(page, asked: asked, generation: generation)) {
      return;
    }
    // Parse data and change state.
    final s = _parseState(page, _authenticationRepository.currentUser?.username, avatarUrl: avatarUrl);
    emit(s);
  }

  Future<void> _onHomepageRefreshRequested(HomepageRefreshRequested event, Emitter<HomepageState> emit) async {
    final generation = ++_pageGeneration;
    // Clear data.
    emit(const HomepageState(status: HomepageStatus.loading));

    final asked = _askedAs();
    _loadedFor = asked.uid;
    final fetched = await _forumHomeRepository.fetchHomePage(force: true).run();
    if (generation != _pageGeneration) {
      // A newer load (an account change) took over: it shows the page.
      return;
    }
    switch (fetched) {
      case Left(value: IdentityChangedException()):
        // The account changed while the page was fetched: load it for the account in use now.
        add(HomepageRefreshRequested());
      case Left(:final value):
        handle(value);
        debug('failed to fetch dom: $value');
        emit(state.copyWith(status: HomepageStatus.failure, failure: LoadFailure.of(value)));
      case Right(:final value):
        if (!await _recordAccountOf(value, asked: asked, generation: generation)) {
          return;
        }
        final loggedUser = _authenticationRepository.currentUser;
        if (loggedUser == null) {
          emit(const HomepageState(status: HomepageStatus.needLogin));
          return;
        }
        final d2 = await _profileRepository.fetchProfile(force: true).run();
        if (generation != _pageGeneration) {
          return;
        }
        if (d2 case Left(value: IdentityChangedException())) {
          // The session changed while the profile was fetched: load the page for the one in use now.
          add(HomepageRefreshRequested());
          return;
        }
        if (d2.isLeft()) {
          handle(d2.unwrapErr());
          emit(state.copyWith(status: HomepageStatus.failure, failure: LoadFailure.of(d2.unwrapErr())));
          return;
        }
        final avatarUrl = d2.unwrap().avatarUrl;
        // Parse data and change state.
        final s = _parseState(value, _authenticationRepository.currentUser?.username, avatarUrl: avatarUrl);
        emit(s);
    }
  }

  /// Ask the forum again for today's daily red packet only (its entry on the greeting card had none).
  ///
  /// The homepage is fetched like a refresh does (same identity checks and daily rewards handling in
  /// [ForumHomeRepository]), but only [HomepageState.dailyRedPacket] and [HomepageState.formHash] change: the loaded
  /// page stays on screen, nothing else is reloaded. The answer is dropped when the page was reloaded or the account
  /// changed meanwhile, or when the page belongs to another account.
  Future<void> _onDailyRedPacketCheckRequested(
    HomepageDailyRedPacketCheckRequested event,
    Emitter<HomepageState> emit,
  ) async {
    final uid = _authenticationRepository.currentUser?.uid;
    if (uid == null || state.status != HomepageStatus.success || state.checkingDailyRedPacket) {
      return;
    }
    final generation = _pageGeneration;
    bool stillCurrent() =>
        generation == _pageGeneration &&
        state.status == HomepageStatus.success &&
        _authenticationRepository.currentUser?.uid == uid;

    emit(state.copyWith(checkingDailyRedPacket: true));
    final result = await _forumHomeRepository.fetchHomePage(force: true).run();
    if (!stillCurrent()) {
      debug('drop the daily red packet check for uid $uid: the page or the account changed meanwhile');
      if (state.checkingDailyRedPacket) {
        emit(state.copyWith(checkingDailyRedPacket: false));
      }
      return;
    }
    switch (result) {
      case Left(:final value):
        handle(value);
        emit(state.copyWith(checkingDailyRedPacket: false));
      case Right(:final value) when value.servedUid != uid:
        debug('drop the daily red packet check for uid $uid: the page belongs to another account');
        emit(state.copyWith(checkingDailyRedPacket: false));
      case Right(:final value):
        emit(
          state.copyWith(checkingDailyRedPacket: false, dailyRedPacket: value.dailyRedPacket, formHash: value.formHash),
        );
    }
  }

  Future<void> _onHomepageAuthChanged(HomepageAuthChanged event, Emitter<HomepageState> emit) async {
    switch (event.curr) {
      case AuthStatusNotAuthed():
        if (event.prev != event.curr) {
          _pageGeneration++;
          _loadedFor = null;
          // The cached `forum.php` was served to the previous user; nobody may show it again.
          _forumHomeRepository.invalidate();
        }
        if (state.status != HomepageStatus.needLogin) {
          // Start from a clean state: keeping the old `loggedUserInfo` would leave the avatar and the logged-in
          // actions in the app bar after logging out. Also while loading: that load is stale now and shows nothing.
          emit(const HomepageState(status: HomepageStatus.needLogin));
        }
      case AuthStatusAuthed(:final userInfo) when userInfo.uid != _loadedFor:
        // Another account than the page is (being) loaded for, the first status of the run included (a switch
        // before the stored login was verified): the cached `forum.php` was served to the previous one (or a guest),
        // nobody may show it again, and the forced refresh below can fail (rate limit, offline), so drop it now.
        _pageGeneration++;
        _forumHomeRepository.invalidate();
        add(HomepageRefreshRequested(userLoginInfo: userInfo));
      case AuthStatusAuthed(:final userInfo)
          when state.status == HomepageStatus.needLogin || state.status == HomepageStatus.failure:
        // The same account logged in again after the page failed or asked for a login.
        add(HomepageRefreshRequested(userLoginInfo: userInfo));
      case AuthStatusAuthed() || AuthStatusLoading() || AuthStatusUnknown():
        break;
    }
  }

  Future<void> _onHomepagePauseSwiper(HomepagePauseSwiper event, Emitter<HomepageState> emit) async {
    emit(state.copyWith(scrollSwiper: false));
  }

  Future<void> _onHomepageResumeSwiper(HomepageResumeSwiper event, Emitter<HomepageState> emit) async {
    emit(state.copyWith(scrollSwiper: true));
  }

  /// [_parseStateFromDocument] for tests comparing two answers of the same page.
  @visibleForTesting
  static HomepageState parseStateForTest(uh.Document document, String? username, {String? avatarUrl}) =>
      _parseStateFromDocument(document, username, avatarUrl: avatarUrl);

  /// The state of [page], for the account [username] with the avatar [avatarUrl] the app has: the web page parsed
  /// as before ([_parseStateFromDocument]), the structured answer of the forum's app API built from its fields
  /// ([homepageStateFromApi]).
  static HomepageState _parseState(ForumHomePage page, String? username, {String? avatarUrl}) => switch (page) {
    ForumHomeWebPage(:final document) => _parseStateFromDocument(document, username, avatarUrl: avatarUrl),
    ForumHomeApiPage(:final json) => homepageStateFromApi(json, username, avatarUrl: avatarUrl),
  };

  static HomepageState _parseStateFromDocument(uh.Document document, String? username, {String? avatarUrl}) {
    final swiperUrlList = <SwiperUrl>[];
    final pinnedThreadGroupList = <PinnedThreadGroup>[];
    ForumStatus? forumStatus;
    LoggedUserInfo? loggedUserInfo;

    final chartZNode = document.querySelector('p.chart.z');
    // TODO: Refactor with style repository here.
    final styleNode =
        // Style 1: Without welcome text.
        document.querySelector('div.mn > style') ??
        // Style 2: With welcome text.
        document.querySelector('div#chart > style');
    final scriptNode =
        // Style 1: Without welcome text.
        document.querySelector('div.mn > script') ??
        // Style 2: With welcome text
        document.querySelector('div#chart > script');

    final picUrlList = _buildKahrpbaPicUrlList(styleNode).whereType<String>().toList();
    final picHrefList = _buildKahrpbaPicHrefList(scriptNode).whereType<String>().toList();
    if ((picUrlList.isEmpty && picHrefList.isEmpty) || (picUrlList.length != picHrefList.length)) {
      // The Kahrpba swiper block is gone since Discuz X5, an empty swiper list is the expected result now.
      talker.debug('homepage swiper block not found, skip');
    } else {
      for (var i = 0; i < picUrlList.length; i++) {
        swiperUrlList.add(SwiperUrl(coverUrl: picUrlList[i], linkUrl: picHrefList[i]));
      }
    }
    final chartZInfoList = chartZNode?.querySelectorAll('em').toList();
    final memberInfoList = chartZInfoList?.map((e) => e.text).whereType<String>().toList(growable: false) ?? [];
    if (memberInfoList.length >= 3) {
      forumStatus = ForumStatus(
        todayCount: memberInfoList[0],
        yesterdayCount: memberInfoList[1],
        threadCount: memberInfoList[2],
      );
    }

    // X5 and legacy: related links in the forum status bar.
    //
    // <div id="chart" class="bm bw0 cl">
    //   <p class="chart z">今日: <em>2855</em> | 昨日: <em>3880</em> | 帖子: <em>28277448</em> | 会员: <em>2218006</em> ...</p>
    //   <div class="y">
    //     <a href="home.php?mod=space&do=thread&view=me">我的帖子</a> | <a href="forum.php?mod=guide&view=new">最新回复</a>
    //   </div>
    // </div>
    final welcomeNode =
        document.querySelector('div#wp.wp div#ct.wp.cl div#chart.bm.bw0.cl div.y') ??
        document.querySelector('div#chart > div.y');
    // X5 header user block:
    //
    // <div id="um">
    //   <div class="avt y"><a href="home.php?mod=space&uid=xxx"><img data-src="..." class="_avt user_avatar"></a></div>
    //   <p><strong class="vwmy"><a href="home.php?mod=space&uid=xxx">username</a></strong>...</p>
    // </div>
    final userBlockNode = document.querySelector('div#um');
    final loggedUsername = username ?? userBlockNode?.querySelector('strong.vwmy > a')?.innerText.trim() ?? '';
    final loggedUserAvatar =
        avatarUrl ??
        (userBlockNode?.querySelector('div.avt img') ??
                document.querySelector('div#hd div.wp div.hdc.cl div#um div.avt.y a img'))
            ?.dataOriginalOrSrcImgUrl();
    final navigateHrefsPairs = welcomeNode
        ?.querySelectorAll('a')
        .where((e) => e.attributes.containsKey('href'))
        .map((e) => (e.firstEndDeepText() ?? 'unknown', e.attributes['href']!))
        .toList();
    loggedUserInfo = LoggedUserInfo(
      username: loggedUsername,
      relatedLinkPairList: navigateHrefsPairs ?? [],
      avatarUrl: loggedUserAvatar,
    );

    pinnedThreadGroupList.addAll(parsePinnedThreadGroupsFromDocument(document));
    // Discuz! X5 renders the unread state in the page header; keep it so the badge can show up right away.
    final (unreadNoticeCount, hasUnreadMessage) = buildUnreadInfoStatus(document);
    return HomepageState(
      status: loggedUsername.isNotEmpty ? HomepageStatus.success : HomepageStatus.needLogin,
      forumStatus: forumStatus ?? const ForumStatus.empty(),
      loggedUserInfo: loggedUserInfo,
      pinnedThreadGroupList: pinnedThreadGroupList,
      swiperUrlList: swiperUrlList,
      unreadNoticeCount: unreadNoticeCount,
      hasUnreadMessage: hasUnreadMessage,
      // The forum embeds today's daily red packet in the footer until it is claimed.
      dailyRedPacket: loggedUsername.isEmpty ? null : parseDailyRedPacketConfig(document),
      formHash: parseFormHash(document),
    );
  }

  @override
  Future<void> close() async {
    await _authStatusSub.cancel();
    await super.close();
  }
}
