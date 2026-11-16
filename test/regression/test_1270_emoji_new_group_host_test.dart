/// A group of emoji the forum added later (`大肥鱼`, group 20, directory `deepseek`):
///
/// 1. the forum's list (a real sample of `data/cache/common_smilies_var.js`, the new group first, file names with
///    spaces and brackets) names each image on the forum's own static directory, the place its web page shows them
///    from (`static/image/smiley/<dir>/<file>`); the image host (`img.tsdm39.com/img02/smilies/`) has not every file;
/// 2. an emoji is downloaded from the forum, else from the image host (and the other way round): one place failing is
///    not the emoji failing; the url saved by an older version (the image host) works the same; the emoji already on
///    the device are never asked again; still a few at once at most;
/// 3. the emoji panel shows the list on the device at once and asks the forum for its list once a run in the
///    background: a group added or changed shows, an emoji removed goes, nothing changed is not saved; a failure says
///    nothing; the editor's fetch of the list shares the same request;
/// 4. a group whose images all fail shows the retry, in a bounded time;
/// 5. an emoji of the new group in the editor (an old list on the device without it) shows its image once the list
///    is fresh.
///
/// No real network: the forum is an adapter of the test.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/editor/bloc/emoji_bloc.dart';
import 'package:tsdm_client/features/editor/repository/editor_repository.dart';
import 'package:tsdm_client/features/editor/widgets/emoji_image.dart';
import 'package:tsdm_client/features/editor/widgets/emoji_panel.dart';
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

/// A 1x1 png.
final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

/// The forum's list, recorded as a guest.
final String _realList = File('test/data/emoji/common_smilies_var.js').readAsStringSync();

const _forumHead = 'https://www.tsdm39.com/static/image/smiley/';
const _hostHead = 'https://img.tsdm39.com/img02/smilies/';

/// A group of a small list: its name, its directory and its emoji `(id, file)`.
typedef _Group = ({String name, String dir, List<(String, String)> emoji});

/// A small list: group [groups] in this order, each `id: [(emojiId, file)]`.
String _list(Map<String, ({String name, String dir, List<(String, String)> emoji})> groups) {
  final b = StringBuffer("var smthumb = '20';var smilies_type = new Array();");
  for (final e in groups.entries) {
    b.write("smilies_type['_${e.key}'] = ['${e.value.name}', '${e.value.dir}'];");
  }
  b.write('var smilies_array = new Array();var smilies_fast = new Array();');
  for (final e in groups.entries) {
    b
      ..write('smilies_array[${e.key}] = new Array();')
      ..write('smilies_array[${e.key}][1] = [')
      ..write(e.value.emoji.map((x) => "['${x.$1}', '{:${e.key}_${x.$1}:}','${x.$2}','20','20','50']").join(','))
      ..write('];');
  }
  return b.toString();
}

final _Group _tsdm = (name: '梦予馨', dir: 'TSDM', emoji: [('865', '9.jpg'), ('853', '16.jpg')]);
final _Group _fish = (name: '大肥鱼', dir: 'deepseek', emoji: [('984', 'd (1).gif'), ('1003', 's (19).png')]);

/// The forum: the list and the images, counted. A url containing one of [missing] answers 404 (an html page, as the
/// image host does), [offline] fails every request, [listFails] the list only.
final class _Forum implements HttpClientAdapter {
  _Forum(this.list);

  String list;
  final requests = <String>[];
  final missing = <String>{};
  bool offline = false;
  bool listFails = false;

  /// How long an image takes to answer.
  Duration imageDelay = const Duration(milliseconds: 5);

  /// The list answers once this completes.
  Completer<void>? listGate;
  int _running = 0;
  int maxRunning = 0;

  Iterable<String> get imageRequests => requests.where((e) => !e.endsWith('.js'));

