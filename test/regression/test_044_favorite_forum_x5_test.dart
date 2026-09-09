import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/favorite/utils/forum_favorite_action.dart';
import 'package:tsdm_client/features/favorite/utils/parse_favorite.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:universal_html/parsing.dart';

/// Issue #2: favorite forums (收藏版块). Discuz! X5 samples captured with a test account on 2026-09-09 (uid -> 1000,
/// username -> Alice, hashes -> XXXXXXXX); the web page uses the handlekeys `favoriteforum` / `a_delete_FAVID`
/// where the app keeps sending `k_favorite` / `favdelete` (the server echoes whatever it gets).
String _data(String name) => File('test/data/$name').readAsStringSync();

/// Serves canned answers by request path and records every request with its form body.
final class _FakeAdapter implements HttpClientAdapter {
  final requests = <(Uri uri, String method, String body)>[];
  final answers = <bool Function(Uri uri, String method), String>{};

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
    final answer = answers.entries.where((e) => e.key(options.uri, options.method)).firstOrNull?.value;
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

/// Authentication repository with a fixed logged user.
final class _FakeAuth extends AuthenticationRepository {
  _FakeAuth(this.user);

  final UserLoginInfo? user;

  @override
  UserLoginInfo? get currentUser => user;
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('forum favorites list page on X5', () {
    test('one record without a note', () {
      final page = parseFavoriteForumListPage(parseHtmlDocument(_data('favorite_forum_list_x5.html')));
      expect(page.needLogin, isFalse);
      expect(page.nextPageUrl, isNull);
      final item = page.items.single;
      expect(item.favid, '500405');
      expect(item.fid, '125');
      expect(item.targetId, '125');
      expect(item.type, FavoriteType.forum);
      expect(item.title, '日麻');
      expect(item.url, '$baseUrl/forum.php?mod=forumdisplay&fid=125');
      expect(item.time, DateTime(2026, 9, 9, 7, 56));
      expect(item.description, isNull);
    });

    test('the thread parser ignores forum rows and the other way round', () {
      expect(parseFavoriteListPage(parseHtmlDocument(_data('favorite_forum_list_x5.html'))).items, isEmpty);
      expect(parseFavoriteForumListPage(parseHtmlDocument(_data('favorite_list_x5.html'))).items, isEmpty);
      final byType = parseFavoriteListPageOfType(
        parseHtmlDocument(_data('favorite_forum_list_x5.html')),
        FavoriteType.forum,
      );
      expect(byType.items.single, isA<FavoriteForum>());
    });

    test('an empty list is neither an error nor a login notice', () {
      final page = parseFavoriteForumListPage(parseHtmlDocument(_data('favorite_forum_list_empty_x5.html')));
      expect(page.items, isEmpty);
      expect(page.needLogin, isFalse);
      expect(page.nextPageUrl, isNull);
    });

    test('a note and a next page link are read like for threads', () {
      final page = parseFavoriteForumListPage(
        parseHtmlDocument('''
<ul id="favorite_ul"><li id="fav_7" class="bbda ptm pbm">
<input type="checkbox" name="favorite[]" class="pc" value="7" vid="42" />
<a href="forum.php?mod=forumdisplay&fid=42" target="_blank">f</a> <span class="xg1"><span title="2026-9-9 07:56">now</span></span>
<div class="quote"><blockquote id="quote_preview">note</blockquote></div>
</li></ul>
<div class="pgs cl mtm"><div class="pg"><strong>1</strong><a href="home.php?mod=space&amp;uid=1000&amp;do=favorite&amp;type=forum&amp;page=2" class="nxt">下一页</a></div></div>
'''),
      );
      expect(page.items.single.fid, '42');
      expect(page.items.single.description, 'note');
      expect(page.nextPageUrl, '$baseUrl/home.php?mod=space&uid=1000&do=favorite&type=forum&page=2');
    });
  });

