/// The fields of the forum's app API plugin 2.8.2 (its audit fixes: what the web page prints and the answer did not
/// give), and what the app does with an older plugin:
///
/// * A. the activities page reads 活动专区's links from `description_html`; before (plugin 2.3.0 to 2.8.1, the
///   description is plain text, the page was empty) the homepage is asked once more with its `document`, in the
///   background, by the shared repository, as for the "我收藏的版块" panel (one request, shared, the same identity
///   checks, a short timeout);
/// * B. the "链接" shortcuts of a forum card are the thread links of `description_html`, as from the page's row;
///   none without it (no request for them);
/// * C. a link forum (`redirect`) and a forum the viewer may not enter (`private`) among the categories and the
///   subforums, as the page prints them; a subforum seen by name only (`permission` 1) of an older plugin too;
/// * D. the reply count of the thread page is `thread.allreplies` (the page's "回复: N"), `replies` before;
/// * E. a floor whose page prints "头像被屏蔽" (`avatar_blocked`) shows no avatar, not even one kept for the author;
/// * F. a hot reply (`hot`) says "推荐" in place of its floor number, with the floor it really is (`hot_position`);
/// * G. the forum page shows and goes on from the page the forum answered (`page`, its first page when asked past
///   the site's limit of pages), the last page being `pages`;
/// * I. the app expects plugin 2.8.2 or later.
///
/// Test data: `tsdmapp/*_282_*.json` are answers of the plugin's 2.8.2 acceptance run (`evidence/audit282.json` of
/// the plugin), scrubbed with the plugin's fixture tool as the other fixtures (see `test/data/tsdmapp/README.md`);
/// `index_v5_*`, `forum_v2_*` and `thread_v3_*` were fetched again from the test forum running 2.8.2 by that tool.
/// `activities_home_x5.html` is the production row of 活动专区.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/activities/models/forum_activity.dart';
import 'package:tsdm_client/features/activities/view/activities_page.dart';
import 'package:tsdm_client/features/blocking/widgets/block_aware_post.dart';
import 'package:tsdm_client/features/forum/bloc/forum_bloc.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_api.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/post_report/view/post_report_dialog.dart';
import 'package:tsdm_client/features/rate/view/rate_post_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/forum_card.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

Translations get t => LocaleSettings.instance.currentTranslations;

Map<String, dynamic> _json(String path) =>
    jsonDecode(File('test/data/$path').readAsStringSync()) as Map<String, dynamic>;

/// The answer [name] of the plugin (`test/data/tsdmapp/`), a fresh copy.
Map<String, dynamic> _api(String name) => _json('tsdmapp/$name.json');

/// A deep copy of [json] with [edit] applied to every map in it.
Map<String, dynamic> _edited(Map<String, dynamic> json, void Function(Map<String, dynamic> map) edit) {
  Object? walk(Object? value) => switch (value) {
    final Map<String, dynamic> map => (Map<String, dynamic>.from(map.map((k, v) => MapEntry(k, walk(v))))..let(edit)),
    final List<dynamic> list => list.map(walk).toList(),
    _ => value,
  };
  return walk(json)! as Map<String, dynamic>;
}

extension<T> on T {
  T let(void Function(T) f) {
    f(this);
    return this;
  }
}

/// [json] as plugins 2.3.0 to 2.8.1 answer it: no `description_html` (the description is plain text).
Map<String, dynamic> _before282(Map<String, dynamic> json) => _edited(json, (m) => m.remove('description_html'));

/// [json] with forum 7 of the test forum named 活动专区: the acceptance run gave it a description of activity links
/// (`-点击下列文字连接进入对应活动主贴-`, a thread of the forum and an outside page), as the production forum's.
Map<String, dynamic> _withActivityForum(Map<String, dynamic> json) => _edited(json, (m) {
  if (m['fid'] == 7 && m['name'] == '神作殿堂') {
    m['name'] = '活动专区';
  }
});

/// The production page's row of 活动专区 and the forum's description as the forum keeps it: what the template prints
/// in `p.xg2`, which plugin 2.8.2 gives as `description_html`.
final String _productionRow = File('test/data/activities_home_x5.html').readAsStringSync();
final String _productionDescription = () {
  const start = '<p class="xg2">';
  final from = _productionRow.indexOf(start) + start.length;
  return _productionRow.substring(from, _productionRow.indexOf('</p><p>子版块'));
}();

Forum _category(Map<String, dynamic> json, int fid) => forumGroupsFromApi(
  json,
).where((e) => !e.isFavorites).expand((e) => e.forumList).firstWhere((e) => e.forumID == fid);

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

/// One answer of the fake forum.
typedef _Answer = ({String body, int status});

_Answer _ok(Object json) => (body: jsonEncode(json), status: 200);

/// A forum answering the homepage asked lean (`nodoc=1`) with [lean] and asked with its document with [full],
/// recording every request.
final class _Forum implements HttpClientAdapter {
  _Forum({required this.lean, required this.full});

  FutureOr<_Answer> Function() lean;
  FutureOr<_Answer> Function() full;
  final requests = <RequestOptions>[];

  List<RequestOptions> get homepage => requests.where((e) => e.uri.path == '/forum.php').toList();

