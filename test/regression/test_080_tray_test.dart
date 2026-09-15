import 'dart:async';
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
import 'package:tsdm_client/utils/tray_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late TrayHelper helper;
  late GoRouter appRouter;
  late PopupRouteObserver popupObserver;
  const trayChannel = MethodChannel('tray_manager');
  const windowChannel = MethodChannel('window_manager');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  late AppDatabase db;
  late SettingsRepository settings;
  late Directory temp;
  late List<MethodCall> trayCalls;
  late List<String> windowCalls;
  late Translations traditionalChinese;
  var minimized = true;
  var shutdownCalls = 0;
  bool? listenersAtShutdown;
  Completer<void>? pendingShutdown;
  Completer<void>? pendingDestroy;
  Completer<void>? pendingFocus;
  String? failMethod;

  List<String> menuLabels() {
    final menuCall = trayCalls.lastWhere((call) => call.method == 'setContextMenu');
    final arguments = menuCall.arguments as Map<Object?, Object?>;
    final menu = arguments['menu']! as Map<Object?, Object?>;
    final items = menu['items']! as List<Object?>;
    return items.map((item) => (item! as Map<Object?, Object?>)['label']).whereType<String>().toList();
  }

  Future<void> settleCallbacks() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('tsdm_tray_test_');
    db = AppDatabase(NativeDatabase.memory());
    settings = SettingsRepository(StorageProvider(db, {}, {}));
    await settings.init();
    getIt.registerSingleton<SettingsRepository>(settings);
    await LocaleSettings.setLocale(AppLocale.en);
    traditionalChinese = await AppLocale.zhTw.build();
    minimized = true;
    failMethod = null;
    shutdownCalls = 0;
    listenersAtShutdown = null;
    pendingShutdown = null;
    pendingDestroy = null;
    pendingFocus = null;
    trayCalls = [];
    windowCalls = [];
    popupObserver = PopupRouteObserver();
    appRouter = GoRouter(
      observers: [popupObserver],
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
    helper = TrayHelper.forTesting(
      appRouter: appRouter,
      popupObserver: popupObserver,
      shutdown: () async {
        shutdownCalls++;
        listenersAtShutdown = trayManager.hasListeners;
        await pendingShutdown?.future;
      },
    );
    messenger
      ..setMockMethodCallHandler(pathChannel, (_) async => temp.path)
      ..setMockMethodCallHandler(trayChannel, (call) async {
        trayCalls.add(call);
        if (call.method == failMethod) {
          throw PlatformException(code: 'test_failure');
        }
        if (call.method == 'destroy') await pendingDestroy?.future;
        return true;
      })
      ..setMockMethodCallHandler(windowChannel, (call) async {
        windowCalls.add(call.method);
        if (call.method == 'restore') minimized = false;
        if (call.method == 'focus') await pendingFocus?.future;
        return call.method == 'isMinimized' ? minimized : null;
      });
  });

  tearDown(() async {
    await helper.dispose();
    appRouter.dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
    for (final channel in [trayChannel, windowChannel, pathChannel]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    final icon = File('${temp.path}/tsdm_tray.ico');
    if (icon.existsSync()) {
      await icon.delete();
    }
    await temp.delete();
  });

  test('failure before creating an icon only removes the listener, and can be retried', () async {
    messenger.setMockMethodCallHandler(pathChannel, (_) async => throw MissingPluginException('path unavailable'));
    await expectLater(helper.init(), throwsA(isA<MissingPluginException>()));
    expect(trayCalls, isEmpty, reason: 'there is no native icon to destroy');
    expect(trayManager.hasListeners, isFalse);

    messenger.setMockMethodCallHandler(pathChannel, (_) async => temp.path);
    await helper.init();
    expect(trayCalls.where((call) => call.method == 'setIcon'), hasLength(1));
  });

  test('failed initialization removes listeners and icon, and can be retried', () async {
    failMethod = 'setContextMenu';
    await expectLater(helper.init(), throwsA(isA<PlatformException>()));
    expect(trayManager.hasListeners, isFalse);
    expect(trayCalls.last.method, 'destroy');

    final beforeUpdate = trayCalls.length;
    helper.updateTranslations(traditionalChinese);
    await settleCallbacks();
    expect(trayCalls.length, beforeUpdate, reason: 'a failed tray must ignore UI rebuilds');

    failMethod = null;
    await helper.init();
    expect(trayManager.hasListeners, isTrue);
    expect(menuLabels(), contains('👥 管理帳戶'));
  });

  test('concurrent initialization creates one icon and replaces stale cached bytes', () async {
    final icon = File('${temp.path}/tsdm_tray.ico');
    await icon.writeAsString('old icon');
    await Future.wait([helper.init(), helper.init()]);
    expect(trayCalls.where((call) => call.method == 'setIcon'), hasLength(1));
    final bundled = await rootBundle.load('assets/images/app_icon.ico');
    expect(await icon.readAsBytes(), bundled.buffer.asUint8List(bundled.offsetInBytes, bundled.lengthInBytes));
  });

  test('UI translations update before settings are saved, and account changes use the same language', () async {
    await helper.init();
    expect(menuLabels(), contains('📖 History'));
    helper.updateTranslations(traditionalChinese);
    await settleCallbacks();
    expect(menuLabels(), contains('📖 歷史'));

    await settings.setValue(SettingsKeys.loginUsername, 'Alice');
    await settleCallbacks();
    expect(menuLabels(), contains('👤 使用者：Alice'));

    final count = trayCalls.length;
    helper.updateTranslations(traditionalChinese);
    await settleCallbacks();
    expect(trayCalls.length, count, reason: 'an unrelated UI rebuild must not replace the native menu');
  });

  test('native menu update errors are contained and a later update succeeds', () async {
    await helper.init();
    failMethod = 'setContextMenu';
    helper.updateTranslations(traditionalChinese);
    await settleCallbacks();
    failMethod = null;
    helper.updateTranslations(AppLocale.en.translations);
    await settleCallbacks();
    expect(menuLabels(), contains('📖 History'));
  });

  test('right click activates the native menu owner without blurring the app', () async {
    await helper.init();
    helper.onTrayIconRightMouseDown();
    await settleCallbacks();
    final popup = trayCalls.lastWhere((call) => call.method == 'popUpContextMenu');
    expect((popup.arguments as Map)['bringAppToFront'], isTrue);
    expect(windowCalls, isEmpty);
  });

  test('left click restores a minimized window before showing and focusing it', () async {
    await helper.init();
    helper.onTrayIconMouseDown();
    await settleCallbacks();
    expect(windowCalls.where((method) => method != 'isMinimized'), ['restore', 'show', 'focus']);
  });

  test('disposal stops settings and language updates', () async {
    await helper.init();
    await helper.dispose();
    final count = trayCalls.length;
    await settings.setValue(SettingsKeys.loginUsername, 'Bob');
    helper.updateTranslations(traditionalChinese);
    await settleCallbacks();
    expect(trayCalls.length, count);
    expect(trayManager.hasListeners, isFalse);
  });

  testWidgets('a blocking logout dialog keeps tray navigation and exit from bypassing it', (tester) async {
    await tester.runAsync(helper.init);
    await tester.pumpWidget(MaterialApp.router(routerConfig: appRouter));
    await tester.pumpAndSettle();
    final context = tester.element(find.text('home'));
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const PopScope(canPop: false, child: AlertDialog(content: Text('logging out'))),
      ),
    );
    await tester.pumpAndSettle();

    for (final action in ['history', 'favorite', 'manageAccount', 'exit']) {
      helper.onTrayMenuItemClick(MenuItem(key: action));
      await tester.pumpAndSettle();
      expect(find.text('logging out'), findsOneWidget);
      expect(appRouter.routerDelegate.currentConfiguration.matches, hasLength(1));
    }
    expect(windowCalls, contains('focus'), reason: 'the user should see the dialog already in progress');
    expect(shutdownCalls, 0);

    // The existing logout completion now pops only its own dialog.
    navigator.pop();
    await tester.pumpAndSettle();
    expect(find.text('logging out'), findsNothing);
    expect(find.text('home'), findsOneWidget);
    helper.onTrayMenuItemClick(MenuItem(key: 'manageAccount'));
    await tester.pumpAndSettle();
    expect(find.text(ScreenPaths.manageAccount), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a dialog appearing while the window is being restored still blocks navigation', (tester) async {
    await tester.runAsync(helper.init);
    await tester.pumpWidget(MaterialApp.router(routerConfig: appRouter));
    await tester.pumpAndSettle();
    pendingFocus = Completer<void>();
    helper.onTrayMenuItemClick(MenuItem(key: 'history'));
    await tester.pumpAndSettle();
    expect(windowCalls, contains('focus'));
    final context = tester.element(find.text('home'));
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(content: Text('please wait')),
      ),
    );
    await tester.pumpAndSettle();
    pendingFocus!.complete();
    await tester.pumpAndSettle();
    expect(find.text('please wait'), findsOneWidget);
    expect(appRouter.routerDelegate.currentConfiguration.matches, hasLength(1));
    navigator.pop();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('exit removes the tray before calling shared shutdown and ignores further actions while closing', () async {
    await helper.init();
    pendingDestroy = Completer<void>();
    pendingShutdown = Completer<void>();
    helper.onTrayMenuItemClick(MenuItem(key: 'exit'));
    await settleCallbacks();
    expect(shutdownCalls, 0, reason: 'shared shutdown must wait for native tray cleanup');
    expect(trayCalls.last.method, 'destroy');
    helper
      ..onTrayMenuItemClick(MenuItem(key: 'exit'))
      ..onTrayMenuItemClick(MenuItem(key: 'manageAccount'));
    await settleCallbacks();
    expect(shutdownCalls, 0);
    pendingDestroy!.complete();
    await settleCallbacks();
    expect(shutdownCalls, 1);
    expect(listenersAtShutdown, isFalse);
    helper.onTrayMenuItemClick(MenuItem(key: 'exit'));
    await settleCallbacks();
    expect(shutdownCalls, 1);
    expect(windowCalls, isEmpty);
    pendingShutdown!.complete();
    await settleCallbacks();
  });

  testWidgets('shutdown while a window restore is pending cancels the late navigation', (tester) async {
    await tester.runAsync(helper.init);
    await tester.pumpWidget(MaterialApp.router(routerConfig: appRouter));
    await tester.pumpAndSettle();
    pendingFocus = Completer<void>();
    helper.onTrayMenuItemClick(MenuItem(key: 'favorite'));
    await tester.pumpAndSettle();
    expect(windowCalls, contains('focus'));
    await tester.runAsync(helper.dispose);
    pendingFocus!.complete();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
    expect(appRouter.routerDelegate.currentConfiguration.matches, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('selecting the page already on top brings the window forward without stacking it again', (tester) async {
    await tester.runAsync(helper.init);
    await tester.pumpWidget(MaterialApp.router(routerConfig: appRouter));
    await tester.pumpAndSettle();
    helper.onTrayMenuItemClick(MenuItem(key: 'history'));
    await tester.pumpAndSettle();
    expect(find.text(ScreenPaths.threadVisitHistory), findsOneWidget);
    expect(appRouter.routerDelegate.currentConfiguration.matches, hasLength(2));

    final focusCount = windowCalls.where((method) => method == 'focus').length;
    helper.onTrayMenuItemClick(MenuItem(key: 'history'));
    await tester.pumpAndSettle();
    expect(
      appRouter.routerDelegate.currentConfiguration.matches,
      hasLength(2),
      reason: 'the same page must not be stacked twice',
    );
    expect(
      windowCalls.where((method) => method == 'focus').length,
      focusCount + 1,
      reason: 'the window is still restored and focused',
    );

    // A different page still opens on top of it.
    helper.onTrayMenuItemClick(MenuItem(key: 'favorite'));
    await tester.pumpAndSettle();
    expect(find.text(ScreenPaths.favorite), findsOneWidget);
    expect(appRouter.routerDelegate.currentConfiguration.matches, hasLength(3));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
