/// The "我收藏的版块" panel of the topics tab (版块) built from the homepage answer of the forum's app API.
///
/// Before, the panel looked each id of `favorite_forums` up among the forums of the categories: a favorite subforum
/// (listed by id and name only, if at all) showed the default icon, 0 / 0 / 0 and no latest thread, and a forum with
/// subforums showed the counts of the categories, which add the subforums' (the web page's panel prints the forum's
/// own). Plugin 2.8.1 answers the panel as the page prints it (`favorites`): the cards are built from it. An older
/// plugin (2.3.0 to 2.8.0) names the favorites by id only: when it names any, the topics tab asks the shared repository
/// for the panel, which asks the page once more without `nodoc=1` in the background (the homepage never waits for it)
/// and publishes that answer; the panel is read from its `document`, as the web page shows it. Pages fetched for the
/// homepage keep the panel the topics tab read. A plugin 2.8.1, a guest and a member without favorites cost no request
/// more; the web page path is untouched. A link forum shows "链接到外部地址" without counts and opens in a browser
/// only, a web address only; a setting that is not one never fails the page.
///
/// Test data:
/// * `tsdmapp/index_v5_favorites.json`: plugin 2.8.1, from the plugin's fixture tool (group `index_fav`): the test
///   forum's account ag_low2 favorited a subforum (15, under 2, with an icon and a description), a forum with that
///   subforum (2), a forum hidden from them (26, the forum hides such forums: `hideprivate`), a forum (7), a link
///   forum (29) and a group's forum (28).
/// * `index_favorites_panel_x5.json`: the same page of the same moment asked without `nodoc=1` (the answer keeps its
///   `document`), trimmed to the fields the panel needs and the document to the panel (the grid of six favorites;
///   the forum's host and name as in the other samples).
/// * `forum_index_x5.html`: the production web page, a panel of one favorite in the list layout.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:rxdart/rxdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_api.dart';
import 'package:tsdm_client/features/forum/utils/group.dart';
import 'package:tsdm_client/features/homepage/bloc/homepage_bloc.dart';
import 'package:tsdm_client/features/homepage/utils/homepage_api.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/topics/bloc/topics_bloc.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/forum_card.dart';
import 'package:universal_html/parsing.dart';

Translations get tr => LocaleSettings.instance.currentTranslations;

Map<String, dynamic> _json(String path) =>
    jsonDecode(File('test/data/$path').readAsStringSync()) as Map<String, dynamic>;

/// The answer of plugin 2.8.1 of the fixture (lean).
Map<String, dynamic> _plugin281() => _json('tsdmapp/index_v5_favorites.json');

/// The answer of the same moment asked with its document (plugin 2.8.1: `favorites` and the panel in `document`).
Map<String, dynamic> _withDocument() => _json('index_favorites_panel_x5.json');

/// [json] as plugin 2.3.0 to 2.8.0 answers it: no `favorites`.
Map<String, dynamic> _older(Map<String, dynamic> json) => {...json}..remove('favorites');

/// [json] asked lean (`nodoc=1`): no `document`.
Map<String, dynamic> _lean(Map<String, dynamic> json) => {...json}..remove('document');

/// The forums of the panel (the first group) of [json], none when there is no panel.
List<Forum> _panel(Map<String, dynamic> json) =>
    forumGroupsFromApi(json).where((e) => e.isFavorites).firstOrNull?.forumList ?? const [];

/// The forum [fid] among the categories of [json] (not the panel).
Forum _inCategories(Map<String, dynamic> json, int fid) => forumGroupsFromApi(
  json,
).where((e) => !e.isFavorites).expand((e) => e.forumList).firstWhere((e) => e.forumID == fid);

/// The forum's wall clock (UTC+8) of a time the app API gives, to the minute: the web page prints the time so.
(int, int, int, int, int) _wallMinute(DateTime time) {
  final wall = time.toUtc().add(const Duration(hours: 8));
  return (wall.year, wall.month, wall.day, wall.hour, wall.minute);
}

/// The time the web page printed, read by its reader as the wall clock of the forum, to the minute.
(int, int, int, int, int) _pageMinute(DateTime time) => (time.year, time.month, time.day, time.hour, time.minute);

const _viewer = UserLoginInfo(uid: 35, username: 'ag_low2');

/// One answer of the fake forum.
typedef _Answer = ({String body, bool json, int status});

_Answer _api(Object answer, {int status = 200}) =>
    (body: answer is String ? answer : jsonEncode(answer), json: true, status: status);

/// A forum answering the homepage asked lean (`nodoc=1`) with [lean] and asked with its document with [full],
/// recording every request; [onFull] runs when the page with its document is asked, before it is answered.
final class _Forum implements HttpClientAdapter {
  _Forum({required this.lean, FutureOr<_Answer> Function()? full}) : full = full ?? lean;

