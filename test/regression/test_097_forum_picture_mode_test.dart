import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/forum/utils/forum_page_parser.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:universal_html/parsing.dart';

String _data(String name) => File('test/data/$name').readAsStringSync();

/// Plays the forum for a picture mode board and records the requested urls.
///
/// Like the forum, answers with the normal thread table only when `forumdefstyle=yes` is requested, else with the
/// thumbnail wall.
final class _RecordingAdapter implements HttpClientAdapter {
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    final html = options.uri.queryParameters['forumdefstyle'] == 'yes'
        ? _data('forum_picture_mode_defstyle_x5.html')
        : _data('forum_picture_mode_x5.html');
    return ResponseBody.fromString(
      html,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Iterable<String> _pictureModeWarnings() => talker.history
    .where((e) => e.logLevel == LogLevel.warning)
    .map((e) => e.message ?? '')
    .where((e) => e.contains('picture mode'));

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(useConsoleLogs: false));
  });
  setUp(() => talker.cleanHistory());

  test('a picture mode board has no thread row: it looks empty, not denied, and the wall is logged', () {
    final page = parseForumPage(parseHtmlDocument(_data('forum_picture_mode_x5.html')), '73');

    expect(page.title, '原创绘图区');
    expect(page.normalThreadList, isEmpty);
    expect(page.stickThreadList, isEmpty);
    // The subforum skips the permission check: nothing tells the user why the board is empty.
    expect(page.subredditList.map((e) => e.name), ['美术部']);
    expect(page.needLogin, isFalse);
    expect(page.havePermission, isTrue);
    expect(page.canLoadMore, isTrue);
    expect(page.totalPages, 188);

    expect(_pictureModeWarnings(), ['forum 73 is in picture mode, 3 threads on the thumbnail wall are not parsed']);
  });

  test('the same board with forumdefstyle=yes is a normal thread table', () {
    final page = parseForumPage(parseHtmlDocument(_data('forum_picture_mode_defstyle_x5.html')), '73');

    expect(page.title, '原创绘图区');
    // The global pinned thread is not on the thumbnail wall, the board's own pinned thread is its first item.
    expect(page.stickThreadList.map((e) => e.threadID), ['1000004', '1000001']);
    expect(page.stickThreadList.first.stateSet, contains(ThreadStateModel.pinnedGlobally));
    expect(page.stickThreadList.last.stateSet, contains(ThreadStateModel.pinnedInSubreddit));
    expect(page.normalThreadList.map((e) => e.threadID), ['1000003', '1000002']);

    final first = page.normalThreadList.first;
    expect(first.title, '个人图帖');
    expect(first.author.uid, '1000');
    expect(first.author.name, 'Alice');
    expect(first.threadType?.name, '个人图帖');
    expect(first.replyCount, 3);
    expect(first.viewCount, 57);
    expect(page.normalThreadList.last.author.uid, '1001');

    expect(page.subredditList.map((e) => e.name), ['美术部']);
    expect(page.canLoadMore, isTrue);
    expect(page.totalPages, 188);
    expect(_pictureModeWarnings(), isEmpty);
  });

  group('forum requests', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late _RecordingAdapter adapter;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      adapter = _RecordingAdapter();
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerFactory<NetClientProvider>(
          () => NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = adapter),
        );
      await settings.init();
    });
    tearDown(() async {
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    test('ask for the normal thread table and get its rows', () async {
      final document = (await ForumRepository().fetchForum(fid: '73', filterState: const FilterState()).run()).unwrap();

      final uri = adapter.requests.single;
      expect(uri.host, baseHost);
      expect(uri.path, '/forum.php');
      // `mobile=no` is added by the net client to every forum request.
      expect(uri.queryParameters, {
        'mod': 'forumdisplay',
        'fid': '73',
        'page': '1',
        'forumdefstyle': 'yes',
        'mobile': 'no',
      });
      expect(parseForumPage(document, '73').normalThreadList.map((e) => e.threadID), ['1000003', '1000002']);
      expect(_pictureModeWarnings(), isEmpty);
    });

    test('keep asking for it on later pages and with every filter', () async {
      const filterState = FilterState(
        filter: 'typeid',
        filterType: FilterType(name: '个人图帖', typeID: '390'),
        filterSpecialType: FilterSpecialType(name: '投票', specialType: 'poll'),
        filterDateline: FilterDateline(name: '一周', dateline: '604800'),
        filterOrder: FilterOrder(name: '发帖时间', orderBy: 'dateline'),
        filterDigest: FilterDigest(digest: true),
        filterRecommend: FilterRecommend(recommend: true),
      );
      (await ForumRepository().fetchForum(fid: '73', filterState: filterState, pageNumber: 3).run()).unwrap();

      expect(adapter.requests.single.queryParameters, {
        'mod': 'forumdisplay',
        'fid': '73',
        'page': '3',
        'forumdefstyle': 'yes',
        'recommend': '1',
        'orderby': 'dateline',
        'typeid': '390',
        'specialtype': 'poll',
        'dateline': '604800',
        'digest': '1',
        'filter': 'typeid',
        'mobile': 'no',
      });
    });
  });
}