  /// The homepage asked with its document (without `nodoc=1`).
  List<RequestOptions> get withDocument => homepage.where((e) => e.uri.queryParameters['nodoc'] != '1').toList();

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancel) async {
    requests.add(options);
    final query = options.uri.queryParameters;
    if (options.uri.path != '/forum.php' || query['tsdmapp'] != 'json') {
      return ResponseBody.fromString('unexpected', 404);
    }
    final a = query['nodoc'] == '1' ? await lean() : await full();
    return ResponseBody.fromString(
      a.body,
      a.status,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// A forum repository answering each page asked with [pages].
final class _FakeForumRepository extends ForumRepository {
  _FakeForumRepository(this.pages);

  final ForumPageData Function(int pageNumber) pages;
  final asked = <int>[];

  /// Whether the next request fails.
  bool Function() fail = () => false;

  @override
  AsyncEither<ForumPageData> fetchForum({required String fid, required FilterState filterState, int pageNumber = 1}) =>
      AsyncEither(() async {
        asked.add(pageNumber);
        return fail() ? left(HttpRequestFailedException(500)) : right(pages(pageNumber));
      });
}

/// The page [answered] of a forum of [total] pages with [threads] (thread ids).
ForumPageData _forumPage({required int answered, required int total, required List<int> threads}) => ForumPageData(
  title: 'forum',
  rulesElement: null,
  normalThreadList: [
    for (final tid in threads)
      NormalThread(
        title: 'thread $tid',
        url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
        threadID: '$tid',
        author: const User(name: 'a', url: ''),
        publishDate: null,
        latestReplyAuthor: const User(name: 'a', url: ''),
        latestReplyTime: null,
        iconUrl: '',
        threadType: null,
        replyCount: 0,
        viewCount: 0,
        price: null,
        css: null,
        stateSet: const {},
        privilege: null,
        isRecentThread: false,
      ),
  ],
  stickThreadList: const [],
  subredditList: const [],
  needLogin: false,
  havePermission: true,
  permissionDeniedMessage: null,
  canLoadMore: answered < total,
  currentPage: answered,
  totalPages: total,
  filterTypeList: const [],
  filterSpecialTypeList: const [],
  filterOrderList: const [],
  filterDatelineList: const [],
);

/// What the cards need of the app: the settings, the image cache (offline), the cookies and the error saver of the
/// network clients; [_unregisterApp] removes them.
Future<({AppDatabase db, SettingsRepository settings})> _registerApp() async {
  final db = AppDatabase(NativeDatabase.memory());
  final storage = StorageProvider(db, {}, {});
  final settings = SettingsRepository(storage);
  getIt
    ..registerSingleton<StorageProvider>(storage)
    ..registerSingleton<SettingsRepository>(settings)
    ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
    ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
    ..registerSingleton<NetErrorSaver>(NetErrorSaver())
    ..registerSingleton<ImageCacheProvider>(
      ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
    );
  await settings.init();
  return (db: db, settings: settings);
}

Future<void> _unregisterApp(({AppDatabase db, SettingsRepository settings}) app) async {
  try {
    await app.settings.dispose();
  } finally {
    await getIt.reset();
    await app.db.close();
  }
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('A. the activities page', () {
    test('plugin 2.8.2: the links of description_html, as the page shows them; the plain description has none', () {
      final json = _withActivityForum(_api('index_v5_282_desc'));
      final activities = parseForumActivitiesFromApi(json);
      expect(activities.map((e) => (e.title, e.url)), [
        ('【测试活动甲】', '$baseUrl/forum.php?mod=viewthread&tid=9199043'),
        ('【站外「乙」】', 'https://example.com/tsdmapp282?a=1&b=2'),
      ]);
      expect(activitiesNeedDocument(json), isFalse, reason: 'nothing more asked for 2.8.2');
      // The bug of plugins before 2.8.2: the plain text description holds no link, the page was empty.
      expect(parseForumActivitiesFromApi(_before282(json)), isEmpty);
    });

    test('the production description of 活动专区 as description_html reads as the production page', () {
      final page = parseForumActivities(parseHtmlDocument(_productionRow));
      expect(page, hasLength(17));
      final api = parseForumActivitiesFromApi({
        'ok': 1,
        'categories': [
          {
            'fid': 1,
            'name': '论坛',
            'forums': [
              {'fid': 45, 'name': '活动专区', 'description': '纯文字', 'description_html': _productionDescription},
            ],
          },
        ],
      });
      expect(api.map((e) => (e.title, e.url)), page.map((e) => (e.title, e.url)));
    });

    test('an older plugin: the page with its document is needed, and the links are read from that document', () {
      final lean = _before282(_withActivityForum(_api('index_v5_282_desc')));
      expect(activitiesNeedDocument(lean), isTrue);
      final full = {...lean, 'document': '<div id="ct">$_productionRow</div>'};
      expect(activitiesNeedDocument(full), isFalse);
      expect(parseForumActivitiesFromApi(full).map((e) => e.title), [
        ...parseForumActivities(parseHtmlDocument(_productionRow)).map((e) => e.title),
      ]);
      // Nothing to ask: no 活动专区 listed, the forum's message.
      expect(activitiesNeedDocument(_before282(_api('index_v5_282_desc'))), isFalse);
      expect(activitiesNeedDocument({'ok': 0, 'error': 'message', 'message': '站点已关闭', 'schema': 5}), isFalse);
    });

    group('the shared request for the page with its document', () {
      late AppDatabase db;
      late StorageProvider storage;
      late SettingsRepository settings;
      late CookieProvider cookie;
      const viewer = UserLoginInfo(uid: 35, username: 'ag_low2');

      setUp(() async {
        db = AppDatabase(NativeDatabase.memory());
        storage = StorageProvider(db, {}, {});
        settings = SettingsRepository(storage);
        cookie = CookieProvider(viewer, {});
        getIt
          ..registerSingleton<StorageProvider>(storage)
          ..registerSingleton<SettingsRepository>(settings)
          ..registerSingleton<CookieProvider>(cookie)
          ..registerSingleton<NetErrorSaver>(NetErrorSaver())
          ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
        await settings.init();
      });
      tearDown(() async {
        if (getIt.isRegistered<NetClientProvider>()) {
          await getIt.unregister<NetClientProvider>();
        }
        await settings.dispose();
        await getIt.unregister<SettingsRepository>();
        await getIt.unregister<StorageProvider>();
        await getIt.unregister<CookieProvider>();
        await getIt.unregister<CookieProvider>(instanceName: ServiceKeys.empty);
        await getIt.unregister<NetErrorSaver>();
        await db.close();
      });

      ForumHomeRepository repositoryOf(_Forum forum, {Duration timeout = const Duration(seconds: 10)}) {
        getIt.registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
        );
        final repo = ForumHomeRepository(documentTimeout: timeout);
        addTearDown(repo.dispose);
        return repo;
      }

      /// The lean answer of an older plugin with 活动专区 and favorites without their panel (plugin 2.8.0).
      Map<String, dynamic> olderLean() =>
          _before282(_withActivityForum(_api('index_v5_282_desc')))..remove('favorites');

      test('the activities and the favorites panel at once: one request, shared, published as the page', () async {
        final hold = Completer<void>();
        final forum = _Forum(
          lean: () => _ok(olderLean()),
          full: () async {
            await hold.future;
            return _ok({...olderLean(), 'document': '<div id="ct">$_productionRow</div>'});
          },
        );
        final repo = repositoryOf(forum);
        final published = <ForumHomePage>[];
        final sub = repo.pageStream.listen(published.add);
        addTearDown(sub.cancel);
        final page = _right(await repo.fetchHomePage().run()) as ForumHomeApiPage;
        expect(favoritesPanelNeedsDocument(page.json), isTrue);
        expect(activitiesNeedDocument(page.json), isTrue);

        final activities = repo.fetchPageDocument(page);
        final panel = repo.requestFavoritesPanel(page);
        final again = repo.fetchPageDocument(page);
        hold.complete();
        final full = await activities;
        await panel;
        expect(await again, same(full));
        expect(forum.withDocument, hasLength(1), reason: 'shared while on its way');
        expect(parseForumActivitiesFromApi(full!.json), hasLength(17));
        expect(repo.getCache(), same(full));
        await Future<void>.delayed(Duration.zero);
        expect(published, [page, full]);

        // Done: asked once per page; a page with its document is itself; a page not cached any more asks nothing.
        expect(await repo.fetchPageDocument(page), same(full));
        expect(await repo.fetchPageDocument(full), same(full));
        expect(forum.withDocument, hasLength(1));
        final next = _right(await repo.fetchHomePage(force: true).run()) as ForumHomeApiPage;
        expect(await repo.fetchPageDocument(page), same(full), reason: 'the request done for that page');
        expect(await repo.fetchPageDocument(next), isNotNull);
        expect(forum.withDocument, hasLength(2), reason: 'a new page, asked once more');
      });

      test('a page another fetch replaced in the same session: asked all the same, not published', () async {
        final forum = _Forum(
          lean: () => _ok(olderLean()),
          full: () => _ok({...olderLean(), 'document': '<div id="ct">$_productionRow</div>'}),
        );
        final repo = repositoryOf(forum);
        // The activities page fetched its page, then the homepage refreshed before the document was asked.
        final mine = _right(await repo.fetchHomePage(force: true).run()) as ForumHomeApiPage;
        final latest = _right(await repo.fetchHomePage(force: true).run()) as ForumHomeApiPage;
        final full = await repo.fetchPageDocument(mine);
        expect(parseForumActivitiesFromApi(full!.json), hasLength(17));
        expect(repo.getCache(), same(latest), reason: 'not published: not the cached page');
        expect(forum.withDocument, hasLength(1));
        // The favorites panel of a page not shown any more is not asked.
        await repo.requestFavoritesPanel(mine);
        expect(forum.withDocument, hasLength(1));
      });

      test('failed, too slow, another account, the session changed: null and the page stays', () async {
        for (final (name, full) in [
          ('failed', _ok({'ok': 0, 'error': 'internal'})),
          ('HTTP 500', (body: '', status: 500)),
          ('another account', _ok({...olderLean(), 'uid': 36, 'document': '<div></div>'})),
        ]) {
          final forum = _Forum(lean: () => _ok(olderLean()), full: () => full);
          final repo = repositoryOf(forum);
          final page = _right(await repo.fetchHomePage().run()) as ForumHomeApiPage;
          expect(await repo.fetchPageDocument(page), isNull, reason: name);
          expect(repo.getCache(), same(page), reason: name);
          await getIt.unregister<NetClientProvider>();
        }

        final slow = Completer<void>();
        var forum = _Forum(
          lean: () => _ok(olderLean()),
          full: () async {
            await slow.future;
            return _ok({...olderLean(), 'document': '<div></div>'});
          },
        );
        var repo = repositoryOf(forum, timeout: const Duration(milliseconds: 100));
        var page = _right(await repo.fetchHomePage().run()) as ForumHomeApiPage;
        expect(await repo.fetchPageDocument(page), isNull, reason: 'timed out');
        slow.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(repo.getCache(), same(page));
        await getIt.unregister<NetClientProvider>();

        // The session of the account changes while the page is asked.
        forum = _Forum(
          lean: () => _ok(olderLean()),
          full: () async {
            cookie.clearUserInfoAndCookie();
            return _ok({...olderLean(), 'document': '<div></div>'});
          },
        );
        repo = repositoryOf(forum);
        page = _right(await repo.fetchHomePage().run()) as ForumHomeApiPage;
        expect(await repo.fetchPageDocument(page), isNull);
        expect(forum.withDocument, hasLength(1));
        expect(repo.getCache(), same(page));
      });

      Future<void> pumpPage(WidgetTester tester, ForumHomeRepository repo) async {
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: RepositoryProvider<ForumHomeRepository>.value(
                value: repo,
                child: ActivitiesPage(key: ObjectKey(repo)),
              ),
            ),
          ),
        );
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump();
        }
        await tester.pumpAndSettle();
      }

      testWidgets('the page: 2.8.2 at once; an older plugin through the page with its document; a failure', (
        tester,
      ) async {
        await LocaleSettings.setLocale(AppLocale.en);
        // Plugin 2.8.2: the lean answer only.
        var forum = _Forum(lean: () => _ok(_withActivityForum(_api('index_v5_282_desc'))), full: () => _ok({}));
        var repo = repositoryOf(forum);
        await pumpPage(tester, repo);
        expect(find.text('【测试活动甲】'), findsOneWidget);
        expect(find.text('【站外「乙」】'), findsOneWidget);
        expect(forum.homepage, hasLength(1));
        expect(forum.withDocument, isEmpty);
        await getIt.unregister<NetClientProvider>();

        // An older plugin: the page asked once more with its document, the links read from it.
        forum = _Forum(
          lean: () => _ok(olderLean()),
          full: () => _ok({...olderLean(), 'document': '<div id="ct">$_productionRow</div>'}),
        );
        repo = repositoryOf(forum);
        await pumpPage(tester, repo);
        expect(find.text('生化危机'), findsOneWidget);
        expect(find.text('游戏俱乐部'), findsOneWidget);
        expect(forum.withDocument, hasLength(1));
        await getIt.unregister<NetClientProvider>();

        // That request failing: a failed load (retry), not "no activities".
        forum = _Forum(lean: () => _ok(olderLean()), full: () => (body: '', status: 500));
        repo = repositoryOf(forum);
        await pumpPage(tester, repo);
        expect(find.text(t.general.failedToLoad), findsOneWidget);
        expect(find.text(t.activitiesPage.empty), findsNothing);
      });
    });
  });

  group('B. the links of a forum card', () {
    test('an image link is named by its picture; one without a name is left out (no empty button)', () {
      // As the production forum's descriptions: banners linking to threads, most without `alt`.
      final description = [
        '<a href="https://www.tsdm39.com/forum.php?mod=viewthread&amp;tid=1" target="_blank">',
        '<img class="zoom" src="https://example.com/1.png" border="0" alt="" /></a>',
        '<a href="forum.php?mod=viewthread&amp;tid=2"><img src="https://example.com/2.png" alt="第二期" /></a>',
        '<a href="forum.php?mod=viewthread&amp;tid=3" title="第三期"><img src="https://example.com/3.png" /></a>',
        '<a href="forum.php?mod=viewthread&amp;tid=4"><font color="red">文字</font></a>',
      ].join();
      const expected = [
        ('第二期', 'forum.php?mod=viewthread&tid=2'),
        ('第三期', 'forum.php?mod=viewthread&tid=3'),
        ('文字', 'forum.php?mod=viewthread&tid=4'),
      ];
      expect(Forum.fromApi({'fid': 1, 'name': '版块', 'description_html': description}).subThreadList, expected);
      final row = parseHtmlDocument(
        [
          '<table><tr class="fl_row"><td><h2><a href="forum.php?mod=forumdisplay&fid=1">版块</a></h2>',
          '<p class="xg2">$description</p></td>',
          '<td class="fl_i"><span class="xi2">1</span><span class="xg1"> / 2</span></td></tr></table>',
        ].join(),
      ).querySelector('tr.fl_row')!;
      expect(Forum.fromFlRowNode(row)!.subThreadList, expected, reason: 'the web page path, the same');
      // Only nameless banners: no shortcut at all.
      expect(
        Forum.fromApi({
          'fid': 1,
          'name': '版块',
          'description_html':
              '<a href="forum.php?mod=viewthread&amp;tid=1"><img src="https://example.com/1.png" /></a>',
        }).subThreadList,
        isNull,
      );
    });

    test('description_html: its thread links, as the page row gives them; none without it', () {
      final row = parseHtmlDocument(_productionRow).querySelector('tr.fl_row')!;
      final page = Forum.fromFlRowNode(row)!;
      expect(page.subThreadList, hasLength(17));
      final api = Forum.fromApi({
        'fid': 45,
        'name': '活动专区',
        'description': '纯文字',
        'description_html': _productionDescription,
      });
      expect(api.subThreadList, page.subThreadList);
      expect(Forum.fromApi({'fid': 45, 'name': '活动专区', 'description': '纯文字'}).subThreadList, isNull);

      // The subforum of the acceptance run whose description links to a thread; the outside link of forum 7 is
      // no thread, as the page's reader takes only `tid=` links.
      final sub = forumPageFromApi(_api('forum_v2_282_sub_desc'), '2').subredditList.single;
      expect(sub.subThreadList, [('捷径 tid=9199857', 'forum.php?mod=viewthread&tid=9199857')]);
      expect(
        forumPageFromApi(_before282(_api('forum_v2_282_sub_desc')), '2').subredditList.single.subThreadList,
        isNull,
      );
      final seven = _category(_api('index_v5_282_desc'), 7);
      expect(seven.subThreadList, [('【测试活动甲】', 'forum.php?mod=viewthread&tid=9199043')]);
    });

    testWidgets('the card shows them under "链接" with the shortcuts on', (tester) async {
      await LocaleSettings.setLocale(AppLocale.en);
      final app = await _registerApp();
      addTearDown(() => _unregisterApp(app));
      await app.settings.setValue(SettingsKeys.showShortcutInForumCard, true);
      final sub = forumPageFromApi(_api('forum_v2_282_sub_desc'), '2').subredditList.single;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: ForumCard(sub))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('${t.forumCard.links} (1)'), findsOneWidget);
      await tester.tap(find.text('${t.forumCard.links} (1)'));
      await tester.pumpAndSettle();
      expect(find.text('捷径 tid=9199857'), findsOneWidget);
    });
  });

  group('C. link forums and forums the viewer may not enter', () {
    test('categories: redirect and private as the page prints them', () {
      final link = _category(_api('index_v5_282_redirect'), 25);
      expect(link.redirectUrl, 'https://example.com/tsdmapp282-25');
      expect(link.url, 'https://example.com/tsdmapp282-25');
      expect((link.threadCount, link.replyCount, link.threadTodayCount), (0, 0, null));
      expect(link.latestThreadUrl, isNull);
      expect(link.isPrivate, isFalse);

      final hidden = _category(_api('index_v5_282_private'), 26);
      expect(hidden.isPrivate, isTrue);
      expect(hidden.redirectUrl, isNull);
      expect((hidden.threadCount, hidden.replyCount), (10, 10), reason: 'the page prints the counts');
      expect(hidden.latestThreadUrl, isNull, reason: 'the page prints "私密版块" in place of the latest thread');

      // The fixture tool's group `index_fav` (2.8.2): forum 29 a link forum among the categories too.
      final fav = _category(_api('index_v5_favorites'), 29);
      expect(fav.redirectUrl, 'https://example.com/tsdmapp281');
      // Any other forum: neither.
      final plain = _category(_api('index_v5_282_redirect'), 7);
      expect((plain.isPrivate, plain.redirectUrl), (false, null));
      expect(plain.latestThreadUrl, isNotNull);
    });

    test('subforums: private and redirect; an older plugin by permission 1, without its latest thread', () {
      final hidden = forumPageFromApi(_api('forum_v2_282_sub_private'), '2').subredditList.single;
      expect((hidden.isPrivate, hidden.latestThreadUrl, hidden.threadCount), (true, null, 10));
      final link = forumPageFromApi(_api('forum_v2_282_sub_redirect'), '2').subredditList.single;
      expect(
        (link.redirectUrl, link.threadCount, link.latestThreadUrl),
        ('https://example.com/tsdmapp282-15', 0, null),
      );
      final open = forumPageFromApi(_api('forum_v2_282_sub_desc'), '2').subredditList.single;
      expect((open.isPrivate, open.redirectUrl), (false, null));
      expect(open.latestThreadUrl, '$baseUrl/forum.php?mod=redirect&tid=9199857&goto=lastpost');

      // Plugin 2.8.1 gave the latest thread of a subforum seen by name only (`permission` 1) and no `private`.
      final older = _edited(_api('forum_v2_282_sub_private'), (m) {
        if (m['fid'] == 15) {
          m
            ..remove('private')
            ..['lastpost'] = {'tid': 9199857, 'subject': '1.9.0 子版发帖 758113', 'dateline': 1792256772, 'author': 'x'};
        }
      });
      final sub = forumPageFromApi(older, '2').subredditList.single;
      expect((sub.isPrivate, sub.latestThreadUrl), (true, null));
    });

    testWidgets('the cards say so, as with the favorites panel', (tester) async {
      await LocaleSettings.setLocale(AppLocale.en);
      final app = await _registerApp();
      addTearDown(() => _unregisterApp(app));
      final link = _category(_api('index_v5_282_redirect'), 25);
      final hidden = _category(_api('index_v5_282_private'), 26);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(child: Column(children: [ForumCard(link), ForumCard(hidden)])),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.forumCard.redirectForum), findsOneWidget);
      expect(find.text(t.forumCard.privateForum), findsOneWidget);
    });
  });

  group('D. the reply count of the thread page', () {
    test('allreplies, the "回复: N" of the page, whatever filter; replies without it', () {
      // Only the author's floors: the forum's `replies` counts them for the pages.
      final author = _api('thread_v15_282_author');
      expect(((author['thread'] as Map)['replies'], (author['thread'] as Map)['allreplies']), (2, 15));
      expect(threadPageFromApi(author, 1).replyCount, 15);
      final long = _api('thread_v3_long_author');
      expect(threadPageFromApi(long, 1).replyCount, 301);
      expect(threadPageFromApi(_api('thread_v3_long_p1'), 1).replyCount, 301);
      // An older plugin.
      final older = _edited(author, (m) => m.remove('allreplies'));
      expect(threadPageFromApi(older, 1).replyCount, 2);
    });
  });

  group('E and F. blocked avatars and hot replies', () {
    test('avatar_blocked: no avatar, nor in the brief profile; the others keep theirs', () {
      final posts = threadPageFromApi(_api('thread_v15_282_avatar_blocked'), 1).postList;
      final blocked = posts.where((e) => e.avatarBlocked).map((e) => e.postID).toList();
      expect(blocked, ['6733', '6734', '6735']);
      for (final post in posts.where((e) => e.avatarBlocked)) {
        expect(post.author.avatarUrl, isNull, reason: post.postID);
        expect(post.userBriefProfile?.avatarUrl, isNull, reason: post.postID);
      }
      final open = posts.firstWhere((e) => e.postID == '6732');
      expect(open.avatarBlocked, isFalse);
      expect(open.author.avatarUrl, isNotNull);
      // The same floors before the site hid the avatars.
      expect(threadPageFromApi(_api('thread_v15_282_hot'), 1).postList.where((e) => e.avatarBlocked), isEmpty);
    });

    test('hot replies: "推荐" with the floor they really are; the others as before', () {
      final posts = threadPageFromApi(_api('thread_v15_282_hot'), 1).postList;
      final hot = posts.where((e) => e.hot).toList();
      expect(hot.map((e) => (e.postID, e.postFloor, e.hotFloor, e.shownFloor)), [
        ('6732', null, 2, 2),
        ('6742', null, 12, 12),
      ]);
      expect(hot.first.shareLink, contains('goto=findpost'));
      final others = posts.where((e) => !e.hot).toList();
      expect(others.map((e) => e.postFloor), [1, 3, 4, 5, 6, 7, 8, 9, 10]);
      expect(others.every((e) => e.hotFloor == null), isTrue);
      // A hot reply whose floor the forum does not know (`hot_position` 0).
      final unknown = threadPageFromApi(
        _edited(_api('thread_v15_282_hot'), (m) {
          if (m['hot'] == 1) {
            m['hot_position'] = 0;
          }
        }),
        1,
      ).postList.firstWhere((e) => e.hot);
      expect((unknown.hotFloor, unknown.shownFloor), (null, null));
    });

    test('the web page path, production markup: a hot reply prints "-1#"; no floor number, a hot reply', () {
      final node = parseHtmlDocument(
        File('test/data/thread_hot_reply_x5.html').readAsStringSync(),
      ).querySelector('div#post_77994723')!;
      final post = Post.fromPostNode(node, 1)!;
      expect((post.hot, post.postFloor, post.hotFloor, post.shownFloor), (true, null, null, null));
      expect(post.shareLink, contains('goto=findpost&ptid=1265238&pid=77994723'));
      // A floor of its own number stays a floor.
      final plain = Post.fromPostNode(
        parseHtmlDocument(
          File('test/data/thread_hot_reply_x5.html').readAsStringSync().replaceFirst('<em>-1</em>', '<em>5</em>'),
        ).querySelector('div#post_77994723')!,
        1,
      )!;
      expect((plain.hot, plain.postFloor), (false, 5));
    });

    test('the web page path: "头像被屏蔽" and "推荐" read from the floor', () {
      final json = _api('thread_v15_282_avatar_blocked');
      final floor = (json['posts'] as List).cast<Map<String, dynamic>>().firstWhere((e) => e['pid'] == 6733);
      uh.Element node({required String number, required String authorHtml}) => parseHtmlDocument(
        '<div id="post_6733"><table><tbody><tr><td class="pls">$authorHtml</td><td class="plc"> '
        '<div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&ptid=9200647&pid=6733">$number</a></strong> '
        '<div class="pti"><div class="authi"><a href="home.php?mod=space&uid=76" class="xi2">cl_ban</a></div></div></div> '
        '<div class="pct"><div class="pcb">内文</div></div></td></tr></tbody></table></div>',
      ).querySelector('div#post_6733')!;
      final blocked = Post.fromPostNode(node(number: '<em>3</em>', authorHtml: floor['author_html'] as String), 1)!;
      expect((blocked.avatarBlocked, blocked.author.avatarUrl, blocked.postFloor, blocked.hot), (true, null, 3, false));
      final hot = Post.fromPostNode(
        node(number: '<em>推荐</em>', authorHtml: '<div><div class="avatar"><img src="a.png"></div></div>'),
        1,
      )!;
      expect((hot.avatarBlocked, hot.postFloor, hot.hot, hot.hotFloor), (false, null, true, null));
    });

    group('the cards', () {
      late ({AppDatabase db, SettingsRepository settings}) app;
      late SettingsBloc bloc;

      setUp(() async {
        await LocaleSettings.setLocale(AppLocale.en);
        app = await _registerApp();
        bloc = SettingsBloc(settingsRepository: app.settings, fragmentsRepository: FragmentsRepository());
      });
      tearDown(() async {
        await bloc.close();
        await _unregisterApp(app);
      });

      /// [post] without what loads images or other pages (the avatar's address, the brief profile, the badges…), as
      /// test_225 shows the cards: what is tested here is the header.
      Post bare(Post post) => post.copyWith(
        author: User(name: post.author.name, uid: post.author.uid, url: post.author.url),
        userBriefProfile: null,
        postMedals: null,
        badge: null,
        secondBadge: null,
        signature: null,
        pokemon: null,
        checkin: null,
      );

      Future<void> pump(WidgetTester tester, List<Post> posts) async {
        await tester.pumpWidget(
          BlocProvider<SettingsBloc>.value(
            value: bloc,
            child: TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  body: SingleChildScrollView(child: Column(children: [for (final p in posts) PostCard(bare(p))])),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
      }

      testWidgets('a blocked avatar is a mark saying so, never an image', (tester) async {
        final posts = threadPageFromApi(_api('thread_v15_282_avatar_blocked'), 1).postList;
        await pump(tester, [posts.firstWhere((e) => e.postID == '6733'), posts.firstWhere((e) => e.postID == '6732')]);
        expect(find.byType(HeroUserAvatar), findsOneWidget, reason: 'the other floor keeps its avatar');
        expect(find.byIcon(Icons.no_accounts_outlined), findsOneWidget);
        expect(find.byTooltip(t.postCard.avatarBlocked), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('a hot reply says "推荐" with its floor; two from one author build side by side', (tester) async {
        final posts = threadPageFromApi(_api('thread_v15_282_hot'), 1).postList;
        final hot = posts.firstWhere((e) => e.postID == '6742');
        await pump(tester, [posts.first, hot, hot.copyWith(postID: '6743', hotFloor: null)]);
        expect(find.text('#1'), findsOneWidget);
        expect(find.text('${t.postCard.hotReply} #12'), findsOneWidget);
        expect(find.text(t.postCard.hotReply), findsOneWidget, reason: 'its floor not known');
        // Going to the floor only where its floor is known (the production forum does not tell it).
        expect(find.byTooltip(t.postCard.jumpToHotFloor), findsOneWidget);
        expect(find.text('#'), findsNothing);
        expect(tester.takeException(), isNull);
      });

      testWidgets('the placeholder of a blocked author names a hot reply as the card does', (tester) async {
        await tester.pumpWidget(
          TranslationProvider(
            child: const MaterialApp(
              home: Scaffold(
                body: Column(
                  children: [
                    BlockedPostPlaceholder(uid: 1, username: 'Bob', hot: true),
                    BlockedPostPlaceholder(uid: 1, username: 'Bob', hot: true, hotFloor: 12),
                    BlockedPostPlaceholder(uid: 1, username: 'Bob', floor: 3),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(find.text(t.postCard.hotReply), findsOneWidget);
        expect(find.text('${t.postCard.hotReply} #12'), findsOneWidget);
        expect(find.text('#3'), findsOneWidget);
        expect(find.text('#'), findsNothing);
      });
    });

    test('the rate page and the report name the floor, without one when it is not known', () {
      expect(
        ratePostDescription(t, username: 'Bob', floor: '12'),
        t.ratePostPage.description(username: 'Bob', floor: '12'),
      );
      for (final unknown in ['0', 'null', '']) {
        expect(
          ratePostDescription(t, username: 'Bob', floor: unknown),
          t.ratePostPage.descriptionNoFloor(username: 'Bob'),
        );
      }
      expect(t.ratePostPage.descriptionNoFloor(username: 'Bob'), isNot(contains('null')));
      final posts = threadPageFromApi(_api('thread_v15_282_hot'), 1).postList;
      final hot = posts.firstWhere((e) => e.postID == '6742');
      expect(postReportFloorLabel(t, hot), '${t.postCard.hotReply} #12');
      expect(postReportFloorLabel(t, hot.copyWith(hotFloor: null)), '${t.postCard.hotReply} (PID 6742)');
      expect(postReportFloorLabel(t, posts.first), '#1');
      expect(postReportFloorLabel(t, posts.first.copyWith(postFloor: null)), 'PID ${posts.first.postID}');
    });
  });

  group('G. the pages of a forum', () {
    test('page and pages as the forum printed them: asked past the limit, the first page of it', () {
      // fid 11 of the test forum: 18 pages, page 23 asked; then the site's limit of pages (`threadmaxpages`) 3.
      final beyond = forumPageFromApi(_api('forum_v2_282_beyond'), '11');
      expect((beyond.currentPage, beyond.totalPages, beyond.canLoadMore), (1, 18, true));
      final maxBeyond = forumPageFromApi(_api('forum_v2_282_max3_beyond'), '11');
      expect((maxBeyond.currentPage, maxBeyond.totalPages, maxBeyond.canLoadMore), (1, 3, true));
      final last = forumPageFromApi(_api('forum_v2_282_max3_last'), '11');
      expect((last.currentPage, last.totalPages, last.canLoadMore), (3, 3, false));
      expect(
        maxBeyond.normalThreadList.map((e) => e.threadID),
        forumPageFromApi(_api('forum_v2_282_beyond'), '11').normalThreadList.map((e) => e.threadID),
        reason: 'the threads of the first page, as the answered page tells',
      );
    });

    test('a page jumped to past the limit shows the page answered, its last page the one named', () async {
      final repository = _FakeForumRepository(
        (n) => n > 3
            ? _forumPage(answered: 1, total: 3, threads: [1, 2])
            : _forumPage(answered: n, total: 3, threads: [n * 10]),
      );
      final bloc = ForumBloc(fid: '11', forumRepository: repository)..add(const ForumJumpPageRequested(23));
      await bloc.stream.firstWhere((e) => e.status == ForumStatus.success);
      expect((bloc.state.currentPage, bloc.state.totalPages), (1, 3));
      expect(bloc.state.normalThreadList.map((e) => e.threadID), ['1', '2']);
      await bloc.close();
    });

    test('retrying a page that failed asks that page again: nothing added twice', () async {
      var failing = false;
      final asked = <int>[];
      final repository = _FakeForumRepository((n) => _forumPage(answered: n, total: 3, threads: [n * 10]))
        ..fail = () => failing;
      final bloc = ForumBloc(fid: '11', forumRepository: repository)..add(const ForumLoadMoreRequested(1));
      await bloc.stream.firstWhere((e) => e.status == ForumStatus.success);
      failing = true;
      bloc.add(const ForumLoadMoreRequested(2));
      // Going on with the list failed: the list stays, its end offers the retry (test_239).
      await bloc.stream.firstWhere((e) => e.loadMoreFailed);
      expect(bloc.state.status, ForumStatus.success);
      expect(bloc.state.normalThreadList.map((e) => e.threadID), ['10']);
      failing = false;
      bloc.add(const ForumRetryRequested());
      await bloc.stream.firstWhere((e) => e.currentPage == 2);
      expect(bloc.state.loadMoreFailed, isFalse);
      expect(bloc.state.normalThreadList.map((e) => e.threadID), ['10', '20'], reason: 'before: 10, 10');
      expect(bloc.state.currentPage, 2);
      asked.addAll(repository.asked);
      expect(asked, [1, 2, 2]);

      // A jump that failed: the page jumped to.
      failing = true;
      bloc.add(const ForumJumpPageRequested(3));
      await bloc.stream.firstWhere((e) => e.status == ForumStatus.failure);
      failing = false;
      bloc.add(const ForumRetryRequested());
      await bloc.stream.firstWhere((e) => e.status == ForumStatus.success);
      expect(bloc.state.normalThreadList.map((e) => e.threadID), ['30']);
      expect(repository.asked.skip(3), [3, 3]);
      await bloc.close();
    });

    test('going on past the last page: nothing added, the list ends', () async {
      // The forum's last page shrank to 2 while the list showed page 2 of 3: page 3 answers the first page.
      var total = 3;
      final repository = _FakeForumRepository(
        (n) => n > total
            ? _forumPage(answered: 1, total: total, threads: [10])
            : _forumPage(answered: n, total: total, threads: [n * 10]),
      );
      final bloc = ForumBloc(fid: '11', forumRepository: repository)..add(const ForumLoadMoreRequested(1));
      await bloc.stream.firstWhere((e) => e.status == ForumStatus.success);
      bloc.add(const ForumLoadMoreRequested(2));
      await bloc.stream.firstWhere((e) => e.currentPage == 2);
      total = 2;
      bloc.add(const ForumLoadMoreRequested(3));
      await bloc.stream.firstWhere((e) => !e.canLoadMore);
      expect(bloc.state.normalThreadList.map((e) => e.threadID), ['10', '20'], reason: 'page 1 not added again');
      expect((bloc.state.currentPage, bloc.state.totalPages, bloc.state.canLoadMore), (2, 2, false));
      expect(repository.asked, [1, 2, 3]);
      await bloc.close();
    });
  });

  test('the answers of the acceptance run carry nothing of the test forum', () {
    final files = Directory('test/data/tsdmapp').listSync().whereType<File>().where((f) => f.path.contains('_282_'));
    expect(files, hasLength(12));
    for (final file in files) {
      final raw = file.readAsStringSync();
      // The test forum's host is rewritten to the production forum's, its pages' blocks dropped (`nodoc`).
      expect(raw, isNot(matches(RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b'))), reason: '${file.path}: an IPv4 address');
      for (final marker in ['"head"', '"document"']) {
        expect(raw, isNot(contains(marker)), reason: '${file.path} $marker');
      }
      expect(raw, isNot(matches(RegExp(r'[\w.+-]+@[\w-]+\.[a-z]{2,}'))), reason: '${file.path}: an email address');
      expect((jsonDecode(raw) as Map<String, dynamic>)['formhash'], 'f1f2f3f4', reason: file.path);
    }
  });

  test('I. the app expects plugin 2.8.2 or later', () {
    expect(compareTsdmAppVersions(expectedTsdmAppVersion, '2.8.2'), greaterThanOrEqualTo(0));
    expect(const TsdmAppPluginInfo(version: '2.8.1', api: 1, nodoc: true).olderThanExpected, isTrue);
    expect(const TsdmAppPluginInfo(version: expectedTsdmAppVersion, api: 1, nodoc: true).olderThanExpected, isFalse);
  });
}
