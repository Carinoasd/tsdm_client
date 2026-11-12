import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/popup_route_observer.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/close_to_tray.dart';
import 'package:tsdm_client/utils/desktop_tray_policy.dart';
import 'package:tsdm_client/utils/tray_helper.dart';

/// Windows: closing the window into the tray; macOS and Linux: the tray icon. Every switch is off by default and,
/// while off, nothing differs from before: the close button is never taken over, the Windows menu is the old one.
void main() {
  group('policy', () {
    test('the tray is always up on Windows, behind its switch on macOS and Linux, absent elsewhere', () {
      for (final setting in [false, true]) {
        expect(trayWanted(TrayPlatform.windows, trayIconSetting: setting), isTrue);
        expect(trayWanted(TrayPlatform.macOS, trayIconSetting: setting), setting);
        expect(trayWanted(TrayPlatform.linux, trayIconSetting: setting), setting);
        expect(trayWanted(TrayPlatform.other, trayIconSetting: setting), isFalse);
      }
      expect(TrayPlatform.windows.hasTrayIconSwitch, isFalse);
      expect(TrayPlatform.linux.hasCloseToTraySwitch, isFalse, reason: 'Linux has the icon only');
    });

    test('both switches are off by default', () {
      expect(SettingsKeys.desktopTrayIcon.defaultValue, isFalse);
      expect(SettingsKeys.closeToTray.defaultValue, isFalse);
    });

    test('the close button is only taken over with the switch on and the tray up', () {
      for (final platform in TrayPlatform.values) {
        expect(interceptsClose(platform, closeToTraySetting: false, trayRunning: true), isFalse);
        expect(interceptsClose(platform, closeToTraySetting: true, trayRunning: false), isFalse);
      }
      expect(interceptsClose(TrayPlatform.windows, closeToTraySetting: true, trayRunning: true), isTrue);
      expect(interceptsClose(TrayPlatform.macOS, closeToTraySetting: true, trayRunning: true), isTrue);
      expect(interceptsClose(TrayPlatform.linux, closeToTraySetting: true, trayRunning: true), isFalse);
      expect(interceptsClose(TrayPlatform.other, closeToTraySetting: true, trayRunning: true), isFalse);
    });

    test('a click on close is decided with the state of now', () {
      WindowCloseAction action({required bool intercepting, bool setting = true, bool tray = true}) => closeActionOf(
        TrayPlatform.windows,
        intercepting: intercepting,
        closeToTraySetting: setting,
        trayRunning: tray,
      );
      expect(action(intercepting: false), WindowCloseAction.native, reason: 'not taken over: the native close');
      expect(action(intercepting: false, setting: false), WindowCloseAction.native);
      expect(action(intercepting: true), WindowCloseAction.hide);
      expect(action(intercepting: true, setting: false), WindowCloseAction.quit, reason: 'switch just turned off');
      expect(action(intercepting: true, tray: false), WindowCloseAction.quit, reason: 'never hidden without an icon');
    });

    test('the Windows menu stays the old one while the window cannot be hidden', () {
      const old = [
        TrayMenuEntry.userInfo,
        TrayMenuEntry.separator,
        TrayMenuEntry.history,
        TrayMenuEntry.favorite,
        TrayMenuEntry.manageAccount,
        TrayMenuEntry.separator,
        TrayMenuEntry.exit,
      ];
      expect(trayMenuEntries(TrayPlatform.windows, closeToTraySetting: false), old);
      expect(trayMenuEntries(TrayPlatform.windows, closeToTraySetting: true), contains(TrayMenuEntry.showWindow));
      for (final platform in [TrayPlatform.macOS, TrayPlatform.linux]) {
        for (final setting in [false, true]) {
          final entries = trayMenuEntries(platform, closeToTraySetting: setting);
          expect(entries, containsAllInOrder([TrayMenuEntry.showWindow, TrayMenuEntry.exit]));
        }
      }
    });

    test('a failed start turns the macOS and Linux switch back off, Windows has none', () {
      for (final result in TrayStartResult.values) {
        expect(turnsTraySwitchOff(TrayPlatform.windows, result), isFalse);
        for (final platform in [TrayPlatform.macOS, TrayPlatform.linux]) {
          expect(turnsTraySwitchOff(platform, result), result != TrayStartResult.started);
        }
      }
    });

    test('Linux gets neither a tooltip nor a popped up menu, and asks for a tray host first', () {
      expect(TrayPlatform.linux.supportsToolTip, isFalse);
      expect(TrayPlatform.linux.popsUpMenu, isFalse);
      expect(TrayPlatform.linux.probesTrayHost, isTrue);
      expect(TrayPlatform.windows.probesTrayHost, isFalse);
      expect(TrayPlatform.macOS.probesTrayHost, isFalse);
    });
  });

  group('tray and close button', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const trayChannel = MethodChannel('tray_manager');
    const windowChannel = MethodChannel('window_manager');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    late AppDatabase db;
    late SettingsRepository settings;
    late Directory temp;
    late List<MethodCall> trayCalls;
    late List<String> windowCalls;
    late List<bool> preventCloseCalls;
    late int shutdownCalls;
    late int hideCalls;
    late bool failPreventClose;
    late bool failHide;
    late GoRouter appRouter;
    final helpers = <TrayHelper>[];
    final closers = <CloseToTray>[];

    TrayHelper newTray({TrayPlatform platform = TrayPlatform.windows, bool hostAvailable = true}) {
      final helper = TrayHelper.forTesting(
        appRouter: appRouter,
        popupObserver: PopupRouteObserver(),
        shutdown: () async => shutdownCalls++,
        platform: platform,
        trayHostAvailable: () async => hostAvailable,
      );
      helpers.add(helper);
      return helper;
    }

    CloseToTray newCloser(TrayHelper tray, {TrayPlatform platform = TrayPlatform.windows}) {
      final closer = CloseToTray.forTesting(
        platform: platform,
        tray: tray,
        setPreventClose: ({required prevent}) async {
          if (failPreventClose) throw PlatformException(code: 'test_failure');
          preventCloseCalls.add(prevent);
        },
        hide: () async {
          if (failHide) throw PlatformException(code: 'test_failure');
          hideCalls++;
        },
      );
      closers.add(closer);
      return closer;
    }

    List<String> menuLabels() {
      final menuCall = trayCalls.lastWhere((call) => call.method == 'setContextMenu');
      final menu = (menuCall.arguments as Map<Object?, Object?>)['menu']! as Map<Object?, Object?>;
      final items = menu['items']! as List<Object?>;
      return items.map((item) => (item! as Map<Object?, Object?>)['label']).whereType<String>().toList();
    }

    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('tsdm_close_to_tray_test_');
      db = AppDatabase(NativeDatabase.memory());
      settings = SettingsRepository(StorageProvider(db, {}, {}));
      await settings.init();
      getIt.registerSingleton<SettingsRepository>(settings);
      await LocaleSettings.setLocale(AppLocale.en);
      trayCalls = [];
      windowCalls = [];
      preventCloseCalls = [];
      shutdownCalls = 0;
      hideCalls = 0;
      failPreventClose = false;
      failHide = false;
      appRouter = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('home')),
          ),
          for (final path in [ScreenPaths.threadVisitHistory, ScreenPaths.favorite, ScreenPaths.manageAccount])
            GoRoute(
              path: path,
              name: path,
              builder: (_, _) => Scaffold(body: Text(path)),
            ),
        ],
      );
      messenger
        ..setMockMethodCallHandler(pathChannel, (_) async => temp.path)
        ..setMockMethodCallHandler(trayChannel, (call) async {
          trayCalls.add(call);
          return true;
        })
        ..setMockMethodCallHandler(windowChannel, (call) async {
          windowCalls.add(call.method);
          return call.method == 'isMinimized' ? false : null;
        });
    });

    tearDown(() async {
      for (final closer in closers) {
        await closer.dispose();
      }
      closers.clear();
      for (final helper in helpers) {
        await helper.dispose();
      }
      helpers.clear();
      appRouter.dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
      for (final channel in [trayChannel, windowChannel, pathChannel]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
      await temp.delete(recursive: true);
    });

    test('fresh settings hold both switches off', () {
      expect(settings.currentSettings.desktopTrayIcon, isFalse);
      expect(settings.currentSettings.closeToTray, isFalse);
    });

    test(
      'Windows with the switch off: the close button is never taken over and close does nothing in the app',
      () async {
        final tray = newTray();
        await tray.init();
        final closer = newCloser(tray)..start();
        await closer.apply();
        expect(preventCloseCalls, isEmpty, reason: 'nothing sent: the native close of before');
        await closer.handleClose();
        expect(hideCalls, 0);
        expect(shutdownCalls, 0);
        expect(menuLabels(), [
          '👤 User: Not logged in',
          '',
          '📖 History',
          '📁 Favorites',
          '👥 Manage accounts',
          '',
          '❌ Exit app',
        ], reason: 'the menu of before, separators included');
      },
    );

    test('Windows with the switch on: close hides, the menu gets "show window", and turning off quits again', () async {
      final tray = newTray();
      await tray.init();
      final closer = newCloser(tray)..start();
      await settings.setValue(SettingsKeys.closeToTray, true);
      await settle();
      await closer.apply();
      expect(preventCloseCalls, [true]);
      expect(closer.intercepting, isTrue);
      expect(menuLabels(), contains(AppLocale.en.translations.tray.showWindow));

      await closer.handleClose();
      expect(hideCalls, 1);
      expect(shutdownCalls, 0, reason: 'still running in the tray');

      windowCalls.clear();
      tray.onTrayMenuItemClick(MenuItem(key: 'showWindow'));
      await settle();
      expect(windowCalls, containsAllInOrder(['show', 'focus']));

      await settings.setValue(SettingsKeys.closeToTray, false);
      await settle();
      await closer.apply();
      expect(preventCloseCalls, [true, false]);
      await closer.handleClose();
      expect(hideCalls, 1);
      expect(shutdownCalls, 0, reason: 'the native close again');
      expect(menuLabels(), isNot(contains(AppLocale.en.translations.tray.showWindow)));
    });

    test('the switch on with no tray up keeps the native close, and takes over once the tray starts', () async {
      await settings.setValue(SettingsKeys.closeToTray, true);
      final tray = newTray();
      final closer = newCloser(tray)..start();
      await closer.apply();
      expect(preventCloseCalls, isEmpty);
      await closer.handleClose();
      expect(hideCalls, 0);

      await tray.init();
      await settle();
      await closer.apply();
      expect(preventCloseCalls, [true]);
    });

    test('the tray going away while hiding is on releases the close button', () async {
      await settings.setValue(SettingsKeys.closeToTray, true);
      final tray = newTray();
      await tray.init();
      final closer = newCloser(tray)..start();
      await closer.apply();
      await tray.dispose();
      await settle();
      await closer.apply();
      expect(preventCloseCalls, [true, false]);
    });

    test('a close still held natively but no longer wanted quits through the shared shutdown', () async {
      await settings.setValue(SettingsKeys.closeToTray, true);
      final tray = newTray();
      await tray.init();
      final closer = newCloser(tray)..start();
      await closer.apply();
      failPreventClose = true;
      await settings.setValue(SettingsKeys.closeToTray, false);
      await settle();
      await closer.apply();
      expect(closer.intercepting, isTrue, reason: 'releasing failed');
      await closer.handleClose();
      expect(hideCalls, 0);
      expect(shutdownCalls, 1);
      expect(trayCalls.last.method, 'destroy', reason: 'the icon goes before the shutdown');
    });

    test('a window that cannot be hidden is closed instead', () async {
      await settings.setValue(SettingsKeys.closeToTray, true);
      final tray = newTray();
      await tray.init();
      final closer = newCloser(tray)..start();
      await closer.apply();
      failHide = true;
      await closer.handleClose();
      expect(shutdownCalls, 1);
    });

    test('Linux never takes the close button over', () async {
      await settings.setValue(SettingsKeys.closeToTray, true);
      final tray = newTray(platform: TrayPlatform.linux);
      await tray.init();
      final closer = newCloser(tray, platform: TrayPlatform.linux)..start();
      await closer.apply();
      await closer.handleClose();
      expect(preventCloseCalls, isEmpty);
      expect(hideCalls + shutdownCalls, 0);
    });

    test('Linux without a tray host: nothing is created, the start reports it, and a later try can succeed', () async {
      final tray = newTray(platform: TrayPlatform.linux, hostAvailable: false);
      expect(await tray.start(), TrayStartResult.unavailable);
      expect(trayCalls, isEmpty);
      expect(trayManager.hasListeners, isFalse);
      expect(tray.running.value, isFalse);
      await expectLater(tray.init(), throwsA(isA<TrayUnavailableException>()));

      final later = newTray(platform: TrayPlatform.linux);
      expect(await later.start(), TrayStartResult.started);
      expect(later.running.value, isTrue);
    });

    test('Linux and macOS take the bundled PNG, Linux skips the tooltip and the popped up menu', () async {
      final linux = newTray(platform: TrayPlatform.linux);
      await linux.init();
      final setIcon = trayCalls.firstWhere((call) => call.method == 'setIcon');
      expect((setIcon.arguments as Map)['iconPath'], endsWith(trayIconAsset));
      expect(trayCalls.map((call) => call.method), isNot(contains('setToolTip')));
      expect(menuLabels(), contains(AppLocale.en.translations.tray.showWindow));
      linux.onTrayIconRightMouseDown();
      await settle();
      expect(trayCalls.map((call) => call.method), isNot(contains('popUpContextMenu')));
      await linux.dispose();

      trayCalls.clear();
      final macOS = newTray(platform: TrayPlatform.macOS);
      await macOS.init();
      expect(trayCalls.map((call) => call.method), containsAllInOrder(['setIcon', 'setToolTip', 'setContextMenu']));
      expect(menuLabels(), contains(AppLocale.en.translations.tray.showWindow));
    });

    test('"exit" in the menu still removes the icon and runs the shared shutdown', () async {
      final tray = newTray(platform: TrayPlatform.macOS);
      await tray.init();
      tray.onTrayMenuItemClick(MenuItem(key: 'exit'));
      await settle();
      expect(trayCalls.last.method, 'destroy');
      expect(shutdownCalls, 1);
      expect(tray.running.value, isFalse);
    });
  });
}
