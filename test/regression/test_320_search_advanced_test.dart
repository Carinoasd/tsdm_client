// The advanced search (forums, time range, order, titles only) and the search history.
//
// The fixtures are answers of the test forum (Discuz X5, plugin tsdmapp) to a search by ag_low2 for "測試" in forums 2
// and 6 ordered by the replies, ascending (`srchfid=2_6&orderby=replies&ascdesc=asc&srchtype=title`): the structured
// answer (`tsdmapp/search_v6_filtered.json`, cut to 5 rows) and the web page of the same search
// (`search_filtered_x5.html`, its result list cut to 5 rows); and the forum's refusal of a second search within its
// interval (10 seconds on the test forum) as the web page gives it (`search_ctrl_x5.html`): the plugin answers a new
// search (`searchsubmit=yes` without a search id) with the web page.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/search/bloc/search_bloc.dart';
import 'package:tsdm_client/features/search/models/models.dart';
import 'package:tsdm_client/features/search/repository/search_history_store.dart';
import 'package:tsdm_client/features/search/repository/search_repository.dart';
import 'package:tsdm_client/features/search/view/search_page.dart';
import 'package:tsdm_client/features/search/widgets/search_filter_bar.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/utils/load_failure.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 31);

/// An answer of the fake forum.
typedef _Answer = ({String body, bool json});

_Answer _file(String path) => (body: File('test/data/$path').readAsStringSync(), json: path.endsWith('.json'));

