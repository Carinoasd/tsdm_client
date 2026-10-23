/// Reading progress round (UX audit item 6), the memory of a long thread:
///
/// * a floor is not kept alive off screen (it is built again when scrolled back to), even when something in it asks;
/// * its munched content is kept apart, in the thread page's [MunchCache] (at most its capacity, dropped with the
///   page): built again it takes the content back instead of munching its html again; two floors showing the same
///   html at once have one each; the spans of a content taken back act from the floor showing them now;
/// * an avatar is not dropped from the image cache (and decoded again) every time its floor is built: only when it was
///   missing before, or the placeholder was loaded for it;
/// * a floor's images are decoded no wider than the floor's content;
/// * nothing of the thread page stays reachable once the page is left.
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
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
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

/// A small PNG (the app's placeholder).
final Uint8List _png = File('assets/images/placeholder.png').readAsBytesSync();

/// Images and avatars from the network: an avatar (`bob.png`) answers the PNG once in [avatars], and fails at once
/// before; any other image answers the PNG.
final class _Images implements HttpClientAdapter {
  final avatars = <String>{};
  final requested = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add('${options.uri}');
    if ('${options.uri}'.endsWith('bob.png') && !avatars.contains('${options.uri}')) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    return ResponseBody.fromBytes(
      _png,
      200,
      headers: {
        Headers.contentTypeHeader: ['image/png'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Make the garbage collector run until the targets of [refs] are gone, or [rounds] rounds went by: large blocks go
/// to the old generation and make the collector go through it too, not only through the new one. Each round lets real
/// async work go on for a moment as well (a request the page left on its way ends, and with it what it held).
Future<void> _collect(Iterable<WeakReference<Object>> refs, {int rounds = 4000}) async {
  final garbage = <Uint8List>[];
  for (var i = 0; i < rounds && refs.any((e) => e.target != null); i++) {
    await Future<void>.delayed(i.isEven ? Duration.zero : const Duration(milliseconds: 1));
    garbage.add(Uint8List(1 << 20));
    if (garbage.length > 32) {
      garbage.removeAt(0);
    }
  }
}

/// A floor that asks to be kept alive.
class _Probe extends StatefulWidget {
  const _Probe(this.floor, this.disposed);

  final int floor;
  final List<int> disposed;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    widget.disposed.add(widget.floor);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SizedBox(height: 300, child: Text('floor ${widget.floor}'));
  }
}

Post _post(int floor, {String? data}) => Post(
  postID: '${800000 + floor}',
  postFloor: floor,
  author: const User(name: 'u', url: 'u'),
  publishTime: DateTime(2026, 10, 23),
  data: data ?? 'floor $floor',
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: (floor - 1) ~/ 10 + 1,
  isDraft: false,
  packetAllTaken: false,
);

void main() {
  late Directory tmp;
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late _Images images;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
    tmp = Directory.systemTemp.createTempSync('tsdm_long_thread_');
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
    TsdmAppApi.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    images = _Images();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _Forum()),
      )
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = images)),
      );
    await settings.init();
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    ThreadAuthorCache.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  tearDown(() async {
    await settingsBloc.close();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  });

  /// Let real async work (requests, files, decoding) and the frames it causes finish.
  Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('a floor is not kept alive off screen, even when something in it asks', (tester) async {
    final disposed = <int>[];
    final controller = ThreadScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PostList(
            threadID: '1',
            postList: [for (var f = 1; f <= 30; f++) _post(f)],
            widgetBuilder: (_, post) => _Probe(post.postFloor!, disposed),
            canLoadMore: false,
            scrollController: controller,
            latestModAct: null,
          ),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -1500));
      await tester.pumpAndSettle();
    }
    // Only the floors around the screen are alive (floors skipped by a fast scroll were never built).
    final alive = tester.stateList<_ProbeState>(find.byType(_Probe, skipOffstage: false)).map((e) => e.widget.floor);
    expect(alive, isNotEmpty);
    expect(alive.every((e) => e > 15), isTrue, reason: 'alive: $alive');
    expect(disposed, containsAll([1, 2, 3]), reason: 'the floors scrolled away are gone');
    expect(File('lib/widgets/card/post_card/post_card.dart').readAsStringSync(), isNot(contains('wantKeepAlive')));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 9000));
    await tester.pumpAndSettle();
    expect(find.text('floor 1'), findsOneWidget, reason: 'built again when scrolled back to');
  });

  group('MunchCache', () {
    Future<void> show(WidgetTester tester, MunchCache cache, List<String> htmls) => tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: MunchCacheScope(
              cache: cache,
              child: Column(children: [for (final html in htmls) MunchedHtml(html)]),
            ),
          ),
        ),
      ),
    );

    Widget contentOf(WidgetTester tester, {int index = 0}) => tester.widget<ClipRect>(
      find.descendant(of: find.byType(MunchedHtml).at(index), matching: find.byType(ClipRect)).first,
    );

    testWidgets('a floor built again takes its content back; at most its capacity; dropped with the page', (
      tester,
    ) async {
      final cache = MunchCache(capacity: 2);
      await show(tester, cache, ['<p>a</p>']);
      final first = contentOf(tester);
      await show(tester, cache, []);
      await show(tester, cache, ['<p>a</p>']);
      expect(contentOf(tester), same(first), reason: 'not munched again');

      await show(tester, cache, ['<p>b</p>', '<p>c</p>']);
      expect(cache.length, 2);
      await show(tester, cache, ['<p>a</p>']);
      expect(contentOf(tester), isNot(same(first)), reason: 'the least recently used one was dropped');
      cache.clear();
      expect(cache.length, 0);
    });

    testWidgets('two floors with the same html at once have one each', (tester) async {
      final cache = MunchCache();
      await show(tester, cache, ['<p>same</p>', '<p>same</p>']);
      expect(contentOf(tester), isNot(same(contentOf(tester, index: 1))));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the spans of a content taken back act from the floor showing them now', (tester) async {
      final cache = MunchCache();
      const html = '<img src="https://img.example/a.png" />';
      await show(tester, cache, [html]);
      await settle(tester, rounds: 2);
      await show(tester, cache, []);
      await show(tester, cache, ['<p>above</p>', html]);
      await settle(tester, rounds: 2);
      await tester.tap(
        find.descendant(of: find.byType(MunchedHtml).at(1), matching: find.byType(GestureDetector)).first,
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull, reason: 'the first floor is gone, its context with it');
      expect(find.text(t.imageBottomSheet.title), findsOneWidget, reason: 'opened from the floor showing it now');
      // Close it before the page goes.
      await tester.tapAt(const Offset(10, 10));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    });
  });

  group('avatars', () {
    const url = 'https://img.example/bob.png';
    const provider = CachedImageProvider(url, usage: ImageUsageInfoUserAvatar('Bob'));

    Future<void> showAvatar(WidgetTester tester, {required bool shown}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: shown ? HeroUserAvatar(username: 'Bob', avatarUrl: url) : const SizedBox(),
          ),
        ),
      );
      await settle(tester, rounds: 4);
    }

    /// The decoded avatar the image cache holds now (the same one while it is not evicted), null when none.
    ImageStreamCompleter? held() {
      var missing = false;
      final completer = PaintingBinding.instance.imageCache.putIfAbsent(provider, () {
        missing = true;
        return OneFrameImageStreamCompleter(Completer<ImageInfo>().future);
      });
      if (missing) {
        PaintingBinding.instance.imageCache.evict(provider);
        return null;
      }
      return completer;
    }

    testWidgets('a cached avatar is decoded once however many times its floor is built', (tester) async {
      images.avatars.add(url);
      await showAvatar(tester, shown: true);
      final decoded = held();
      expect(decoded, isNotNull);
      for (var i = 0; i < 3; i++) {
        await showAvatar(tester, shown: false);
        await showAvatar(tester, shown: true);
        expect(held(), same(decoded), reason: 'evicted at every answer, it was decoded again each time');
      }
      expect(images.requested.where((e) => e == url), [url], reason: 'downloaded once');
    });

    testWidgets('loaded as the placeholder, the avatar replaces it once cached, here and in the floors built later', (
      tester,
    ) async {
      await showAvatar(tester, shown: true);
      expect(provider.loadedAsPlaceholder, isTrue, reason: 'nothing to show yet');
      final placeholder = held();
      // Downloaded meanwhile (another page asked for it).
      images.avatars.add(url);
      await tester.runAsync(
        () => getIt.get<ImageCacheProvider>().getOrMakeCache(
          const ImageCacheUserAvatarRequest(username: 'Bob', imageUrl: url),
        ),
      );
      // Evicted, painted anew, read from the file and decoded: real work.
      await settle(tester, rounds: 14);
      expect(provider.loadedAsPlaceholder, isFalse);
      expect(held(), isNot(same(placeholder)));
      final avatar = held();
      await showAvatar(tester, shown: false);
      await showAvatar(tester, shown: true);
      expect(held(), same(avatar));
    });
  });

  testWidgets("a floor's images are decoded no wider than the floor's content", (tester) async {
    tester.view
      ..physicalSize = const Size(1080, 2280)
      ..devicePixelRatio = 2.625;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PostLineWidth(child: CachedImage('https://img.example/photo.jpg'))),
      ),
    );
    final image = tester.widget<Image>(find.byWidgetPredicate((w) => w is Image && w.image is ResizeImage));
    final resize = image.image as ResizeImage;
    final content = postContentWidthOf(tester.element(find.byType(CachedImage)))!;
    expect(content, lessThan(1080 / 2.625));
    expect(resize.width, (content * 2.625).ceil());
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
  });

  testWidgets('nothing of the thread page stays reachable once it is left', (tester) async {
    const alice = UserLoginInfo(username: 'Alice', uid: 31);
    final auth = AuthenticationRepository(user: alice);
    final blocks = UserBlockRepository(storage);
    final info = NotificationInfoRepository();
    final counts = NotificationStateCubit(info);
    final cubit = UserBlockCubit(repository: blocks, currentUid: () => alice.uid, authStatus: auth.status);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('the list')),
          routes: [
            GoRoute(
              path: 'thread',
              builder: (_, _) => const ThreadPage(
                threadID: '1264975',
                findPostID: null,
                pageNumber: '1',
                overrideReverseOrder: true,
                overrideWithExactOrder: null,
              ),
            ),
          ],
        ),
      ],
    );
    addTearDown(() async {
      router.dispose();
      await cubit.close();
      await info.dispose();
      await counts.close();
      await blocks.dispose();
      await auth.dispose();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: RepositoryProvider<AuthenticationRepository>.value(
          value: auth,
          child: MultiRepositoryProvider(
            providers: [RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository())],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<UserBlockCubit>.value(value: cubit),
                BlocProvider<NotificationBloc>.value(value: _Notifications()),
                BlocProvider<NotificationStateCubit>.value(value: counts),
              ],
              child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
            ),
          ),
        ),
      ),
    );
    unawaited(router.push('/thread'));
    await settle(tester);
    for (var i = 0; i < 4; i++) {
      await tester.drag(find.byType(PostList), const Offset(0, -2500));
      await settle(tester);
    }
    // Only weak references outlive this closure: a local of the test itself would keep them.
    final refs = () {
      final bloc = BlocProvider.of<ThreadBloc>(tester.element(find.byType(PostList)));
      expect(bloc.state.currentPage, greaterThan(2), reason: 'read on through a few pages');
      return <String, WeakReference<Object>>{
        'bloc': WeakReference(bloc),
        'list': WeakReference(tester.state(find.byType(PostList))),
        'floor card': WeakReference(tester.state(find.byType(PostCard).first)),
        'floor': WeakReference(bloc.state.postList.first),
        'page': WeakReference(tester.state(find.byType(ThreadPage))),
      };
    }();

    await tester.binding.handlePopRoute();
    await settle(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('the list'), findsOneWidget);
    // A request the page left on its way ends in real time; what follows it runs in the test's fake time: let both go
    // on between the collections.
    for (var i = 0; i < 3 && refs.values.any((e) => e.target != null); i++) {
      await tester.runAsync(() => _collect(refs.values));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final kept = [
      for (final MapEntry(:key, :value) in refs.entries)
        if (value.target != null) key,
    ];
    expect(kept, isEmpty, reason: 'still reachable after the page was left');
  });
}

