import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/favorite/utils/parse_favorite.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:universal_html/parsing.dart';

/// Discuz! X5 favorites samples captured with a test account on 2026-09-06 (uid -> 1000, username -> Alice,
/// hashes -> XXXXXXXX; the note of the second record was dropped so both shapes are covered).
String _data(String name) => File('test/data/$name').readAsStringSync();

/// Serves canned answers by request path and records every request with its form body.
final class _FakeAdapter implements HttpClientAdapter {
  final requests = <(Uri uri, String method, String body)>[];
  final answers = <bool Function(Uri uri, String method), String>{};

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
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

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('favorites list page on X5', () {
    test('records with and without a note', () {
      final page = parseFavoriteListPage(parseHtmlDocument(_data('favorite_list_x5.html')));
      expect(page.needLogin, isFalse);
      expect(page.nextPageUrl, isNull, reason: 'a single page has no pagination bar');
      expect(page.items, hasLength(2));

      final first = page.items[0];
      expect(first.favid, '500335');
      expect(first.tid, '1264928');
      expect(first.title, isNotEmpty);
      expect(first.url, '$baseUrl/forum.php?mod=viewthread&tid=1264928');
      expect(first.time, DateTime(2026, 9, 6, 2, 39));
      expect(first.description, 'tsdm_client 收藏測試備註');

      final second = page.items[1];
      expect(second.favid, '500329');
      expect(second.tid, '1264975');
      expect(second.time, DateTime(2026, 9, 5, 20, 43));
      expect(second.description, isNull);
    });

    test('next page link is absolute', () {
      final page = parseFavoriteListPage(
        parseHtmlDocument('''
<ul id="favorite_ul"><li id="fav_1" class="bbda ptm pbm">
<input type="checkbox" name="favorite[]" class="pc" value="1" vid="42" />
<a href="forum.php?mod=viewthread&tid=42" target="_blank">t</a> <span class="xg1"><span title="2026-9-6 02:39">now</span></span>
</li></ul>
<div class="pgs cl mtm"><div class="pg"><strong>1</strong><a href="home.php?mod=space&amp;uid=1000&amp;do=favorite&amp;type=thread&amp;page=2">2</a><a href="home.php?mod=space&amp;uid=1000&amp;do=favorite&amp;type=thread&amp;page=2" class="nxt">下一页</a></div></div>
'''),
      );
      expect(page.items.single.tid, '42');
      expect(page.nextPageUrl, '$baseUrl/home.php?mod=space&uid=1000&do=favorite&type=thread&page=2');
    });

    test('guests get a login notice instead of the list', () {
      final page = parseFavoriteListPage(parseHtmlDocument(_data('favorite_list_guest_x5.html')));
      expect(page.items, isEmpty);
      expect(page.needLogin, isTrue);
    });
  });

  group('favorite dialogs and answers on X5', () {
    test('add and delete dialogs carry formhash and referer', () {
      expect(parseFavoriteForm(_data('favorite_add_form_x5.xml')), (formHash: 'XXXXXXXX', referer: '$baseUrl/./'));
      expect(parseFavoriteForm(_data('favorite_delete_form_x5.xml')), (formHash: 'XXXXXXXX', referer: '$baseUrl/./'));
      expect(parseFavoriteForm(_data('favorite_delete_missing_x5.xml')), isNull, reason: 'no form for a missing record');
      expect(parseFavoriteForm(_data('favorite_add_dialog_repeat_x5.xml')), isNull, reason: 'no form when already favorited');
    });

    test('add answers', () {
      expect(parseFavoriteAddResult(_data('favorite_add_success_x5.xml')), isA<FavoriteAdded>().having((e) => e.favid, 'favid', '500335'));
      expect(parseFavoriteAddResult(_data('favorite_add_repeat_x5.xml')), isA<FavoriteAlreadyExists>());
      expect(parseFavoriteAddResult(_data('favorite_add_dialog_repeat_x5.xml')), isA<FavoriteAlreadyExists>());
      expect(
        parseFavoriteAddResult('<html><body><div id="messagetext"><p>抱歉，您没有权限</p></div></body></html>'),
        isA<FavoriteAddFailed>().having((e) => e.message, 'message', '抱歉，您没有权限'),
      );
    });

    test('delete answers', () {
      expect(parseFavoriteRemoveResult(_data('favorite_delete_success_x5.xml')).removed, isTrue);
      final missing = parseFavoriteRemoveResult(_data('favorite_delete_missing_x5.xml'));
      expect(missing.removed, isTrue, reason: 'a record that does not exist anymore counts as removed');
      expect(missing.message, '抱歉，您指定的收藏不存在');
      final other = parseFavoriteRemoveResult("errorhandle_favdelete('抱歉，您没有权限', {});");
      expect(other.removed, isFalse);
      expect(other.message, '抱歉，您没有权限');
    });
  });

