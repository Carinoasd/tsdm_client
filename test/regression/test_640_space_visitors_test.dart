import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/friend/models/models.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/features/friend/utils/friend_page_api.dart';
import 'package:tsdm_client/features/friend/utils/parse_friend.dart';
import 'package:tsdm_client/features/friend/widgets/friend_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:universal_html/parsing.dart';

/// The "最近访客" list of the own space (`home.php?mod=space&do=friend&view=visitor`): the plugin answers it as the
/// friends list (`schema` 10, `view` visitor) with the time of each visit in `dateline`; the web page prints only a
/// date ("11月8日"). Another member's `view=visitor` is answered as that member's list of friends by the forum, so
/// only the own list is asked.
String _data(String name) => File('test/data/$name').readAsStringSync();

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  const url = 'https://forum.test/home.php?mod=space&do=friend&view=visitor';

  test('the plugin answer: the visitors with the time of the visit in the forum wall clock', () {
    final json = jsonDecode(_data('tsdmapp/friend_v10_visitor.json')) as Map<String, dynamic>;
    final answer = friendApiAnswerOf(json);
    expect(answer, isNotNull);
    final page = friendListPageFromApi(answer!, url);
    expect(page.items.map((e) => e.username), ['ag_low', 'ag_t02', 'ag_admin', 'ag_t01']);
    expect(page.totalCount, 4);
    expect(page.nextPageUrl, isNull);
    final first = page.items.first;
    expect(first.uid, '31');
    expect(first.avatarUrl, 'https://forum.test/data/avatar/000/00/00/31_avatar_small.jpg');
    // 1794113072 is 2026-11-08 04:44:32 UTC, +8 hours of the answer.
    expect(first.visitedAt, DateTime(2026, 11, 8, 12, 44, 32));
    expect(first.visitedText, isNull);
    expect(page.items.every((e) => e.visitedAt != null), isTrue);
  });

  test('a friends list answer carries no visit time', () {
    final json = jsonDecode(_data('tsdmapp/friend_v10_other.json')) as Map<String, dynamic>;
    final page = friendListPageFromApi(json, '$baseUrl/home.php?mod=space&uid=64&do=friend');
    expect(page.items.single.visitedAt, isNull);
  });

  test('the web page of an older plugin: visitors that are not friends are listed, with the printed date', () {
    final page = parseFriendListPage(parseHtmlDocument(_data('friend_visitor_x5.html')), visitor: true);
    expect(page.items.map((e) => e.uid), ['31', '38', '32', '37']);
    expect(page.items.first.username, 'ag_low');
    expect(page.items.first.visitedText, '11月8日');
    expect(page.items.first.visitedAt, isNull);
    expect(page.items.first.groupName, isNull, reason: 'the line under the name is the mood, not a user group');
    expect(page.nextPageUrl, contains('view=visitor'));
    expect(page.nextPageUrl, contains('page=2'));
    // As a friends list the same page has no friend: every row carries a "加为好友" link.
    expect(parseFriendListPage(parseHtmlDocument(_data('friend_visitor_x5.html'))).items, isEmpty);
  });

  test('a visitor whose link has no text is named by its title', () {
    final document = parseHtmlDocument(
      '<ul class="buddy cl"><li id="friend_9_li"><div class="avt"></div><h4><span class="xg1 y">1月1日</span> '
      '<a href="home.php?mod=space&uid=9" title="Nine"></a></h4></li></ul>',
    );
    final page = parseFriendListPage(document, visitor: true);
    expect(page.items.single.username, 'Nine');
    expect(page.items.single.visitedText, '1月1日');
  });

  test('the visitors url is told from a friends list', () {
    expect(FriendRepository.isVisitorUrl(FriendRepository.visitorListUrl), isTrue);
    expect(FriendRepository.isVisitorUrl('$baseUrl/home.php?mod=space&do=friend&view=visitor&page=2'), isTrue);
    expect(FriendRepository.isVisitorUrl(FriendRepository.listUrl(uid: '31')), isFalse);
  });

  test('links to the own visitors list open it; a member given keeps the friends list', () {
    final own = '$baseUrl/home.php?mod=space&do=friend&view=visitor'.parseUrlToRoute();
    expect(own?.screenPath, ScreenPaths.friend);
    expect(own?.queryParameters, {'view': 'visitor'});
    final other = '$baseUrl/home.php?mod=space&uid=31&do=friend&view=visitor'.parseUrlToRoute();
    expect(other?.queryParameters, {'uid': '31'});
    expect('$baseUrl/home.php?mod=space&do=friend'.parseUrlToRoute()?.queryParameters, isEmpty);
  });

  group('visitor card', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      getIt
        ..registerSingleton<StorageProvider>(StorageProvider(db, {}, {}))
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<ImageCacheProvider>(ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio())));
    });

    tearDown(() async {
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await db.close();
    });

    Future<void> pump(WidgetTester tester, Friend friend) => tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(body: FriendCard(friend, visitor: true)),
        ),
      ),
    );

    testWidgets('shows the time of the visit and no message button', (tester) async {
      await pump(tester, Friend(uid: '31', username: 'ag_low', visitedAt: DateTime(2026, 11, 8, 12, 44)));
      expect(find.text('ag_low'), findsOneWidget);
      expect(find.textContaining('2026'), findsOneWidget);
      expect(find.byIcon(Icons.email_outlined), findsNothing);
    });

    testWidgets('a visit without a time leaves no empty line', (tester) async {
      await pump(tester, const Friend(uid: '31', username: 'ag_low'));
      expect(find.byType(Text), findsOneWidget);
    });

    testWidgets('shows the printed date of the web page', (tester) async {
      await pump(tester, const Friend(uid: '31', username: 'ag_low', visitedText: '11月8日'));
      expect(find.text('11月8日'), findsOneWidget);
    });
  });
}