  group('forum favorite dialogs and answers on X5', () {
    test('dialogs carry formhash and referer, the repeat dialog has no form', () {
      expect(parseFavoriteForm(_data('favorite_forum_add_form_x5.xml')), (
        formHash: 'XXXXXXXX',
        referer: '$baseUrl/./',
      ));
      expect(parseFavoriteForm(_data('favorite_forum_delete_form_x5.xml')), (
        formHash: 'XXXXXXXX',
        referer: '$baseUrl/./',
      ));
      expect(parseFavoriteForm(_data('favorite_forum_add_dialog_repeat_x5.xml')), isNull);
    });

    test('answers are recognised whatever handlekey the server echoes', () {
      expect(
        parseFavoriteAddResult(_data('favorite_forum_add_success_x5.xml')),
        isA<FavoriteAdded>().having((e) => e.favid, 'favid', '500405'),
      );
      expect(parseFavoriteAddResult(_data('favorite_forum_add_dialog_repeat_x5.xml')), isA<FavoriteAlreadyExists>());
      expect(parseFavoriteRemoveResult(_data('favorite_forum_delete_success_x5.xml')).removed, isTrue);
      expect(parseFavoriteRemoveResult("errorhandle_a_delete_1('抱歉，您指定的收藏不存在', {});").removed, isTrue);
      expect(parseFavoriteRemoveResult("errorhandle_a_delete_1('抱歉，您没有权限', {});").removed, isFalse);
    });
  });

