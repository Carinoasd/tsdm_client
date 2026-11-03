/// A table of a post in a page of its own, a hot reply going to its floor in the thread on screen:
///
/// * a table wider than the post (it scrolls sideways) has a button at its top right opening it in a page of its
///   own, the table in a view zoomed and moved both ways, laid out as wide as it reads; a double tap puts it back; a
///   table that fits has none;
/// * the "推荐 #N" of a hot reply whose floor is known ([Post.hotFloor], the plugin's `hot_position`) asks the thread
///   on screen for that floor ([ThreadJumpToFloorRequested] with its post id); without the floor, nothing to tap.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/jump_page/cubit/jump_page_cubit.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/offline_floor.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/thread/v1/widgets/post_list.dart';
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
import 'package:tsdm_client/utils/html/author_style.dart';
import 'package:tsdm_client/utils/html/post_table.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/munched_html.dart';

Translations get t => LocaleSettings.instance.currentTranslations;

final _light = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue));
final _dark = ThemeData(
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
);

/// [html] as the forum serves a floor: in its message cell.
String _inPost(String html) =>
    '<div class="t_fsz"><table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_1">'
    '$html</td></tr></table></div>';

/// A table of [columns] columns, two rows: nine are too many for a phone.
String _table(int columns) {
  final row = '<tr>${[for (var i = 1; i <= columns; i++) '<td>第$i列</td>'].join()}</tr>';
  return 'x<br /><table>$row$row</table>';
}

/// [html] as the content of a post card on a phone, of the thread [thread] when given, with the text scale
/// [textScale]; under the line width of the floors ([PostLineWidth]) when [lineWidth].
Future<void> _pumpPost(
  WidgetTester tester,
  String html, {
  ThemeData? theme,
  _ThreadBloc? thread,
  double textScale = 1,
  bool lineWidth = false,
}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = const Size(390, 800);
  addTearDown(tester.view.reset);
  Widget post = PostTypographyScope(typography: const PostTypography(), child: MunchedHtml(_inPost(html)));
  if (thread != null) {
    post = RepositoryProvider<ThreadRepository>.value(
      value: thread.threadRepository,
      child: BlocProvider<ThreadBloc>.value(value: thread, child: post),
    );
  }
  if (lineWidth) {
    post = PostLineWidth(child: post);
  }
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: theme ?? _light,
        themeAnimationDuration: Duration.zero,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(padding: const EdgeInsets.symmetric(horizontal: 22), child: post),
          ),
        ),
      ),
    ),
  );
  // The view tells whether it scrolls once laid out.
  await tester.pump();
  await tester.pump();
  expect(tester.takeException(), isNull);
}

final Finder _button = find.byIcon(Icons.open_in_full);

/// The circle the button is drawn as.
final Finder _circle = find.byWidgetPredicate((w) => w is Material && w.shape == const CircleBorder());

/// The table's view under [tester]: its scrollable, hit when a tap reaches the table.
RenderObject _tableView(WidgetTester tester) =>
    tester.renderObject(find.descendant(of: find.byType(PostTableScrollView), matching: find.byType(Scrollable)));

/// Whether a tap at [at] reaches the table ([_tableView]) rather than the button over it.
bool _reachesTable(WidgetTester tester, Offset at) {
  final view = _tableView(tester);
  return tester.hitTestOnBinding(at).path.any((e) => e.target == view);
}

/// Whether a tap at [at] hits the button.
bool _hitsButton(WidgetTester tester, Offset at) {
  final button = tester.renderObject(_circle);
  return tester.hitTestOnBinding(at).path.any((e) => e.target == button);
}

ScrollPosition _tablePosition(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(of: find.byType(PostTableScrollView), matching: find.byType(Scrollable)),
    )
    .position;

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// What the cards need of the app: the settings, the image cache (offline), the cookies and the error saver.
Future<({AppDatabase db, SettingsRepository settings})> _registerApp() async {
  final db = AppDatabase(NativeDatabase.memory());
  final storage = StorageProvider(db, {}, {});
  final settings = SettingsRepository(storage);
  getIt
    ..registerSingleton<StorageProvider>(storage)
    ..registerSingleton<SettingsRepository>(settings)
    ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
    ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
    ..registerSingleton<NetErrorSaver>(NetErrorSaver())
    ..registerSingleton<ImageCacheProvider>(
      ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
    );
  await settings.init();
  return (db: db, settings: settings);
}

