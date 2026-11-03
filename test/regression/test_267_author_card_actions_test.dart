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
import 'package:tsdm_client/features/blocking/widgets/block_aware_post.dart';
import 'package:tsdm_client/features/member_thread/utils/member_thread_url.dart';
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
/// 2. the current account's own floor: "my threads" and "my replies" only, no friend and no block, and they open
///    the "my threads" page (the redirect of the member thread route);
/// 3. the thread and reply chips open the member thread route with the uid (replies with `tab=reply`), by the name
///    when the floor carries no uid;
/// 4. a blocked author offers "unblock"; without a block list provided the block chip is left out and nothing throws;
/// 5. blocking asks first, then the chip turns into "unblock" and the list of the account has the author; a floor
///    behind [BlockAwarePost] turns into the placeholder under the open dialog, and closing the dialog throws nothing;
/// 6. on a 360 wide phone (content 204 wide, Traditional Chinese, 1.0 scale) the chips take two rows at most;
/// 7. without any account in use the lists stay and friend and block are left out; a floor with neither uid nor name
///    gets no action row at all; a floor with the own name but no uid is the own floor too.
///
/// Synthetic accounts and pages only: no network, no login, nothing is sent.
Translations get tr => LocaleSettings.instance.currentTranslations;

String _data(String name) => File('test/data/$name').readAsStringSync();

/// Author of the floor of the fixture.
const _author = 1115;