  int get listRequests => requests.where((e) => e.endsWith('common_smilies_var.js')).length;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // Without the query the client adds to every request (`mobile=no`).
    final url = options.uri.replace(query: '').toString().replaceAll(RegExp(r'\?$'), '');
    requests.add(url);
    _running++;
    maxRunning = _running > maxRunning ? _running : maxRunning;
    try {
      await Future<void>.delayed(url.endsWith('.js') ? const Duration(milliseconds: 5) : imageDelay);
      if (offline) {
        throw DioException.connectionError(requestOptions: options, reason: 'offline');
      }
      if (url.endsWith('common_smilies_var.js')) {
        await listGate?.future;
        if (listFails) {
          return ResponseBody.fromString('<html>busy</html>', 503);
        }
        return ResponseBody.fromString(
          list,
          200,
          headers: {
            Headers.contentTypeHeader: ['application/javascript'],
          },
        );
      }
      if (missing.any(url.contains)) {
        return ResponseBody.fromString(
          '<html><body>404 Not Found</body></html>',
          404,
          headers: {
            Headers.contentTypeHeader: ['text/html'],
          },
        );
      }
      return ResponseBody.fromBytes(
        _png,
        200,
        headers: {
          Headers.contentTypeHeader: ['image/png'],
        },
      );
    } finally {
      _running--;
    }
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late _Forum forum;
  late NetClientProvider client;
  late ImageCacheProvider cache;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    tmp = Directory.systemTemp.createTempSync('tsdm_emoji_new_group_');
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => switch (call.method) {
        'getApplicationCachePath' || 'getApplicationCacheDirectory' => '${tmp.path}/cache',
        'getApplicationSupportPath' || 'getApplicationSupportDirectory' => '${tmp.path}/support',
        'getTemporaryPath' || 'getTemporaryDirectory' => '${tmp.path}/tmp',
        _ => null,
      },
    );
    await initCache();
  });
  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    EmojiListInBackground.reset();
    db = AppDatabase(NativeDatabase.memory());
    forum = _Forum(_list({'20': _fish, '12': _tsdm}));
    final storage = StorageProvider(db, {}, {});
    final settings = SettingsRepository(storage);
    client = NetClientProvider.buildNoCookie(
      dio: Dio()..httpClientAdapter = forum,
      cookie: CookieProvider.buildEmpty(),
    );
    cache = ImageCacheProvider(client);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings, dispose: (s) => s.dispose())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<NetClientProvider>(client, instanceName: ServiceKeys.noCookie)
      ..registerSingleton<ImageCacheProvider>(cache);
    await settings.init();
    await cache.clearEmojiCache();
  });
  tearDown(() async {
    await getIt.reset();
    await cache.dispose();
    await db.close();
  });

  EditorRepository newRepo() => EditorRepository(netClientProvider: client, imageCacheProvider: cache);

  /// What an older version saved: the list naming the images on the image host.
  Future<void> saveOldList(Map<String, ({String name, String dir, List<(String, String)> emoji})> groups) =>
      cache.saveEmojiInfo([
        for (final g in groups.entries)
          EmojiGroup(
            name: g.value.name,
            id: g.key,
            routeName: g.value.dir,
            emojiList: [
              for (final e in g.value.emoji)
                Emoji(
                  id: e.$1,
                  code: '{:${g.key}_${e.$1}:}',
                  url: '$_hostHead${g.value.dir}/${Uri.encodeComponent(e.$2)}',
                ),
            ],
          ),
      ]);

  group('1. the real list', () {
    test('the new group first, its images on the forum, names encoded', () {
      final groups = newRepo().parseEmojiInfo(_realList);
      expect(groups.first.id, '20');
      expect(groups.first.name, '大肥鱼');
      expect(groups.first.routeName, 'deepseek');
      expect(groups.first.emojiList, hasLength(36));
      expect(groups.first.emojiList.first.code, '{:20_984:}');
      expect(groups.first.emojiList.first.url, '${_forumHead}deepseek/d%20(1).gif');
      expect(groups.first.emojiList[1].url, '${_forumHead}deepseek/s%20(19).png');
      expect(groups.map((e) => e.id), containsAll(['20', '12', '4', '6', '11']));
      expect(groups.where((e) => e.id == '12').single.emojiList.first.url, startsWith('${_forumHead}TSDM/'));
      for (final g in groups) {
        for (final e in g.emojiList) {
          expect(ImageCacheProvider.emojiImageKeyOf(e.url), isNotNull, reason: e.url);
        }
      }
    });

    test('each emoji has the forum and the image host as places, whatever url was saved', () {
      for (final saved in ['${_forumHead}deepseek/d%20(1).gif', '${_hostHead}deepseek/d%20(1).gif']) {
        expect(ImageCacheProvider.emojiImageUrlsOf(saved), [
          '${_forumHead}deepseek/d%20(1).gif',
          '${_hostHead}deepseek/d%20(1).gif',
        ]);
      }
      // Not one of the forum's places: that url only.
      expect(ImageCacheProvider.emojiImageUrlsOf('https://img.example/a.gif'), ['https://img.example/a.gif']);
    });
  });

  group('2. two places for each image', () {
    test('a new group the image host has not: from the forum, one request each', () async {
      forum.missing.add('img02/smilies/deepseek/');
      final repo = newRepo();
      await repo.loadEmojiFromCacheOrServer().run();
      final fish = repo.emojiGroupList!.firstWhere((e) => e.id == '20');
      expect(await repo.downloadEmojiGroup(fish), 0);
      expect(cache.hasEmojiCacheFile('20', '984'), isTrue);
      expect(cache.hasEmojiCacheFile('20', '1003'), isTrue);
      expect(forum.imageRequests, ['${_forumHead}deepseek/d%20(1).gif', '${_forumHead}deepseek/s%20(19).png']);
    });

    test('the forum failing: from the image host', () async {
      forum.missing.add('static/image/smiley/TSDM/');
      final repo = newRepo();
      await repo.loadEmojiFromCacheOrServer().run();
      final tsdm = repo.emojiGroupList!.firstWhere((e) => e.id == '12');
      expect(await repo.downloadEmojiGroup(tsdm), 0);
      expect(forum.imageRequests.where((e) => e.startsWith(_hostHead)), hasLength(2));
    });

    test('the url an older version saved (the image host, without the file there): from the forum', () async {
      await saveOldList({'20': _fish});
      forum.missing.add('img02/smilies/');
      final repo = EditorRepository(netClientProvider: client, imageCacheProvider: ImageCacheProvider(client));
      await repo.loadEmojiFromCacheOrServer().run();
      expect(await repo.downloadEmojiGroup(repo.emojiGroupList!.single), 0);
      expect(cache.hasEmojiCacheFile('20', '984'), isTrue);
      // The editor and the recent ones ask by the ids only.
      await cache.clearEmojiCache();
      await saveOldList({'20': _fish});
      expect(await ImageCacheProvider(client).getOrMakeEmojiCache('20', '984'), _png);
    });

    test('both failing: not there, and asked again on retry', () async {
      forum.missing.add('deepseek/d%20(1)');
      final repo = newRepo();
      await repo.loadEmojiFromCacheOrServer().run();
      final fish = repo.emojiGroupList!.firstWhere((e) => e.id == '20');
      expect(await repo.downloadEmojiGroup(fish), 1);
      expect(forum.imageRequests.where((e) => e.contains('d%20(1)')), hasLength(2));
      forum.missing.clear();
      expect(await repo.downloadEmojiGroup(fish), 0);
    });

    test('the emoji on the device are never asked again; a few at once at most', () async {
      final repo = newRepo();
      await repo.loadEmojiFromCacheOrServer().run();
      forum.list = _realList;
      EmojiListInBackground.reset();
      await cache.clearEmojiCache();
      final real = newRepo();
      await real.loadEmojiFromCacheOrServer().run();
      final big = real.emojiGroupList!.firstWhere((e) => e.id == '6');
      forum
        ..requests.clear()
        ..missing.add('static/image/smiley/');
      expect(await real.downloadEmojiGroup(big), 0);
      expect(forum.maxRunning, lessThanOrEqualTo(ImageCacheProvider.maxEmojiDownloads));
      forum.requests.clear();
      expect(await real.downloadEmojiGroup(big), 0);
      expect(forum.requests, isEmpty);
    });
  });

  group('3. the list refreshed in the background', () {
    Future<EmojiBloc> openPanel() async {
      final bloc = EmojiBloc(editRepository: newRepo())..add(EmojiFetchFromCacheEvent());
      addTearDown(bloc.close);
      await bloc.stream.firstWhere((e) => e.status == EmojiStatus.success);
      return bloc;
    }

    test('a group added: shown after the list on the device, saved, nothing downloaded again', () async {
      await saveOldList({'12': _tsdm});
      for (final id in ['865', '853']) {
        await cache.updateEmojiCache('12', id, _png);
      }
      final bloc = EmojiBloc(editRepository: newRepo());
      addTearDown(bloc.close);
      final lists = <List<String>>[];
      final sub = bloc.stream.listen((e) {
        final ids = e.emojiGroupList?.map((g) => g.id).toList();
        if (ids != null && (lists.isEmpty || lists.last.join() != ids.join())) lists.add(ids);
      });
      addTearDown(sub.cancel);
      bloc.add(EmojiFetchFromCacheEvent());
      await bloc.stream.firstWhere((e) => e.emojiGroupList?.length == 2);
      expect(lists, [
        ['12'],
        ['20', '12'],
      ], reason: "the list on the device first, then the forum's");
      expect(forum.listRequests, 1);
      expect(forum.imageRequests, isEmpty);
      expect((await cache.loadEmojiInfo())!.map((e) => e.id), ['20', '12']);
      expect(cache.hasEmojiCacheFile('12', '865'), isTrue);

      // Opened again in the same run: not asked again.
      await openPanel();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(forum.listRequests, 1);
    });

    test(
      'an emoji removed: no longer shown nor known, its file stays; a group shown downloads what it gained',
      () async {
        await saveOldList({
          '12': (name: '梦予馨', dir: 'TSDM', emoji: [('865', '9.jpg'), ('700', 'old.jpg')]),
        });
        await cache.updateEmojiCache('12', '865', _png);
        await cache.updateEmojiCache('12', '700', _png);
        forum.list = _list({'12': _tsdm});
        final bloc = EmojiBloc(editRepository: newRepo())..add(EmojiFetchFromCacheEvent());
        addTearDown(bloc.close);
        await bloc.stream.firstWhere((e) => e.status == EmojiStatus.success);
        bloc.add(EmojiFetchGroupEvent('12'));
        final done = await bloc.stream.firstWhere(
          (e) =>
              e.emojiGroupList!.single.emojiList.length == 2 &&
              e.emojiGroupList!.single.emojiList.last.id == '853' &&
              e.groupProgress['12']?.status == EmojiStatus.success &&
              e.groupProgress['12']?.total == 2,
        );
        expect(done.emojiGroupList!.single.emojiList.map((e) => e.id), ['865', '853']);
        expect(forum.imageRequests, ['${_forumHead}TSDM/16.jpg'], reason: 'the emoji gained only');
        expect(cache.hasEmojiCacheFile('12', '700'), isTrue, reason: 'files stay');
        // An emoji in a post of the file removed is an image like any other now.
        const removed = '${_forumHead}TSDM/old.jpg';
        expect((await cache.getOrMakeCache(const ImageCacheGeneralRequest(removed))).toNullable(), _png);
        expect(await getIt.get<StorageProvider>().getImageCache(removed), isNotNull, reason: 'not the emoji cache');
        expect(await cache.isInEmojiList('12', '700'), isFalse);
      },
    );

    test('a group downloading when the list comes ends with all its images', () async {
      final six = (
        name: '梦予馨',
        dir: 'TSDM',
        emoji: [for (var i = 1; i <= 6; i++) ('${860 + i}', '$i.jpg')],
      );
      await saveOldList({'12': six});
      forum
        ..list = _list({'20': _fish, '12': six})
        ..imageDelay = const Duration(milliseconds: 40);
      final gate = forum.listGate = Completer<void>();
      final bloc = EmojiBloc(editRepository: newRepo())..add(EmojiFetchFromCacheEvent());
      addTearDown(bloc.close);
      await bloc.stream.firstWhere((e) => e.status == EmojiStatus.success);
      bloc.add(EmojiFetchGroupEvent('12'));
      await bloc.stream.firstWhere((e) => (e.groupProgress['12']?.done ?? 0) > 0);
      gate.complete();
      await bloc.stream.firstWhere((e) => e.emojiGroupList!.length == 2);
      final done = await bloc.stream
          .firstWhere((e) => e.groupProgress['12']?.status != EmojiStatus.loading)
          .timeout(const Duration(seconds: 5));
      expect(done.groupProgress['12']!.status, EmojiStatus.success);
      expect(done.groupProgress['12']!.done, 6);
      for (var i = 1; i <= 6; i++) {
        expect(cache.hasEmojiCacheFile('12', '${860 + i}'), isTrue);
      }
      expect(forum.imageRequests, hasLength(6), reason: 'not downloaded twice');
    });

    test('a panel that read the list before another one refreshed it gets the new list', () async {
      await saveOldList({'12': _tsdm});
      final late = newRepo();
      await late.loadEmojiFromCacheOrServer().run();
      expect(await EmojiListInBackground.refresh(cache), isNotNull);
      expect((await late.refreshEmojiList())!.map((e) => e.id), ['20', '12']);
      expect(forum.listRequests, 1);
    });

    test('nothing changed: not saved again, not shown again', () async {
      final repo = newRepo();
      await repo.loadEmojiFromCacheOrServer().run();
      EmojiListInBackground.reset();
      forum.requests.clear();
      final revision = cache.emojiListRevision.value;
      final bloc = await openPanel();
      final states = <EmojiState>[];
      final sub = bloc.stream.listen(states.add);
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(forum.listRequests, 1);
      expect(cache.emojiListRevision.value, revision);
      expect(states, isEmpty);
    });

    test('the url of the list saved by an older version is no change', () async {
      await saveOldList({'20': _fish, '12': _tsdm});
      final revision = cache.emojiListRevision.value;
      await openPanel();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(forum.listRequests, 1);
      expect(cache.emojiListRevision.value, revision);
    });

    test('a failure says nothing and is not asked again in the run', () async {
      await saveOldList({'12': _tsdm});
      forum.listFails = true;
      final bloc = await openPanel();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(bloc.state.status, EmojiStatus.success);
      expect(bloc.state.emojiGroupList!.map((e) => e.id), ['12']);
      expect(forum.listRequests, 1);
      forum.listFails = false;
      await openPanel();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(forum.listRequests, 1, reason: 'next run');
    });

    test('the editor and the panel share one request', () async {
      await saveOldList({'12': _tsdm});
      final results = await Future.wait([
        EmojiListInBackground.refresh(cache),
        openPanel().then((b) => b.stream.firstWhere((e) => e.emojiGroupList!.length == 2)),
      ]);
      expect(results.first, isNotNull);
      expect(forum.listRequests, 1);
    });

    test('without a list the panel still fetches it again after a failure (its retry)', () async {
      forum.offline = true;
      expect(await EmojiListInBackground.ensure(cache), isFalse);
      forum.offline = false;
      expect((await newRepo().loadEmojiFromCacheOrServer().run()).isRight(), isTrue);
      expect(forum.listRequests, 2);
    });
  });

  /// Let the files and the forum answer, until [done] or a while.
  Future<void> settle(WidgetTester tester, bool Function() done, {int rounds = 100}) async {
    for (var i = 0; i < rounds && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  group('4. the panel', () {
    Widget panel() => TranslationProvider(
      child: MaterialApp(
        home: Scaffold(body: EmojiPanel(onPicked: (_) {})),
      ),
    );

    testWidgets('a group whose images all fail shows the retry, and the images after it', (tester) async {
      forum.missing.add('deepseek/');
      await tester.pumpWidget(panel());
      await settle(tester, () => find.byType(FilledButton).evaluate().isNotEmpty);
      final fish = find.byKey(const ValueKey('emoji-panel-group-20'));
      expect(fish, findsOneWidget, reason: 'the first group is shown');
      expect(find.descendant(of: fish, matching: find.byType(FilledButton)), findsOneWidget);

      forum.missing.clear();
      await tester.tap(find.descendant(of: fish, matching: find.byType(FilledButton)));
      await settle(tester, () => find.descendant(of: fish, matching: find.byType(Image)).evaluate().length == 2);
      expect(find.descendant(of: fish, matching: find.byType(Image)), findsNWidgets(2));
      expect(find.byKey(const ValueKey('emoji-group-retry')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('while the images fail one after the other the bar moves', (tester) async {
      forum
        ..list = _list({
          '20': (name: '大肥鱼', dir: 'deepseek', emoji: [for (var i = 1; i <= 8; i++) ('${983 + i}', 'd ($i).gif')]),
        })
        ..missing.add('deepseek/')
        ..imageDelay = const Duration(milliseconds: 100);
      const bar = ValueKey('emoji-group-progress');
      double? value() => tester.widget<LinearProgressIndicator>(find.byKey(bar)).value;
      await tester.pumpWidget(panel());
      await settle(tester, () => find.byKey(bar).evaluate().isNotEmpty);
      expect(value(), isNull, reason: 'running before the first answer, not an empty bar at 0');
      await settle(tester, () => find.byKey(bar).evaluate().isEmpty || (value() ?? 0) > 0);
      expect(value(), allOf(greaterThan(0), lessThan(1)), reason: 'the failed ones move it');
      await settle(tester, () => find.byType(FilledButton).evaluate().isNotEmpty);
      expect(find.byType(FilledButton), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('some failing: the images that came and the retry', (tester) async {
      forum.missing.add('deepseek/s%20(19)');
      await tester.pumpWidget(panel());
      await settle(tester, () => find.byKey(const ValueKey('emoji-group-retry')).evaluate().isNotEmpty);
      final fish = find.byKey(const ValueKey('emoji-panel-group-20'));
      expect(find.descendant(of: fish, matching: find.byKey(const ValueKey('emoji-group-retry'))), findsOneWidget);
      expect(find.descendant(of: fish, matching: find.byType(Image)), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the group shown stays shown when the list refreshed adds a group before it', (tester) async {
      await tester.runAsync(
        () => saveOldList({
          '12': _tsdm,
          '4': (name: 'MIKU', dir: 'MIKU', emoji: [('131', '9.jpg')]),
        }),
      );
      forum.list = _list({
        '20': _fish,
        '12': _tsdm,
        '4': (name: 'MIKU', dir: 'MIKU', emoji: [('131', '9.jpg')]),
      });
      final gate = forum.listGate = Completer<void>();
      addTearDown(() => gate.isCompleted ? null : gate.complete());
      await tester.pumpWidget(panel());
      await settle(tester, () => find.byKey(const ValueKey('emoji-panel-group-12')).evaluate().isNotEmpty);
      await tester.tap(find.text('MIKU'));
      await settle(tester, () => find.byKey(const ValueKey('emoji-panel-group-4')).evaluate().isNotEmpty);
      await settle(tester, () => false, rounds: 30);
      expect(find.text('大肥鱼'), findsNothing, reason: 'the list on the device until the forum answers');
      // The forum's list arrives now.
      gate.complete();
      await settle(tester, () => find.text('大肥鱼').evaluate().isNotEmpty);
      await settle(tester, () => false, rounds: 30);
      expect(find.text('大肥鱼'), findsOneWidget);
      expect(find.byKey(const ValueKey('emoji-panel-group-4')), findsOneWidget, reason: 'still MIKU');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('5. the editor', () {
    testWidgets('an emoji of the new group with an old list on the device: the image once the list is fresh', (
      tester,
    ) async {
      await tester.runAsync(() => saveOldList({'12': _tsdm}));
      forum.missing.add('img02/smilies/');
      await tester.runAsync(
        () => tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: EmojiCacheImage(groupId: '20', id: '984', fetch: true, placeholder: Text('{:20_984:}')),
            ),
          ),
        ),
      );
      await settle(tester, () => find.byType(Image).evaluate().isNotEmpty);
      expect(find.byType(Image), findsOneWidget);
      expect(forum.listRequests, 1);
      expect(forum.imageRequests, ['${_forumHead}deepseek/d%20(1).gif']);
    });
  });
}
