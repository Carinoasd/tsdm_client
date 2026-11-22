/// The backgrounds the authors of the floors set in the forum's background shop (plugin 4.1.0): the thread page asked
/// with `tsdmv=4` answers `schema` 78 with `backgrounds` (by the uid of the author) and each floor's `background`.
///
/// 1. the answer of the test forum (six floors of five authors, one author twice): each floor gets its author's
///    backgrounds, the styles as the web page draws them; the same thread asked without `tsdmv=4` (`schema` 23, the
///    answer of plugin 4.0.x) gives no floor any;
/// 2. what is never drawn: an anonymous floor, a blocked floor, a floor naming no background, a picture that is not an
///    absolute `https` url (or one of the forum), an empty or broken `backgrounds`;
/// 3. the request: `tsdmv=4` only with the setting on and a `status` that told the plugin knows it; never in the url
///    kept for sharing and reloading.
///
/// Fixtures only (cleaned answers of the test forum); nothing is sent.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/post_background/models/post_background.dart';
import 'package:tsdm_client/features/post_background/utils/post_background_query.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

Map<String, dynamic> _answer(String name) =>
    jsonDecode(File('test/data/tsdmapp_410/$name').readAsStringSync()) as Map<String, dynamic>;

List<Post> _posts(Map<String, dynamic> json) => threadPageFromApi(threadApiAnswerOf(json)!, 1).postList;

const _base = 'https://forum.test/source/plugin/background/background';

