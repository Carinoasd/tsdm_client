/// "Add to home screen" of a forum or a thread (Android): the menus of the forum and the thread pages ask the launcher
/// to pin a shortcut `forum-<fid>` or `thread-<tid>`, which opens that page.
///
/// 1. the ids: a forum or a thread with a positive id, nothing else; an id handed over is the app's own, a link one
///    from another app; the shortcuts of the app icon are as they were;
/// 2. a pinned one opens its page, with or without an account, from the app's own shortcut or another app's link:
///    pushed above the page on top, not again when that page is on top already (a thread by its tid), a thread into the
///    detail pane of a two-pane list page in view;
/// 3. the channel: whether the launcher pins, the request with its labels and what came of it, a missing native side;
/// 4. the labels: white space collapsed, cut by the characters the user sees, none without a title;
/// 5. the menu item: only while the launcher pins and the page has an id and a title; the launcher's answer told only
///    when it is not the launcher's own dialog;
/// 6. Android: the shortcut starts the activity that is not exported (as the launcher shortcuts do), without the key,
///    Android 8 or later; the activity hands the pinning calls to it; the Kotlin test runs in the Test build.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/shortcuts/models/app_shortcut.dart';
import 'package:tsdm_client/features/shortcuts/repository/app_shortcuts_channel.dart';
import 'package:tsdm_client/features/shortcuts/utils/app_shortcut_action.dart';
import 'package:tsdm_client/features/shortcuts/utils/pin_to_home.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/two_pane.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('ids', () {
    test('a forum or a thread with a positive id', () {
      expect(PinnedShortcut.fromId('forum-12'), const PinnedForum(12));
      expect(PinnedShortcut.fromId('thread-1234567890'), const PinnedThread(1234567890));
      for (final id in [
        null,
        '',
        'checkin',
        'forum-0',
        'forum-012',
        'forum-',
        'thread-12345678901',
        'thread-1x',
        'thread-1/2',
        'Thread-1',
        ' forum-1',
        'post-1',
      ]) {
        expect(PinnedShortcut.fromId(id), isNull, reason: id);
      }
      expect(PinnedForum.tryParse('12'), const PinnedForum(12));
      expect(PinnedThread.tryParse('42'), const PinnedThread(42));
      for (final id in [null, '', '0', '-1', '1%262', 'abc']) {
        expect(PinnedForum.tryParse(id), isNull, reason: id);
        expect(PinnedThread.tryParse(id), isNull, reason: id);
      }
    });

    test('the id and the link the shortcut carries', () {
      expect(const PinnedForum(12).id, 'forum-12');
      expect(const PinnedThread(42).id, 'thread-42');
      expect(const PinnedThread(42).link, 'tsdm://shortcut/thread-42');
    });

    test("an id is the app's own shortcut, a link one from another app", () {
      expect(ShortcutTarget.requestOf('thread-42'), (shortcut: const PinnedThread(42), external: false));
      expect(ShortcutTarget.requestOf('tsdm://shortcut/forum-12'), (shortcut: const PinnedForum(12), external: true));
      expect(
        ShortcutTarget.requestOf('tsdm://shortcut/thread-42?key=anything'),
        (shortcut: const PinnedThread(42), external: true),
      );
      for (final value in ['tsdm://shortcut/thread-0', 'tsdm://shortcut/forum/12', 'https://x/forum-12', 'forum-1x']) {
        expect(ShortcutTarget.requestOf(value), isNull, reason: value);
      }
    });

    test('the shortcuts of the app icon are as they were', () {
      for (final shortcut in AppShortcut.values) {
        expect(ShortcutTarget.requestOf(shortcut.id), (shortcut: shortcut, external: false));
        expect(ShortcutTarget.requestOf(shortcut.link), (shortcut: shortcut, external: true));
      }
      expect(AppShortcut.requestOf('thread-42'), isNull);
      expect(AppShortcut.fromIdOrLink('tsdm://shortcut/thread-42'), isNull);
    });
  });

  group('opening', () {
    test('a pinned one opens its page, whoever asked for it', () {
      for (final loggedIn in [true, false]) {
        for (final external in [true, false]) {
          expect(
            decideAppShortcut(const PinnedForum(12), loggedIn: loggedIn, external: external),
            isA<AppShortcutOpenRoute>().having((e) => e.route.screenPath, 'path', ScreenPaths.forum).having(
              (e) => e.route.pathParameters,
              'path parameters',
              {'fid': '12'},
            ),
          );
          expect(
            decideAppShortcut(const PinnedThread(42), loggedIn: loggedIn, external: external),
            isA<AppShortcutOpenRoute>().having((e) => e.route.screenPath, 'path', ScreenPaths.threadV1).having(
              (e) => e.route.queryParameters,
              'query',
              {'tid': '42'},
            ),
          );
        }
      }
    });

    GoRouter makeRouter() => GoRouter(
      initialLocation: ScreenPaths.homepage,
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (_, _, navigator) => navigator,
          branches: [
            StatefulShellBranch(
              routes: [
                GoRoute(path: ScreenPaths.homepage, name: ScreenPaths.homepage, builder: (_, _) => const Text('home')),
              ],
            ),
          ],
        ),
        GoRoute(
          path: ScreenPaths.forum,
          name: ScreenPaths.forum,
          builder: (_, state) => Text('forum ${state.pathParameters['fid']}'),
        ),
        GoRoute(
          path: ScreenPaths.threadV1,
          name: ScreenPaths.threadV1,
          builder: (_, state) => Text('thread ${state.uri.queryParameters['tid']}'),
        ),
      ],
    );

    Future<GoRouter> pumpRouter(WidgetTester tester) async {
      final router = makeRouter();
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      return router;
    }

    Future<void> open(WidgetTester tester, GoRouter router, PinnedShortcut shortcut, {BuildContext? list}) async {
      performAppShortcut(
        router,
        decideAppShortcut(shortcut, loggedIn: true),
        hasPopup: false,
        checkin: () => fail('no check-in'),
        listInView: () => list,
      );
      await tester.pumpAndSettle();
    }

    int pages(GoRouter router) => router.routerDelegate.currentConfiguration.matches.length;

    testWidgets('pushed above the page on top, not again when it is on top already', (tester) async {
      final router = await pumpRouter(tester);
      final start = pages(router);

      await open(tester, router, const PinnedForum(12));
      expect(find.text('forum 12'), findsOneWidget);
      expect(pages(router), start + 1);
      await open(tester, router, const PinnedForum(12));
      expect(pages(router), start + 1);

      await open(tester, router, const PinnedThread(42));
      expect(find.text('thread 42'), findsOneWidget);
      expect(pages(router), start + 2);
      // The same location as another thread: told apart by the tid.
      await open(tester, router, const PinnedThread(42));
      expect(pages(router), start + 2);
      await open(tester, router, const PinnedThread(43));
      expect(find.text('thread 43'), findsOneWidget);
      expect(pages(router), start + 3);

      await open(tester, router, const PinnedForum(13));
      expect(find.text('forum 13'), findsOneWidget);
      expect(pages(router), start + 4);
    });

    testWidgets('a thread goes into the detail pane of the two-pane list page in view', (tester) async {
      final router = makeRouter();
      addTearDown(router.dispose);
      final tabs = TwoPaneTabs();
      addTearDown(tabs.dispose);
      late BuildContext list;
      late BuildContext outside;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              TwoPaneScope(
                tabs: tabs,
                side: TwoPaneSide.list,
                child: Builder(
                  builder: (context) {
                    list = context;
                    return const SizedBox();
                  },
                ),
              ),
              Builder(
                builder: (context) {
                  outside = context;
                  return const SizedBox();
                },
              ),
              Expanded(child: MaterialApp.router(routerConfig: router)),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      final start = pages(router);

      await open(tester, router, const PinnedThread(42), list: list);
      expect(tabs.active?.top?.query, {'tid': '42'});
      expect(pages(router), start);

      // A forum is a page of its own; so is a thread when the context is in no two-pane layout.
      await open(tester, router, const PinnedForum(12), list: list);
      expect(pages(router), start + 1);
      expect(tabs.length, 1);
      await open(tester, router, const PinnedThread(43), list: outside);
      expect(pages(router), start + 2);
      expect(tabs.active?.top?.query, {'tid': '42'});
    });
  });

  group('channel', () {
    const channel = MethodChannel(AppShortcutsChannel.name);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('a cold start and a tap while the app runs hand a pinned one over', () async {
      messenger.setMockMethodCallHandler(channel, (_) async => 'thread-42');
      expect(await const AppShortcutsChannel().initialRequest(), (shortcut: const PinnedThread(42), external: false));
      // The icon's shortcut only: a pinned one is none of them.
      expect(await const AppShortcutsChannel().initial(), isNull);

      const shortcuts = AppShortcutsChannel();
      final got = <AppShortcutRequest>[];
      shortcuts.listenRequests(got.add);
      addTearDown(shortcuts.dispose);
      const codec = StandardMethodCodec();
      for (final value in ['forum-12', 'tsdm://shortcut/forum-12', 'forum-0']) {
        await messenger.handlePlatformMessage(
          AppShortcutsChannel.name,
          codec.encodeMethodCall(MethodCall(AppShortcutsChannel.onShortcut, value)),
          (_) {},
        );
      }
      expect(got, [
        (shortcut: const PinnedForum(12), external: false),
        (shortcut: const PinnedForum(12), external: true),
      ]);
    });

    test('whether the launcher pins', () async {
      for (final (answer, supported) in [(true, true), (false, false), (null, false)]) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, AppShortcutsChannel.isPinShortcutSupported);
          return answer;
        });
        expect(await const AppShortcutsChannel().pinSupported(), supported);
      }
      messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'x'));
      expect(await const AppShortcutsChannel().pinSupported(), isFalse);
      messenger.setMockMethodCallHandler(channel, null);
      expect(await const AppShortcutsChannel().pinSupported(), isFalse);
    });

    test('the request carries the id and the labels, and tells what came of it', () async {
      final calls = <MethodCall>[];
      for (final (answer, result) in [
        ('requested', PinShortcutResult.requested),
        ('updated', PinShortcutResult.updated),
        (null, PinShortcutResult.failed),
        ('something else', PinShortcutResult.failed),
      ]) {
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return answer;
        });
        expect(
          await const AppShortcutsChannel().requestPin(const PinnedThread(42), shortLabel: 'short', longLabel: 'long'),
          result,
        );
      }
      expect(calls.first.method, AppShortcutsChannel.requestPinShortcut);
      expect(calls.first.arguments, {'id': 'thread-42', 'shortLabel': 'short', 'longLabel': 'long'});
      messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'x'));
      expect(
        await const AppShortcutsChannel().requestPin(const PinnedForum(1), shortLabel: 'a', longLabel: 'a'),
        PinShortcutResult.failed,
      );
      messenger.setMockMethodCallHandler(channel, null);
      expect(
        await const AppShortcutsChannel().requestPin(const PinnedForum(1), shortLabel: 'a', longLabel: 'a'),
        PinShortcutResult.failed,
      );
    });

    test('asked on Android only', () async {
      var asked = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        asked++;
        return true;
      });
      addTearDown(() => PinToHome.supported.value = false);
      await PinToHome.refresh(android: true);
      expect(PinToHome.supported.value, isTrue);
      await PinToHome.refresh(android: false);
      expect(PinToHome.supported.value, isFalse);
      expect(asked, 1);
    });
  });

  test('the labels', () {
    expect(pinnedShortcutLabels(''), isNull);
    expect(pinnedShortcutLabels(' \n\t '), isNull);
    expect(pinnedShortcutLabels('  动漫\n 讨论  '), (short: '动漫 讨论', long: '动漫 讨论'));
    expect(pinnedShortcutLabels('一二三四五六七八九十'), (short: '一二三四五六七八九十', long: '一二三四五六七八九十'));
    final long = pinnedShortcutLabels('一二三四五六七八九十甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉')!;
    expect(long.short, '一二三四五六七八九…');
    expect(long.long, '一二三四五六七八九十甲乙丙丁戊己庚辛壬癸子丑寅卯…');
    // A character the user sees as one is never cut apart.
    final family = '👨‍👩‍👧‍👦' * 12;
    expect(pinnedShortcutLabels(family)!.short, '${'👨‍👩‍👧‍👦' * 9}…');
  });

  group('menu item', () {
    const channel = MethodChannel(AppShortcutsChannel.name);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      PinToHome.supported.value = false;
    });

    Future<BuildContext> pumpPage(WidgetTester tester) async {
      late BuildContext page;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            scaffoldMessengerKey: snackbarKey,
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  page = context;
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      return page;
    }

    testWidgets('offered while the launcher pins, for a page with an id and a title', (tester) async {
      final page = await pumpPage(tester);
      PinToHome.supported.value = false;
      expect(pinToHomeMenuItem(page, const PinnedThread(42), 'title'), isNull);
      PinToHome.supported.value = true;
      expect(pinToHomeMenuItem(page, null, 'title'), isNull);
      expect(pinToHomeMenuItem(page, const PinnedThread(42), null), isNull);
      expect(pinToHomeMenuItem(page, const PinnedThread(42), '  '), isNull);
      final item = pinToHomeMenuItem(page, const PinnedThread(42), 'title');
      expect(item?.description, '添加到桌面');
      expect(item?.icon, Icons.add_to_home_screen_outlined);
    });

    testWidgets('told when pinned already or refused, not when the launcher asks', (tester) async {
      final page = await pumpPage(tester);
      PinToHome.supported.value = true;
      String? answer;
      final requests = <Object?>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        requests.add(call.arguments);
        return answer;
      });
      final item = pinToHomeMenuItem(page, const PinnedForum(12), '  动漫\n讨论区  ')!;

      answer = 'requested';
      await item.onSelected();
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
      expect(requests.single, {'id': 'forum-12', 'shortLabel': '动漫 讨论区', 'longLabel': '动漫 讨论区'});

      answer = 'updated';
      await item.onSelected();
      await tester.pump();
      expect(find.text('已更新桌面图标'), findsOneWidget);

      answer = null;
      await item.onSelected();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('无法添加到桌面'), findsOneWidget);
    });
  });

  group('Android', () {
    String read(String path) => File(path).readAsStringSync();
    const kotlin = 'android/app/src/main/kotlin/kzs/th000/tsdm_client';

    test('the shortcut starts the activity that is not exported, without the key', () {
      final pins = read('$kotlin/PinnedShortcuts.kt');
      expect(pins, contains('.setClass(context, ShortcutActivity::class.java)'));
      expect(pins, contains(r'.setData(Uri.parse("tsdm://shortcut/$id"))'));
      expect(pins, isNot(contains('ShortcutKey.')));
      expect(pins, isNot(contains('MainActivityImpl::class')));
      expect(pins, contains('sdk >= Build.VERSION_CODES.O && ShortcutManagerCompat.isRequestPinShortcutSupported'));
      final manifest = read('android/app/src/main/AndroidManifest.xml');
      final entry = RegExp(r'<activity\s+android:name="\.ShortcutActivity"[^>]*>').firstMatch(manifest)?.group(0);
      expect(entry, contains('android:exported="false"'));
    });

    test('the activity hands the pinning calls over, on the shortcuts channel', () {
      expect(read('$kotlin/MainActivity.kt'), contains('pins = PinnedShortcuts(this)'));
      expect(read('$kotlin/ShortcutsHandler.kt'), contains('pins == null || !pins.handle(call, result)'));
    });

    test('two icons, the adaptive one for Android 8 and a fallback', () {
      for (final name in ['forum', 'thread']) {
        expect(read('android/app/src/main/res/drawable-anydpi-v26/ic_shortcut_$name.xml'), contains('<adaptive-icon'));
        expect(read('android/app/src/main/res/drawable/ic_shortcut_$name.xml'), contains('<vector'));
        expect(read('android/app/src/main/res/drawable/ic_shortcut_${name}_foreground.xml'), contains('<vector'));
      }
    });

    test('the Kotlin tests run in the Test build', () {
      final workflow = read('.github/workflows/test_build.yml');
      expect(workflow, contains('--tests kzs.th000.tsdm_client.PinnedShortcutsTest'));
      expect(workflow, contains('--tests kzs.th000.tsdm_client.AppIconSwitcherTest'));
    });

    // Pinned already: only updated, the launcher is not asked again (Pixel Launcher would add a second icon). Switching
    // the app icon moves the pinned shortcuts to the new alias before the old one is disabled.
    test('pinning again only updates; the icon switch moves the pinned shortcuts first', () {
      final pins = read('$kotlin/PinnedShortcuts.kt');
      expect(
        pins,
        contains('id in pinnedIds() -> if (ShortcutManagerCompat.updateShortcuts(context, listOf(info))) UPDATED'),
      );
      final switcher = read('$kotlin/AppIconSwitcher.kt');
      final enable = switcher.indexOf('setEnabled(context, manager, chosen, true)');
      final move = switcher.indexOf('moveShortcuts(ComponentName(context,');
      final disable = switcher.indexOf('if (alias != chosen) setEnabled(context, manager, alias, false)');
      expect(enable, greaterThan(0));
      expect(move, greaterThan(enable));
      expect(disable, greaterThan(move));
      expect(switcher, contains('moveShortcuts: (ComponentName) -> Unit = { PinnedShortcuts.moveTo(context, it) }'));
    });

    test('the forum and the thread pages offer it', () {
      expect(
        read('lib/features/forum/view/forum_page.dart'),
        contains('?pinToHomeMenuItem(context, PinnedForum.tryParse(widget.fid), state.title ?? widget.title)'),
      );
      expect(
        read('lib/features/thread/v1/view/thread_page.dart'),
        contains('?pinToHomeMenuItem(context, PinnedThread.tryParse(state.tid), state.title ?? widget.title)'),
      );
    });
  });
}