/// Name of the author of the floor of the fixture.
final String _authorName = _post().userBriefProfile!.username;

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

  /// Opens the author dialog of the floor as the account [reader] (null: no verified session); [withBlocks] provides
  /// the block list of it, with [blockedAuthor] on it. [blockAware] puts the floor behind [BlockAwarePost] like the
  /// thread page does, [post] replaces the floor of the fixture, [window] sizes the window (1.0 scale).
  Future<List<Uri>> openDialog(
    WidgetTester tester, {
    required int? reader,
    bool withBlocks = false,
    bool blockedAuthor = false,
    bool blockAware = false,
    Post? post,
    Size? window,
  }) async {
    if (window != null) {
      tester.view
        ..physicalSize = window
        ..devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    }
    final floor = post ?? _post();
    final opened = <Uri>[];
    final auth = AuthenticationRepository(
      user: reader == null ? null : UserLoginInfo(username: 'Reader', uid: reader),
    );
    final status = StreamController<AuthStatus>.broadcast(sync: true);
    final titles = CurrentTitleCubit(
      currentUid: () => reader,
      authStatus: status.stream,
      fetchTitles: () => TaskEither.right(const []),
    );
    status.add(
      reader == null ? const AuthStatusNotAuthed() : AuthStatusAuthed(UserLoginInfo(username: 'Reader', uid: reader)),
    );
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
          builder: (_, _) => Scaffold(
            body: SingleChildScrollView(
              child: blockAware
                  ? BlockAwarePost(post: floor, postList: [floor], builder: (_, p) => PostCard(p))
                  : PostCard(floor),
            ),
          ),
        ),
        GoRoute(
          name: ScreenPaths.memberThread,
          path: ScreenPaths.memberThread,
          // Like the app: the own list is the "my threads" page.
          redirect: (_, state) => memberThreadRedirect(
            state.uri.queryParameters,
            currentUid: auth.effectiveCurrentUid,
            currentUsername: auth.effectiveCurrentUser?.username,
          ),
          builder: (_, state) {
            opened.add(state.uri);
            return const Scaffold(body: Text('member threads page'));
          },
        ),
        GoRoute(
          name: ScreenPaths.myThread,
          path: ScreenPaths.myThread,
          builder: (_, state) {
            opened.add(state.uri);
            return const Scaffold(body: Text('my threads page'));
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

  /// Rows the action chips take: distinct top edges.
  int actionRows(WidgetTester tester) => ['threads', 'replies', 'friend', 'block']
      .where((key) => action(key).evaluate().isNotEmpty)
      .map((key) => tester.getTopLeft(action(key)).dy.round())
      .toSet()
      .length;

  /// Confirms the block question of the author.
  Future<void> confirmBlock(WidgetTester tester) async {
    expect(find.text(tr.userBlock.blockConfirmTitle(name: _authorName)), findsOneWidget, reason: 'asked first');
    await tester.tap(find.text(tr.general.ok));
    await _settle(tester);
  }

  testWidgets('another author: threads, replies, friend and block, before the info section', (tester) async {
    await openDialog(tester, reader: 2000, withBlocks: true);
    for (final key in ['threads', 'replies', 'friend', 'block']) {
      expect(action(key), findsOneWidget, reason: key);
    }
    expect(find.text(tr.postCard.profileDialog.memberThreads), findsOneWidget);
    expect(find.text(tr.postCard.profileDialog.memberReplies), findsOneWidget);
    expect(find.text(tr.postCard.profileDialog.myThreads), findsNothing);
    // Friend and block are icons with a tooltip, no text.
    expect(find.byTooltip(tr.friendPage.addFriend.tooltip), findsOneWidget);
    expect(find.byTooltip(tr.userBlock.block), findsOneWidget);
    expect(find.text(tr.friendPage.addFriend.tooltip), findsNothing);
    expect(find.text(tr.userBlock.block), findsNothing);
    expect(
      tester.getTopLeft(action('threads')).dy,
      lessThan(tester.getTopLeft(find.text(tr.postCard.profileDialog.tabName.info)).dy),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('own floor: my threads and my replies only, opening the my threads page', (tester) async {
    final opened = await openDialog(tester, reader: _author, withBlocks: true);
    expect(action('threads'), findsOneWidget);
    expect(action('replies'), findsOneWidget);
    expect(action('friend'), findsNothing);
    expect(action('block'), findsNothing);
    expect(find.text(tr.postCard.profileDialog.myThreads), findsOneWidget);
    expect(find.text(tr.postCard.profileDialog.myReplies), findsOneWidget);
    expect(find.text(tr.postCard.profileDialog.memberThreads), findsNothing);
    expect(find.text(tr.postCard.profileDialog.memberReplies), findsNothing);
    await tester.tap(action('replies'));
    await _settle(tester);
    // Redirected: the member thread route itself was never built.
    expect(opened, hasLength(1));
    expect(opened.single.path, ScreenPaths.myThread);
    expect(opened.single.queryParameters, {'tab': 'reply'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('own floor known only from the stored session: still the own floor', (tester) async {
    // The stored session is not verified yet (an offline start, a thread opened from a link): currentUser is null
    // but the global cookie names the account. The own floor must not offer "add friend".
    getIt
      ..unregister<CookieProvider>()
      ..registerSingleton<CookieProvider>(CookieProvider(const UserLoginInfo(username: 'Reader', uid: _author), {}));
    await openDialog(tester, reader: null, withBlocks: true);
    expect(action('threads'), findsOneWidget);
    expect(find.text(tr.postCard.profileDialog.myThreads), findsOneWidget);
    expect(action('friend'), findsNothing);
    expect(action('block'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a uid, the own name is the own floor: my threads, no friend and no block', (tester) async {
    final post = _post();
    final opened = await openDialog(
      tester,
      reader: 2000,
      withBlocks: true,
      // The account is "Reader"; the forum ignores the case when it looks a name up.
      post: post.copyWith(
        userBriefProfile: post.userBriefProfile!.copyWith(uid: '', username: 'reader'),
      ),
    );
    expect(find.text(tr.postCard.profileDialog.myThreads), findsOneWidget);
    expect(find.text(tr.postCard.profileDialog.memberThreads), findsNothing);
    expect(action('friend'), findsNothing);
    expect(action('block'), findsNothing);
    await tester.tap(action('threads'));
    await _settle(tester);
    expect(opened.single.path, ScreenPaths.myThread);
    expect(tester.takeException(), isNull);
  });

  testWidgets('360x640, Traditional Chinese: the two list chips keep their own width on the first row', (tester) async {
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhTw));
    addTearDown(() => LocaleSettings.setLocale(AppLocale.en));
    await openDialog(tester, reader: 2000, withBlocks: true, window: const Size(360, 640));
    final threads = tester.getSize(action('threads'));
    final replies = tester.getSize(action('replies'));
    final row = tester.getSize(find.ancestor(of: action('threads'), matching: find.byType(Row)).first);
    // Not stretched to half the row each: the label decides the width.
    expect(threads.width + replies.width + 8, lessThan(row.width), reason: 'room is left over');
    expect(tester.getTopLeft(action('threads')).dy, tester.getTopLeft(action('replies')).dy, reason: 'one row');
    expect(tester.takeException(), isNull);
  });

  testWidgets('without a uid the chips open the lists by the name', (tester) async {
    final post = _post();
    final opened = await openDialog(
      tester,
      reader: 2000,
      withBlocks: true,
      post: post.copyWith(userBriefProfile: post.userBriefProfile!.copyWith(uid: '')),
    );
    expect(action('threads'), findsOneWidget);
    expect(action('replies'), findsOneWidget);
    expect(action('friend'), findsNothing, reason: 'needs a uid');
    expect(action('block'), findsNothing, reason: 'needs a uid');
    await tester.tap(action('threads'));
    await _settle(tester);
    expect(opened, hasLength(1));
    expect(opened.single.path, ScreenPaths.memberThread);
    expect(opened.single.queryParameters, {'username': _authorName});
    expect(tester.takeException(), isNull);
  });

  testWidgets('360x640, Traditional Chinese, 1.0 scale: the four chips take two rows at most', (tester) async {
    // Switching the locale uses real timers: outside the fake async zone.
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhTw));
    addTearDown(() => LocaleSettings.setLocale(AppLocale.en));
    await openDialog(tester, reader: 2000, withBlocks: true, window: const Size(360, 640));
    for (final key in ['threads', 'replies', 'friend', 'block']) {
      expect(action(key), findsOneWidget, reason: key);
    }
    expect(actionRows(tester), lessThanOrEqualTo(2));
    expect(tester.takeException(), isNull, reason: 'no overflow');
  });

  testWidgets('blocking asks first; then the chip is "unblock" and the list has the author', (tester) async {
    await openDialog(tester, reader: 2000, withBlocks: true);
    expect(find.byTooltip(tr.userBlock.block), findsOneWidget);
    await tester.tap(action('block'));
    await _settle(tester);
    await confirmBlock(tester);
    expect(find.byTooltip(tr.userBlock.unblock), findsOneWidget);
    expect(find.byTooltip(tr.userBlock.block), findsNothing);
    expect((await tester.runAsync(() => blocks.load(2000)))!.isBlocked(_author), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('blocking a floor behind BlockAwarePost: placeholder under the dialog, closing throws nothing', (
    tester,
  ) async {
    await openDialog(tester, reader: 2000, withBlocks: true, blockAware: true);
    expect(find.byType(BlockedPostPlaceholder), findsNothing);
    await tester.tap(action('block'));
    await _settle(tester);
    await confirmBlock(tester);
    // The floor under the dialog is the placeholder now; the dialog stays open and says "unblock".
    expect(find.byType(BlockedPostPlaceholder), findsOneWidget);
    expect(find.text(tr.postCard.profileDialog.tabName.info), findsOneWidget, reason: 'the dialog is still open');
    expect(find.byTooltip(tr.userBlock.unblock), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Close it: the hero of the avatar has nowhere to fly back to.
    Navigator.of(tester.element(find.text(tr.postCard.profileDialog.tabName.info))).pop();
    await _settle(tester, rounds: 12);
    expect(find.text(tr.postCard.profileDialog.tabName.info), findsNothing);
    expect(find.byType(BlockedPostPlaceholder), findsOneWidget);
    expect(find.byType(PostCard), findsNothing);
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
    expect(find.byTooltip(tr.userBlock.unblock), findsOneWidget);
    expect(find.byTooltip(tr.userBlock.block), findsNothing);
    await tester.tap(action('block'));
    await _settle(tester);
    expect((await tester.runAsync(() => blocks.load(2000)))!.isBlocked(_author), isFalse);
    expect(find.byTooltip(tr.userBlock.block), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no account in use: the lists stay, friend and block are left out', (tester) async {
    await openDialog(tester, reader: null, withBlocks: true);
    expect(action('threads'), findsOneWidget);
    expect(action('replies'), findsOneWidget);
    expect(find.text(tr.postCard.profileDialog.memberThreads), findsOneWidget);
    expect(action('friend'), findsNothing, reason: 'nobody to add the friend to');
    expect(action('block'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('neither uid nor name: no action row, the info section comes first', (tester) async {
    final post = _post();
    await openDialog(
      tester,
      reader: 2000,
      withBlocks: true,
      post: post.copyWith(
        userBriefProfile: post.userBriefProfile!.copyWith(uid: '', username: ''),
      ),
    );
    for (final key in ['threads', 'replies', 'friend', 'block']) {
      expect(action(key), findsNothing, reason: key);
    }
    final dialog = find.byType(SingleChildScrollView).last;
    final info = find.text(tr.postCard.profileDialog.tabName.info);
    // The info header sits at the top of the dialog body: no empty block and no separator above it.
    expect(tester.getTopLeft(info).dy - tester.getTopLeft(dialog).dy, lessThan(12), reason: "the header padding only");
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
