import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart' show AuthStatus, AuthStatusAuthed;
import 'package:tsdm_client/features/blocking/cubit/keyword_block_cubit.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/keyword_block_repository.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/block_filter.dart';
import 'package:tsdm_client/features/blocking/utils/notice_block_filter.dart';
import 'package:tsdm_client/features/blocking/view/user_block_page.dart';
import 'package:tsdm_client/features/blocking/widgets/block_aware_post.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
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
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';

/// Local keyword block (#268): a per account keyword list hiding thread titles, floors and notices; content of the
/// account itself is never hidden.
const _aliceUid = 1000;
const _bobUid = 2000;
const _carolUid = 3000;
const _alice = UserLoginInfo(username: 'Alice', uid: _aliceUid);

Translations get tr => LocaleSettings.instance.currentTranslations;

/// Settings rows kept in memory.
final class _MemorySettings extends Fake implements StorageProvider {
  final rows = <String, List<String>>{};

  @override
  Future<List<String>?> getStringList(String key) async => rows[key];

  @override
  Future<void> saveStringList(String key, List<String> value) async {
    rows[key] = List.of(value);
  }

  @override
  Future<void> deleteKey(String key) async {
    rows.remove(key);
  }
}

final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  @override
  int? get effectiveCurrentUid => currentUser?.uid;

  void switchTo(UserLoginInfo user) {
    currentUser = user;
    _controller.add(AuthStatusAuthed(user));
  }

  Future<void> close() => _controller.close();
}

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

Post _post({
  required String pid,
  required int floor,
  required int uid,
  required String data,
  String? signature,
}) => Post(
  postID: pid,
  postFloor: floor,
  author: User(name: 'U$uid', uid: '$uid', url: 'home.php?mod=space&uid=$uid'),
  publishTime: null,
  data: data,
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: 1,
  isDraft: false,
  packetAllTaken: false,
  signature: signature,
);

String _replyNotice(String title, {int author = _bobUid}) =>
    '<a href="home.php?mod=space&uid=$author">U$author</a> 回复了您的帖子 '
    '<a href="forum.php?mod=redirect&goto=findpost&ptid=10&pid=20" target="_blank">$title</a> &nbsp; '
    '<a href="forum.php?mod=redirect&goto=findpost&pid=20&ptid=10" target="_blank" class="lit">查看</a>';