Future<void> _unregisterApp(({AppDatabase db, SettingsRepository settings}) app) async {
  try {
    await app.settings.dispose();
  } finally {
    await getIt.reset();
    await app.db.close();
  }
}

/// The thread on screen: its floors as told ([show]), the events asked of it recorded, not run.
final class _ThreadBloc extends ThreadBloc {
  _ThreadBloc({String? onlyVisibleUid}) : this._(ThreadRepository(), onlyVisibleUid);

  _ThreadBloc._(this.threadRepository, String? onlyVisibleUid)
    : super(
        tid: '9200647',
        pid: null,
        onlyVisibleUid: onlyVisibleUid,
        reverseOrder: null,
        exactOrder: null,
        threadRepository: threadRepository,
        currentUid: () => 1,
      );

  final ThreadRepository threadRepository;

  final asked = <ThreadEvent>[];

  /// Closed as the page it was of is left (a real close waits for its listeners, past the test's frames).
  bool closedOnScreen = false;

  @override
  bool get isClosed => closedOnScreen || super.isClosed;

  @override
  void add(ThreadEvent event) => asked.add(event);

  void show(List<Post> posts, {DateTime? offlineSavedAt}) =>
      emit(state.copyWith(status: ThreadStatus.success, postList: posts, offlineSavedAt: offlineSavedAt));
}

/// A floor of a thread, [hot] its copy as a hot reply.
Post _floorPost(int floor, {bool hot = false}) => Post(
  postID: '${700000 + floor}',
  postFloor: hot ? null : floor,
  hot: hot,
  hotFloor: hot ? floor : null,
  author: const User(name: 'u', url: 'u'),
  publishTime: DateTime(2026, 11, 3),
  data: 'floor $floor',
  replyAction: null,
  rateAction: null,
  lastEditUsername: null,
  lastEditTime: null,
  shareLink: null,
  page: (floor - 1) ~/ 10 + 1,
  isDraft: false,
  packetAllTaken: false,
);

