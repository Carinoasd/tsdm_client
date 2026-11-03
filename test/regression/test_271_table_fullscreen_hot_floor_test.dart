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
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
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

/// [html] as the content of a post card on a phone.
Future<void> _pumpPost(WidgetTester tester, String html, {ThemeData? theme}) async {
  tester.view
    ..devicePixelRatio = 1
    ..physicalSize = const Size(390, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: theme ?? _light,
        themeAnimationDuration: Duration.zero,
        home: Scaffold(
          body: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: PostTypographyScope(typography: const PostTypography(), child: MunchedHtml(_inPost(html))),
            ),
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
  _ThreadBloc()
    : super(
        tid: '9200647',
        pid: null,
        onlyVisibleUid: null,
        reverseOrder: null,
        exactOrder: null,
        threadRepository: ThreadRepository(),
        currentUid: () => 1,
      );

  final asked = <ThreadEvent>[];

  @override
  void add(ThreadEvent event) => asked.add(event);

  void show(List<Post> posts) => emit(state.copyWith(status: ThreadStatus.success, postList: posts));
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('A. a table in a page of its own', () {
    testWidgets('a table that scrolls sideways has the button, one that fits has none', (tester) async {
      await _pumpPost(tester, _table(9));
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: find.byType(PostTableScrollView), matching: find.byType(Scrollable)),
          )
          .position;
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
  });
}
