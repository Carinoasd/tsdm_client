import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:universal_html/parsing.dart';

/// The thread list of a forum shows the author of every thread, but the rows carry no avatar at all: the only thing
/// they say about the author is the name and the uid in the profile link. The avatar circle therefore fell back to
/// the first letter of the name for everyone.
///
/// The avatar url is built from that uid, following the rule the forum's own script uses, and the avatar the app
/// already cached for a user fills in when the forum stores no file for them.
const _fixture = 'test/data/forum_thread_list_authors_x5.html';

/// A 1x1 transparent PNG, the "avatar" of every user in these tests.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Serves [_png] for the urls in [available] and answers 404 for anything else, like the forum does for a user who
/// never uploaded an avatar.
final class _AvatarAdapter implements HttpClientAdapter {
  _AvatarAdapter(this.available);

  final Set<String> available;
  final requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // The client appends `mobile=no` to every request, drop it to keep the urls readable here.
    final uri = options.uri;
    final url = Uri(scheme: uri.scheme, host: uri.host, path: uri.path).toString();
    requested.add(url);
    if (available.contains(url)) {
      return ResponseBody.fromBytes(
        _png,
        200,
        headers: {
          Headers.contentTypeHeader: ['image/png'],
        },
      );
    }
    return ResponseBody.fromString(
      '<html><head><title>404 Not Found</title></head><body>404 Not Found</body></html>',
      404,
      headers: {
        Headers.contentTypeHeader: ['text/html'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

List<NormalThread> _threads(String html) => parseHtmlDocument(
  html,
).querySelectorAll('tbody[id^="normalthread_"]').map(NormalThread.fromTBody).whereType<NormalThread>().toList();

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('avatar url built from uid', () {
    test('follows the directory layout the forum uses', () {
      // The shape was checked against the server: a thread page emits exactly this url for a user who uploaded an
      // avatar.
      expect(avatarUrlOfUid('7'), '$baseUrl/data/avatar/000/00/00/07_avatar_middle.jpg');
      expect(avatarUrlOfUid('1001'), '$baseUrl/data/avatar/000/00/10/01_avatar_middle.jpg');
      expect(avatarUrlOfUid('123456'), '$baseUrl/data/avatar/000/12/34/56_avatar_middle.jpg');
      expect(avatarUrlOfUid('1234567'), '$baseUrl/data/avatar/001/23/45/67_avatar_middle.jpg');
    });

    test('has no url without a usable uid', () {
      for (final uid in [null, '', '0', '-1', 'abc', 'uid', '12a', ' ']) {
        expect(avatarUrlOfUid(uid), isNull, reason: 'uid "$uid" names no user');
      }
    });
  });

  group('thread rows', () {
    late List<NormalThread> threads;

    setUpAll(() => threads = _threads(File(_fixture).readAsStringSync()));

    test('every author with a uid gets the avatar url of that uid', () {
      expect(threads.map((e) => e.author.name), ['Alice', 'Bob', 'Carol']);
      expect(threads[0].author.uid, '1000');
      expect(threads[0].author.avatarUrl, '$baseUrl/data/avatar/000/00/10/00_avatar_middle.jpg');
      expect(threads[1].author.uid, '1001');
      expect(threads[1].author.avatarUrl, '$baseUrl/data/avatar/000/00/10/01_avatar_middle.jpg');
    });

    test("an anonymous author gets no avatar instead of somebody else's", () {
      // The author cell of the third row is `<cite>匿名</cite>` without a link, so the parser falls back to the last
      // reply cell, which names a user by name only. Without a uid there is nothing to build an url from, and the
      // avatar of the user the fallback named must not be used for the anonymous author.
      final anonymous = threads[2];
      expect(anonymous.threadID, '1000003');
      expect(anonymous.author.uid, isNull);
      expect(anonymous.author.avatarUrl, isNull);
    });

    test('the row itself still carries no avatar', () {
      // Guards the reason this url is built at all: if the forum ever starts sending avatars in the list, the parser
      // should read them instead of guessing.
      final rows = parseHtmlDocument(File(_fixture).readAsStringSync()).querySelectorAll('tbody[id^="normalthread_"]');
      expect(rows.every((e) => e.querySelectorAll('img').isEmpty), isTrue);
    });
  });

  group('thread card', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late Directory tmp;
    late _AvatarAdapter adapter;

    NormalThread thread(String tid, {required String name, String? uid}) => NormalThread(
      title: 'Thread $tid',
      url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
      threadID: tid,
      author: User(
        name: name,
        url: '$baseUrl/home.php?mod=space&uid=$uid',
        uid: uid,
        avatarUrl: avatarUrlOfUid(uid),
      ),
      publishDate: DateTime(2026, 9),
      latestReplyAuthor: User(name: name, url: '$baseUrl/home.php?mod=space&username=$name'),
      latestReplyTime: DateTime(2026, 9, 2, 8),
      iconUrl: '',
      threadType: null,
      replyCount: 3,
      viewCount: 30,
      price: null,
      privilege: null,
      css: null,
      stateSet: const {},
      isRecentThread: false,
    );

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('tsdm_thread_avatar_');
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => switch (call.method) {
          'getApplicationCachePath' || 'getApplicationCacheDirectory' => '${tmp.path}/cache',
          'getApplicationSupportPath' || 'getApplicationSupportDirectory' => '${tmp.path}/support',
          'getTemporaryPath' || 'getTemporaryDirectory' => '${tmp.path}/tmp',
          'getApplicationDocumentsPath' || 'getApplicationDocumentsDirectory' => '${tmp.path}/docs',
          _ => null,
        },
      );
      await initCache();
    });

    tearDownAll(() => tmp.delete(recursive: true));

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      adapter = _AvatarAdapter({'$baseUrl/data/avatar/000/00/10/00_avatar_middle.jpg'});
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = adapter)),
        );
      await settings.init();
    });

    tearDown(() async {
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
    });

    /// Pumps the cards and keeps pumping until [until] holds, because loading an avatar is real async work.
    Future<void> pump(WidgetTester tester, List<NormalThread> threads, {required bool Function() until}) async {
      await tester.runAsync(() async {
        await tester.pumpWidget(
          TranslationProvider(
            child: BlocProvider<SettingsBloc>(
              create: (_) => SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository()),
              child: MaterialApp(
                home: Scaffold(
                  body: ListView(children: threads.map((e) => NormalThreadCard(e, disableTap: true)).toList()),
                ),
              ),
            ),
          ),
        );
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          await tester.pump(const Duration(milliseconds: 20));
          if (i > 4 && until()) {
            return;
          }
        }
      });
    }

    bool gone(String letter) => find.text(letter).evaluate().isEmpty;

    HeroUserAvatar avatarOf(WidgetTester tester, String name) => tester.widget<HeroUserAvatar>(
      find.byWidgetPredicate((w) => w is HeroUserAvatar && w.username == name),
    );

    testWidgets('the avatar circle asks for the avatar of the thread author', (tester) async {
      await pump(
        tester,
        [thread('10', name: 'Alice', uid: '1000'), thread('11', name: 'Bob', uid: '1001')],
        until: () => gone('A'),
      );

      expect(avatarOf(tester, 'Alice').avatarUrl, '$baseUrl/data/avatar/000/00/10/00_avatar_middle.jpg');
      expect(avatarOf(tester, 'Bob').avatarUrl, '$baseUrl/data/avatar/000/00/10/01_avatar_middle.jpg');
      // Alice uploaded an avatar, so it is loaded once and kept in the cache; Bob has none and keeps the letter.
      expect(adapter.requested.toSet(), {
        '$baseUrl/data/avatar/000/00/10/00_avatar_middle.jpg',
        '$baseUrl/data/avatar/000/00/10/01_avatar_middle.jpg',
      }, reason: 'only the two author avatars are asked for');
      expect(find.text('B'), findsOneWidget, reason: 'the letter stays for an author without an avatar file');
      expect(find.text('A'), findsNothing, reason: 'the loaded avatar replaces the letter');
    });

    testWidgets('an author without a uid keeps the letter and asks for nothing', (tester) async {
      await pump(tester, [thread('12', name: 'Carol')], until: () => find.text('C').evaluate().isNotEmpty);

      expect(avatarOf(tester, 'Carol').avatarUrl, isNull);
      expect(adapter.requested, isEmpty);
      expect(find.text('C'), findsOneWidget);
    });

    testWidgets('a cached avatar is shown when the forum stores no file for the user', (tester) async {
      // Dave set an external avatar url, so the forum has no file under his uid and the built url answers 404. The
      // app cached his avatar from a page that did carry the url, for example a thread page.
      const external = 'https://example.com/avatars/dave.gif';
      adapter.available.add(external);
      // Caching an avatar is real io, so it runs outside the fake async zone of the test.
      await tester.runAsync(
        () async => getIt.get<ImageCacheProvider>().getOrMakeCache(
          const ImageCacheUserAvatarRequest(username: 'Dave', imageUrl: external),
        ),
      );
      expect(adapter.requested, [external], reason: 'the external avatar was cached before the list was opened');
      adapter.requested.clear();

      await pump(tester, [thread('13', name: 'Dave', uid: '1002')], until: () => gone('D'));

      expect(avatarOf(tester, 'Dave').avatarUrl, '$baseUrl/data/avatar/000/00/10/02_avatar_middle.jpg');
      expect(
        adapter.requested,
        contains('$baseUrl/data/avatar/000/00/10/02_avatar_middle.jpg'),
        reason: 'the current avatar is asked for first',
      );
      expect(find.text('D'), findsNothing, reason: 'the cached avatar is used instead of the letter');
    });

    testWidgets('the missing avatar file is asked for once, not again on every card', (tester) async {
      // The url built from the uid answers 404 forever for a user with an external avatar. Asking the server again
      // every time the card is built would put one request per card on every list, so the answer is remembered.
      const external = 'https://example.com/avatars/erin.gif';
      adapter.available.add(external);
      await tester.runAsync(
        () async => getIt.get<ImageCacheProvider>().getOrMakeCache(
          const ImageCacheUserAvatarRequest(username: 'Erin', imageUrl: external),
        ),
      );
      adapter.requested.clear();

      const missing = '$baseUrl/data/avatar/000/00/10/04_avatar_middle.jpg';
      await pump(tester, [thread('14', name: 'Erin', uid: '1004')], until: () => gone('E'));
      expect(adapter.requested.where((e) => e == missing), hasLength(1), reason: 'asked for once');

      // The card goes away and comes back, the way a list does while scrolling.
      for (var round = 0; round < 3; round++) {
        await pump(tester, [], until: () => true);
        await pump(tester, [thread('14', name: 'Erin', uid: '1004')], until: () => gone('E'));
      }

      expect(
        adapter.requested.where((e) => e == missing),
        hasLength(1),
        reason: 'the server is not asked again for a file that is known to be missing',
      );
      expect(find.text('E'), findsNothing, reason: 'the cached avatar is still shown');
    });

    testWidgets('an author with no avatar anywhere is asked for once as well', (tester) async {
      // Nothing is cached for this user, so the card keeps the letter. The image the loader ends up with is kept by
      // the framework's image cache, so showing the card again does not repeat the request either.
      const missing = '$baseUrl/data/avatar/000/00/10/05_avatar_middle.jpg';
      await pump(tester, [thread('15', name: 'Frank', uid: '1005')], until: () => find.text('F').evaluate().isNotEmpty);
      expect(adapter.requested.where((e) => e == missing), hasLength(1));

      for (var round = 0; round < 3; round++) {
        await pump(tester, [], until: () => true);
        await pump(tester, [
          thread('15', name: 'Frank', uid: '1005'),
        ], until: () => find.text('F').evaluate().isNotEmpty);
      }

      expect(adapter.requested.where((e) => e == missing), hasLength(1), reason: 'asked for once, not once per card');
      expect(find.text('F'), findsOneWidget, reason: 'the letter stays');
    });
  });
}