  group('FavoriteRepository on X5', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late _FakeAdapter adapter;

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
    });
    tearDown(() async {
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    test('adding fetches the dialog then posts the form', () async {
      adapter.answers[(uri, method) => method == 'GET' && uri.queryParameters['ac'] == 'favorite'] = _data(
        'favorite_add_form_x5.xml',
      );
      adapter.answers[(uri, method) => method == 'POST'] = _data('favorite_add_success_x5.xml');
      final repo = FavoriteRepository();
      final result = await repo.addFavorite(tid: '1264928', description: '備註').run();
      expect(result.toNullable(), isA<FavoriteAdded>().having((e) => e.favid, 'favid', '500335'));

      expect(adapter.requests, hasLength(2));
      final (getUri, getMethod, _) = adapter.requests[0];
      expect(getMethod, 'GET');
      expect(getUri.path, '/home.php');
      expect(getUri.queryParameters, containsPair('id', '1264928'));
      expect(getUri.queryParameters, containsPair('handlekey', 'k_favorite'));
      expect(getUri.queryParameters, containsPair('inajax', '1'));
      final (postUri, postMethod, body) = adapter.requests[1];
      expect(postMethod, 'POST');
      expect(postUri.queryParameters, containsPair('spaceuid', '0'));
      final form = Uri.splitQueryString(body);
      expect(form, containsPair('favoritesubmit', 'true'));
      expect(form, containsPair('formhash', 'XXXXXXXX'));
      expect(form, containsPair('referer', '$baseUrl/./'));
      expect(form, containsPair('handlekey', 'k_favorite'));
      expect(form, containsPair('description', '備註'));
    });

    test('removing fetches the dialog then posts deletesubmit', () async {
      adapter.answers[(uri, method) => method == 'GET'] = _data('favorite_delete_form_x5.xml');
      adapter.answers[(uri, method) => method == 'POST'] = _data('favorite_delete_success_x5.xml');
      final repo = FavoriteRepository();
      final result = await repo.removeFavorite(favid: '500335').run();
      expect(result.toNullable()?.removed, isTrue);
      expect(adapter.requests, hasLength(2));
      final (uri, method, body) = adapter.requests[1];
      expect(method, 'POST');
      expect(uri.queryParameters, containsPair('op', 'delete'));
      expect(uri.queryParameters, containsPair('favid', '500335'));
      expect(uri.queryParameters, containsPair('handlekey', 'favdelete'));
      final form = Uri.splitQueryString(body);
      expect(form, containsPair('deletesubmit', 'true'));
      expect(form, containsPair('formhash', 'XXXXXXXX'));
      expect(form, containsPair('handlekey', 'favdelete'));
    });

    test('an already favorited thread is answered in the dialog, nothing is posted', () async {
      adapter.answers[(uri, method) => method == 'GET'] = _data('favorite_add_dialog_repeat_x5.xml');
      final result = await FavoriteRepository().addFavorite(tid: '1264975').run();
      expect(result.toNullable(), isA<FavoriteAlreadyExists>());
      expect(adapter.requests.where((e) => e.$2 == 'POST'), isEmpty);
    });

    test('a record that is already gone counts as removed, nothing is posted', () async {
      adapter.answers[(uri, method) => method == 'GET'] = _data('favorite_delete_missing_x5.xml');
      final result = await FavoriteRepository().removeFavorite(favid: '1').run();
      expect(result.toNullable()?.removed, isTrue);
      expect(result.toNullable()?.message, '抱歉，您指定的收藏不存在');
      expect(adapter.requests.where((e) => e.$2 == 'POST'), isEmpty);
    });

    test('an unexpected dialog is a failure, not a silent post', () async {
      adapter.answers[(uri, method) => method == 'GET'] = '<html><body><div id="messagetext"><p>抱歉，您没有权限</p></div></body></html>';
      final added = await FavoriteRepository().addFavorite(tid: '1').run();
      expect(added.toNullable(), isA<FavoriteAddFailed>().having((e) => e.message, 'message', '抱歉，您没有权限'));
      final removed = await FavoriteRepository().removeFavorite(favid: '1').run();
      expect(removed.toNullable()?.removed, isFalse);
      expect(adapter.requests.where((e) => e.$2 == 'POST'), isEmpty);
    });

    test('findFavid walks the list and remembers every record', () async {
      adapter.answers[(uri, method) => method == 'GET'] = _data('favorite_list_x5.html');
      final repo = FavoriteRepository();
      expect((await repo.findFavid(tid: '1264975', uid: 1000).run()).toNullable(), '500329');
      expect((await repo.findFavid(tid: '404', uid: 1000).run()).toNullable(), isNull);
      expect(repo.cachedFavid(uid: 1000, tid: '1264928'), '500335');
      expect(repo.cachedFavid(uid: 1000, tid: '1264975'), '500329');
      expect(repo.cachedFavid(uid: 2000, tid: '1264975'), isNull, reason: 'records are per user');
      repo.forget(uid: 1000, tid: '1264975');
      expect(repo.cachedFavid(uid: 1000, tid: '1264975'), isNull);
    });
  });
}
