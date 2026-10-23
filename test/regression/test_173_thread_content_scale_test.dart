import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
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
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';

/// GitHub #137: the thread content scale setting enlarges the floors of the thread page on top of the global text
/// scale, without touching the app bar or the reply bar, and the combined scale is capped.
///
/// The thread page is synthetic (grounded in the Discuz template), no real account or network.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);

/// Notification bloc holding a fixed state; the thread page only reads it.
final class _Notifications extends Fake implements NotificationBloc {
  _Notifications(this.state);

  @override
  void add(NotificationEvent event) {}

  @override
  final NotificationState state;

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// Never answers: avatars are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Serves one thread page for every request.
final class _ThreadAdapter implements HttpClientAdapter {
  _ThreadAdapter(this.page);

  String page;

  int requests = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.method, 'GET', reason: 'layout tests must never perform a forum write');
    requests++;
    return ResponseBody.fromString(
      page,
      200,
      headers: {
        Headers.contentTypeHeader: ['text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

String _floor({required int pid, required int floor, required int uid, required String name}) =>
    '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=$uid" class="xi2">$name</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor text</div></div></div></td>
</tr></tbody></table></div>''';

String _threadPage(List<String> floors, {String title = 'Scaled title'}) =>
    '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=1264975" /></head><body>
<div id="postlist"><h1 class="ts"><span id="thread_subject">$title</span></h1><div class="bm">
${floors.join('\n')}
</div></div>
</body></html>''';

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late UserBlockRepository blocks;
  late AuthenticationRepository auth;
  late _ThreadAdapter adapter;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
    adapter = _ThreadAdapter(_threadPage([_floor(pid: 1, floor: 1, uid: _alice.uid!, name: 'Alice')]));
    getIt
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      )
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
        ),
      );
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    blocks = UserBlockRepository(storage);
    auth = AuthenticationRepository(user: _alice);
    ThreadAuthorCache.clear();
  });

  tearDown(() async {
    await settingsBloc.close();
    await blocks.dispose();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// Pump the thread page under the providers of the app, with [globalScale] as the app wide linear text scale.
  Future<void> pump(WidgetTester tester, {double globalScale = 1}) async {
    final info = NotificationInfoRepository();
    final counts = NotificationStateCubit(info);
    final cubit = UserBlockCubit(repository: blocks, currentUid: () => _alice.uid, authStatus: auth.status);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const ThreadPage(
            threadID: '1264975',
            findPostID: null,
            pageNumber: '1',
            overrideReverseOrder: false,
            overrideWithExactOrder: null,
          ),
        ),
      ],
    );
    addTearDown(() async {
      router.dispose();
      await cubit.close();
      await info.dispose();
      await counts.close();
    });
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiRepositoryProvider(
          providers: [
            RepositoryProvider<AuthenticationRepository>.value(value: auth),
            RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
          ],
          child: MultiBlocProvider(
            providers: [
              BlocProvider<SettingsBloc>.value(value: settingsBloc),
              BlocProvider<UserBlockCubit>.value(value: cubit),
              BlocProvider<NotificationBloc>.value(
                value: _Notifications(const NotificationState(status: NotificationStatus.success)),
              ),
              BlocProvider<NotificationStateCubit>.value(value: counts),
            ],
            // Like the app, the global scale is a linear scaler above the app (`lib/app.dart`).
            child: MediaQuery(
              data: MediaQueryData.fromView(tester.view).copyWith(textScaler: TextScaler.linear(globalScale)),
              child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  /// The text scale factor in effect where [finder] is built.
  double scaleAt(WidgetTester tester, Finder finder) => MediaQuery.textScalerOf(tester.element(finder.first)).scale(1);

  Finder floorText() => find.textContaining('floor 1 text', findRichText: true);
  // Measured at the app bar itself: the app bar clamps the scale of its own title (1.34 at most).
  Finder appBarTitle() => find.byType(AppBar);

  Future<void> set(WidgetTester tester, SettingsKeys<double> key, double value) async {
    await tester.runAsync(() => settings.setValue(key, value));
    await settle(tester);
  }

  testWidgets('the default setting leaves the floors at the global text scale', (tester) async {
    await pump(tester);
    expect(floorText(), findsWidgets);
    expect(find.descendant(of: appBarTitle(), matching: find.text('Scaled title')), findsOneWidget);
    expect(scaleAt(tester, floorText()), 1.0);
    expect(scaleAt(tester, appBarTitle()), 1.0);
  });

  testWidgets('the setting scales the floors but not the app bar nor the reply bar', (tester) async {
    await pump(tester);
    await set(tester, SettingsKeys.threadContentScale, 2);
    expect(scaleAt(tester, floorText()), 2.0);
    expect(scaleAt(tester, appBarTitle()), 1.0);
    expect(scaleAt(tester, find.byType(ReplyBar)), 1.0);

    // Back to no extra scale, live.
    await set(tester, SettingsKeys.threadContentScale, 1);
    expect(scaleAt(tester, floorText()), 1.0);
  });

  testWidgets('the setting multiplies the global text scale and the product is capped', (tester) async {
    await pump(tester, globalScale: 1.5);
    expect(scaleAt(tester, appBarTitle()), 1.5);
    expect(scaleAt(tester, floorText()), 1.5);

    await set(tester, SettingsKeys.threadContentScale, 1.6);
    expect(scaleAt(tester, floorText()), closeTo(2.4, 0.001));
    expect(scaleAt(tester, appBarTitle()), 1.5);

    await set(tester, SettingsKeys.threadContentScale, 2);
    expect(scaleAt(tester, floorText()), threadContentMaxTextScale, reason: '1.5 * 2 exceeds the cap');
    expect(scaleAt(tester, find.byType(ReplyBar)), 1.5);
  });

  /// Real view metrics, including the status bar that Scaffold removes for its body.
  void viewport(WidgetTester tester, Size size, FakeViewPadding padding) {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = size
      ..viewPadding = padding
      ..padding = padding;
  }

  /// The title starts directly below the app bar; every line is visible or reachable by scrolling.
  Future<void> expectTitleVisible(WidgetTester tester, String title) async {
    final list = find.byType(PostList);
    final text = find.descendant(of: list, matching: find.text(title));
    expect(text, findsOneWidget);
    final titleRect = tester.getRect(text);
    final appBarRect = tester.getRect(find.byType(AppBar));
    final view = find.descendant(of: list, matching: find.byType(Viewport));
    final visibleRect = tester.getRect(view.first);
    expect(visibleRect.top, closeTo(appBarRect.bottom, 0.01), reason: 'no second status-bar inset in the body');
    expect(titleRect.top - appBarRect.bottom, closeTo(8, 0.01), reason: 'only the normal title margin remains');
    final paragraph = tester.renderObject<RenderParagraph>(text);
    final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: title.length));
    expect(boxes, isNotEmpty);
    for (final box in boxes) {
      final line = box.toRect().shift(paragraph.localToGlobal(Offset.zero));
      expect(line.top, greaterThanOrEqualTo(visibleRect.top));
      expect(line.bottom, lessThanOrEqualTo(titleRect.bottom + 0.01));
      expect(line.left, greaterThanOrEqualTo(visibleRect.left));
      expect(line.right, lessThanOrEqualTo(visibleRect.right));
    }
    final controller = tester.widget<PostList>(list).scrollController;
    // At the start of the list: its zero offset is at the first floor, the title above it (reading progress round).
    final start = controller.position.minScrollExtent;
    expect(controller.offset, closeTo(start, 0.01));
    // A large multi-line title may legitimately exceed a short landscape viewport. Its last line must be
    // reachable by scrolling, not clipped by a fixed-height title container.
    if (titleRect.bottom > visibleRect.bottom) {
      controller.jumpTo(start + titleRect.bottom - visibleRect.bottom);
      await settle(tester);
      final lastLine = boxes.last.toRect().shift(paragraph.localToGlobal(Offset.zero));
      expect(lastLine.top, greaterThanOrEqualTo(visibleRect.top));
      expect(lastLine.bottom, lessThanOrEqualTo(visibleRect.bottom + 0.01));
      controller.jumpTo(start);
      await settle(tester);
    }
    expect(tester.takeException(), isNull);
  }

  const shortTitle = '老人回归';
  const longTitle = '老人回归：一起聊聊最近喜欢的动画与论坛生活';
  final layouts = [
    ('small phone', TargetPlatform.android, const Size(360, 780), const FakeViewPadding(top: 24, bottom: 24)),
    ('reported phone', TargetPlatform.android, const Size(384, 792), const FakeViewPadding(top: 40, bottom: 24)),
    ('reported tablet', TargetPlatform.android, const Size(533, 853), const FakeViewPadding(top: 24, bottom: 24)),
    (
      'landscape left cutout',
      TargetPlatform.android,
      const Size(792, 368),
      const FakeViewPadding(left: 40, bottom: 24),
    ),
    (
      'landscape right cutout',
      TargetPlatform.android,
      const Size(792, 368),
      const FakeViewPadding(right: 40, bottom: 24),
    ),
    ('iOS', TargetPlatform.iOS, const Size(390, 844), const FakeViewPadding(top: 47, bottom: 34)),
    ('desktop', TargetPlatform.windows, const Size(1440, 900), FakeViewPadding.zero),
  ];
  for (final (name, platform, size, padding) in layouts) {
    for (final large in [false, true]) {
      testWidgets('initial thread title: $name, large text=$large', (tester) async {
        viewport(tester, size, padding);
        addTearDown(tester.view.reset);
        final title = large ? longTitle : shortTitle;
        adapter.page = _threadPage([
          for (var i = 1; i <= 10; i++) _floor(pid: i, floor: i, uid: _alice.uid!, name: 'Alice'),
        ], title: title);
        if (large) {
          await settings.setValue<double>(SettingsKeys.threadContentScale, 2);
          await settings.setValue(SettingsKeys.textScaleFactor, 1.5);
        }
        await pump(tester, globalScale: large ? 1.5 : 1);
        await expectTitleVisible(tester, title);
        expect(adapter.requests, 1, reason: 'first open only, no pull to refresh');
        if (large && size.width < 600) {
          final text = find.descendant(of: find.byType(PostList), matching: find.text(title));
          expect(tester.getSize(text).height, greaterThan(60), reason: 'a real multi-line large title');
        }
      }, variant: TargetPlatformVariant({platform}));
    }
  }

  testWidgets('rotation keeps the title visible and consumes only the current safe area', (tester) async {
    viewport(tester, const Size(384, 792), const FakeViewPadding(top: 40, bottom: 24));
    addTearDown(tester.view.reset);
    await pump(tester);
    await expectTitleVisible(tester, 'Scaled title');
    viewport(tester, const Size(792, 368), const FakeViewPadding(left: 40, bottom: 24));
    await settle(tester);
    await expectTitleVisible(tester, 'Scaled title');
    viewport(tester, const Size(384, 792), const FakeViewPadding(top: 40, bottom: 24));
    await settle(tester);
    await expectTitleVisible(tester, 'Scaled title');
  });

  testWidgets('pull to refresh returns the title to the same inset-free position', (tester) async {
    viewport(tester, const Size(384, 792), const FakeViewPadding(top: 40, bottom: 24));
    addTearDown(tester.view.reset);
    await pump(tester);
    await expectTitleVisible(tester, 'Scaled title');
    final before = adapter.requests;
    await tester.drag(find.byType(PostList), const Offset(0, 300));
    for (var i = 0; i < 20; i++) {
      await settle(tester);
    }
    expect(adapter.requests, greaterThan(before), reason: 'the actual refresh callback reloaded the page');
    await expectTitleVisible(tester, 'Scaled title');
  });
}

/// Let database work and futures finish outside the fake zone, then build the frames it caused.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}
