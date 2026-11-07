/// The reward price and the red packet go along when the kind of a new thread is switched, and with its local draft.
///
/// The editor of a new thread offers the kinds the forum allows (an ordinary thread, a reward, a red packet). Switching
/// hands the title and the post to the editor of the other kind ([ThreadModeTransfer]), now with the reward price and
/// the red packet set: carried through the other kinds, set again once the member is back on their kind, posted only
/// on the form of their kind ([PostForm.bodyWith]). The local draft keeps the kind and both settings
/// ([LocalDraft.threadKind], [LocalDraft.rewardPrice], [LocalDraft.hongbao]); a draft written as another kind is
/// restored in the editor of its kind.
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
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/editor/repository/recent_emoji_store.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/local_draft/utils/draft_autosaver.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/models/special_thread_form.dart';
import 'package:tsdm_client/features/post/utils/flood_control.dart';
import 'package:tsdm_client/features/post/view/post_edit_page.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
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
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 31);

/// The title field of the editor (the thread type field comes before it).
final Finder _titleField = find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == '標題',
);

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/post_v16_$name.json').readAsStringSync()) as Map<String, dynamic>;

/// The thread types of a forum offering them (`post_v16_newthread_types`).
Map<String, dynamic> _types() => _json('newthread_types')['types'] as Map<String, dynamic>;

/// The form of an ordinary new thread in a forum allowing rewards too, with thread types.
Map<String, dynamic> _ordinary() {
  final json = _json('newthread');
  json['special'] = {
    ...json['special'] as Map<String, dynamic>,
    'allowed': [0, 1, 3],
  };
  json['types'] = _types();
  return json;
}

/// The form of a new reward thread, with thread types.
Map<String, dynamic> _reward() => {..._json('newthread_reward'), 'types': _types()};

const _packet = HongbaoEdits(
  total: 100,
  shares: 5,
  split: HongbaoSplit.even,
  condReply: true,
  password: 'pw',
  appoint: 'Bob',
  expire: '24',
  blessing: '恭喜',
);