/// The thread page answers whatever it is asked.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  final Object answer;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode(answer),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('1. the answer of the test forum', () {
    test("schema 78: every floor its author's backgrounds, styles as the web page draws them", () {
      final json = _answer('thread_v78_backgrounds.json');
      expect(json['schema'], 78);
      final posts = _posts(json);
      expect(posts.map((p) => p.postID), ['24607', '24608', '24609', '24610', '24611', '24612']);
      final byPid = {for (final p in posts) p.postID: p.background};

      // ag_t16: the content tiled from the top left, the column's picture once at the right.
      expect(
        byPid['24607'],
        const PostBackground(
          content: PostBackgroundLayer(
            imageUrl: '$_base/1209-5.jpg',
            repeat: PostBackgroundRepeat.both,
            alignX: PostBackgroundAlignX.left,
            alignY: PostBackgroundAlignY.top,
          ),
          sidebar: PostBackgroundLayer(imageUrl: '$_base/1209-1.jpg', alignX: PostBackgroundAlignX.right),
        ),
      );
      // The same author further down: the same backgrounds (the answer gives them once).
      expect(byPid['24612'], byPid['24607']);
      // ag_t17: the content only, once at the bottom right.
      expect(
        byPid['24608'],
        const PostBackground(
          content: PostBackgroundLayer(
            imageUrl: '$_base/a1.jpg',
            alignX: PostBackgroundAlignX.right,
            alignY: PostBackgroundAlignY.bottom,
          ),
        ),
      );
      // ag_t18: the content stretched to the width at the top, the column tiled.
      expect(
        byPid['24609'],
        const PostBackground(
          content: PostBackgroundLayer(
            imageUrl: '$_base/BB1.jpg',
            alignY: PostBackgroundAlignY.top,
            size: PostBackgroundSize.fitWidth,
          ),
          sidebar: PostBackgroundLayer(imageUrl: '$_base/1209-2.jpg', repeat: PostBackgroundRepeat.both),
        ),
      );
      // ag_t19: the column only.
      expect(byPid['24610'], const PostBackground(sidebar: PostBackgroundLayer(imageUrl: '$_base/BB2.jpg')));
      // ag_t20: the content set not shown (none given), the column tiled from the bottom.
      expect(
        byPid['24611'],
        const PostBackground(
          sidebar: PostBackgroundLayer(
            imageUrl: '$_base/1209-4.jpg',
            repeat: PostBackgroundRepeat.both,
            alignY: PostBackgroundAlignY.bottom,
          ),
        ),
      );
    });

    test('the same thread without tsdmv=4 (schema 23, plugin 4.0.x): no floor has any, the rest the same', () {
      final older = _answer('thread_v23_same_thread.json');
      expect(older['schema'], 23);
      expect(older.containsKey('backgrounds'), isFalse);
      final posts = _posts(older);
      expect(posts, hasLength(6));
      expect(posts.where((p) => p.background != null), isEmpty);
      final newer = _posts(_answer('thread_v78_backgrounds.json'));
      expect(newer.map((p) => p.copyWith(background: null)).toList(), posts);
    });
  });

  group('2. what is never drawn', () {
    Map<String, dynamic> edited(void Function(Map<String, dynamic> json, List<Map<String, dynamic>> posts) edit) {
      final json = _answer('thread_v78_backgrounds.json');
      edit(json, (json['posts'] as List).cast<Map<String, dynamic>>());
      return json;
    }

    test('an anonymous floor, a blocked one, one whose avatar is blocked, one naming none or an unknown author', () {
      final posts = _posts(
        edited((json, posts) {
          // The plugin names none on an anonymous floor; an answer that did is not followed.
          posts[0]['anonymous'] = 1;
          posts[1]['message_reason'] = 'banned';
          posts[2]['avatar_blocked'] = 1;
          posts[3]['background'] = 0;
          posts[4]['background'] = 99;
          posts[5].remove('background');
        }),
      );
      expect(posts.where((p) => p.background != null), isEmpty);
    });

    test('an author in a banned group (a moderator sees the content): none either', () {
      final posts = _posts(
        edited((json, posts) {
          (posts[0]['group'] as Map<String, dynamic>)['gid'] = 4;
          (posts[1]['group'] as Map<String, dynamic>)['gid'] = 5;
        }),
      );
      expect(
        {for (final p in posts.take(3)) p.postID: p.background != null},
        {
          '24607': false,
          '24608': false,
          '24609': true,
        },
      );
    });

    test('backgrounds empty, an array, missing, or entries of the wrong shape', () {
      for (final value in <Object?>[<String, Object?>{}, <Object?>[], null, 'x', 1]) {
        final posts = _posts(edited((json, _) => json['backgrounds'] = value));
        expect(posts.where((p) => p.background != null), isEmpty, reason: '$value');
      }
      final posts = _posts(
        edited((json, _) {
          final backgrounds = json['backgrounds'] as Map<String, dynamic>;
          backgrounds['52'] = <Object?>[];
          backgrounds['53'] = {'content': 'x', 'sidebar': null};
          backgrounds['54'] = {'content': null, 'sidebar': null};
        }),
      );
      expect(
        {for (final p in posts) p.postID: p.background != null},
        {
          '24607': false,
          '24608': false,
          '24609': false,
          '24610': true,
          '24611': true,
          '24612': false,
        },
      );
    });

    test('pictures: an absolute https url, or one of the forum itself; nothing else', () {
      expect(postBackgroundImageUrl('https://cdn.example/a.jpg'), 'https://cdn.example/a.jpg');
      expect(postBackgroundImageUrl('$baseUrl/source/plugin/background/background/a.jpg'), isNotNull);
      for (final bad in <Object?>[
        '',
        '  ',
        null,
        1,
        'http://cdn.example/a.jpg',
        'a.jpg',
        '/source/plugin/background/background/a.jpg',
        '//cdn.example/a.jpg',
        'javascript:alert(1)',
        'data:image/png;base64,AAAA',
        'file:///etc/passwd',
        'https://user:pass@cdn.example/a.jpg',
      ]) {
        expect(postBackgroundImageUrl(bad), isNull, reason: '$bad');
      }
      // A layer whose picture is refused is none: the other one stays.
      expect(PostBackgroundLayer.fromApi({'image': 'http://cdn.example/a.jpg'}), isNull);
    });

    test('styles the member form never picks (an admin or an older plugin stored them), unknown values', () {
      PostBackgroundLayer layer(Map<String, Object?> style) =>
          PostBackgroundLayer.fromApi({'image': 'https://cdn.example/a.jpg', ...style})!;
      expect(layer({'repeat': 'x'}).repeat, PostBackgroundRepeat.x);
      expect(layer({'repeat': 'y'}).repeat, PostBackgroundRepeat.y);
      expect(layer({'size': 'cover'}).size, PostBackgroundSize.cover);
      expect(layer({'size': 'contain'}).size, PostBackgroundSize.contain);
      // The web page's defaults for anything else.
      expect(
        layer({'repeat': 'repeat', 'align_x': 2, 'align_y': 'middle', 'size': '100% auto'}),
        const PostBackgroundLayer(imageUrl: 'https://cdn.example/a.jpg'),
      );
    });
  });

  group('3. the request', () {
    late AppDatabase db;
    late SettingsRepository settings;

    setUp(() async {
      getIt.allowReassignment = true;
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
      await settings.init();
      TsdmAppApi.reset();
    });
    tearDown(() async {
      TsdmAppApi.reset();
      await getIt.reset();
      getIt.allowReassignment = false;
      await settings.dispose();
      await db.close();
    });

    void knowsV4({required bool on}) => TsdmAppApi.pluginInfo.value = TsdmAppPluginInfo(
      version: '4.1.0',
      api: 1,
      nodoc: true,
      v4: on ? const TsdmAppV4Flags(on: true) : TsdmAppV4Flags.none,
    );

    Future<(RequestOptions, String?)> ask() async {
      final forum = _Forum(_answer('thread_v78_backgrounds.json'));
      getIt.registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      );
      final repository = ThreadRepository();
      final page = (await repository.fetchThreadPage(tid: '9203680').run()).fold((e) => throw e, (v) => v);
      expect(page.postList, hasLength(6));
      expect(forum.requests, hasLength(1), reason: 'nothing else asked: no status, no picture');
      return (forum.requests.single, repository.threadUrl);
    }

    test('the setting on and a status that knows tsdmv=4: asked with it, the url kept without', () async {
      knowsV4(on: true);
      expect(SettingsKeys.showPostBackgrounds.defaultValue, isTrue);
      final (request, kept) = await ask();
      expect(request.uri.queryParameters, containsPair('tsdmv', '4'));
      expect(request.uri.queryParameters, containsPair('tsdmapp', 'json'));
      expect(kept, isNot(contains('tsdmv')));
      expect(kept, isNot(contains('tsdmapp')));
    });

    test('the setting off: asked exactly as before', () async {
      knowsV4(on: true);
      await settings.setValue(SettingsKeys.showPostBackgrounds, false);
      final (request, _) = await ask();
      expect(request.uri.queryParameters.containsKey('tsdmv'), isFalse);
    });

    test('no status told yet, or one of a plugin without tsdmv=4: not asked, nothing asked to learn it', () async {
      var (request, _) = await ask();
      expect(request.uri.queryParameters.containsKey('tsdmv'), isFalse);
      knowsV4(on: false);
      (request, _) = await ask();
      expect(request.uri.queryParameters.containsKey('tsdmv'), isFalse);
    });

    test('the query is added once, and never to a url with a fragment', () {
      knowsV4(on: true);
      expect(withPostBackgroundsQuery('$baseUrl/forum.php?mod=viewthread&tid=1&tsdmapp=json'), endsWith('&tsdmv=4'));
      expect(
        withPostBackgroundsQuery('$baseUrl/forum.php?mod=viewthread&tid=1&tsdmv=4'),
        '$baseUrl/forum.php?mod=viewthread&tid=1&tsdmv=4',
      );
      expect(withPostBackgroundsQuery('$baseUrl/forum.php?tid=1#pid2'), '$baseUrl/forum.php?tid=1#pid2');
      expect(postBackgroundsAsked(), isTrue);
      expect(TsdmAppV4.on, isTrue);
    });
  });
}