/// A tap at [position] at [time], as a finger does it.
Future<void> _tapAt(WidgetTester tester, Offset position, Duration time, {int pointer = 1}) async {
  final finger = TestPointer(pointer);
  await tester.sendEventToBinding(finger.down(position, timeStamp: time));
  await tester.sendEventToBinding(finger.up(timeStamp: time + const Duration(milliseconds: 40)));
  await tester.pump();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('A. a table in a page of its own', () {
    testWidgets('a table that scrolls sideways has the button, one that fits has none', (tester) async {
      await _pumpPost(tester, _table(9));
      final position = _tablePosition(tester);
      expect(position.maxScrollExtent, greaterThan(0));
      expect(_button, findsOneWidget);
      // At the top right of the table, in its fade.
      final view = tester.getRect(find.byType(PostTableScrollView));
      final button = tester.getRect(_button);
      expect(view.contains(button.center), isTrue);
      expect(view.right - button.right, lessThan(PostTableScrollView.fadeWidth));
      expect(button.top - view.top, lessThan(view.height / 2));

      await _pumpPost(tester, _table(2));
      expect(find.byType(PostTableScrollView), findsOneWidget);
      expect(_button, findsNothing);
    });

    testWidgets('the button opens the table in a view zoomed and moved, a double tap puts it back', (tester) async {
      await _pumpPost(tester, _table(9));
      final inPost = tester.getSize(find.byType(PostTable));
      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(find.byType(PostTableFullscreenPage), findsOneWidget);
      expect(find.descendant(of: find.byType(AppBar), matching: find.text(t.html.table.title)), findsOneWidget);
      expect(find.byType(BackButton), findsOneWidget);
      final viewer = find.byType(InteractiveViewer);
      expect(viewer, findsOneWidget);
      final table = find.descendant(of: viewer, matching: find.byType(PostTable));
      expect(table, findsOneWidget);
      expect(find.descendant(of: viewer, matching: find.text('第9列')), findsNWidgets(2));
      // As wide as it reads: wider than the screen, as wide as it scrolled in the post.
      final size = tester.getSize(table);
      expect(size.width, greaterThan(390));
      expect(size.width, moreOrLessEquals(inPost.width, epsilon: 0.5));

      final iv = tester.widget<InteractiveViewer>(viewer);
      expect((iv.constrained, iv.panEnabled, iv.scaleEnabled), (false, true, true));
      final controller = iv.transformationController!..value = Matrix4.diagonal3Values(2, 2, 1);
      await tester.pump();
      final center = tester.getCenter(viewer);
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(controller.value, Matrix4.identity());

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(PostTableFullscreenPage), findsNothing);
      expect(_button, findsOneWidget);
    });

    testWidgets('dark: the page and its table in the dark theme', (tester) async {
      await _pumpPost(tester, _table(9), theme: _dark);
      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final scaffold = tester.widget<Scaffold>(
        find.ancestor(of: find.byType(InteractiveViewer), matching: find.byType(Scaffold)),
      );
      expect(scaffold.backgroundColor, isNull, reason: "the theme's surface");
      final text = tester.widget<RichText>(
        find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(RichText)).first,
      );
      final color = text.text.style?.color ?? DefaultTextStyle.of(tester.element(find.byType(PostTable))).style.color;
      expect(color, isNotNull);
      // Light text on the dark surface.
      expect(color!.computeLuminance(), greaterThan(_dark.colorScheme.surface.computeLuminance()));
    });

    testWidgets('a double tap, told by the pointers: not a slow second tap nor a pan; taps wait for nothing', (
      tester,
    ) async {
      await _pumpPost(tester, _table(9));
      await tester.tap(_button);
      await tester.pumpAndSettle();
      final page = find.byType(PostTableFullscreenPage);
      expect(
        find.descendant(
          of: page,
          matching: find.byWidgetPredicate((w) => w is GestureDetector && w.onDoubleTap != null),
        ),
        findsNothing,
        reason: 'no double tap recognizer keeping the taps of the table waiting',
      );
      final viewer = find.byType(InteractiveViewer);
      final controller = tester.widget<InteractiveViewer>(viewer).transformationController!;
      final zoomed = Matrix4.diagonal3Values(2, 2, 1);
      final center = tester.getCenter(viewer);

      controller.value = zoomed.clone();
      await _tapAt(tester, center, const Duration(seconds: 10));
      await _tapAt(tester, center, const Duration(seconds: 11));
      expect(controller.value, zoomed, reason: 'a second tap a second later');

      await _tapAt(tester, center, const Duration(seconds: 20));
      await _tapAt(
        tester,
        center + const Offset(kDoubleTapSlop + 20, 0),
        const Duration(seconds: 20, milliseconds: 150),
      );
      expect(controller.value, zoomed, reason: 'a second tap far away');

      await _tapAt(tester, center, const Duration(seconds: 30));
      await _tapAt(tester, center, const Duration(seconds: 30, milliseconds: 150));
      // Put back in a short move, not a jump.
      await tester.pump(const Duration(milliseconds: 100));
      final midway = controller.value.clone();
      expect(midway, isNot(zoomed));
      expect(midway, isNot(Matrix4.identity()));
      expect(midway.getMaxScaleOnAxis(), inExclusiveRange(1, 2));
      await tester.pumpAndSettle();
      expect(controller.value, Matrix4.identity());

      // A finger on the table while it goes back takes it from where it is.
      controller.value = zoomed.clone();
      await _tapAt(tester, center, const Duration(seconds: 40));
      await _tapAt(tester, center, const Duration(seconds: 40, milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 100));
      final held = controller.value.clone();
      expect(held, isNot(zoomed));
      final finger = TestPointer(2);
      await tester.sendEventToBinding(finger.down(center, timeStamp: const Duration(seconds: 41)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(controller.value, held);
      await tester.sendEventToBinding(finger.up(timeStamp: const Duration(seconds: 41, milliseconds: 40)));
      await tester.pumpAndSettle();
      expect(controller.value, held);
    });

    testWidgets('the button is the circle it is drawn as: the corner of the table around it is tapped and dragged', (
      tester,
    ) async {
      await _pumpPost(tester, _table(9));
      final view = tester.getRect(find.byType(PostTableScrollView));
      final circle = tester.getRect(_circle);
      expect(circle.size, const Size.square(PostTableScrollView.buttonSize));
      expect(circle.right, view.right);
      expect(_hitsButton(tester, circle.center), isTrue);
      expect(_reachesTable(tester, circle.center), isFalse);
      // In its square but outside the circle: the table.
      final corner = circle.bottomLeft + const Offset(2, -2);
      expect(_hitsButton(tester, corner), isFalse);
      expect(_reachesTable(tester, corner), isTrue);
      // Where a finger's room around it (48dp) used to take every tap: the table, tapped and dragged.
      final under = Offset(view.right - 40, view.top + 40);
      expect(view.contains(under), isTrue);
      expect(_hitsButton(tester, under), isFalse);
      expect(_reachesTable(tester, under), isTrue);
      final position = _tablePosition(tester);
      expect(position.pixels, 0);
      await tester.dragFrom(under, const Offset(-120, 0));
      await tester.pumpAndSettle();
      expect(position.pixels, greaterThan(0));
      expect(find.byType(PostTableFullscreenPage), findsNothing);
    });

    testWidgets(
      'the button goes with the fade at the right end: half gone half way in, gone and taking no tap at the end',
      (
        tester,
      ) async {
        await _pumpPost(tester, _table(9));
        final position = _tablePosition(tester);
        final circle = tester.getRect(_circle);
        double opacity() =>
            tester.widget<Opacity>(find.ancestor(of: _button, matching: find.byType(Opacity)).first).opacity;
        expect(opacity(), 1);

        position.jumpTo(position.maxScrollExtent - PostTableScrollView.fadeWidth / 2);
        await tester.pump();
        expect(opacity(), moreOrLessEquals(0.5));
        expect(_hitsButton(tester, circle.center), isTrue);

        position.jumpTo(position.maxScrollExtent);
        await tester.pump();
        expect(opacity(), 0);
        expect(_hitsButton(tester, circle.center), isFalse);
        expect(_reachesTable(tester, circle.center), isTrue);
        await tester.tapAt(circle.center);
        await tester.pumpAndSettle();
        expect(find.byType(PostTableFullscreenPage), findsNothing);

        position.jumpTo(0);
        await tester.pump();
        expect(opacity(), 1);
        await tester.tap(_button);
        await tester.pumpAndSettle();
        expect(find.byType(PostTableFullscreenPage), findsOneWidget);
      },
    );

    testWidgets('its tooltip in the text scale of the post', (tester) async {
      await _pumpPost(tester, _table(14), textScale: 2);
      expect(_button, findsOneWidget);
      expect(tester.getSize(_circle), const Size.square(PostTableScrollView.buttonSize));
      final tooltip = find.byTooltip(t.html.table.fullscreen);
      expect(MediaQuery.textScalerOf(tester.element(tooltip)).scale(10), 20);
    });

    testWidgets('text scale 2.0: the page lays the table out as wide as it reads, nothing thrown', (tester) async {
      await _pumpPost(tester, _table(9), textScale: 2);
      await tester.tap(_button);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final table = find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(PostTable));
      final size = tester.getSize(table);
      expect(size.width, greaterThan(390));
      expect(size.width, lessThan(390 * 6));
      expect(find.descendant(of: table, matching: find.text('第9列')), findsNWidgets(2));
      // The text scale of the page, once.
      expect(MediaQuery.textScalerOf(tester.element(find.text('第9列').first)).scale(10), 20);
    });

    testWidgets('the thread goes along: what needs it there finds it, an offline copy is one there too', (
      tester,
    ) async {
      final thread = _ThreadBloc()..show([_floorPost(1)], offlineSavedAt: DateTime(2026, 11));
      addTearDown(thread.close);
      await _pumpPost(tester, _table(9), thread: thread);
      final inPost = tester.element(find.byType(PostTable));
      expect(isOfflineFloor(inPost), isTrue);
      await tester.tap(_button);
      await tester.pumpAndSettle();
      final there = tester.element(
        find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(PostTable)),
      );
      expect(there.read<ThreadBloc>(), same(thread));
      expect(there.read<ThreadRepository>(), same(thread.threadRepository));
      expect(isOfflineFloor(there), isOfflineFloor(inPost));

      // Out of a thread: nothing of one there either.
      await tester.pumpWidget(const SizedBox());
      await _pumpPost(tester, _table(9));
      await tester.tap(_button);
      await tester.pumpAndSettle();
      final alone = tester.element(
        find.descendant(of: find.byType(InteractiveViewer), matching: find.byType(PostTable)),
      );
      expect(alone.readOrNull<ThreadBloc>(), isNull);
      expect(isOfflineFloor(alone), isFalse);
    });

    testWidgets('the line width of the floors goes along: a long paragraph in a cell lays out there as in the post', (
      tester,
    ) async {
      final long = List.filled(40, '長段落的文字').join();
      await _pumpPost(tester, 'x<br /><table><tr><td>$long</td>${'<td>第二列</td>' * 8}</tr></table>', lineWidth: true);
      final inPost = tester.element(find.byType(PostTable));
      final lineWidth = PostLineWidth.maybeOf(inPost);
      expect(lineWidth, isNotNull);
      final contentWidth = postContentWidthOf(inPost);
      expect(contentWidth, isNotNull);
      final paragraph = find.descendant(of: find.byType(PostTable), matching: find.textContaining('長段落的文字'));
      expect(paragraph, findsOneWidget);
      final inPostSize = tester.getSize(paragraph);
      expect(inPostSize.height, greaterThan(inPostSize.width / 10), reason: 'several lines');

      await tester.tap(_button);
      await tester.pumpAndSettle();
      final viewer = find.byType(InteractiveViewer);
      final there = tester.element(find.descendant(of: viewer, matching: find.byType(PostTable)));
      expect(PostLineWidth.maybeOf(there), lineWidth);
      expect(postContentWidthOf(there), contentWidth);
      final thereSize = tester.getSize(find.descendant(of: viewer, matching: find.textContaining('長段落的文字')));
      expect(thereSize.width, moreOrLessEquals(inPostSize.width, epsilon: 0.5));
      expect(thereSize.height, moreOrLessEquals(inPostSize.height, epsilon: 0.5));

      // Without one above (the post of a notice): none there either.
      await tester.pumpWidget(const SizedBox());
      await _pumpPost(tester, _table(9));
      await tester.tap(_button);
      await tester.pumpAndSettle();
      final alone = tester.element(find.descendant(of: viewer, matching: find.byType(PostTable)));
      expect(PostLineWidth.maybeOf(alone), isNull);
    });

    testWidgets('on the background the author put it on, in the dark theme too', (tester) async {
      for (final theme in [_light, _dark]) {
        await tester.pumpWidget(const SizedBox());
        await _pumpPost(
          tester,
          '<div style="background-color: #303030"><font color="#ffffff">x</font>'
          '${_table(9)}</div>',
          theme: theme,
        );
        final block = tester.widget<PostBlockBackground>(find.byType(PostBlockBackground));
        await tester.tap(_button);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final scaffold = tester.widget<Scaffold>(
          find.ancestor(of: find.byType(InteractiveViewer), matching: find.byType(Scaffold)),
        );
        expect(scaffold.backgroundColor, block.color);
      }
    });
  });

  group('B. a hot reply goes to its floor', () {
    late ({AppDatabase db, SettingsRepository settings}) app;
    late SettingsBloc settings;
    late _ThreadBloc thread;

    setUp(() async {
      app = await _registerApp();
      settings = SettingsBloc(settingsRepository: app.settings, fragmentsRepository: FragmentsRepository());
      thread = _ThreadBloc();
    });
    tearDown(() async {
      await thread.close();
      await settings.close();
      await _unregisterApp(app);
    });

    List<Post> page() {
      final json =
          jsonDecode(File('test/data/tsdmapp/thread_v15_282_hot.json').readAsStringSync()) as Map<String, dynamic>;
      return threadPageFromApi(json, 1).postList;
    }

    Post bare(Post post) => post.copyWith(
      author: User(name: post.author.name, uid: post.author.uid, url: post.author.url),
      userBriefProfile: null,
      postMedals: null,
      badge: null,
      secondBadge: null,
      signature: null,
      pokemon: null,
      checkin: null,
    );

    Future<void> pump(WidgetTester tester, List<Post> posts) async {
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<SettingsBloc>.value(value: settings),
            BlocProvider<ThreadBloc>.value(value: thread),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(child: Column(children: [for (final p in posts) PostCard(bare(p))])),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('its floor known: "推荐 #12", tapped asks the thread on screen for floor 12', (tester) async {
      final posts = page();
      final hot = posts.firstWhere((e) => e.postID == '6742');
      expect((hot.hot, hot.hotFloor), (true, 12));
      thread.show(posts);
      await pump(tester, [posts.first, hot]);
      expect(find.text('${t.postCard.hotReply} #12'), findsOneWidget);
      await tester.tap(find.byTooltip(t.postCard.jumpToHotFloor));
      await tester.pump();
      expect(thread.asked, [const ThreadJumpToFloorRequested(12, pid: '6742')]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('its floor not known: "推荐" alone, nothing to tap', (tester) async {
      final posts = page();
      final hot = posts.firstWhere((e) => e.postID == '6742').copyWith(hotFloor: null);
      thread.show([posts.first, hot]);
      await pump(tester, [posts.first, hot]);
      expect(find.text(t.postCard.hotReply), findsOneWidget);
      expect(find.textContaining('#12'), findsNothing);
      expect(find.byTooltip(t.postCard.jumpToHotFloor), findsNothing);
      await tester.tap(find.text(t.postCard.hotReply));
      await tester.pump();
      expect(thread.asked, isEmpty);
    });

    /// The cards in an app with the share links pushed to a page of their own.
    Future<List<String>> pumpRouted(WidgetTester tester, List<Post> posts) async {
      final pushed = <String>[];
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: SingleChildScrollView(child: Column(children: [for (final p in posts) PostCard(bare(p))])),
            ),
          ),
          GoRoute(
            path: ScreenPaths.threadV1,
            name: ScreenPaths.threadV1,
            builder: (_, state) {
              pushed.add(state.uri.queryParameters['pid'] ?? '');
              return const Scaffold(body: Text('findpost'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        MultiBlocProvider(
          providers: [
            BlocProvider<SettingsBloc>.value(value: settings),
            BlocProvider<ThreadBloc>.value(value: thread),
          ],
          child: TranslationProvider(child: MaterialApp.router(routerConfig: router)),
        ),
      );
      await tester.pump();
      return pushed;
    }

    testWidgets('a card not of the thread on screen goes by its share link', (tester) async {
      final posts = page();
      final hot = posts.firstWhere((e) => e.postID == '6742');
      thread.show([posts.first]);
      final pushed = await pumpRouted(tester, [posts.first, hot]);
      await tester.tap(find.byTooltip(t.postCard.jumpToHotFloor));
      await tester.pumpAndSettle();
      expect(thread.asked, isEmpty);
      expect(pushed, ['6742']);
      expect(find.text('findpost'), findsOneWidget);
    });

    testWidgets('the thread closed: by its share link', (tester) async {
      final posts = page();
      final hot = posts.firstWhere((e) => e.postID == '6742');
      thread.show(posts);
      final pushed = await pumpRouted(tester, [posts.first, hot]);
      thread.closedOnScreen = true;
      await tester.tap(find.byTooltip(t.postCard.jumpToHotFloor));
      await tester.pumpAndSettle();
      expect(thread.asked, isEmpty);
      expect(pushed, ['6742']);
    });

    testWidgets("the thread showing one author's floors only: by its share link", (tester) async {
      // Closed after the test as the group's is: a close waits past the test's frames.
      addTearDown(thread.close);
      thread = _ThreadBloc(onlyVisibleUid: '2');
      final posts = page();
      final hot = posts.firstWhere((e) => e.postID == '6742');
      thread.show(posts);
      expect(thread.state.onlyVisibleUid, '2');
      final pushed = await pumpRouted(tester, [posts.first, hot]);
      await tester.tap(find.byTooltip(t.postCard.jumpToHotFloor));
      await tester.pumpAndSettle();
      expect(thread.asked, isEmpty);
      expect(pushed, ['6742']);
    });

    testWidgets('the list brings the floor itself to the top, not its copy as a hot reply', (tester) async {
      final posts = [
        _floorPost(1),
        _floorPost(25, hot: true),
        for (var f = 2; f <= 30; f++) _floorPost(f),
      ];
      final controller = ThreadScrollController();
      addTearDown(controller.dispose);
      var serial = 0;
      String? target;
      late StateSetter setHost;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: BlocProvider(
              create: (_) => JumpPageCubit(),
              child: StatefulBuilder(
                builder: (context, setState) {
                  setHost = setState;
                  return Scaffold(
                    body: PostList(
                      threadID: '1120',
                      title: 'Thread title',
                      postList: posts,
                      widgetBuilder: (_, post) => SizedBox(
                        height: 200,
                        child: Text(
                          'floor',
                          key: ValueKey('${post.hot ? 'hot' : 'floor'}-${post.postFloor ?? post.hotFloor}'),
                        ),
                      ),
                      canLoadMore: false,
                      scrollController: controller,
                      latestModAct: null,
                      useDivider: true,
                      lastPage: 3,
                      scrollTargetPid: target,
                      scrollTargetSerial: serial,
                      onLoadNext: () {},
                      onLoadPrevious: () {},
                      onRefresh: () {},
                      onTopFloorChanged: (_, {required atThreadTop}) {},
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('hot-25')), findsOneWidget, reason: 'the copy on screen, under the first floor');
      setHost(() {
        target = '700025';
        serial++;
      });
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      final top = tester.getTopLeft(find.byType(PostList)).dy;
      expect(tester.getTopLeft(find.byKey(const ValueKey('floor-25'))).dy - top, lessThan(100));
      expect(find.byKey(const ValueKey('hot-25')), findsNothing, reason: 'far above');
      expect(tester.takeException(), isNull);
    });
  });
}