  group('FavoriteRepository forum favorites on X5', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late _FakeAdapter adapter;
    late FavoriteRepository repo;
    late List<void> changes;
    late StreamSubscription<void> changeSub;

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
      repo = FavoriteRepository();
      changes = [];
      changeSub = repo.forumFavoritesChanged.listen(changes.add);
    });
    tearDown(() async {
      await changeSub.cancel();
      await repo.dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    test('adding fetches the dialog then posts the form with type=forum', () async {
      adapter.answers[(uri, method) => method == 'GET'] = _data('favorite_forum_add_form_x5.xml');
      adapter.answers[(uri, method) => method == 'POST'] = _data('favorite_forum_add_success_x5.xml');
      final result = await repo.addForumFavorite(fid: '125', description: '備註').run();
      expect(result.toNullable(), isA<FavoriteAdded>().having((e) => e.favid, 'favid', '500405'));

      expect(adapter.requests, hasLength(2));
      final (getUri, getMethod, _) = adapter.requests[0];
      expect(getMethod, 'GET');
      expect(getUri.path, '/home.php');
      expect(getUri.queryParameters, containsPair('mod', 'spacecp'));
      expect(getUri.queryParameters, containsPair('ac', 'favorite'));
      expect(getUri.queryParameters, containsPair('type', 'forum'));
      expect(getUri.queryParameters, containsPair('id', '125'));
      expect(getUri.queryParameters, containsPair('handlekey', 'k_favorite'));
      expect(getUri.queryParameters, containsPair('inajax', '1'));
      final (postUri, postMethod, body) = adapter.requests[1];
      expect(postMethod, 'POST');
      expect(postUri.queryParameters, containsPair('type', 'forum'));
      expect(postUri.queryParameters, containsPair('id', '125'));
      expect(postUri.queryParameters, containsPair('spaceuid', '0'));
      final form = Uri.splitQueryString(body);
      expect(form, containsPair('favoritesubmit', 'true'));
      expect(form, containsPair('formhash', 'XXXXXXXX'));
      expect(form, containsPair('referer', '$baseUrl/./'));
      expect(form, containsPair('handlekey', 'k_favorite'));
      expect(form, containsPair('description', '備註'));
      await Future<void>.delayed(Duration.zero);
      expect(changes, hasLength(1), reason: 'the topics tab is told once');
    });

    test('an already favorited forum is answered in the dialog, nothing is posted', () async {
      adapter.answers[(uri, method) => method == 'GET'] = _data('favorite_forum_add_dialog_repeat_x5.xml');
      final result = await repo.addForumFavorite(fid: '125').run();
      expect(result.toNullable(), isA<FavoriteAlreadyExists>());
      expect(adapter.requests.where((e) => e.$2 == 'POST'), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(changes, isEmpty);
    });

    test('removing posts deletesubmit with type=forum', () async {
      adapter.answers[(uri, method) => method == 'GET'] = _data('favorite_forum_delete_form_x5.xml');
      adapter.answers[(uri, method) => method == 'POST'] = _data('favorite_forum_delete_success_x5.xml');
      final result = await repo.removeFavorite(favid: '500405', type: FavoriteType.forum).run();
      expect(result.toNullable()?.removed, isTrue);
      expect(adapter.requests, hasLength(2));
      final (uri, method, body) = adapter.requests[1];
      expect(method, 'POST');
      expect(uri.queryParameters, containsPair('op', 'delete'));
      expect(uri.queryParameters, containsPair('favid', '500405'));
      expect(uri.queryParameters, containsPair('type', 'forum'));
      expect(uri.queryParameters, containsPair('handlekey', 'favdelete'));
      final form = Uri.splitQueryString(body);
      expect(form, containsPair('deletesubmit', 'true'));
      expect(form, containsPair('formhash', 'XXXXXXXX'));
      expect(form, containsPair('handlekey', 'favdelete'));
      await Future<void>.delayed(Duration.zero);
      expect(changes, hasLength(1));
    });

    test('removing a thread favorite does not touch the forum change stream', () async {
      adapter.answers[(uri, method) => method == 'GET'] = _data('favorite_delete_form_x5.xml');
      adapter.answers[(uri, method) => method == 'POST'] = _data('favorite_delete_success_x5.xml');
      expect((await repo.removeFavorite(favid: '500335').run()).toNullable()?.removed, isTrue);
      expect(adapter.requests[1].$1.queryParameters, containsPair('type', 'thread'));
      await Future<void>.delayed(Duration.zero);
      expect(changes, isEmpty);
    });

    test('findForumFavid walks the forum list and fills the per-user cache', () async {
      adapter.answers[(uri, method) => uri.queryParameters['do'] == 'favorite'] = _data('favorite_forum_list_x5.html');
      expect((await repo.findForumFavid(fid: '125', uid: 1000).run()).toNullable(), '500405');
      expect(adapter.requests.single.$1.queryParameters, containsPair('type', 'forum'));
      expect((await repo.findForumFavid(fid: '404', uid: 1000).run()).toNullable(), isNull);
      expect(repo.isForumFavorited(uid: 1000, fid: '125'), isTrue);
      expect(repo.cachedForumFavid(uid: 1000, fid: '125'), '500405');
      expect(repo.isForumFavorited(uid: 2000, fid: '125'), isFalse, reason: 'records are per user');
      expect(repo.cachedFavid(uid: 1000, tid: '125'), isNull, reason: 'threads and forums are separate');
      repo.forgetForum(uid: 1000, fid: '125');
      expect(repo.isForumFavorited(uid: 1000, fid: '125'), isFalse);
    });

    test('notifyForumFavoritesChanged tells the topics tab once, and nothing after dispose', () async {
      repo.notifyForumFavoritesChanged();
      await Future<void>.delayed(Duration.zero);
      expect(changes, hasLength(1));
      await repo.dispose();
      repo.notifyForumFavoritesChanged();
      await Future<void>.delayed(Duration.zero);
      expect(changes, hasLength(1));
    });

    test('seeding from the forum index keeps known favids and drops forums no longer listed', () {
      repo
        ..rememberForum(uid: 1000, fid: '125', favid: '500405')
        ..rememberForum(uid: 1000, fid: '17', favid: '1')
        ..seedForumFavorites(uid: 1000, fids: ['125', '45']);
      expect(repo.isForumFavorited(uid: 1000, fid: '125'), isTrue);
      expect(repo.cachedForumFavid(uid: 1000, fid: '125'), '500405');
      expect(repo.isForumFavorited(uid: 1000, fid: '45'), isTrue);
      expect(repo.cachedForumFavid(uid: 1000, fid: '45'), isNull);
      expect(repo.isForumFavorited(uid: 1000, fid: '17'), isFalse);
      repo.seedForumFavorites(uid: 1000, fids: const []);
      expect(repo.isForumFavorited(uid: 1000, fid: '125'), isFalse);
    });
  });

  group('toggleForumFavorite from the forum page', () {
    const alice = UserLoginInfo(username: 'Alice', uid: 1000);
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late _FakeAdapter adapter;
    late FavoriteRepository repo;
    late List<void> changes;
    late StreamSubscription<void> changeSub;
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
      repo = FavoriteRepository();
      changes = [];
      changeSub = repo.forumFavoritesChanged.listen(changes.add);
      auth = _FakeAuth(alice);
    });
    tearDown(() async {
      await changeSub.cancel();
      await repo.dispose();
      await auth.dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    /// A page with one button that toggles forum 125, recording the result in [results].
    Widget host(List<bool> results) => TranslationProvider(
      child: MultiRepositoryProvider(
        providers: [
          RepositoryProvider<AuthenticationRepository>.value(value: auth),
          RepositoryProvider<FavoriteRepository>.value(value: repo),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => results.add(await toggleForumFavorite(context, fid: '125')),
                child: const Text('toggle'),
              ),
            ),
          ),
        ),
      ),
    );