  FutureOr<_Answer> Function() lean;
  FutureOr<_Answer> Function() full;
  FutureOr<void> Function()? onFull;
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
    final _Answer a;
    if (query['nodoc'] == '1') {
      a = await lean();
    } else {
      await onFull?.call();
      a = await full();
    }
    return ResponseBody.fromString(
      a.body,
      a.status,
      headers: {
        Headers.contentTypeHeader: [if (a.json) 'application/json; charset=utf-8' else 'text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// [forum], and the daily red packet of the hongbao plugin claimed through it ([onClaim]).
final class _Claim implements HttpClientAdapter {
  _Claim(this.forum, this.onClaim);

  final _Forum forum;
  final void Function() onClaim;

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancel) async {
    if (options.uri.queryParameters['id'] == 'hongbao:daily') {
      onClaim();
      return ResponseBody.fromString(
        jsonEncode({'ok': true, 'amount': 5}),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json; charset=utf-8'],
        },
      );
    }
    return forum.fetch(options, requestStream, cancel);
  }

  @override
  void close({bool force = false}) {}
}

/// Authentication repository of [user].
final class _FakeAuth extends AuthenticationRepository {
  _FakeAuth(this.user);

  UserLoginInfo? user;
  final subject = BehaviorSubject<AuthStatus>();

  @override
  UserLoginInfo? get currentUser => user;

  @override
  Stream<AuthStatus> get status => subject.stream;

  @override
  Future<void> dispose() async {
    await subject.close();
    await super.dispose();
  }
}

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

/// The list layout of the panel (up to three favorites) as the forum's template prints it: a forum with its latest
/// thread, a forum the viewer may not enter ("私密版块") and a link forum ("链接到外部地址", no counts).
const _listLayoutPage = '''
<html><body><div id="wp" class="wp"><div id="ct" class="wp cl"><div class="mn"><div class="fl bm">
<div class="bm bmw  cl">
<div class="bm_h cl"><h2><a href="home.php?mod=space&amp;do=favorite&amp;type=forum">我收藏的版块</a></h2></div>
<div id="category_0" class="bm_c" style="">
<table cellspacing="0" cellpadding="0" class="fl_tb">
<tr><td class="fl_icn"><a href="forum.php?mod=forumdisplay&fid=7" title="神作殿堂"><img src="data/attachment/common/7.png" alt="神作殿堂" /></a></td>
<td>
<h2><a href="forum.php?mod=forumdisplay&fid=7">神作殿堂</a><em class="xw0 xi1" title="今日"> (3)</em></h2>
<p class="xg2">经典神作回顾与安利推荐</p>
</td>
<td class="fl_i"><span class="xi2">27</span><span class="xg1"> / <span title="12300">1万</span></span></td>
<td class="fl_by">
<div>
<a href="forum.php?mod=redirect&amp;tid=9199201&amp;goto=lastpost#lastpost" class="xi2">ATP JSON 89328</a> <cite>2026-9-23 21:58 <a href="home.php?mod=space&username=ag_low2">ag_low2</a></cite>
</div>
</td>
</tr>
<tr class="fl_row">
<td class="fl_icn"><a href="forum.php?mod=forumdisplay&fid=26" title="BU 黑名單權限版 G"><img src="data/attachment/common/26.png" alt="BU 黑名單權限版 G" /></a></td>
<td>
<h2><a href="forum.php?mod=forumdisplay&fid=26">BU 黑名單權限版 G</a></h2>
</td>
<td class="fl_i"><span class="xi2">10</span><span class="xg1"> / 10</span></td>
<td class="fl_by">
<div>
私密版块
</div>
</td>
</tr>
<tr class="fl_row">
<td class="fl_icn"><a href="forum.php?mod=forumdisplay&fid=29" target="_blank" title="BU 通知驗收版 H"><img src="template/discuzx5/static//images/forum.png" alt="BU 通知驗收版 H" /></a></td>
<td>
<h2><a href="forum.php?mod=forumdisplay&fid=29" target="_blank">BU 通知驗收版 H</a></h2>
</td>
<td class="fl_i">
</td>
<td class="fl_by">
<div>
<a href="forum.php?mod=forumdisplay&fid=29" class="xi2">链接到外部地址</a>
</div>
</td>
</tr>
<tr class="fl_row">
</tr>
</table>
</div>
</div>
</div></div></div></div></body></html>
''';

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(TsdmAppApi.reset);

  group('plugin 2.8.1: the panel is the favorites of the answer', () {
    test('every favorite in the order of the page, first; a favorite subforum with all of its data', () {
      final json = _plugin281();
      final groups = forumGroupsFromApi(json);
      expect(groups.first.isFavorites, isTrue);
      expect(groups.first.name, '我收藏的版块');
      expect(groups.first.url, 'home.php?mod=space&do=favorite&type=forum');
      expect(groups.first.forumList.map((e) => e.forumID), [15, 2, 26, 7, 29, 28]);
      expect(groups.skip(1).where((e) => e.isFavorites), isEmpty);

      final sub = groups.first.forumList.first;
      expect(sub.name, 'GLTEST 子版塊（型別 sub）');
      expect(sub.url, '$baseUrl/forum.php?mod=forumdisplay&fid=15');
      expect(sub.iconUrl, '$baseUrl/data/attachment/common/tsdmapp281_sub.png');
      expect((sub.threadCount, sub.replyCount), (10, 10));
      expect(sub.latestThreadUrl, '$baseUrl/forum.php?mod=redirect&tid=9199857&goto=lastpost');
      expect(sub.latestThreadTitle, '1.9.0 子版发帖 758113');
      expect(sub.latestThreadUserName, 'ag_low2');
      expect(sub.latestThreadTime, DateTime.fromMillisecondsSinceEpoch(1792256772 * 1000));
      expect(sub.isPrivate, isFalse);
      expect(sub.redirectUrl, isNull);
      // The forum lists no subforums here: the subforum is nowhere among the categories.
      expect(groups.skip(1).expand((e) => e.forumList).map((e) => e.forumID), isNot(contains(15)));

      // The group's forum, listed in no category either.
      final groupForum = groups.first.forumList.last;
      expect(groupForum.name, 'BU群組855956');
      expect((groupForum.threadCount, groupForum.replyCount), (3, 3));
      expect(groupForum.latestThreadUserName, 'ag_mid');
    });

    test('a forum with subforums: its own counts, where the categories (and the panel before) add the subforums', () {
      final json = _plugin281();
      final parent = _panel(json)[1];
      expect(parent.forumID, 2);
      expect((parent.threadCount, parent.replyCount), (47, 147));
      final listed = _inCategories(json, 2);
      expect((listed.threadCount, listed.replyCount), (57, 157), reason: 'with the 10 / 10 of subforum 15');

      // What the panel showed when it looked the favorites up among the categories (the answer of plugin 2.8.0,
      // lean): the categories' counts, the subforum, the hidden forum and the group's forum left out.
      final before = _panel(_older(json));
      expect(before.map((e) => e.forumID), [2, 7, 29]);
      expect((before.first.threadCount, before.first.replyCount), (57, 157));

      // The member of the index fixture: the same forum, the same counts.
      final member = _json('tsdmapp/index_v5_member.json');
      expect(_panel(member).map((e) => (e.forumID, e.threadCount, e.replyCount)), [(2, 47, 147)]);
      expect(_inCategories(member, 2).threadCount, 57);
    });

    test('a link forum: its address, no counts, no latest thread', () {
      final link = _panel(_plugin281())[4];
      expect(link.forumID, 29);
      expect(link.redirectUrl, 'https://example.com/tsdmapp281');
      expect((link.threadCount, link.replyCount, link.threadTodayCount), (0, 0, null));
      expect(link.latestThreadUrl, isNull);
      expect(link.latestThreadTime, isNull);
      expect(link.isPrivate, isFalse);
    });

    test('a forum hidden from the viewer (hideprivate): no icon, no latest thread, the counts; not marked', () {
      final hidden = _panel(_plugin281())[2];
      expect(hidden.forumID, 26);
      expect(hidden.name, 'BU 黑名單權限版 G');
      expect(hidden.iconUrl, isEmpty, reason: 'the page prints the file name of the icon as text');
      expect((hidden.threadCount, hidden.replyCount), (10, 10));
      expect(hidden.latestThreadUrl, isNull);
      expect(hidden.latestThreadTime, isNull);
      expect(hidden.isPrivate, isFalse, reason: 'the page prints no 私密版块 then');
      expect(hidden.redirectUrl, isNull);
    });

    test('private 1 (a forum that does not hide them): marked, its counts and icon kept', () {
      final json = _plugin281();
      final favorites = (json['favorites'] as List).cast<Map<String, dynamic>>();
      favorites[3] = {...favorites[3], 'private': 1, 'lastpost': null, 'icon': '$baseUrl/data/attachment/common/7.png'};
      final forum = _panel(json)[3];
      expect(forum.forumID, 7);
      expect(forum.isPrivate, isTrue);
      expect((forum.threadCount, forum.replyCount), (27, 2300));
      expect(forum.iconUrl, '$baseUrl/data/attachment/common/7.png');
      expect(forum.latestThreadTime, isNull);
      expect(_panel(_plugin281())[3].isPrivate, isFalse);
    });

    test("the panel follows the favorites' order; every id of favorite_forums is seeded as before", () {
      final json = _plugin281();
      json['favorites'] = (json['favorites'] as List).reversed.toList();
      expect(_panel(json).map((e) => e.forumID), [28, 29, 7, 26, 2, 15]);
      expect(favoriteForumIdsOf(json), [15, 2, 26, 7, 29, 28]);
    });

    test('no panel: a guest, a member without favorites, the categories untouched', () {
      final guest = _json('tsdmapp/index_v5_guest.json');
      expect(guest['favorites'], isEmpty);
      expect(forumGroupsFromApi(guest).where((e) => e.isFavorites), isEmpty);
      final none = {..._plugin281(), 'favorites': <Object?>[], 'favorite_forums': <Object?>[]};
      expect(forumGroupsFromApi(none).where((e) => e.isFavorites), isEmpty);
      expect(
        forumGroupsFromApi(none).map((e) => e.name),
        forumGroupsFromApi(_plugin281()).skip(1).map((e) => e.name),
      );
    });
  });

  group('plugin 2.3.0 to 2.8.0: the panel read from the page', () {
    test('favoritesPanelNeedsDocument: favorites named by id only, lean; nothing else', () {
      final older = _older(_plugin281());
      expect(favoritesPanelNeedsDocument(older), isTrue);
      expect(favoritesPanelNeedsDocument(_plugin281()), isFalse, reason: 'plugin 2.8.1');
      expect(favoritesPanelNeedsDocument({..._plugin281(), 'favorites': <Object?>[]}), isFalse);
      expect(favoritesPanelNeedsDocument(_older(_withDocument())), isFalse, reason: 'the document is there');
      expect(favoritesPanelNeedsDocument({...older, 'favorite_forums': <Object?>[]}), isFalse, reason: 'no favorites');
      expect(favoritesPanelNeedsDocument(_older(_json('tsdmapp/index_v5_guest.json'))), isFalse, reason: 'a guest');
      expect(
        favoritesPanelNeedsDocument({'ok': 0, 'error': 'message', 'message': '站点已关闭', 'login': 0, 'schema': 5}),
        isFalse,
        reason: "the forum's message",
      );
    });

    test('the panel of the page gives what the plugin gives for the same moment', () {
      final full = _withDocument();
      final fromApi = _panel(full);
      final fromPage = _panel(_older(full));
      expect(fromPage.map((e) => e.forumID), [15, 2, 26, 7, 29, 28]);
      expect(fromPage.map((e) => e.forumID), fromApi.map((e) => e.forumID));
      for (final (page, api) in IterableZip([fromPage, fromApi]).map((e) => (e[0], e[1]))) {
        final reason = 'fid ${api.forumID}';
        expect(page.name, api.name, reason: reason);
        expect((page.threadCount, page.replyCount), (api.threadCount, api.replyCount), reason: reason);
        expect(page.threadTodayCount, api.threadTodayCount, reason: reason);
        expect(page.isPrivate, api.isPrivate, reason: reason);
        expect(page.redirectUrl == null, api.redirectUrl == null, reason: reason);
        expect(
          page.latestThreadUrl?.uriQueryParameter('tid'),
          api.latestThreadUrl?.uriQueryParameter('tid'),
          reason: reason,
        );
        expect(page.latestThreadTime == null, api.latestThreadTime == null, reason: reason);
        if (api.latestThreadTime != null) {
          expect(_pageMinute(page.latestThreadTime!), _wallMinute(api.latestThreadTime!), reason: reason);
        }
      }
      // The parent forum: its own counts, not the categories'.
      expect((fromPage[1].threadCount, fromPage[1].replyCount), (47, 147));
      expect(_inCategories(full, 2).threadCount, 57);

      // What only the page has: the forum's default picture for a forum without an icon, the icon as the page links
      // it; nothing for the hidden forum (its file name printed as text). The grid prints no title nor author of the
      // latest thread, and no address of the link forum: its own page, which the forum redirects.
      expect(fromPage.map((e) => e.iconUrl), [
        'data/attachment/common/tsdmapp281_sub.png',
        'template/discuzx5/static//images/forum.png',
        '',
        'template/discuzx5/static//images/forum.png',
        'template/discuzx5/static//images/forum.png',
        'template/discuzx5/static//images/forum.png',
      ]);
      expect(fromPage.map((e) => e.latestThreadTitle), everyElement(isNull));
      expect(fromPage[4].redirectUrl, '$baseUrl/forum.php?mod=forumdisplay&fid=29');
      expect(fromApi[4].redirectUrl, 'https://example.com/tsdmapp281');
    });

    test('the list layout of up to three: a forum the viewer may not enter, a link forum; the web path as before', () {
      final document = parseHtmlDocument(_listLayoutPage);
      final forums = favoriteForumsOfDocument(document)!;
      expect(forums.map((e) => e.forumID), [7, 26, 29]);

      final normal = forums[0];
      expect((normal.threadCount, normal.replyCount, normal.threadTodayCount), (27, 12300, 3));
      expect(normal.iconUrl, 'data/attachment/common/7.png');
      expect(normal.latestThreadTitle, 'ATP JSON 89328');
      expect(normal.latestThreadUserName, 'ag_low2');
      expect(_pageMinute(normal.latestThreadTime!), (2026, 9, 23, 21, 58));
      expect((normal.isPrivate, normal.redirectUrl), (false, null));

      final private = forums[1];
      expect(private.isPrivate, isTrue);
      expect((private.threadCount, private.replyCount), (10, 10));
      expect(private.iconUrl, 'data/attachment/common/26.png');
      expect(private.latestThreadUrl, isNull);
      expect(private.latestThreadTime, isNull);

      final link = forums[2];
      expect(link.name, 'BU 通知驗收版 H');
      expect((link.threadCount, link.replyCount, link.threadTodayCount), (0, 0, null));
      expect(link.redirectUrl, '$baseUrl/forum.php?mod=forumdisplay&fid=29');
      expect(link.iconUrl, 'template/discuzx5/static//images/forum.png');
      expect(link.latestThreadUrl, isNull);

      // The reader of the web page (no plugin, or one before 2.3.0) is untouched: it still drops the link forum.
      final web = buildGroupListFromDocument(document).single;
      expect(web.isFavorites, isTrue);
      expect(web.forumList.map((e) => e.forumID), [7, 26]);
      expect(web.forumList.map((e) => e.isPrivate), [false, false]);
    });

    test('the production page: the same forums as the reader of the web page', () {
      final document = parseHtmlDocument(File('test/data/forum_index_x5.html').readAsStringSync());
      final web = buildGroupListFromDocument(document).firstWhere((e) => e.isFavorites).forumList;
      final forums = favoriteForumsOfDocument(document)!;
      expect(forums, web);
      expect(forums.single.forumID, 125);
      expect(
        favoriteForumsOfDocument(parseHtmlDocument(File('test/data/forum_index_nofav_x5.html').readAsStringSync())),
        isNull,
      );
    });

    test('without the document, or a document without the panel: looked up among the categories as before', () {
      final lean = _lean(_older(_withDocument()));
      expect(_panel(lean).map((e) => e.forumID), [2, 7, 29]);
      final garbage = {...lean, 'document': '<div id="wp">nothing</div>'};
      expect(_panel(garbage).map((e) => e.forumID), [2, 7, 29]);
      expect(_panel({...lean, 'favorite_forums': <Object?>[]}), isEmpty);
    });
  });

  group('the address of a link forum, and the edges of the page', () {
    test('a setting that is no web address never fails the page: the forum page instead', () {
      for (final (redirect, expected) in [
        (' https://example.com/x ', 'https://example.com/x'),
        ('forum.php?mod=viewthread&tid=1', '$baseUrl/forum.php?mod=viewthread&tid=1'),
        ('//other.example/x', 'https://other.example/x'),
        ('http://example.com:abc/', '$baseUrl/forum.php?mod=forumdisplay&fid=9'),
        ('http://[::1', '$baseUrl/forum.php?mod=forumdisplay&fid=9'),
        ('javascript:alert(1)', '$baseUrl/forum.php?mod=forumdisplay&fid=9'),
        ('intent://x#Intent;scheme=http;end', '$baseUrl/forum.php?mod=forumdisplay&fid=9'),
        ('file:///sdcard/a', '$baseUrl/forum.php?mod=forumdisplay&fid=9'),
        ('mailto:a', '$baseUrl/forum.php?mod=forumdisplay&fid=9'),
      ]) {
        final forum = Forum.fromApi({'fid': 9, 'name': 'x', 'redirect': redirect});
        expect(forum.redirectUrl, expected, reason: redirect);
        expect(forum.url, expected, reason: redirect);
      }
      expect(Forum.fromApi({'fid': 9, 'name': 'x', 'redirect': '   '}).redirectUrl, isNull);
      expect(Forum.fromApi({'fid': 9, 'name': 'x'}).redirectUrl, isNull);

      // The topics tab and the forum page whose subforums hold one (plugin 2.0.0 sends `redirect` with them).
      final json = _plugin281();
      final favorites = (json['favorites'] as List).cast<Map<String, dynamic>>();
      favorites[4] = {...favorites[4], 'redirect': 'http://[::1'};
      expect(_panel(json)[4].redirectUrl, '$baseUrl/forum.php?mod=forumdisplay&fid=29');
      final page = _json('tsdmapp/forum_v2_fid2.json');
      page['subforums'] = [
        ...(page['subforums'] as List),
        {
          'fid': 99,
          'name': '外連',
          'redirect': ' http://example.com:abc/',
          'threads': 5,
          'posts': 6,
          'todayposts': 0,
          'icon': '',
          'lastpost': {'tid': 1, 'subject': 's', 'dateline': 1792256772, 'author': 'a'},
          'subforums': <Object?>[],
        },
      ];
      final link = forumPageFromApi(page, '2').subredditList.last;
      expect(link.redirectUrl, '$baseUrl/forum.php?mod=forumdisplay&fid=99');
      expect(link.latestThreadUrl, isNull, reason: 'the page prints no latest thread for a link forum');
      expect(link.latestThreadTime, isNull);
      expect(link.latestThreadUserName, isNull);
    });

    test('the list layout: a link forum hidden from the viewer, an anonymous author, a forum bound to a domain', () {
      final document = parseHtmlDocument(
        _listLayoutPage
            .replaceFirst(
              '<a href="forum.php?mod=redirect&amp;tid=9199201&amp;goto=lastpost#lastpost" class="xi2">ATP JSON 89328</a> '
                  '<cite>2026-9-23 21:58 <a href="home.php?mod=space&username=ag_low2">ag_low2</a></cite>',
              '<a href="forum.php?mod=redirect&amp;tid=9199201&amp;goto=lastpost#lastpost" class="xi2">ATP JSON 89328</a> '
                  '<cite>2026-9-23 21:58 匿名</cite>',
            )
            // The forum the viewer may not enter is a link forum too: no counts, 私密版块 in place of the link.
            .replaceFirst(
              '<a href="forum.php?mod=forumdisplay&fid=26" title="BU 黑名單權限版 G">',
              '<a href="forum.php?mod=forumdisplay&fid=26" target="_blank" title="BU 黑名單權限版 G">',
            )
            .replaceFirst(
              '<h2><a href="forum.php?mod=forumdisplay&fid=26">',
              '<h2><a href="forum.php?mod=forumdisplay&fid=26" target="_blank">',
            )
            .replaceFirst(
              '<td class="fl_i"><span class="xi2">10</span><span class="xg1"> / 10</span></td>',
              '<td class="fl_i"></td>',
            )
            // The link forum is bound to a domain of its own.
            .replaceAll('forum.php?mod=forumdisplay&fid=29', 'https://link.example.test/'),
      );
      expect(favoriteForumsOfDocument(document)!.map((e) => e.forumID), [7, 26], reason: 'no id for the bound one');
      final forums = favoriteForumsOfDocument(document, fids: [7, 26, 29])!;
      expect(forums.map((e) => e.forumID), [7, 26, 29]);

      final anonymous = forums[0];
      expect(anonymous.latestThreadUserName, '匿名');
      expect(_pageMinute(anonymous.latestThreadTime!), (2026, 9, 23, 21, 58));
      expect(anonymous.latestThreadTimeText, '2026-9-23 21:58');
      expect(anonymous.latestThreadTitle, 'ATP JSON 89328');

      final hiddenLink = forums[1];
      expect((hiddenLink.isPrivate, hiddenLink.redirectUrl), (true, '$baseUrl/forum.php?mod=forumdisplay&fid=26'));
      expect((hiddenLink.threadCount, hiddenLink.replyCount), (0, 0));
      expect(hiddenLink.name, 'BU 黑名單權限版 G');

      final bound = forums[2];
      expect(bound.name, 'BU 通知驗收版 H');
      expect(bound.redirectUrl, '$baseUrl/forum.php?mod=forumdisplay&fid=29');
      expect((bound.threadCount, bound.replyCount), (0, 0));

      // A recent time in its `<span title>`, the anonymous author after it.
      final recent = parseHtmlDocument(
        _listLayoutPage.replaceFirst(
          '<cite>2026-9-23 21:58 <a href="home.php?mod=space&username=ag_low2">ag_low2</a></cite>',
          '<cite><span title="2026-10-20 12:00">昨天&nbsp;12:00</span> 匿名</cite>',
        ),
      );
      final first = favoriteForumsOfDocument(recent)!.first;
      expect(first.latestThreadUserName, '匿名');
      expect(_pageMinute(first.latestThreadTime!), (2026, 10, 20, 12, 0));
    });

    test('the grid: a link forum hidden from the viewer, a plugin row after the latest thread', () {
      final document = parseHtmlDocument('''
<div id="ct" class="wp cl"><div class="mn"><div class="fl bm"><div class="bm bmw  flg cl">
<div class="bm_h cl"><h2><a href="home.php?mod=space&amp;do=favorite&amp;type=forum">我收藏的版块</a></h2></div>
<div id="category_0" class="bm_c"><table cellspacing="0" cellpadding="0" class="fl_tb"><tr>
<td class="fl_g"><div class="fl_icn_g"><a href="forum.php?mod=forumdisplay&fid=40" target="_blank"><img src="a.png"/></a></div>
<dl><dt><a href="forum.php?mod=forumdisplay&fid=40" target="_blank">私密链接</a></dt><dd>私密版块</dd></dl></td>
<td class="fl_g"><div class="fl_icn_g">common/26.png</div>
<dl><dt><a href="forum.php?mod=forumdisplay&fid=26">隐藏</a></dt>
<dd><em>主题: 10</em>, <em>帖数: 10</em></dd><dd>从未</dd><dd><a href="plugin.php?id=x&fid=26">插件</a></dd></dl></td>
<td class="fl_g"><div class="fl_icn_g"><a href="forum.php?mod=forumdisplay&fid=7"><img src="e.png"/></a></div>
<dl><dt><a href="forum.php?mod=forumdisplay&fid=7">普通</a><em class="xw0 xi1" title="今日"> (3)</em></dt>
<dd><em>主题: 27</em>, <em>帖数: 12300</em></dd>
<dd><a href="forum.php?mod=redirect&tid=9&goto=lastpost#lastpost">最后发表: <span title="2026-10-20 12:00">昨天&nbsp;12:00</span></a></dd>
<dd><a href="plugin.php?id=x&fid=7">插件</a></dd></dl></td>
<td class="fl_g"></td><td class="fl_g"></td>
</tr></table></div></div></div></div></div>''');
      final forums = favoriteForumsOfDocument(document)!;
      expect(forums.map((e) => e.forumID), [40, 26, 7]);
      expect(
        (forums[0].isPrivate, forums[0].redirectUrl, forums[0].threadCount),
        (
          true,
          '$baseUrl/forum.php?mod=forumdisplay&fid=40',
          0,
        ),
      );
      expect((forums[1].isPrivate, forums[1].redirectUrl, forums[1].threadCount), (false, null, 10));
      expect(forums[1].iconUrl, isEmpty);
      expect(forums[1].latestThreadTime, isNull);
      expect((forums[2].threadCount, forums[2].replyCount, forums[2].threadTodayCount), (27, 12300, 3));
      expect(_pageMinute(forums[2].latestThreadTime!), (2026, 10, 20, 12, 0));
      expect(forums[2].redirectUrl, isNull, reason: 'the plugin row is not the latest thread');
    });

    test('a panel none of whose forums can be read: looked up among the categories', () {
      final lean = _lean(_older(_withDocument()));
      final json = {
        ...lean,
        'document': '<div id="ct"><div id="category_0" class="bm_c"><ul><li>another theme</li></ul></div></div>',
      };
      expect(favoriteForumsOfDocument(tsdmAppPageDocument(json)), isNull);
      expect(_panel(json).map((e) => e.forumID), [2, 7, 29]);
    });
  });

  group('the repository: the panel asked in the background, for the topics tab only', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late CookieProvider cookie;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      cookie = CookieProvider(_viewer, {});
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(cookie);
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

    _Forum olderForum() =>
        _Forum(lean: () => _api(_lean(_older(_withDocument()))), full: () => _api(_older(_withDocument())));

    test('plugin 2.8.0 with favorites: the lean page at once; the panel asked once, published as the page', () async {
      final forum = olderForum();
      final repo = repositoryOf(forum);
      final published = <ForumHomePage>[];
      final sub = repo.pageStream.listen(published.add);
      addTearDown(sub.cancel);

      final page = _right(await repo.fetchHomePage().run());
      expect(forum.homepage, hasLength(1), reason: 'the homepage gets the lean page, no request for the panel');
      expect(forum.homepage.single.uri.queryParameters, containsPair('nodoc', '1'));
      expect((page as ForumHomeApiPage).json.containsKey('document'), isFalse);

      await repo.requestFavoritesPanel(page);
      expect(forum.homepage, hasLength(2));
      expect(forum.homepage[1].uri.queryParameters.keys.toSet(), {'tsdmapp', 'mobile'}, reason: 'no nodoc');
      final full = repo.getCache()! as ForumHomeApiPage;
      expect(full.json['document'], isA<String>());
      expect(full.servedUid, 35);
      expect(_panel(full.json).map((e) => (e.forumID, e.threadCount)), [
        (15, 10),
        (2, 47),
        (26, 10),
        (7, 27),
        (29, 0),
        (28, 3),
      ]);
      await Future<void>.delayed(Duration.zero);
      expect(published, [page, full]);

      // Once per page; nothing for the page with the document, nor for a page that is not the cached one.
      await repo.requestFavoritesPanel(page);
      await repo.requestFavoritesPanel(full);
      expect(forum.homepage, hasLength(2));
      expect(_right(await repo.fetchTopicPage().run()), same(full), reason: 'the cache');
      final again = _right(await repo.fetchHomePage(force: true).run());
      expect(forum.homepage, hasLength(3));
      await repo.requestFavoritesPanel(page);
      expect(forum.homepage, hasLength(3), reason: 'not the cached page any more');
      await repo.requestFavoritesPanel(again);
      expect(forum.homepage, hasLength(4));
    });

    test('a slow page with its document holds nothing; past the timeout it is dropped', () async {
      final hold = Completer<void>();
      final forum = _Forum(
        lean: () => _api(_lean(_older(_withDocument()))),
        full: () async {
          await hold.future;
          return _api(_older(_withDocument()));
        },
      );
      final repo = repositoryOf(forum, timeout: const Duration(milliseconds: 200));
      final watch = Stopwatch()..start();
      final page = _right(await repo.fetchHomePage().run());
      final panel = repo.requestFavoritesPanel(page);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)), reason: 'the page did not wait for the panel');
      expect(repo.getCache(), same(page));
      await panel;
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)), reason: 'the timeout');
      hold.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(repo.getCache(), same(page), reason: 'the late answer is not taken');
      expect(_panel((page as ForumHomeApiPage).json).map((e) => e.forumID), [2, 7, 29], reason: 'the categories');
    });

    test('fetches at once share one request; a forced one asks again', () async {
      final forum = _Forum(
        lean: () async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          return _api(_lean(_older(_withDocument())));
        },
      );
      final repo = repositoryOf(forum);
      final pages = await Future.wait([repo.fetchHomePage().run(), repo.fetchTopicPage().run()]);
      expect(forum.homepage, hasLength(1));
      expect(_right(pages[0]), same(_right(pages[1])));
      repo.invalidate();
      await Future.wait([repo.fetchHomePage().run(), repo.fetchTopicPage(force: true).run()]);
      expect(forum.homepage, hasLength(3), reason: 'a forced fetch never shares');
    });

    test(
      'nothing asked for the panel: plugin 2.8.1, no favorites, a guest, the message, a reload after a claim',
      () async {
        for (final (name, answer) in [
          ('2.8.1', _plugin281()),
          ('no favorites', {..._older(_plugin281()), 'favorite_forums': <Object?>[]}),
          ('guest', _older(_json('tsdmapp/index_v5_guest.json'))),
          ('message', {'ok': 0, 'error': 'message', 'message': '站点已关闭', 'login': 0, 'schema': 5}),
        ]) {
          final forum = _Forum(lean: () => _api(answer));
          final repo = repositoryOf(forum);
          final page = _right(await repo.fetchHomePage().run());
          await repo.requestFavoritesPanel(page);
          expect(forum.homepage, hasLength(1), reason: name);
          await getIt.unregister<NetClientProvider>();
        }

        // The daily red packet claimed: the page is fetched again, lean, and no panel asked.
        await settings.setValue(SettingsKeys.autoDailyRedPacket, true);
        var claimed = false;
        final forum = _Forum(
          lean: () => _api({
            ..._lean(_older(_withDocument())),
            'red_packet': claimed ? null : {'entry': 1, 'dateflag': '20261001', 'from': 'x', 'bless': 'x', 'unit': 'x'},
          }),
        );
        getIt.registerFactory<NetClientProvider>(
          () => NetClientProvider.build(
            dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _Claim(forum, () => claimed = true),
          ),
        );
        final repo = ForumHomeRepository();
        addTearDown(repo.dispose);
        _right(await repo.fetchHomePage().run());
        // The claim and the reload run after the page was answered (cold start).
        await repo.dailyRewardsDone;
        expect(repo.getCache()?.dailyRedPacket, isNull, reason: 'claimed, the page fetched again');
        expect(forum.homepage, hasLength(2));
        expect(forum.withDocument, isEmpty);
      },
    );

    test('the answer with its document failed or is another account: the lean page stays', () async {
      for (final (name, full) in [
        ('failed', _api({'ok': 0, 'error': 'internal'})),
        ('HTTP 500', _api('', status: 500)),
        ('another account', _api({..._older(_withDocument()), 'uid': 36})),
        ('a guest', _api({..._older(_withDocument()), 'uid': 0})),
      ]) {
        final forum = _Forum(lean: () => _api(_lean(_older(_withDocument()))), full: () => full);
        final repo = repositoryOf(forum);
        final page = _right(await repo.fetchHomePage().run());
        await repo.requestFavoritesPanel(page);
        expect(forum.homepage, hasLength(2), reason: name);
        expect(repo.getCache(), same(page), reason: name);
        expect(_panel((page as ForumHomeApiPage).json).map((e) => e.forumID), [2, 7, 29], reason: name);
        await getIt.unregister<NetClientProvider>();
      }
    });

    test('the account or its session changes while the panel is asked: dropped', () async {
      // Another account.
      var forum = olderForum()..onFull = cookie.clearUserInfoAndCookie;
      var repo = repositoryOf(forum);
      var page = _right(await repo.fetchHomePage().run());
      await repo.requestFavoritesPanel(page);
      expect(forum.withDocument, hasLength(1));
      expect(repo.getCache(), same(page));
      await getIt.unregister<NetClientProvider>();

      // A new session of the same account (a login with the password).
      getIt.registerSingleton<CookieProvider>(cookie = CookieProvider(_viewer, {}));
      await storage.saveCookie(username: 'ag_low2', uid: 35, cookie: {'cdb_auth': 'A2'});
      forum = olderForum()..onFull = () => cookie.loadCookieFromStorage(_viewer);
      repo = repositoryOf(forum);
      page = _right(await repo.fetchHomePage().run());
      await repo.requestFavoritesPanel(page);
      expect(forum.withDocument, hasLength(1));
      expect(repo.getCache(), same(page));

      // The session changed before the panel is asked: nothing asked for a page of the previous session.
      await getIt.unregister<NetClientProvider>();
      forum = olderForum();
      repo = repositoryOf(forum);
      page = _right(await repo.fetchHomePage().run());
      await cookie.loadCookieFromStorage(_viewer);
      await repo.requestFavoritesPanel(page);
      expect(forum.withDocument, isEmpty);
    });
  });

  group('the topics tab and the homepage share the fetch', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late _Forum forum;
    late ForumHomeRepository forumHome;
    late FavoriteRepository favorites;
    late _FakeAuth auth;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      forum = _Forum(
        lean: () => _api(_lean(_older(_withDocument()))),
        full: () => _api(_older(_withDocument())),
      );
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
        );
      await settings.init();
      forumHome = ForumHomeRepository();
      favorites = FavoriteRepository();
      auth = _FakeAuth(_viewer);
    });
    tearDown(() async {
      await forumHome.dispose();
      await favorites.dispose();
      await auth.dispose();
      await settings.dispose();
      await getIt.unregister<NetClientProvider>();
      await getIt.unregister<SettingsRepository>();
      await getIt.unregister<StorageProvider>();
      await getIt.unregister<CookieProvider>();
      await db.close();
    });

    TopicsBloc topicsBloc() {
      final bloc = TopicsBloc(
        forumHomeRepository: forumHome,
        authenticationRepository: auth,
        favoriteRepository: favorites,
      );
      addTearDown(bloc.close);
      return bloc;
    }

    List<int> panelOf(TopicsBloc bloc) =>
        bloc.state.forumGroupList.where((e) => e.isFavorites).firstOrNull?.forumList.map((e) => e.forumID).toList() ??
        const [];

    Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 50));

    test('plugin 2.8.0: the panel of the page, every favorite seeded; pages fetched elsewhere keep it', () async {
      final bloc = topicsBloc()..add(TopicsLoadRequested());
      await bloc.stream.firstWhere((s) => s.status.isSuccess);
      await settle();
      expect(panelOf(bloc), [15, 2, 26, 7, 29, 28]);
      expect(bloc.state.forumGroupList.first.forumList[1].threadCount, 47);
      expect(forum.homepage, hasLength(2));
      expect(forum.withDocument, hasLength(1));
      for (final fid in [15, 2, 26, 7, 29, 28]) {
        expect(favorites.isForumFavorited(uid: 35, fid: '$fid'), isTrue, reason: 'seeded: $fid');
      }

      // The homepage starts from the same page: nothing asked.
      final homepage = HomepageBloc(
        forumHomeRepository: forumHome,
        profileRepository: ProfileRepository(),
        authenticationRepository: auth,
      );
      addTearDown(homepage.close);
      expect(homepage.state.status, HomepageStatus.success);
      expect(forum.homepage, hasLength(2));

      // The homepage, the red packet check or the activities page fetch it again: the topics tab keeps the panel it
      // read, asking nothing itself.
      await forumHome.fetchHomePage(force: true).run();
      await settle();
      expect(forum.homepage, hasLength(3));
      expect(forum.withDocument, hasLength(1));
      expect(panelOf(bloc), [15, 2, 26, 7, 29, 28]);
      expect(bloc.state.forumGroupList.first.forumList[1].threadCount, 47);

      // Its own refresh asks for the panel again.
      bloc.add(const TopicsRefreshRequested(silent: true));
      await settle();
      expect(forum.withDocument, hasLength(2));
      expect(panelOf(bloc), [15, 2, 26, 7, 29, 28]);

      // The favorites changed on the web: a page fetched elsewhere names others, the kept panel does not fit.
      final changed = _lean(_older(_withDocument()))..['favorite_forums'] = [2, 7];
      final changedFull = {
        ..._older(_withDocument()),
        'favorite_forums': [2, 7],
      };
      forum
        ..lean = (() => _api(changed))
        ..full = (() => _api(changedFull));
      await forumHome.fetchHomePage(force: true).run();
      await settle();
      expect(forum.withDocument, hasLength(3));
    });

    test('the homepage and the topics tab loading together: one lean request, one for the panel', () async {
      final homepage = HomepageBloc(
        forumHomeRepository: forumHome,
        profileRepository: ProfileRepository(),
        authenticationRepository: auth,
      );
      addTearDown(homepage.close);
      final bloc = topicsBloc();
      homepage.add(HomepageLoadRequested());
      bloc.add(TopicsLoadRequested());
      await bloc.stream.firstWhere((s) => s.status.isSuccess);
      await settle();
      expect(forum.homepage.where((e) => e.uri.queryParameters['nodoc'] == '1'), hasLength(1));
      expect(forum.withDocument, hasLength(1));
      expect(panelOf(bloc), [15, 2, 26, 7, 29, 28]);
    });

    test('plugin 2.8.1: one request, the panel of the answer, every favorite seeded', () async {
      forum.lean = () => _api(_plugin281());
      final bloc = topicsBloc()..add(TopicsLoadRequested());
      final loaded = await bloc.stream.firstWhere((s) => s.status.isSuccess);
      await settle();
      expect(loaded.forumGroupList.first.forumList.map((e) => e.forumID), [15, 2, 26, 7, 29, 28]);
      expect(forum.homepage, hasLength(1));
      for (final fid in [15, 2, 26, 7, 29, 28]) {
        expect(favorites.isForumFavorited(uid: 35, fid: '$fid'), isTrue, reason: 'seeded: $fid');
      }
    });
  });

  group('the cards of the panel', () {
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    const mainChannel = MethodChannel('kzs.th000.tsdm_client/mainChannel');
    final launched = <MethodCall>[];
    late AppDatabase db;
    late SettingsRepository settings;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.build(
            dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _Forum(lean: () => _api('')),
          ),
        );
      await settings.init();
      getIt.registerSingleton<ImageCacheProvider>(ImageCacheProvider(getIt.get<NetClientProvider>()));
      launched.clear();
      for (final channel in [launcher, mainChannel]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
          call,
        ) async {
          launched.add(call);
          return true;
        });
      }
    });
    tearDown(() async {
      for (final channel in [launcher, mainChannel]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      }
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.unregister<ImageCacheProvider>();
      await getIt.unregister<NetClientProvider>();
      await settings.dispose();
      await getIt.unregister<SettingsRepository>();
      await getIt.unregister<StorageProvider>();
      await getIt.unregister<CookieProvider>();
      await db.close();
    });

    Future<GoRouter> pumpCards(WidgetTester tester, List<Forum> forums, {bool large = false}) async {
      tester.view
        ..physicalSize = large ? const Size(1400, 2400) : const Size(390, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              // No picture to load in a widget test.
              body: ListView(
                children: [for (final f in forums) ForumCard(f.copyWith(iconUrl: ''), large: large)],
              ),
            ),
          ),
          GoRoute(
            path: ScreenPaths.forum,
            name: ScreenPaths.forum,
            builder: (_, state) => Text('forum ${state.pathParameters['fid']}'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      return router;
    }

    Finder card(int fid) => find.byWidgetPredicate((w) => w is ForumCard && w.forum.forumID == fid);
    Finder inCard(int fid, Finder finder) => find.descendant(of: card(fid), matching: finder);

    testWidgets('private: 私密版块 where the time goes, the counters kept; a link forum: no counters', (tester) async {
      final json = _plugin281();
      final favorites = (json['favorites'] as List).cast<Map<String, dynamic>>();
      favorites[3] = {...favorites[3], 'private': 1, 'lastpost': null};
      final forums = _panel(json);
      for (final large in [false, true]) {
        await pumpCards(tester, forums, large: large);
        expect(inCard(7, find.text(tr.forumCard.privateForum)), findsOneWidget, reason: 'large: $large');
        expect(inCard(7, find.text('27')), findsOneWidget, reason: 'large: $large');
        expect(inCard(29, find.text(tr.forumCard.redirectForum)), findsOneWidget, reason: 'large: $large');
        expect(inCard(29, find.byType(large ? ForumCardStat : AppInfoPill)), findsNothing, reason: 'large: $large');
        expect(inCard(15, find.byType(large ? ForumCardStat : AppInfoPill)), findsNWidgets(3), reason: 'large: $large');
        expect(inCard(15, find.text(tr.forumCard.privateForum)), findsNothing);
        expect(inCard(26, find.text(tr.forumCard.privateForum)), findsNothing, reason: 'hidden, not private');
      }
      expect(tr.forumCard.privateForum, '私密版块');
      expect(tr.forumCard.redirectForum, '链接到外部地址');
    });

    testWidgets('a link forum opens in a browser only, web addresses only; another forum opens its page', (
      tester,
    ) async {
      final forums = [
        ..._panel(_plugin281()),
        // Read from the web page of an older plugin: the forum's own page, a link of this app.
        _panel(_older(_withDocument()))[4].copyWith(forumID: 129),
        // Not from any reader: a link forum whose address is no web address is not opened.
        _panel(_plugin281())[4].copyWith(forumID: 229, redirectUrl: 'javascript:alert(1)'),
        _panel(_plugin281())[4].copyWith(forumID: 329, redirectUrl: 'intent://x#Intent;scheme=http;end'),
      ];
      final router = await pumpCards(tester, forums);
      await tester.tap(card(29));
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        launched.map((e) => (e.method, (e.arguments as Map)['url'])),
        [
          ('openInBrowser', 'https://example.com/tsdmapp281'),
        ],
        reason: 'the browser-only channel (Android), never a generic launch',
      );
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');

      await tester.ensureVisible(card(129));
      await tester.tap(card(129));
      await tester.pump(const Duration(milliseconds: 100));
      expect(launched.last.method, 'openInBrowser');
      expect((launched.last.arguments as Map)['url'], '$baseUrl/forum.php?mod=forumdisplay&fid=29');

      for (final fid in [229, 329]) {
        await tester.ensureVisible(card(fid));
        await tester.tap(card(fid));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(launched, hasLength(2), reason: 'javascript: and intent: are not opened');
      expect(router.routerDelegate.currentConfiguration.uri.path, '/');

      await tester.ensureVisible(card(15));
      await tester.tap(card(15));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('forum 15'), findsOneWidget);
      expect(launched, hasLength(2));
    });
  });

  test('the app expects plugin 2.8.1 or later; 2.8.0 is older (no favorites panel)', () {
    expect(compareTsdmAppVersions(expectedTsdmAppVersion, '2.8.1'), greaterThanOrEqualTo(0));
    expect(const TsdmAppPluginInfo(version: '2.8.0', api: 1, nodoc: true).olderThanExpected, isTrue);
    expect(const TsdmAppPluginInfo(version: expectedTsdmAppVersion, api: 1, nodoc: true).olderThanExpected, isFalse);
  });
}