/// A forum answering every request through [answer] and recording it.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  _Answer Function(Uri uri) answer;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final a = answer(options.uri);
    return ResponseBody.fromString(
      a.body,
      200,
      headers: {
        Headers.contentTypeHeader: [if (a.json) 'application/json; charset=utf-8' else 'text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

/// The query of [uri] as the forum reads it (`srchfid[]` kept by its name).
Map<String, String> _query(Uri uri) => uri.queryParameters;

const _filtered = SearchFilter(orderBy: SearchOrderBy.replies, ascending: true);

void main() {
  late _Forum forum;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  setUp(() {
    TsdmAppApi.reset();
    forum = _Forum((uri) => fail('unexpected request: $uri'));
    getIt
      ..allowReassignment = true
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      );
  });

  tearDown(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });

  group('the query of a search', () {
    test('the forum defaults add nothing: the query of before', () {
      final q = buildSearchQuery(keyword: 'x', fid: '0', uid: '0', authorName: '', pageNumber: 1);
      expect(q, {'mod': 'forum', 'srchtxt': 'x', 'searchsubmit': 'yes'});
    });

    test('one forum is srchfid[], several are srchfid joined by _ (an array item 2_6 would be read as 2)', () {
      expect(
        buildSearchQuery(keyword: 'x', fid: '6', uid: '0', authorName: '', pageNumber: 1),
        allOf(containsPair('srchfid[]', '6'), isNot(contains('srchfid'))),
      );
      final q = buildSearchQuery(
        keyword: 'x',
        fid: searchForumIdsValue([6, 2, 6]),
        uid: '0',
        authorName: '',
        pageNumber: 1,
      );
      expect(q, containsPair('srchfid', '2_6'));
      expect(q, isNot(contains('srchfid[]')));
    });

    test('the forums as the fid of a search and back', () {
      expect(searchForumIdsValue(const []), '0');
      expect(searchForumIdsValue([14, 2, 0, 2]), '2_14');
      expect(searchForumIdsOf('2_14'), [2, 14]);
      expect(searchForumIdsOf('6'), [6]);
      expect(searchForumIdsOf('0'), isEmpty);
      expect(searchForumIdsOf(''), isEmpty);
    });

    test('the time range is srchfrom in the seconds of the forum form, the order goes as orderby and ascdesc', () {
      expect(SearchTimeRange.values.map((e) => e.seconds), [
        0,
        86400,
        604800,
        2592000,
        7776000,
        15552000,
        31536000,
      ]);
      final q = buildSearchQuery(
        keyword: '',
        fid: '2_6',
        uid: '0',
        authorName: 'ag_low2',
        pageNumber: 1,
        filter: const SearchFilter(
          timeRange: SearchTimeRange.week,
          orderBy: SearchOrderBy.dateline,
          titleOnly: false,
        ),
      );
      expect(q, {
        'mod': 'forum',
        'srchtxt': '',
        'srchuname': 'ag_low2',
        'srchfid': '2_6',
        'srchfrom': '604800',
        'srchtype': 'fulltext',
        'orderby': 'dateline',
        'ascdesc': 'desc',
        'searchsubmit': 'yes',
      });
      // The last post first, ascending: still an order to send.
      expect(
        buildSearchQuery(
          keyword: 'x',
          fid: '0',
          uid: '0',
          authorName: '',
          pageNumber: 1,
          filter: const SearchFilter(ascending: true),
        ),
        allOf(containsPair('orderby', 'lastpost'), containsPair('ascdesc', 'asc')),
      );
    });
  });

  group('the repository', () {
    test('a filtered search: the new search with its filters, its other pages in the same order', () async {
      forum.answer = (uri) => _file('tsdmapp/search_v6_filtered.json');
      final repo = SearchRepository();
      final first = _right(
        await repo.searchWithParameters(keyword: '測試', fid: '2_6', uid: '0', pageNumber: 1, filter: _filtered).run(),
      );
      expect(first.count, 54);
      expect(first.totalPages, 3);
      expect(first.data!.map((e) => e.tid), hasLength(5));
      expect(first.fullText, isFalse);
      final asked = _query(forum.requests.single);
      expect(asked, containsPair('srchfid', '2_6'));
      expect(asked, containsPair('orderby', 'replies'));
      expect(asked, containsPair('ascdesc', 'asc'));
      expect(asked, containsPair('searchsubmit', 'yes'));

      await repo.searchWithParameters(keyword: '測試', fid: '2_6', uid: '0', pageNumber: 2, filter: _filtered).run();
      final next = _query(forum.requests.last);
      expect(next, containsPair('searchid', '4'));
      expect(next, containsPair('orderby', 'replies'), reason: 'not the last post order of before');
      expect(next, containsPair('ascdesc', 'asc'));
      expect(next, containsPair('page', '2'));
      expect(next, isNot(contains('srchtxt')));

      // Another time range is another search, not a page of the one before.
      const week = SearchFilter(orderBy: SearchOrderBy.replies, ascending: true, timeRange: SearchTimeRange.week);
      await repo.searchWithParameters(keyword: '測試', fid: '2_6', uid: '0', pageNumber: 2, filter: week).run();
      expect(_query(forum.requests.last), allOf(containsPair('srchfrom', '604800'), isNot(contains('searchid'))));
    });

    test('the web page of the same search is parsed as before', () async {
      forum.answer = (uri) => _file('search_filtered_x5.html');
      final repo = SearchRepository();
      final web = _right(
        await repo.searchWithParameters(keyword: '測試', fid: '2_6', uid: '0', pageNumber: 1, filter: _filtered).run(),
      );
      forum.answer = (uri) => _file('tsdmapp/search_v6_filtered.json');
      final api = _right(
        await SearchRepository()
            .searchWithParameters(keyword: '測試', fid: '2_6', uid: '0', pageNumber: 1, filter: _filtered)
            .run(),
      );
      expect(web.count, api.count);
      expect(web.totalPages, api.totalPages);
      expect(web.data!.map((e) => e.tid), api.data!.map((e) => e.tid));
      expect(web.data!.map((e) => e.title), api.data!.map((e) => e.title));
      expect(web.fullText, isNull, reason: 'the page does not tell');

      await repo.searchWithParameters(keyword: '測試', fid: '2_6', uid: '0', pageNumber: 2, filter: _filtered).run();
      expect(_query(forum.requests.last), allOf(containsPair('searchid', '4'), containsPair('orderby', 'replies')));
    });

    test('a search within the interval: the words of the forum without its script, and the seconds', () async {
      forum.answer = (uri) => _file('search_ctrl_x5.html');
      final result = await SearchRepository()
          .searchWithParameters(keyword: 'APP', fid: '0', uid: '0', pageNumber: 1)
          .run();
      final e = result.getLeft().toNullable();
      expect(e, isA<ServerRespondedErrorException>());
      final message = (e! as ServerRespondedErrorException).message ?? '';
      expect(message, '抱歉，您在 10 秒内只能进行一次搜索');
      expect(searchRateLimitSeconds(message), 10);
      expect(searchRateLimitSeconds('抱歉，站点设置每分钟系统最多响应搜索请求 10 次，请稍候再试'), 60);
    });

    test('the bloc keeps the filters for every page and tells the wait of the forum', () async {
      forum.answer = (uri) => _file('tsdmapp/search_v6_filtered.json');
      final bloc = SearchBloc(searchRepository: SearchRepository())
        ..add(const SearchRequested(keyword: '測試', fid: '2_6', uid: '0', pageNumer: 1, filter: _filtered));
      var state = await bloc.stream.firstWhere((s) => s.status == SearchStatus.success);
      expect(state.filter, _filtered);
      expect(state.fid, '2_6');

      bloc.add(SearchGotoNextPageRequested());
      state = await bloc.stream.firstWhere((s) => s.status != SearchStatus.loading && s != state);
      expect(_query(forum.requests.last), allOf(containsPair('searchid', '4'), containsPair('orderby', 'replies')));

      bloc.add(const SearchLoadMoreRequested());
      await bloc.stream.firstWhere((s) => !s.loadingMore);
      expect(_query(forum.requests.last), allOf(containsPair('searchid', '4'), containsPair('ascdesc', 'asc')));

      forum.answer = (uri) => _file('search_ctrl_x5.html');
      bloc.add(const SearchRequested(keyword: 'APP', fid: '0', uid: '0', pageNumer: 1));
      state = await bloc.stream.firstWhere((s) => s.status == SearchStatus.failed);
      expect(state.failure?.kind, LoadFailureKind.rateLimited);
      expect(state.failedMessage, '抱歉，您在 10 秒内只能进行一次搜索');
      expect(state.retryAfterSeconds, 10);
      await bloc.close();
    });
  });

  group('the search history', () {
    test('a keyword searched again goes first, once; blanks are not kept; at most 20', () {
      var history = <String>[];
      for (final k in ['a', ' b ', 'c', 'a', '   ']) {
        history = searchHistoryWith(history, k);
      }
      expect(history, ['a', 'c', 'b']);
      for (var i = 0; i < 30; i++) {
        history = searchHistoryWith(history, 'k$i');
      }
      expect(history, hasLength(searchHistoryMaxCount));
      expect(history.first, 'k29');
      expect(history.last, 'k10');
    });

    test('the suggestions start with what is typed, ignoring case, without the keyword typed in full', () {
      const history = ['Fate', 'fate zero', 'FGO', 'fat', 'other'];
      expect(searchHistorySuggestions(history, 'fa'), ['Fate', 'fate zero', 'fat']);
      expect(searchHistorySuggestions(history, ' FATE '), ['fate zero']);
      expect(searchHistorySuggestions(history, ''), isEmpty);
    });

    test('kept per account in the storage: add, remove, clear; an unreadable row is no history', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final storage = StorageProvider(db, {}, {});
      final store = SearchHistoryStore(storage);
      await store.add(31, 'a');
      await store.add(31, 'b');
      await store.add(0, 'guest');
      expect(await store.load(31), ['b', 'a']);
      expect(await store.load(0), ['guest']);
      expect(await store.load(7), isEmpty);

      expect(await store.remove(31, 'b'), ['a']);
      expect(await store.load(31), ['a']);
      await store.clear(31);
      expect(await store.load(31), isEmpty);
      expect(await storage.getString(searchHistoryKey(31)), isNull, reason: 'the row goes');
      expect(await store.load(0), ['guest'], reason: 'another account keeps its own');

      await storage.saveString(searchHistoryKey(5), '{broken');
      expect(await store.load(5), isEmpty);
      await storage.saveString(searchHistoryKey(5), jsonEncode(['x', 1, ' ', 'x', ' y ']));
      expect(await store.load(5), ['x', 'y']);
    });
  });

  group('the forums to pick', () {
    Forum forum(int fid, String name, {List<(String, String)>? subs, bool private = false, String? redirect}) => Forum(
      forumID: fid,
      url: '$baseUrl/forum.php?mod=forumdisplay&fid=$fid',
      name: name,
      iconUrl: '',
      threadCount: 0,
      replyCount: 0,
      latestThreadUrl: null,
      latestThreadTime: null,
      latestThreadTimeText: null,
      threadTodayCount: null,
      subForumList: subs,
      isPrivate: private,
      redirectUrl: redirect,
    );

    test('the forums of the index with their subforums; no favorites panel, link or private forums', () {
      final groups = [
        ForumGroup(
          name: 'fav',
          url: '$baseUrl/home.php?mod=space&do=favorite&type=forum',
          forumList: [forum(6, 'A')],
        ),
        ForumGroup(
          name: 'G1',
          url: '$baseUrl/forum.php?gid=1',
          forumList: [
            forum(2, 'B', subs: [('B1', 'forum.php?mod=forumdisplay&fid=15'), ('bad', 'forum.php')]),
            forum(30, 'link', redirect: 'https://example.test'),
            forum(31, 'private', private: true),
          ],
        ),
        ForumGroup(name: 'G3', url: '$baseUrl/forum.php?gid=3', forumList: [forum(6, 'A')]),
      ];
      expect(searchForumOptions(groups), [
        (fid: 2, name: 'B', group: 'G1', sub: false),
        (fid: 15, name: 'B1', group: 'G1', sub: true),
        (fid: 6, name: 'A', group: 'G3', sub: false),
      ]);
    });
  });

  group('the page', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late SettingsBloc settingsBloc;

    setUp(() async {
      await LocaleSettings.setLocale(AppLocale.zhTw);
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings);
      await settings.init();
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });

    tearDown(() async {
      await settingsBloc.close();
      await settings.dispose();
      await db.close();
    });

    Widget app(Widget child) => TranslationProvider(
      child: RepositoryProvider<AuthenticationRepository>.value(
        value: AuthenticationRepository(user: _alice),
        child: BlocProvider<SettingsBloc>.value(
          value: settingsBloc,
          child: MaterialApp(home: child),
        ),
      ),
    );

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
    }

    testWidgets('the history under the empty keyword, the filters chosen in chips go with the search', (tester) async {
      await tester.runAsync(() async {
        await SearchHistoryStore(storage).add(_alice.uid!, '舊的');
        await SearchHistoryStore(storage).add(_alice.uid!, '測試');
      });
      forum.answer = (uri) => _file('search_ctrl_x5.html');
      await tester.pumpWidget(app(const SearchPage()));
      await settle(tester);
      final tr = t.searchPage;

      // The keyword field has the focus: the keywords searched before, the latest first.
      expect(find.byKey(const ValueKey('search-history-測試')), findsOneWidget);
      expect(find.byKey(const ValueKey('search-history-舊的')), findsOneWidget);
      expect(find.byKey(const ValueKey('search-history-clear')), findsOneWidget);

      // Typing narrows them to the ones starting with it.
      await tester.enterText(find.byType(TextFormField).first, '舊');
      await tester.pump();
      expect(find.byKey(const ValueKey('search-history-舊的')), findsOneWidget);
      expect(find.byKey(const ValueKey('search-history-測試')), findsNothing);
      await tester.enterText(find.byType(TextFormField).first, '');
      await tester.pump();

      // A week, the post time, the full text.
      await tester.tap(find.byKey(const ValueKey('search-filter-time')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr.filter.time.week).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('search-filter-order')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(tr.filter.order.dateline).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('search-filter-title-only')));
      await tester.pump();
      expect(find.text(tr.filter.time.week), findsOneWidget);
      expect(find.text(tr.filter.order.dateline), findsOneWidget);

      // A time range searches without a keyword.
      await tester.tap(find.byIcon(Icons.search_outlined));
      await settle(tester);
      final asked = _query(forum.requests.single);
      expect(asked['srchtxt'], '');
      expect(asked, containsPair('srchfrom', '604800'));
      expect(asked, containsPair('orderby', 'dateline'));
      expect(asked, containsPair('srchtype', 'fulltext'));
      expect(find.text('抱歉，您在 10 秒内只能进行一次搜索'), findsOneWidget);

      // A keyword tapped in the history is searched, and goes first.
      await tester.tap(find.byType(TextFormField).first);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('search-history-舊的')));
      await settle(tester);
      expect(_query(forum.requests.last)['srchtxt'], '舊的');
      expect(await tester.runAsync(() => SearchHistoryStore(storage).load(_alice.uid!)), ['舊的', '測試']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    });

    testWidgets('the forums picked in the dialog go as srchfid; a full text the forum did not search springs back', (
      tester,
    ) async {
      // The answer without its rows (the cards need the image cache): it says the titles were searched, fulltext 0.
      final answer = jsonDecode(_file('tsdmapp/search_v6_filtered.json').body) as Map<String, dynamic>;
      forum.answer = (uri) => (body: jsonEncode({...answer, 'threads': <Object>[], 'count': 0}), json: true);
      // Opened from a forum page: that forum picked, its name not known without the index.
      await tester.pumpWidget(app(const SearchPage(fid: '6')));
      await settle(tester);
      expect(find.text(t.searchPage.filter.forumId(fid: 6)), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('search-filter-title-only')));
      await tester.pump();
      expect(
        tester.widget<FilterChip>(find.byKey(const ValueKey('search-filter-title-only'))).selected,
        isFalse,
      );
      await tester.enterText(find.byType(TextFormField).first, '測試');
      await tester.tap(find.byIcon(Icons.search_outlined));
      await settle(tester);
      final asked = _query(forum.requests.last);
      expect(asked, containsPair('srchfid[]', '6'));
      expect(asked, containsPair('srchtype', 'fulltext'));
      // The answer says the titles were searched (fulltext 0).
      expect(
        tester.widget<FilterChip>(find.byKey(const ValueKey('search-filter-title-only'))).selected,
        isTrue,
      );

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 30));
    });
  });
}