final class _Notifications extends Fake implements NotificationBloc {
  @override
  void add(NotificationEvent event) {}

  @override
  NotificationState get state => const NotificationState(status: NotificationStatus.success);

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// Pages of 10 floors (8 pages), each floor a few lines with a link and an image.
final class _Forum implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final page = int.tryParse(options.uri.queryParameters['page'] ?? '') ?? 1;
    final pager =
        '<div class="pg">${[
          for (var i = 1; i <= 8; i++) i == page ? '<strong>$i</strong>' : '<a href="forum.php?mod=viewthread&tid=1264975&page=$i">$i</a>',
        ].join()}<label><input type="text" name="custompage"/><span title="共 8 页"> / 8 页</span></label></div>';
    String floor(int f) =>
        '''
<div id="post_${9800000 + f}"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=${9800000 + f}"><em>$f</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1000" class="xi2">Bob</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_${9800000 + f}">floor $f <a href="https://example.com/$f">link</a>
<img src="https://img.example/$f.png" /><br />${'line<br />' * 4}</div></div></div></td>
</tr></tbody></table></div>''';
    final body =
        '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=1264975" /></head><body>
$pager
<div id="postlist"><h1 class="ts"><span id="thread_subject">Thread title</span></h1><div class="bm">
${[for (var f = (page - 1) * 10 + 1; f <= page * 10; f++) floor(f)].join('\n')}
</div></div>
</body></html>''';
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