NoticeV2 _notice(int id, String data) =>
    NoticeV2(id: id, timestamp: id, data: data, ignoreType: 'post', authorId: _bobUid);

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('repository', () {
    late _MemorySettings settings;
    late KeywordBlockRepository repo;

    setUp(() {
      settings = _MemorySettings();
      repo = KeywordBlockRepository(settings);
    });

    tearDown(() => repo.dispose());

    test('saves a trimmed keyword per account, latest first, posts on by default', () async {
      final at = DateTime(2026, 11, 3, 10);
      expect(await repo.add(ownerUid: _aliceUid, keyword: '  剧透 ', now: at), KeywordBlockResult.ok);
      expect(await repo.add(ownerUid: _aliceUid, keyword: 'Spoiler'), KeywordBlockResult.ok);
      final list = await repo.load(_aliceUid);
      expect(list.keywords.map((e) => e.keyword), ['Spoiler', '剧透']);
      expect(list.keywords.every((e) => e.appliesToPosts), isTrue);
      expect(list.keywords.last.createdAt, at);
      expect(settings.rows.keys, [KeywordBlockRepository.keyOf(_aliceUid)]);
      // Another account has its own, empty list.
      expect((await repo.load(_bobUid)).keywords, isEmpty);
      // A new repository (another isolate, a restart) reads the same row.
      final again = await KeywordBlockRepository(settings).load(_aliceUid);
      expect(again.keywords.map((e) => e.keyword), ['Spoiler', '剧透']);
    });

    test('compares ignoring case: duplicates, removal and matching', () async {
      await repo.add(ownerUid: _aliceUid, keyword: 'Spoiler');
      expect(await repo.add(ownerUid: _aliceUid, keyword: 'SPOILER'), KeywordBlockResult.duplicate);
      final list = await repo.load(_aliceUid);
      expect(list.hidesTitle('a spOILer inside'), isTrue);
      expect(list.hidesTitle('nothing'), isFalse);
      expect(await repo.remove(ownerUid: _aliceUid, keyword: 'spoiler'), KeywordBlockResult.ok);
      expect((await repo.load(_aliceUid)).keywords, isEmpty);
      expect(settings.rows, isEmpty);
      expect(await repo.remove(ownerUid: _aliceUid, keyword: 'spoiler'), KeywordBlockResult.notFound);
    });

    test('limits: empty, 50 characters, 200 keywords, invalid owner', () async {
      expect(await repo.add(ownerUid: _aliceUid, keyword: '   '), KeywordBlockResult.empty);
      expect(await repo.add(ownerUid: _aliceUid, keyword: '字' * 51), KeywordBlockResult.tooLong);
      expect(await repo.add(ownerUid: _aliceUid, keyword: '字' * 50), KeywordBlockResult.ok);
      expect(await repo.add(ownerUid: null, keyword: 'x'), KeywordBlockResult.invalid);
      expect(await repo.add(ownerUid: 0, keyword: 'x'), KeywordBlockResult.invalid);
      for (var i = 1; i < KeywordBlockRepository.maxCount; i++) {
        expect(await repo.add(ownerUid: _aliceUid, keyword: 'k$i'), KeywordBlockResult.ok);
      }
      expect((await repo.load(_aliceUid)).keywords, hasLength(200));
      expect(await repo.add(ownerUid: _aliceUid, keyword: 'one more'), KeywordBlockResult.limitReached);
      expect((await repo.load(_aliceUid)).keywords, hasLength(200));
    });

    test('switch of floors, kept unreadable entries', () async {
      settings.rows[KeywordBlockRepository.keyOf(_aliceUid)] = ['not json', '{"k":"old","p":false,"at":1}'];
      final loaded = await repo.load(_aliceUid);
      expect(loaded.keywords.single.appliesToPosts, isFalse);
      expect(loaded.postKeys, isEmpty);
      expect(loaded.titleKeys, ['old']);
      await repo.add(ownerUid: _aliceUid, keyword: 'New');
      expect(
        await repo.setAppliesToPosts(ownerUid: _aliceUid, keyword: 'new', value: false),
        KeywordBlockResult.ok,
      );
      final list = await repo.load(_aliceUid);
      expect(list.keywords.map((e) => (e.keyword, e.appliesToPosts)), [('New', false), ('old', false)]);
      expect(settings.rows[KeywordBlockRepository.keyOf(_aliceUid)], contains('not json'));
    });

    test('a failed read is an error, not an empty list', () async {
      final broken = KeywordBlockRepository(_BrokenSettings());
      addTearDown(broken.dispose);
      await expectLater(broken.load(_aliceUid), throwsA(isA<KeywordBlockStorageException>()));
      expect((await noticeKeywordListOf(_BrokenSettings(), _aliceUid)).titleKeys, isEmpty);
    });
  });

  group('cubit', () {
    test('follows the account and keeps the list in memory', () async {
      final settings = _MemorySettings();
      final repo = KeywordBlockRepository(settings);
      await repo.add(ownerUid: _aliceUid, keyword: 'alice');
      await repo.add(ownerUid: _bobUid, keyword: 'bob');
      final auth = _Auth(_alice);
      var changes = 0;
      final cubit = KeywordBlockCubit(
        repository: repo,
        currentUid: () => auth.effectiveCurrentUid,
        authStatus: auth.status,
        onListChanged: () => changes++,
      );
      addTearDown(() async {
        await cubit.close();
        await repo.dispose();
        await auth.close();
      });
      await pumpEventQueue();
      expect(cubit.state.titleKeys, ['alice']);
      expect(changes, 1);
      auth.switchTo(const UserLoginInfo(username: 'Bob', uid: _bobUid));
      await pumpEventQueue();
      expect(cubit.state.titleKeys, ['bob']);
      expect(await cubit.add('alice', expectedOwner: _aliceUid), KeywordBlockResult.accountChanged);
      expect(await cubit.add('More', expectedOwner: _bobUid), KeywordBlockResult.ok);
      await pumpEventQueue();
      expect(cubit.state.titleKeys, ['more', 'bob']);
      expect(changes, 3);
    });
  });

  group('thread titles', () {
    late _MemorySettings settings;
    late KeywordBlockRepository repo;
    late KeywordBlockCubit cubit;

    setUp(() async {
      settings = _MemorySettings();
      repo = KeywordBlockRepository(settings);
      await repo.add(ownerUid: _aliceUid, keyword: 'Spoiler');
      cubit = KeywordBlockCubit(
        repository: repo,
        currentUid: () => _aliceUid,
        authStatus: const Stream<AuthStatus>.empty(),
      );
      await pumpEventQueue();
    });

    tearDown(() async {
      await cubit.close();
      await repo.dispose();
    });

    testWidgets('a title with a keyword is hidden, a thread of the account itself is not', (tester) async {
      Widget probe(String title, String uid) => Builder(
        builder: (context) => Text(isTitleHiddenByKeyword(context, title, authorUid: uid) ? 'hidden' : title),
      );
      await tester.pumpWidget(
        BlocProvider.value(
          value: cubit,
          child: MaterialApp(
            home: Column(
              children: [
                probe('Big SPOILER here', '$_bobUid'),
                probe('my spoiler thread', '$_aliceUid'),
                probe('plain title', '$_bobUid'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('hidden'), findsOneWidget);
      expect(find.text('my spoiler thread'), findsOneWidget);
      expect(find.text('plain title'), findsOneWidget);

      // Removing the keyword shows the thread at once.
      await tester.runAsync(() => cubit.remove('spoiler', expectedOwner: _aliceUid));
      await tester.pumpAndSettle();
      expect(find.text('hidden'), findsNothing);
      expect(find.text('Big SPOILER here'), findsOneWidget);
    });

    testWidgets('without a cubit nothing is hidden', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Text(isTitleHiddenByKeyword(context, 'Spoiler', authorUid: '1') ? 'hidden' : 'x'),
          ),
        ),
      );
      expect(find.text('x'), findsOneWidget);
    });

    group('real thread card', () {
      late AppDatabase db;
      late StorageProvider storage;
      late SettingsRepository settingsRepo;
      late Directory tmp;

      NormalThread thread(String tid, String title, int uid) => NormalThread(
        title: title,
        url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
        threadID: tid,
        author: User(name: 'U$uid', url: '$baseUrl/home.php?mod=space&uid=$uid', uid: '$uid'),
        publishDate: DateTime(2026, 9),
        latestReplyAuthor: User(name: 'U$uid', url: '$baseUrl/home.php?mod=space&username=U$uid'),
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
        tmp = Directory.systemTemp.createTempSync('tsdm_keyword_block_');
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
        settingsRepo = SettingsRepository(storage);
        getIt
          ..registerSingleton<StorageProvider>(storage)
          ..registerSingleton<SettingsRepository>(settingsRepo)
          ..registerSingleton<NetErrorSaver>(NetErrorSaver())
          ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
          ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
          ..registerSingleton<ImageCacheProvider>(
            ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
          );
        await settingsRepo.init();
      });

      tearDown(() async {
        await getIt.get<ImageCacheProvider>().dispose();
        await getIt.reset();
        await settingsRepo.dispose();
        await db.close();
      });

      testWidgets('the forum list leaves out the row, keeps the others', (tester) async {
        await tester.runAsync(() async {
          await tester.pumpWidget(
            TranslationProvider(
              child: MultiBlocProvider(
                providers: [
                  BlocProvider<SettingsBloc>(
                    create: (_) =>
                        SettingsBloc(settingsRepository: settingsRepo, fragmentsRepository: FragmentsRepository()),
                  ),
                  BlocProvider.value(value: cubit),
                ],
                child: MaterialApp(
                  home: Scaffold(
                    body: ListView(
                      children: [
                        NormalThreadCard(thread('1', '新番 spoiler 讨论', _bobUid), disableTap: true),
                        NormalThreadCard(thread('2', '普通主题', _bobUid), disableTap: true),
                        NormalThreadCard(thread('3', '我的 Spoiler 帖', _aliceUid), disableTap: true),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
        expect(find.textContaining('新番', findRichText: true), findsNothing);
        expect(find.textContaining('普通主题', findRichText: true), findsOneWidget);
        expect(find.textContaining('我的 Spoiler 帖', findRichText: true), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      });
    });
  });

  group('floors', () {
    late _MemorySettings settings;
    late KeywordBlockRepository repo;
    late KeywordBlockCubit cubit;
    late UserBlockRepository users;
    late UserBlockCubit userCubit;

    setUp(() async {
      settings = _MemorySettings();
      repo = KeywordBlockRepository(settings);
      users = UserBlockRepository(settings);
      await repo.add(ownerUid: _aliceUid, keyword: 'Spoiler');
      await repo.add(ownerUid: _aliceUid, keyword: '只标题');
      await repo.setAppliesToPosts(ownerUid: _aliceUid, keyword: '只标题', value: false);
      cubit = KeywordBlockCubit(
        repository: repo,
        currentUid: () => _aliceUid,
        authStatus: const Stream<AuthStatus>.empty(),
      );
      userCubit = UserBlockCubit(
        repository: users,
        currentUid: () => _aliceUid,
        authStatus: const Stream<AuthStatus>.empty(),
      );
      await pumpEventQueue();
    });

    tearDown(() async {
      await cubit.close();
      await userCubit.close();
      await repo.dispose();
      await users.dispose();
    });

    Future<void> pumpPosts(WidgetTester tester, List<Post> posts) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiBlocProvider(
            providers: [
              BlocProvider.value(value: cubit),
              BlocProvider.value(value: userCubit),
            ],
            child: MaterialApp(
              home: Scaffold(
                body: ListView(
                  children: [
                    for (final p in posts)
                      BlockAwarePost(
                        post: p,
                        postList: posts,
                        builder: (_, p) => Text('BODY ${p.postID}'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('body, signature and first floor: only the content is replaced', (tester) async {
      final posts = [
        // The first floor of the thread: hidden in place, the replies stay readable.
        _post(pid: '1', floor: 1, uid: _bobUid, data: '<p>Big <b>SPOI</b>LER</p>'),
        _post(pid: '2', floor: 2, uid: _bobUid, data: 'fine', signature: '<i>spoiler</i> sig'),
        _post(pid: '3', floor: 3, uid: _bobUid, data: 'a normal reply'),
        // The account's own floor is never hidden.
        _post(pid: '4', floor: 4, uid: _aliceUid, data: 'my spoiler'),
        // A keyword limited to titles does not touch floors.
        _post(pid: '5', floor: 5, uid: _carolUid, data: '只标题 in a floor'),
        // Tags never match: only the text counts.
        _post(pid: '6', floor: 6, uid: _carolUid, data: '<span class="spoiler">ok</span>'),
      ];
      await pumpPosts(tester, posts);
      final placeholder = tr.userBlock.keyword.postPlaceholder;
      expect(placeholder, '已隐藏：含屏蔽关键字的内容');
      expect(find.text(placeholder), findsNWidgets(2));
      expect(find.text('BODY 1'), findsNothing);
      expect(find.text('BODY 2'), findsNothing);
      for (final pid in ['3', '4', '5', '6']) {
        expect(find.text('BODY $pid'), findsOneWidget, reason: 'floor $pid');
      }
      // The floor numbers stay; the placeholder has no "show anyway" action, like the one of blocked users.
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('#2'), findsOneWidget);
      expect(find.byType(KeywordBlockedPostPlaceholder), findsNWidgets(2));
      expect(
        find.descendant(of: find.byType(KeywordBlockedPostPlaceholder), matching: find.byType(TextButton)),
        findsNothing,
      );
    });

    testWidgets('turning floors off brings the floor back', (tester) async {
      final posts = [_post(pid: '7', floor: 2, uid: _bobUid, data: 'SPOILER')];
      await pumpPosts(tester, posts);
      expect(find.text('BODY 7'), findsNothing);
      await tester.runAsync(() => cubit.setAppliesToPosts('spoiler', value: false, expectedOwner: _aliceUid));
      await tester.pumpAndSettle();
      expect(find.text('BODY 7'), findsOneWidget);
    });

    test('plain text is computed once per post', () async {
      final list = await repo.load(_aliceUid);
      final post = _post(pid: '8', floor: 3, uid: _bobUid, data: '<p>spoiler</p>');
      expect(keywordHidesPost(post, list), isTrue);
      expect(keywordHidesPost(post, list), isTrue);
      expect(keywordHidesPost(post.copyWith(data: 'safe'), list), isFalse);
      expect(htmlPlainText('a<b>b</b>&amp;c'), 'ab&c');
    });
  });

  group('notices', () {
    final keywords = KeywordBlockList(
      ownerUid: _aliceUid,
      keywords: [BlockedKeyword(keyword: 'Spoiler', createdAt: DateTime(2026))],
    );

    test('a notice whose thread title has a keyword is hidden', () {
      expect(isKeywordBlockedNotice(_replyNotice('新番 SPOILER 讨论'), _bobUid, keywords), isTrue);
      expect(isKeywordBlockedNotice(_replyNotice('普通主题'), _bobUid, keywords), isFalse);
      // Only the title counts, not the rest of the text.
      expect(isKeywordBlockedNotice('Spoiler 回复了您的帖子', _bobUid, keywords), isFalse);
      // Triggered by the account itself: never hidden.
      expect(isKeywordBlockedNotice(_replyNotice('Spoiler'), _aliceUid, keywords), isFalse);
      // Unattributed notices are matched as well.
      expect(isKeywordBlockedNotice(_replyNotice('Spoiler'), null, keywords), isTrue);
    });

    test('news and the unread badge leave them out', () async {
      final notification = NotificationV2(
        status: 0,
        noticeList: [_notice(1, _replyNotice('Spoiler 1')), _notice(2, _replyNotice('other'))],
        personalMessageList: const [],
        broadcastMessageList: const [],
      );
      final news = withoutBlockedNotices(notification, const UserBlockList.empty(_aliceUid), keywords: keywords);
      expect(news.noticeList.map((e) => e.id), [2]);

      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final storage = StorageProvider(db, {}, {});
      await storage
          .saveNotification(
            uid: _aliceUid,
            notificationGroup: NotificationGroup(
              noticeList: [
                for (final (nid, title) in [(1, 'Spoiler 1'), (2, 'other'), (3, 'more spoiler')])
                  NoticeEntity(
                    uid: _aliceUid,
                    nid: nid,
                    timestamp: nid,
                    data: _replyNotice(title),
                    alreadyRead: false,
                    authorId: _bobUid,
                  ),
              ],
              personalMessageList: const [],
              broadcastMessageList: const [],
            ),
          )
          .run();
      expect((await countUnreadNotification(storage: storage, uid: _aliceUid)).notice, 3);
      expect(await countUnreadNotificationTotal(storage: storage, uid: _aliceUid), 3);
      final repo = KeywordBlockRepository(storage);
      addTearDown(repo.dispose);
      await repo.add(ownerUid: _aliceUid, keyword: 'spoiler');
      expect((await countUnreadNotification(storage: storage, uid: _aliceUid)).notice, 1);
      expect(await countUnreadNotificationTotal(storage: storage, uid: _aliceUid), 1);
    });
  });

  group('manager page', () {
    late _MemorySettings settings;
    late KeywordBlockRepository repo;
    late UserBlockRepository users;
    late _Auth auth;

    setUp(() {
      settings = _MemorySettings();
      repo = KeywordBlockRepository(settings);
      users = UserBlockRepository(settings);
      auth = _Auth(_alice);
    });

    tearDown(() async {
      await repo.dispose();
      await users.dispose();
      await auth.close();
    });

    Future<KeywordBlockCubit> pumpPage(WidgetTester tester) async {
      final cubit = KeywordBlockCubit(repository: repo, currentUid: () => _aliceUid, authStatus: auth.status);
      final userCubit = UserBlockCubit(repository: users, currentUid: () => _aliceUid, authStatus: auth.status);
      addTearDown(() async {
        await cubit.close();
        await userCubit.close();
      });
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MultiBlocProvider(
              providers: [
                BlocProvider.value(value: cubit),
                BlocProvider.value(value: userCubit),
              ],
              child: MaterialApp(scaffoldMessengerKey: snackbarKey, home: const UserBlockPage()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return cubit;
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(pumpEventQueue);
      await tester.pumpAndSettle();
    }

    testWidgets('add, switch and remove keywords', (tester) async {
      await pumpPage(tester);
      final ktr = tr.userBlock.keyword;
      expect(find.text(ktr.title), findsOneWidget);
      expect(find.text(ktr.empty), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('keyword-input')), '  Spoiler ');
      await tester.tap(find.byKey(const ValueKey('keyword-add')));
      await settle(tester);
      expect(find.text('Spoiler'), findsOneWidget);
      expect(find.text(ktr.empty), findsNothing);
      expect(find.text(ktr.appliesToPosts), findsOneWidget);
      expect((await tester.runAsync(() => repo.load(_aliceUid)))!.keywords.single.keyword, 'Spoiler');

      // The same keyword in another case is refused.
      await tester.enterText(find.byKey(const ValueKey('keyword-input')), 'SPOILER');
      await tester.tap(find.byKey(const ValueKey('keyword-add')));
      await settle(tester);
      expect(find.text(ktr.duplicate), findsOneWidget);
      expect((await tester.runAsync(() => repo.load(_aliceUid)))!.keywords, hasLength(1));

      // The switch: floors on by default, turned off and saved.
      final row = find.byKey(const ValueKey('keyword-spoiler'));
      final toggle = find.descendant(of: row, matching: find.byType(Switch));
      expect(tester.widget<Switch>(toggle).value, isTrue);
      await tester.tap(toggle);
      await settle(tester);
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect((await tester.runAsync(() => repo.load(_aliceUid)))!.keywords.single.appliesToPosts, isFalse);

      // Remove.
      await tester.tap(find.descendant(of: row, matching: find.byIcon(Icons.delete_outline)));
      await settle(tester);
      expect(find.byKey(const ValueKey('keyword-spoiler')), findsNothing);
      expect(find.text(ktr.empty), findsOneWidget);
      expect(settings.rows.containsKey(KeywordBlockRepository.keyOf(_aliceUid)), isFalse);
    });

    testWidgets('narrow width keeps the row readable', (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() => repo.add(ownerUid: _aliceUid, keyword: '一个比较长的屏蔽关键字示例'));
      await pumpPage(tester);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('一个比较长的屏蔽关键字示例'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);
    });
  });
}

final class _BrokenSettings extends Fake implements StorageProvider {
  @override
  Future<List<String>?> getStringList(String key) async => throw StateError('database is busy');
}
