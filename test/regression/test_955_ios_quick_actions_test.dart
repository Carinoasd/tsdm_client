/// The quick actions of a long press on the iOS app icon: the same four shortcuts as Android's (check in, messages,
/// favorites, search), whose type is the `tsdm://shortcut/<id>` link the widget opens; `HomeWidgetBridge` hands it to
/// Dart over the shortcuts channel, which then does what an Android shortcut does.
///
/// 1. Info.plist: the four items in Android's order, each typed by its link and with a system symbol as its icon;
/// 2. their titles in English, Simplified and Traditional Chinese (`InfoPlist.strings`), the words of Android's;
/// 3. the strings files are resources of the app target only, the project knows both Chinese regions;
/// 4. the bridge takes the item of a cold start (scene connection) and the one of an app already running
///    (`performActionFor`), by the selectors of the Flutter headers;
/// 5. Dart: the link of a cold start and the link while the app runs both reach the shortcut, and each of the four
///    leads where the Android shortcut does, with and without an account.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/local_notice/tap.dart';
import 'package:tsdm_client/features/shortcuts/models/app_shortcut.dart';
import 'package:tsdm_client/features/shortcuts/repository/app_shortcuts_channel.dart';
import 'package:tsdm_client/features/shortcuts/utils/app_shortcut_action.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  String read(String path) => File(path).readAsStringSync();

  /// The `<dict>`s of `UIApplicationShortcutItems`, each as key to string.
  List<Map<String, String>> quickActions() {
    final info = read('ios/Runner/Info.plist');
    final array = RegExp(
      r'<key>UIApplicationShortcutItems</key>\s*<array>(.*?)</array>',
      dotAll: true,
    ).firstMatch(info)!.group(1)!;
    return [
      for (final dict in RegExp('<dict>(.*?)</dict>', dotAll: true).allMatches(array))
        {
          for (final pair in RegExp(r'<key>([^<]+)</key>\s*<string>([^<]*)</string>').allMatches(dict.group(1)!))
            pair.group(1)!: pair.group(2)!,
        },
    ];
  }

  /// The `"key" = "value";` pairs of a strings file.
  Map<String, String> strings(String path) => {
    for (final m in RegExp(r'^"([^"]+)"\s*=\s*"([^"]*)";', multiLine: true).allMatches(read(path)))
      m.group(1)!: m.group(2)!,
  };

  /// The shortcut labels of an Android `strings.xml`, by id.
  Map<String, String> androidLabels(String values) => {
    for (final m in RegExp(
      r'<string name="shortcut_(\w+)">([^<]+)</string>',
    ).allMatches(read('android/app/src/main/res/$values/strings.xml')))
      m.group(1)!: m.group(2)!,
  };

  group('Info.plist', () {
    test('the four shortcuts, typed by their link, with a system symbol', () {
      final items = quickActions();
      expect(items.map((e) => e['UIApplicationShortcutItemType']), AppShortcut.values.map((e) => e.link));
      for (final item in items) {
        expect(AppShortcut.fromLink(item['UIApplicationShortcutItemType']), isNotNull);
        expect(item['UIApplicationShortcutItemTitle'], isNotEmpty);
        // SF Symbols of iOS 13 (the deployment target): no image of our own.
        expect(
          item['UIApplicationShortcutItemIconSymbolName'],
          isIn(['checkmark.circle', 'bell', 'star', 'magnifyingglass']),
        );
        expect(item.containsKey('UIApplicationShortcutItemIconFile'), isFalse);
      }
      // Still opened by the scheme the widget uses.
      expect(read('ios/Runner/Info.plist'), contains('<string>${AppShortcut.linkScheme}</string>'));
    });

    test('the titles in three languages, the words of the Android shortcuts', () {
      final items = quickActions();
      final ids = [for (final item in items) AppShortcut.fromLink(item['UIApplicationShortcutItemType'])!.id];
      final titles = [for (final item in items) item['UIApplicationShortcutItemTitle']!];
      for (final (lproj, values) in [('en', 'values-en'), ('zh-Hans', 'values'), ('zh-Hant', 'values-zh-rTW')]) {
        final table = strings('ios/Runner/$lproj.lproj/InfoPlist.strings');
        final android = androidLabels(values);
        expect(table.keys.toSet(), titles.toSet(), reason: lproj);
        for (final (i, title) in titles.indexed) {
          expect(table[title], android[ids[i]], reason: '$lproj ${ids[i]}');
        }
      }
      // A failed lookup shows the title of Info.plist itself: readable English.
      expect(titles, strings('ios/Runner/en.lproj/InfoPlist.strings').values);
    });

    test('the strings files are resources of the app only', () {
      final project = read('ios/Runner.xcodeproj/project.pbxproj');
      final variant = RegExp(
        r'(\w{24}) /\* InfoPlist\.strings \*/ = \{\s*isa = PBXVariantGroup;(.*?)\};',
        dotAll: true,
      ).firstMatch(project)!;
      for (final lproj in ['en', 'zh-Hans', 'zh-Hant']) {
        expect(
          project,
          anyOf(
            contains('path = $lproj.lproj/InfoPlist.strings;'),
            contains('path = "$lproj.lproj/InfoPlist.strings";'),
          ),
        );
        expect(variant.group(2), contains('/* $lproj */'));
      }
      final buildFile = RegExp(
        r'(\w{24}) /\* InfoPlist\.strings in Resources \*/ = \{isa = PBXBuildFile; fileRef = (\w{24})',
      ).allMatches(project).toList();
      expect(buildFile, hasLength(1));
      expect(buildFile.single.group(2), variant.group(1));
      final phases = RegExp(
        r'(\w{24}) /\* Resources \*/ = \{\s*isa = PBXResourcesBuildPhase;(.*?)\};',
        dotAll: true,
      ).allMatches(project).toList();
      final withStrings = phases.where((p) => p.group(2)!.contains(buildFile.single.group(1)!)).toList();
      expect(withStrings, hasLength(1));
      // The phase of the app target (the one with its storyboards), not the widget's nor the tests'.
      expect(withStrings.single.group(2), contains('Main.storyboard in Resources'));
      final regions = RegExp(r'knownRegions = \((.*?)\);', dotAll: true).firstMatch(project)!.group(1)!;
      expect(regions, allOf(contains('"zh-Hans"'), contains('"zh-Hant"'), contains('en')));
    });
  });

  group('HomeWidgetBridge', () {
    final bridge = read('ios/Runner/HomeWidgetBridge.swift');

    test('takes the quick action of a cold start and of a running app, by the selectors of the headers', () {
      for (final selector in [
        'scene:willConnectToSession:options:',
        'windowScene:performActionForShortcutItem:completionHandler:',
        'application:performActionForShortcutItem:completionHandler:',
      ]) {
        expect(bridge, contains('@objc($selector)'));
      }
      expect(bridge, contains('options.shortcutItem'));
      // The type is the link, handed over as a link is.
      expect(bridge, contains('URL(string: item.type)'));
      // Not taken, the handler is left to Flutter, which hands it on to the app delegate.
      expect(bridge, contains('guard open(shortcutItem) else { return false }'));
      // AppDelegate is not touched: the bridge registers as it did.
      expect(read('ios/Runner/AppDelegate.swift'), isNot(contains('shortcutItem')));
    });

    test('the Flutter headers declare the selectors', () {
      final flutter = Platform.environment['FLUTTER_ROOT'] ?? '';
      final header = File(
        '$flutter/engine/src/flutter/shell/platform/darwin/ios/framework/Headers/FlutterSceneLifeCycle.h',
      );
      if (flutter.isEmpty || !header.existsSync()) {
        markTestSkipped('no Flutter engine sources here');
        return;
      }
      final text = header.readAsStringSync().replaceAll(RegExp(r'\s+'), ' ');
      expect(text, contains('(BOOL)windowScene:(UIWindowScene*)windowScene performActionForShortcutItem:'));
    });
  });

  group('the shortcuts channel', () {
    const channel = MethodChannel(AppShortcutsChannel.name);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? initialLink;

    setUp(() {
      initialLink = null;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == AppShortcutsChannel.getInitialShortcut) {
          final link = initialLink;
          initialLink = null;
          return link;
        }
        throw MissingPluginException();
      });
    });
    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    Future<void> opened(String link) async {
      final done = Completer<ByteData?>();
      await messenger.handlePlatformMessage(
        AppShortcutsChannel.name,
        channel.codec.encodeMethodCall(MethodCall(AppShortcutsChannel.onShortcut, link)),
        done.complete,
      );
      await done.future;
    }

    test('a cold start from each quick action', () async {
      const shortcuts = AppShortcutsChannel();
      for (final item in quickActions()) {
        final link = item['UIApplicationShortcutItemType'];
        initialLink = link;
        expect(await shortcuts.initial(), AppShortcut.fromLink(link));
      }
      expect(await shortcuts.initial(), isNull);
    });

    test('each quick action while the app runs', () async {
      const shortcuts = AppShortcutsChannel();
      final got = <AppShortcut>[];
      shortcuts.listen(got.add);
      addTearDown(shortcuts.dispose);
      for (final item in quickActions()) {
        await opened(item['UIApplicationShortcutItemType']!);
      }
      expect(got, AppShortcut.values);
    });
  });

  group('where each quick action leads', () {
    late GoRouter router;
    late int checkins;

    Future<void> pump(WidgetTester tester) async {
      checkins = 0;
      router = GoRouter(
        initialLocation: ScreenPaths.homepage,
        routes: [
          StatefulShellRoute.indexedStack(
            builder: (_, _, navigator) => navigator,
            branches: [
              StatefulShellBranch(
                routes: [
                  GoRoute(
                    path: ScreenPaths.homepage,
                    name: ScreenPaths.homepage,
                    builder: (_, _) => const Text('home'),
                  ),
                ],
              ),
              StatefulShellBranch(
                routes: [
                  GoRoute(path: ScreenPaths.notice, name: ScreenPaths.notice, builder: (_, _) => const Text('notice')),
                ],
              ),
            ],
          ),
          GoRoute(path: ScreenPaths.rootNotice, name: ScreenPaths.rootNotice, builder: (_, _) => const Text('notice')),
          GoRoute(path: ScreenPaths.login, name: ScreenPaths.login, builder: (_, _) => const Text('login')),
          GoRoute(path: ScreenPaths.search, name: ScreenPaths.search, builder: (_, _) => const Text('search')),
          GoRoute(path: ScreenPaths.favorite, name: ScreenPaths.favorite, builder: (_, _) => const Text('favorite')),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
    }

    Future<void> open(WidgetTester tester, String link, {required bool loggedIn}) async {
      final shortcut = AppShortcut.fromIdOrLink(link)!;
      performAppShortcut(
        router,
        decideAppShortcut(shortcut, loggedIn: loggedIn),
        hasPopup: false,
        checkin: () => checkins++,
      );
      await tester.pumpAndSettle();
    }

    for (final (id, location, checkedIn) in [
      ('checkin', ScreenPaths.homepage, 1),
      ('notice', ScreenPaths.notice, 0),
      ('favorite', ScreenPaths.favorite, 0),
      ('search', ScreenPaths.search, 0),
    ]) {
      testWidgets('$id with an account', (tester) async {
        await pump(tester);
        await open(tester, 'tsdm://shortcut/$id', loggedIn: true);
        expect(routerTopLocation(router), location);
        expect(checkins, checkedIn);
      });

      testWidgets('$id without an account', (tester) async {
        await pump(tester);
        await open(tester, 'tsdm://shortcut/$id', loggedIn: false);
        expect(routerTopLocation(router), id == 'search' ? ScreenPaths.search : ScreenPaths.login);
        expect(checkins, 0);
      });
    }
  });
}
