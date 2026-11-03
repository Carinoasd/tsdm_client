import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
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
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The author dialog of a floor offers the threads and replies of the author, adding a friend and blocking:
///
/// 1. another author: four chips, in the dialog before the info section;
/// 2. the current account's own floor: threads and replies only, no friend and no block;
/// 3. the thread and reply chips open the member thread route with the uid (replies with `tab=reply`);
/// 4. a blocked author offers "unblock"; without a block list provided the block chip is left out and nothing throws.
///
/// Synthetic accounts and pages only: no network, no login, nothing is sent.
Translations get tr => LocaleSettings.instance.currentTranslations;

String _data(String name) => File('test/data/$name').readAsStringSync();

/// Author of the floor of the fixture.
const _author = 1115;

final Uint8List _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

/// Answers a PNG for every image request; nothing leaves the test.
final class _ImageAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromBytes(
    _png,
    200,
    headers: {
      Headers.contentTypeHeader: ['image/png'],
    },
  );

  @override
  void close({bool force = false}) {}
}

Future<void> _settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The floor of the fixture as a post with a plain body.
Post _post() {
  final doc = parseHtmlDocument(_data('locked_purchase_x5.html'));
  final original = doc.querySelector('div#post_77983102')!;
  final floor = original.clone(true) as uh.Element;
  original.parent!.append(floor);
  final post = Post.fromPostNode(floor, 1)!;
  return post.copyWith(data: '<p>floor body</p>', locked: const [], signature: null, pokemon: null, checkin: null);
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late UserBlockRepository blocks;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
    tmp = Directory.systemTemp.createTempSync('tsdm_author_card_');
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
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _ImageAdapter())),
      );
    await settings.init();
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    blocks = UserBlockRepository(storage);
  });

  tearDown(() async {
    await settingsBloc.close();
    await blocks.dispose();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  /// Opens the author dialog of the floor as the account [reader]; [withBlocks] provides the block list of it, with
  /// [blockedAuthor] on it.
  Future<List<Uri>> openDialog(
    WidgetTester tester, {
    required int reader,
    bool withBlocks = false,
    bool blockedAuthor = false,
  }) async {
    final opened = <Uri>[];
    final auth = AuthenticationRepository(
      user: UserLoginInfo(username: 'Reader', uid: reader),
    );
    final status = StreamController<AuthStatus>.broadcast(sync: true);
    final titles = CurrentTitleCubit(
      currentUid: () => reader,
      authStatus: status.stream,
      fetchTitles: () => TaskEither.right(const []),
    );
    status.add(AuthStatusAuthed(UserLoginInfo(username: 'Reader', uid: reader)));
    UserBlockCubit? blockCubit;
    if (withBlocks) {
      if (blockedAuthor) {
        await tester.runAsync(() => blocks.block(ownerUid: reader, uid: _author, username: 'Author'));
      }
      blockCubit = UserBlockCubit(
        repository: blocks,
        currentUid: () => reader,
        authStatus: status.stream,
        retryDelays: const [],
      );
    }
    addTearDown(() async {
      await blockCubit?.close();
      await titles.close();
      await status.close();
      await auth.dispose();
    });
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(body: SingleChildScrollView(child: PostCard(_post()))),
        ),
        GoRoute(
          name: ScreenPaths.memberThread,
          path: ScreenPaths.memberThread,
          builder: (_, state) {
            opened.add(state.uri);
            return const Scaffold(body: Text('member threads page'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      RepositoryProvider<AuthenticationRepository>.value(
        value: auth,
        child: MultiBlocProvider(
          providers: [
            BlocProvider<SettingsBloc>.value(value: settingsBloc),
            BlocProvider<CurrentTitleCubit>.value(value: titles),
            if (blockCubit != null) BlocProvider<UserBlockCubit>.value(value: blockCubit),
          ],
          child: TranslationProvider(child: MaterialApp.router(routerConfig: router)),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byType(HeroUserAvatar).first);
    await _settle(tester, rounds: 12);
    expect(find.text(tr.postCard.profileDialog.tabName.info), findsOneWidget, reason: 'the dialog is open');
    return opened;
  }

  Finder action(String key) => find.byKey(ValueKey('brief-profile-action-$key'));

  testWidgets('another author: threads, replies, friend and block, before the info section', (tester) async {
    await openDialog(tester, reader: 2000, withBlocks: true);
    for (final key in ['threads', 'replies', 'friend', 'block']) {
      expect(action(key), findsOneWidget, reason: key);
    }
    expect(find.text(tr.postCard.profileDialog.memberThreads), findsOneWidget);
    expect(find.text(tr.postCard.profileDialog.memberReplies), findsOneWidget);
    expect(find.text(tr.friendPage.addFriend.tooltip), findsOneWidget);
    expect(find.text(tr.postCard.profileDialog.blockShort), findsOneWidget);
    expect(
      tester.getTopLeft(action('threads')).dy,
      lessThan(tester.getTopLeft(find.text(tr.postCard.profileDialog.tabName.info)).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('own floor: threads and replies only', (tester) async {
    await openDialog(tester, reader: _author, withBlocks: true);
    expect(action('threads'), findsOneWidget);
    expect(action('replies'), findsOneWidget);
    expect(action('friend'), findsNothing);
    expect(action('block'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final (key, query) in [
    ('threads', {'uid': '$_author'}),
    ('replies', {'uid': '$_author', 'tab': 'reply'}),
  ]) {
    testWidgets('the $key chip opens the member threads route with the uid', (tester) async {
      final opened = await openDialog(tester, reader: 2000);
      await tester.tap(action(key));
      await _settle(tester);
      expect(opened, hasLength(1));
      expect(opened.single.path, ScreenPaths.memberThread);
      expect(opened.single.queryParameters, query);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a blocked author offers unblock and unblocking clears the list', (tester) async {
    await openDialog(tester, reader: 2000, withBlocks: true, blockedAuthor: true);
    expect(action('block'), findsOneWidget);
    expect(find.text(tr.userBlock.unblock), findsOneWidget);
    expect(find.text(tr.postCard.profileDialog.blockShort), findsNothing);
    await tester.tap(action('block'));
    await _settle(tester);
    expect((await tester.runAsync(() => blocks.load(2000)))!.isBlocked(_author), isFalse);
    expect(find.text(tr.postCard.profileDialog.blockShort), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a block list the block chip is left out and nothing throws', (tester) async {
    await openDialog(tester, reader: 2000);
    expect(action('threads'), findsOneWidget);
    expect(action('friend'), findsOneWidget);
    expect(action('block'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