/// The fake forum: the new thread form of the kind asked for.
final class _Forum implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancel) async {
    requests.add(options);
    if (options.method != 'GET') {
      throw StateError('nothing is posted');
    }
    final query = options.uri.queryParameters;
    final json = query['special'] == '3' ? _reward() : _ordinary();
    return ResponseBody.fromString(
      jsonEncode(json),
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
  late AppDatabase db;
  late SettingsRepository settings;
  late LocalDraftStore drafts;
  late _Forum forum;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });

  setUp(() async {
    TsdmAppApi.reset();
    FloodControl.reset();
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    drafts = LocalDraftStore.memory();
    forum = _Forum();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<LocalDraftStore>(drafts)
      ..registerSingleton<RecentEmojiStore>(RecentEmojiStore.memory())
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
      );
    await settings.init();
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  group('kept', () {
    test('a red packet as a map and back', () {
      expect(HongbaoEdits.fromJson(_packet.toJson())?.toFields(), _packet.toFields());
      expect(HongbaoEdits.fromJson(jsonDecode(jsonEncode(_packet.toJson())))?.toFields(), _packet.toFields());
      expect(HongbaoEdits.fromJson(null), isNull);
      expect(HongbaoEdits.fromJson('100'), isNull);
      // What is not a count is not set.
      final broken = HongbaoEdits.fromJson({'total': -1, 'shares': '5', 'split': 'x'})!;
      expect(broken.total, isNull);
      expect(broken.shares, isNull);
      expect(broken.split, HongbaoSplit.lucky);
    });

    test('a local draft with its kind and settings, and one written before them', () {
      final key = LocalDraftKey.newThread('7');
      final draft = LocalDraft(
        key: key,
        body: '內文',
        subject: '標題',
        updatedAt: DateTime(2026, 11, 7),
        threadKind: 'reward',
        rewardPrice: 50,
        hongbao: _packet.toJson(),
      );
      final read = LocalDraft.fromJson(key, jsonDecode(jsonEncode(draft.toJson())))!;
      expect(read.threadKind, 'reward');
      expect(read.rewardPrice, 50);
      expect(HongbaoEdits.fromJson(read.hongbao)?.toFields(), _packet.toFields());
      expect(read.copyWith(maybeSent: true).rewardPrice, 50);
      expect(read.withKey(key.backupAt(1)).threadKind, 'reward');
      // The same title and post: the same draft, whatever the kind (an editor switched to another kind holds it).
      expect(read.sameContent(LocalDraft(key: key, body: '內文', subject: '標題', updatedAt: DateTime(2026))), isTrue);
      final old = LocalDraft.fromJson(key, {'body': '內文', 'updatedAt': 1})!;
      expect(old.threadKind, isNull);
      expect(old.rewardPrice, isNull);
      expect(old.hongbao, isNull);
      expect(old.toJson().keys, isNot(contains('threadKind')));
    });

    test('a change of the settings alone is written', () async {
      final key = LocalDraftKey.newThread('7');
      var price = 10;
      final saver = DraftAutosaver(
        read: () => (
          uid: 31,
          key: key,
          draft: LocalDraft(key: key, body: '內文', updatedAt: DateTime.now(), threadKind: 'reward', rewardPrice: price),
        ),
      )..attach();
      addTearDown(saver.dispose);
      saver.flush();
      await drafts.pendingWrites;
      expect((await drafts.load(31, key))?.rewardPrice, 10);
      price = 20;
      saver.flush();
      await drafts.pendingWrites;
      expect((await drafts.load(31, key))?.rewardPrice, 20);
    });
  });

  group('the editor', () {
    late SettingsBloc settingsBloc;
    setUp(() => settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository()));
    tearDown(() => settingsBloc.close());

    Future<GoRouter> pump(WidgetTester tester, {required String kind, ThreadModeTransfer? transfer}) async {
      final auth = AuthenticationRepository(user: _alice);
      addTearDown(auth.dispose);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('below the editor')),
          ),
          GoRoute(
            path: ScreenPaths.editPost,
            name: ScreenPaths.editPost,
            builder: (_, state) => PostEditPage(
              editType: PostEditType.newThread,
              fid: state.pathParameters['fid']!,
              tid: null,
              pid: null,
              threadKind: ThreadKind.fromQuery(state.uri.queryParameters['kind']),
              transfer: state.extra as ThreadModeTransfer?,
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: BlocProvider<SettingsBloc>.value(
              value: settingsBloc,
              child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
            ),
          ),
        ),
      );
      unawaited(
        router.pushNamed(
          ScreenPaths.editPost,
          pathParameters: {'editType': '${PostEditType.newThread.index}', 'fid': '7'},
          queryParameters: {'kind': ?ThreadKind.fromQuery(kind).query},
          extra: transfer,
        ),
      );
      await _settle(tester);
      return router;
    }

    PostEditPage page(WidgetTester tester) => tester.widget<PostEditPage>(find.byType(PostEditPage));

    testWidgets('switched in with a reward price and a red packet: the price shown, both kept in the draft', (
      tester,
    ) async {
      await pump(
        tester,
        kind: 'reward',
        transfer: const ThreadModeTransfer(
          uid: 31,
          fid: '7',
          subject: '帶過來的標題',
          body: '帶過來的內文',
          rewardPrice: 50,
          hongbao: _packet,
        ),
      );
      expect(page(tester).threadKind, ThreadKind.reward);
      expect(find.byIcon(Icons.emoji_events), findsOneWidget, reason: 'the reward button, set');
      expect(find.text('50'), findsOneWidget);
      await tester.enterText(_titleField, '改過的標題');
      await tester.pump(const Duration(seconds: 3));
      await _io(tester);
      final stored = await _wait(tester, drafts.load(31, LocalDraftKey.newThread('7')));
      expect(stored?.subject, '改過的標題');
      expect(stored?.threadKind, 'reward');
      expect(stored?.rewardPrice, 50);
      // Carried for when the member is on a red packet thread again.
      expect(HongbaoEdits.fromJson(stored?.hongbao)?.toFields(), _packet.toFields());
      await _unpump(tester);
    });

    testWidgets("switching the kind: the draft written last is the next editor's, not offered there", (tester) async {
      await pump(tester, kind: 'normal');
      await tester.enterText(_titleField, '切換前的標題');
      await tester.pump(const Duration(seconds: 3));
      await _io(tester);
      await tester.tap(find.byType(PopupMenuButton<ThreadKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('懸賞').last);
      await _settle(tester);
      await _io(tester);
      await tester.pumpAndSettle();
      expect(page(tester).threadKind, ThreadKind.reward);
      expect(find.text('切換前的標題'), findsWidgets);
      expect(find.byKey(const ValueKey('draft-offer-banner')), findsNothing);
      final stored = await _wait(tester, drafts.load(31, LocalDraftKey.newThread('7')));
      expect(stored?.subject, '切換前的標題');
      expect(stored?.threadKind, 'reward');
      await _unpump(tester);
    });

    testWidgets('a draft of an ordinary thread is written as one; one written before the kinds is restored in place', (
      tester,
    ) async {
      await pump(tester, kind: 'normal');
      await tester.enterText(_titleField, '普通帖標題');
      await tester.pump(const Duration(seconds: 3));
      await _io(tester);
      expect((await _wait(tester, drafts.load(31, LocalDraftKey.newThread('7'))))?.threadKind, 'normal');
      await _unpump(tester);

      drafts.save(
        31,
        LocalDraft(
          key: LocalDraftKey.newThread('7'),
          body: '舊草稿內文',
          subject: '舊草稿標題',
          updatedAt: DateTime(2026, 11, 2),
        ),
      );
      await _wait(tester, drafts.pendingWrites);
      await pump(tester, kind: 'reward');
      await tester.tap(find.byKey(const ValueKey('draft-offer-restore')));
      await _settle(tester);
      expect(page(tester).threadKind, ThreadKind.reward, reason: 'not switched to an ordinary thread');
      expect(find.text('舊草稿標題'), findsWidgets);
      await _unpump(tester);
    });

    testWidgets('a draft written as a reward thread is restored in the reward editor, with its price', (tester) async {
      drafts.save(
        31,
        LocalDraft(
          key: LocalDraftKey.newThread('7'),
          body: '懸賞草稿內文',
          subject: '懸賞草稿標題',
          updatedAt: DateTime(2026, 11, 7),
          threadKind: 'reward',
          rewardPrice: 60,
          typeId: '5',
          delta: jsonEncode([
            {'insert': '從文件來的內文\n'},
          ]),
        ),
      );
      await _wait(tester, drafts.pendingWrites);
      await pump(tester, kind: 'normal');
      expect(page(tester).threadKind, ThreadKind.normal);
      expect(find.byKey(const ValueKey('draft-offer-banner')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('draft-offer-restore')));
      await _settle(tester);
      await _io(tester);
      await tester.pumpAndSettle();
      expect(page(tester).threadKind, ThreadKind.reward);
      expect(find.text('懸賞草稿標題'), findsWidgets);
      expect(find.text('60'), findsOneWidget);
      // The draft is the reward editor's own now: not offered again, kept as written.
      expect(find.byKey(const ValueKey('draft-offer-banner')), findsNothing);
      final stored = await _wait(tester, drafts.list(31));
      expect(stored, hasLength(1));
      expect(stored.single.threadKind, 'reward');
      expect(stored.single.rewardPrice, 60);
      expect(forum.requests.where((r) => r.uri.queryParameters['special'] == '3'), isNotEmpty);
      // The thread type and the editor's own document came along.
      expect(find.text('其他'), findsWidgets);
      await _unpump(tester);
      final kept = await _wait(tester, drafts.load(31, LocalDraftKey.newThread('7')));
      expect(kept?.body, '從文件來的內文');
      expect(kept?.typeId, '5');
    });
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

/// Let the queued work of the store (in memory, on microtasks) and the frames it causes finish.
Future<void> _io(WidgetTester tester) async {
  await _wait(tester, getIt.get<LocalDraftStore>().pendingWrites);
  await tester.pump();
}

/// [future], once the frames let it complete.
Future<T> _wait<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  late T value;
  unawaited(
    future.then((v) {
      value = v;
      done = true;
    }),
  );
  for (var i = 0; i < 50 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done, isTrue, reason: 'the store answered');
  return value;
}

Future<void> _unpump(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _io(tester);
  await tester.pump(const Duration(seconds: 3));
}
