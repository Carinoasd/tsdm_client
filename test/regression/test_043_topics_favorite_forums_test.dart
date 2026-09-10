import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/topics/bloc/topics_bloc.dart';
import 'package:tsdm_client/features/topics/view/topics_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:universal_html/parsing.dart';

/// Issue #1: a forum added to favorites on the web only showed up on the 分区 tab after a pull to refresh there, and
/// that refresh threw "Controller's length property (N) does not match the number of tabs (N+1)" because the
/// "我收藏的版块" panel is one more group and the TabController kept its old length.
///
/// `forum_index_x5.html` / `forum_index_nofav_x5.html` are `forum.php` captured on 2026-09-09 with the same test
/// account (uid -> 1000, username -> Alice, hashes -> XXXXXXXX), with and without one favorite forum (fid 125).
String _data(String name) => File('test/data/$name').readAsStringSync();

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);

/// Fixture [name] as served to [user]: the user node in the header rewritten (captured as Alice), or removed for a
/// guest. The topics tab only trusts a page whose user node names the current user.
String _indexAs(String name, UserLoginInfo? user) {
  final html = _data(name);
  if (user == null) {
    // A guest page has neither the header user node nor a positive `discuz_uid`.
    return html
        .replaceAll(RegExp('<strong class="vwmy">.*?</strong>'), '')
        .replaceAll("discuz_uid = '1000'", "discuz_uid = '0'");
  }
  return html.replaceAll('uid=1000', 'uid=${user.uid}').replaceAll('>Alice<', '>${user.username}<');
}