    /// Pump a few frames; the snack bar keeps `pumpAndSettle` busy.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    /// Confirm the dialog on screen (the last action is Ok).
    Future<void> confirm(WidgetTester tester) async {
      await tester.tap(find.byType(TextButton).last);
      await settle(tester);
    }

    testWidgets('removing a forum the panel listed but the server no longer has tells the topics tab', (tester) async {
      // Listed by the "我收藏的版块" panel (favid unknown), removed on the web since.
      repo.seedForumFavorites(uid: 1000, fids: ['125']);
      adapter.answers[(uri, method) => uri.queryParameters['do'] == 'favorite'] = _data(
        'favorite_forum_list_empty_x5.html',
      );
      final results = <bool>[];
      await tester.pumpWidget(host(results));
      await tester.tap(find.text('toggle'));
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget, reason: 'asks before removing');
      await confirm(tester);

      expect(results, [true]);
      expect(repo.isForumFavorited(uid: 1000, fid: '125'), isFalse);
      expect(
        adapter.requests.where((e) => e.$1.queryParameters['op'] == 'delete'),
        isEmpty,
        reason: 'nothing to delete',
      );
      expect(changes, hasLength(1), reason: 'the panel still lists the forum: reload it');
    });

    testWidgets('adding a forum already favorited on the web tells the topics tab once found', (tester) async {
      adapter.answers[(uri, method) => uri.queryParameters['ac'] == 'favorite'] = _data(
        'favorite_forum_add_dialog_repeat_x5.xml',
      );
      adapter.answers[(uri, method) => uri.queryParameters['do'] == 'favorite'] = _data('favorite_forum_list_x5.html');
      final results = <bool>[];
      await tester.pumpWidget(host(results));
      await tester.tap(find.text('toggle'));
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget, reason: 'asks for the note');
      await confirm(tester);

      expect(results, [true]);
      expect(repo.cachedForumFavid(uid: 1000, fid: '125'), '500405', reason: 'looked up in the list');
      expect(changes, hasLength(1), reason: 'the panel does not list the forum yet: reload it');
    });

    testWidgets('an "already favorited" answer without a record in the list changes nothing', (tester) async {
      adapter.answers[(uri, method) => uri.queryParameters['ac'] == 'favorite'] = _data(
        'favorite_forum_add_dialog_repeat_x5.xml',
      );
      adapter.answers[(uri, method) => uri.queryParameters['do'] == 'favorite'] = _data(
        'favorite_forum_list_empty_x5.html',
      );
      final results = <bool>[];
      await tester.pumpWidget(host(results));
      await tester.tap(find.text('toggle'));
      await tester.pump();
      await confirm(tester);

      expect(results, [false]);
      expect(repo.isForumFavorited(uid: 1000, fid: '125'), isFalse);
      expect(changes, isEmpty);
    });
  });

  group('favorites urls', () {
    test('type=forum opens the forums tab, anything else the threads', () {
      final forum = '$baseUrl/home.php?mod=space&do=favorite&type=forum'.parseUrlToRoute();
      expect(forum?.screenPath, ScreenPaths.favorite);
      expect(forum?.queryParameters, {'type': 'forum'});
      final thread = '$baseUrl/home.php?mod=space&uid=1000&do=favorite&view=me&type=thread'.parseUrlToRoute();
      expect(thread?.screenPath, ScreenPaths.favorite);
      expect(thread?.queryParameters, isEmpty);
      expect('$baseUrl/home.php?mod=space&do=favorite'.parseUrlToRoute()?.queryParameters, isEmpty);
    });
  });
}