/// Serves canned answers by request path and records every request.
final class _FakeAdapter implements HttpClientAdapter {
  final requests = <(Uri uri, String method, String body)>[];
  final answers = <bool Function(Uri uri, String method), String Function()>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var body = '';
    if (requestStream != null) {
      final bytes = await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      body = utf8.decode(bytes);
    }
    requests.add((options.uri, options.method, body));
    final answer = answers.entries.where((e) => e.key(options.uri, options.method)).firstOrNull?.value.call();
    if (answer == null) {
      return ResponseBody.fromString('not found', 404);
    }
    final contentType = answer.startsWith('<?xml') ? 'text/xml; charset=utf-8' : 'text/html; charset=utf-8';
    return ResponseBody.fromString(
      answer,
      200,
      headers: {
        Headers.contentTypeHeader: [contentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Authentication repository whose status is driven by the test.
final class _FakeAuth extends AuthenticationRepository {
  _FakeAuth(this.user);

  UserLoginInfo? user;
  final subject = BehaviorSubject<AuthStatus>();

  @override
  UserLoginInfo? get currentUser => user;

  @override
  Stream<AuthStatus> get status => subject.stream;

  void signIn(UserLoginInfo info) {
    user = info;
    subject.add(AuthStatusAuthed(info));
  }

  void signOut() {
    user = null;
    subject.add(const AuthStatusNotAuthed());
  }

  @override
  Future<void> dispose() async {
    await subject.close();
    await super.dispose();
  }
}

/// A `forum.php` served to [user] with [names] as groups (no forums, so no cards and no images are built).
String _index(List<String> names, {UserLoginInfo? user = _alice}) {
  final header = user == null
      ? ''
      : '<div id="hd"><div class="wp"><div class="hdc cl"><div id="um"> '
            '<p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=${user.uid}">${user.username}</a></strong></p> '
            '</div></div></div></div>';
  final groups = names.indexed
      .map(
        (e) =>
            '<div class="bm bmw  cl"><div class="bm_h cl"><h2><a href="${e.$2 == '我收藏的版块' ? 'home.php?mod=space&amp;do=favorite&amp;type=forum' : 'forum.php?gid=${e.$1 + 1}'}">${e.$2}</a></h2></div> '
            '<div id="category_${e.$1 + 1}" class="bm_c"><table class="fl_tb"><tr class="fl_row"></tr></table></div></div>',
      )
      .join();
  return '<html><body>$header<div id="ct"><div class="mn"><div class="fl bm">$groups</div></div></div></body></html>';
}

void main() {
  const alice = _alice;
  const bob = _bob;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('favorites panel on the X5 forum index', () {
    test('is parsed as the first group, linked to the favorites list', () {
      final groups = buildGroupListFromDocument(parseHtmlDocument(_data('forum_index_x5.html')));
      final withoutPanel = buildGroupListFromDocument(parseHtmlDocument(_data('forum_index_nofav_x5.html')));
      expect(groups.length, withoutPanel.length + 1);
      expect(withoutPanel.where((e) => e.isFavorites), isEmpty);

      final panel = groups.first;
      expect(panel.isFavorites, isTrue);
      expect(panel.name, '我收藏的版块');
      expect(panel.url, contains('do=favorite'));
      expect(panel.url, contains('type=forum'));
      expect(panel.forumList.map((e) => e.forumID), [125]);
      expect(panel.forumList.single.name, '日麻');
      expect(groups.skip(1).map((e) => e.name), withoutPanel.map((e) => e.name));
      expect(groups.skip(1).where((e) => e.isFavorites), isEmpty);
    });
  });

  group('TopicsBloc', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late _FakeAdapter adapter;
    late ForumHomeRepository forumHome;
    late FavoriteRepository favorites;
    late _FakeAuth auth;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      adapter = _FakeAdapter();
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
        );
      await settings.init();
      forumHome = ForumHomeRepository();
      favorites = FavoriteRepository();
      auth = _FakeAuth(alice);
    });
    tearDown(() async {
      await forumHome.dispose();
      await favorites.dispose();
      await auth.dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    int indexRequests() => adapter.requests.where((e) => e.$1.path == '/forum.php').length;

    test('re-parses the document the homepage fetched and seeds the favorite forums', () async {
      var index = 'forum_index_nofav_x5.html';
      adapter.answers[(uri, _) => uri.path == '/forum.php'] = () => _data(index);
      final bloc = TopicsBloc(
        forumHomeRepository: forumHome,
        authenticationRepository: auth,
        favoriteRepository: favorites,
      )..add(TopicsLoadRequested());
      final loaded = await bloc.stream.firstWhere((s) => s.status.isSuccess);
      final n = loaded.forumGroupList.length;
      expect(n, greaterThan(0));
      expect(loaded.forumGroupList.where((e) => e.isFavorites), isEmpty);
      expect(favorites.isForumFavorited(uid: 1000, fid: '125'), isFalse);

      // The homepage refreshes the shared document (after a login, a pull to refresh...): no event on the bloc.
      index = 'forum_index_x5.html';
      final updated = bloc.stream.firstWhere((s) => s.forumGroupList.length == n + 1);
      await forumHome.fetchHomePage(force: true).run();
      final state = await updated;
      expect(state.status.isSuccess, isTrue);
      expect(state.forumGroupList.first.isFavorites, isTrue);
      expect(indexRequests(), 2, reason: 'the bloc must not fetch again on its own');
      expect(favorites.isForumFavorited(uid: 1000, fid: '125'), isTrue, reason: 'seeded from the panel');
      expect(favorites.cachedForumFavid(uid: 1000, fid: '125'), isNull, reason: 'the panel has no favid');

      // Back to no favorites: the seeded record goes away with the panel.
      index = 'forum_index_nofav_x5.html';
      final shrunk = bloc.stream.firstWhere((s) => s.forumGroupList.length == n);
      await forumHome.fetchHomePage(force: true).run();
      await shrunk;
      expect(favorites.isForumFavorited(uid: 1000, fid: '125'), isFalse);
      await bloc.close();
    });

    test('reloads silently after a forum favorite changed', () async {
      adapter.answers[(uri, _) => uri.path == '/forum.php'] = () => _data('forum_index_x5.html');
      adapter.answers[(uri, method) => method == 'GET' && uri.queryParameters['op'] == 'delete'] = () =>
          _data('favorite_forum_delete_form_x5.xml');
      adapter.answers[(uri, method) => method == 'POST'] = () => _data('favorite_forum_delete_success_x5.xml');
      final bloc = TopicsBloc(
        forumHomeRepository: forumHome,
        authenticationRepository: auth,
        favoriteRepository: favorites,
      )..add(TopicsLoadRequested());
      await bloc.stream.firstWhere((s) => s.status.isSuccess);
      expect(indexRequests(), 1);

      final statuses = <TopicsStatus>[];
      final sub = bloc.stream.listen((s) => statuses.add(s.status));
      final removed = await favorites.removeFavorite(favid: '500405', type: FavoriteType.forum).run();
      expect(removed.toNullable()?.removed, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(indexRequests(), 2, reason: 'the topics tab reloads the panel');
      expect(statuses, isNot(contains(TopicsStatus.loading)), reason: 'silent: the groups stay on screen');
      await sub.cancel();
      await bloc.close();
    });

    test('reloads after a logout, and after a user change the homepage did not follow', () async {
      adapter.answers[(uri, _) => uri.path == '/forum.php'] = () => _indexAs('forum_index_nofav_x5.html', auth.user);
      final bloc = TopicsBloc(
        forumHomeRepository: forumHome,
        authenticationRepository: auth,
        favoriteRepository: favorites,
        // Long enough for a cold parse of the index (well over 100 ms on a loaded runner) to beat the grace timer:
        // the test below expects the fresh document, not the timer, to win.
        authRefreshGrace: const Duration(seconds: 1),
      )..add(TopicsLoadRequested());
      await bloc.stream.firstWhere((s) => s.status.isSuccess);
      expect(indexRequests(), 1);

      // Wait for the guest index itself, not for a moment that is usually long enough: reaching the bloc after the
      // next sign in, it is a document of the wrong user and costs one more fetch, which raced on a loaded runner.
      // The stream replays its latest document to a new listener, so skip that one.
      final guestIndex = forumHome.documentStream.skip(1).first;
      auth
        ..signIn(alice)
        ..signOut();
      await guestIndex;
      await pumpEventQueue();
      expect(indexRequests(), 2, reason: 'logged out: fetch the guest index right away');

      // Another account logs in and the homepage publishes a fresh document in time: no extra fetch.
      auth.signIn(bob);
      await pumpEventQueue();
      await forumHome.fetchHomePage(force: true).run();
      await pumpEventQueue();
      expect(indexRequests(), 3);

      // Switch again, this time nobody refreshes the document: the bloc fetches after the grace period.
      auth.signIn(alice);
      await pumpEventQueue();
      expect(indexRequests(), 3);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(indexRequests(), 4);
      await bloc.close();
    });

    test("created after an account switch: the previous user's cached page is neither shown nor seeded", () async {
      // Alice's page (favorite forum 125) was fetched by the homepage before the switch.
      var name = 'forum_index_x5.html';
      adapter.answers[(uri, _) => uri.path == '/forum.php'] = () => _indexAs(name, auth.user);
      await forumHome.fetchHomePage().run();
      expect(indexRequests(), 1);

      // Bob logs in and the homepage refresh failed: the cache and the stream replay still hold Alice's page.
      auth.signIn(bob);
      name = 'forum_index_nofav_x5.html';
      final states = <TopicsState>[];
      final bloc = TopicsBloc(
        forumHomeRepository: forumHome,
        authenticationRepository: auth,
        favoriteRepository: favorites,
      );
      final sub = bloc.stream.listen(states.add);
      bloc.add(TopicsLoadRequested());
      await bloc.stream.firstWhere((s) => s.status.isSuccess);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        states.where((s) => s.forumGroupList.any((e) => e.isFavorites)),
        isEmpty,
        reason: "Alice's panel is never shown to Bob",
      );
      expect(states.last.status.isSuccess, isTrue);
      expect(states.last.forumGroupList, isNotEmpty);
      expect(
        favorites.isForumFavorited(uid: bob.uid!, fid: '125'),
        isFalse,
        reason: "not seeded from Alice's page",
      );
      expect(favorites.isForumFavorited(uid: alice.uid!, fid: '125'), isFalse);
      expect(indexRequests(), 2, reason: "one forced fetch for Bob's page, the cached one is refetched once only");
      await sub.cancel();
      await bloc.close();
    });

    test("created after a logout: the previous user's cached page is not shown to the guest", () async {
      var name = 'forum_index_x5.html';
      adapter.answers[(uri, _) => uri.path == '/forum.php'] = () => _indexAs(name, auth.user);
      await forumHome.fetchHomePage().run();
      auth.signOut();
      // The guest index has no favorites panel.
      name = 'forum_index_nofav_x5.html';
      final states = <TopicsState>[];
      final bloc = TopicsBloc(
        forumHomeRepository: forumHome,
        authenticationRepository: auth,
        favoriteRepository: favorites,
      );
      final sub = bloc.stream.listen(states.add);
      bloc.add(TopicsLoadRequested());
      await bloc.stream.firstWhere((s) => s.status.isSuccess);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(states.where((s) => s.forumGroupList.any((e) => e.isFavorites)), isEmpty);
      expect(states.last.forumGroupList, isNotEmpty);
      expect(favorites.isForumFavorited(uid: alice.uid!, fid: '125'), isFalse);
      expect(indexRequests(), 2);
      await sub.cancel();
      await bloc.close();
    });

    test('drops the cached document on every auth transition, even when the reload fails', () async {
      adapter.answers[(uri, _) => uri.path == '/forum.php'] = () => _indexAs('forum_index_nofav_x5.html', auth.user);
      final bloc = TopicsBloc(
        forumHomeRepository: forumHome,
        authenticationRepository: auth,
        favoriteRepository: favorites,
        authRefreshGrace: const Duration(milliseconds: 20),
      )..add(TopicsLoadRequested());
      await bloc.stream.firstWhere((s) => s.status.isSuccess);
      expect(forumHome.hasCache(), isTrue);

      // From now on every fetch fails (rate limit).
      adapter.answers.clear();
      auth
        ..signIn(alice)
        ..signOut();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forumHome.hasCache(), isFalse, reason: 'logged out');
      expect(bloc.state.status.isSuccess, isTrue, reason: 'silent: the groups stay on screen');

      adapter.answers[(uri, _) => uri.path == '/forum.php'] = () => _indexAs('forum_index_nofav_x5.html', auth.user);
      await forumHome.fetchHomePage(force: true).run();
      expect(forumHome.hasCache(), isTrue);
      adapter.answers.clear();
      auth.signIn(bob);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forumHome.hasCache(), isFalse, reason: 'user changed');
      await bloc.close();
    });

    test('HomepageBloc drops the cached document on every auth transition too', () async {
      adapter.answers[(uri, _) => uri.path == '/forum.php'] = () => _indexAs('forum_index_nofav_x5.html', auth.user);
      await forumHome.fetchHomePage().run();
      final profile = ProfileRepository();
      final bloc = HomepageBloc(
        forumHomeRepository: forumHome,
        profileRepository: profile,
        authenticationRepository: auth,
      );
      adapter.answers.clear();
      auth
        ..signIn(alice)
        ..signOut();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forumHome.hasCache(), isFalse, reason: 'logged out');

      adapter.answers[(uri, _) => uri.path == '/forum.php'] = () => _indexAs('forum_index_nofav_x5.html', auth.user);
      await forumHome.fetchHomePage(force: true).run();
      adapter.answers.clear();
      auth.signIn(bob);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forumHome.hasCache(), isFalse, reason: 'user changed and the forced refresh failed');
      await bloc.close();
    });
  });

  group('TopicsPage', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late _FakeAdapter adapter;
    late ForumHomeRepository forumHome;
    late FavoriteRepository favorites;
    late _FakeAuth auth;
    late FragmentsRepository fragments;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      adapter = _FakeAdapter();
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
        );
      await settings.init();
      forumHome = ForumHomeRepository();
      favorites = FavoriteRepository();
      auth = _FakeAuth(alice);
      fragments = FragmentsRepository();
    });
    tearDown(() async {
      await forumHome.dispose();
      await favorites.dispose();
      await auth.dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    Widget host() => TranslationProvider(
      child: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<ForumHomeRepository>.value(value: forumHome),
          RepositoryProvider<AuthenticationRepository>.value(value: auth),
          RepositoryProvider<FavoriteRepository>.value(value: favorites),
          RepositoryProvider<FragmentsRepository>.value(value: fragments),
        ],
        child: const MaterialApp(home: TopicsPage()),
      ),
    );

    /// Pump a few frames; `pumpAndSettle` never returns here because a refresh indicator keeps animating.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('the tab bar follows the group count without a controller length error', (tester) async {
      var names = ['天使·后花园', '动漫综合'];
      adapter.answers[(uri, _) => uri.path == '/forum.php'] = () => _index(names);
      await tester.pumpWidget(host());
      await settle(tester);
      expect(find.byType(Tab), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('动漫综合'));
      await settle(tester);
      expect(fragments.topicsPageTabIndex, 1);

      // The homepage refreshed the document after the first forum was favorited: one more group in front, and it
      // is selected so the user sees it instead of staying on the tab that kept the old index (#1).
      names = ['我收藏的版块', '天使·后花园', '动漫综合'];
      // Under FakeAsync the fetch only completes while frames are pumped.
      unawaited(forumHome.fetchHomePage(force: true).run());
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Tab), findsNWidgets(3));
      expect(find.text('我收藏的版块'), findsOneWidget);
      expect(fragments.topicsPageTabIndex, 0);

      // Select the last tab, then drop the panel again: the saved index is clamped instead of pointing past the end.
      await tester.tap(find.text('动漫综合'));
      await settle(tester);
      expect(fragments.topicsPageTabIndex, 2);
      names = ['天使·后花园', '动漫综合'];
      // Under FakeAsync the fetch only completes while frames are pumped.
      unawaited(forumHome.fetchHomePage(force: true).run());
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Tab), findsNWidgets(2));
      expect(find.text('我收藏的版块'), findsNothing);
      expect(fragments.topicsPageTabIndex, 1);

      // Pull to refresh with an unchanged count keeps working as before.
      await tester.drag(find.byType(TabBarView), const Offset(0, 400));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(Tab), findsNWidgets(2));
    });
  });
}
