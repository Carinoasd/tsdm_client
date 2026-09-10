import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/app.dart';
import 'package:tsdm_client/cmd.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/window_configs.dart';
import 'package:window_manager/window_manager.dart';

// WindowListener declares void callbacks; App implements them asynchronously.
Future<void> dispatch(void Function() callback) => (callback as Future<void> Function())();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late WindowListener listener;
  late List<MethodCall> calls;
  var maximized = false;
  var minimized = false;
  var fullScreen = false;
  var bounds = const Rect.fromLTWH(120, 90, 1000, 700);

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    parseCmdArgs([]);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    await settings.init();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings);
    calls = [];
    maximized = false;
    minimized = false;
    fullScreen = false;
    bounds = const Rect.fromLTWH(120, 90, 1000, 700);
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return switch (call.method) {
        'isMaximized' => maximized,
        'isMinimized' => minimized,
        'isFullScreen' => fullScreen,
        'getBounds' => {'x': bounds.left, 'y': bounds.top, 'width': bounds.width, 'height': bounds.height},
        _ => null,
      };
    });
    listener =
        const App(
              0,
              0,
              autoCheckin: false,
              autoSyncNoticeSeconds: 0,
              fontFamily: '',
              checkUpdate: false,
            ).createState()
            as WindowListener;
  });

  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  test('maximizing is remembered even without a resize event', () async {
    await dispatch(listener.onWindowMoved);
    maximized = true;
    await dispatch(listener.onWindowMaximize);
    expect(await storage.getBool('windowMaximized'), isTrue);
    // Reload from the database, as a fresh app launch does.
    await settings.init();
    expect(settings.currentSettings.windowMaximized, isTrue);
    calls.clear();
    await desktopRestoreWindowBounds(settings.currentSettings);
    expect(calls.map((call) => call.method), ['setBounds', 'setBounds', 'maximize']);
  });

  test('final drag events save the final normal size and position', () async {
    await dispatch(listener.onWindowMoved);
    await dispatch(listener.onWindowResized);
    expect(await storage.getOffset('windowPosition'), bounds.topLeft);
    expect(await storage.getSize('windowSize'), bounds.size);
    bounds = const Rect.fromLTWH(300, 220, 1200, 800);
    await dispatch(listener.onWindowMoved);
    await dispatch(listener.onWindowResized);
    expect(await storage.getOffset('windowPosition'), bounds.topLeft);
    expect(await storage.getSize('windowSize'), bounds.size);
  });

  test('maximizing preserves normal bounds for restoring down after restart', () async {
    final normalBounds = bounds;
    await dispatch(listener.onWindowMoved);
    await dispatch(listener.onWindowResized);
    maximized = true;
    bounds = const Rect.fromLTWH(-8, -8, 1936, 1056);
    await dispatch(listener.onWindowMaximize);
    await dispatch(listener.onWindowMoved);
    await dispatch(listener.onWindowResized);
    await settings.init();
    expect(settings.currentSettings.windowSize, normalBounds.size);
    expect(settings.currentSettings.windowPosition, normalBounds.topLeft);
    calls.clear();
    await desktopRestoreWindowBounds(settings.currentSettings);
    expect(calls[0].arguments, containsPair('width', normalBounds.width));
    expect(calls[1].arguments, containsPair('x', normalBounds.left));
    expect(calls.last.method, 'maximize');
  });

  test('restoring down clears the persisted maximized flag', () async {
    maximized = true;
    await dispatch(listener.onWindowMaximize);
    maximized = false;
    await dispatch(listener.onWindowUnmaximize);
    await settings.init();
    expect(settings.currentSettings.windowMaximized, isFalse);
    calls.clear();
    await desktopRestoreWindowBounds(settings.currentSettings);
    expect(calls.any((call) => call.method == 'maximize'), isFalse);
  });

  test('minimized and fullscreen bounds do not replace normal bounds', () async {
    await dispatch(listener.onWindowMoved);
    await dispatch(listener.onWindowResized);
    final normalBounds = bounds;
    bounds = const Rect.fromLTWH(-32000, -32000, 0, 0);
    minimized = true;
    await dispatch(listener.onWindowMoved);
    await dispatch(listener.onWindowResized);
    minimized = false;
    fullScreen = true;
    bounds = const Rect.fromLTWH(0, 0, 1920, 1080);
    await dispatch(listener.onWindowMoved);
    await dispatch(listener.onWindowResized);
    expect(await storage.getOffset('windowPosition'), normalBounds.topLeft);
    expect(await storage.getSize('windowSize'), normalBounds.size);
  });

  test('maximizing cancels pending normal-bounds debounce writes', () async {
    await dispatch(listener.onWindowMove);
    await dispatch(listener.onWindowResize);
    maximized = true;
    await dispatch(listener.onWindowMaximize);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(await storage.getOffset('windowPosition'), isNull);
    expect(await storage.getSize('windowSize'), isNull);
    expect(await storage.getBool('windowMaximized'), isTrue);
  });

  test('disabled remember options prevent saving and restoring bounds', () async {
    await settings.setValue(SettingsKeys.windowRememberSize, false);
    await settings.setValue(SettingsKeys.windowRememberPosition, false);
    await dispatch(listener.onWindowMoved);
    await dispatch(listener.onWindowResized);
    await dispatch(listener.onWindowMaximize);
    expect(await storage.getOffset('windowPosition'), isNull);
    expect(await storage.getSize('windowSize'), isNull);
    expect(await storage.getBool('windowMaximized'), isNull);
    calls.clear();
    await desktopRestoreWindowBounds(settings.currentSettings.copyWith(windowMaximized: true));
    expect(calls, isEmpty);
  });

  test('center option prevents recording position', () async {
    await settings.setValue(SettingsKeys.windowInCenter, true);
    await dispatch(listener.onWindowMoved);
    await dispatch(listener.onWindowResized);
    expect(await storage.getOffset('windowPosition'), isNull);
    expect(await storage.getSize('windowSize'), bounds.size);
  });

  test('centering uses the restored size before maximizing', () async {
    const screenChannel = MethodChannel('dev.leanflutter.plugins/screen_retriever');
    const display = {
      'id': 'primary',
      'size': {'width': 1920.0, 'height': 1080.0},
      'visiblePosition': {'dx': 0.0, 'dy': 0.0},
      'visibleSize': {'width': 1920.0, 'height': 1040.0},
    };
    messenger.setMockMethodCallHandler(
      screenChannel,
      (call) async => switch (call.method) {
        'getPrimaryDisplay' => display,
        'getAllDisplays' => {
          'displays': [display],
        },
        'getCursorScreenPoint' => {'dx': 100.0, 'dy': 100.0},
        _ => null,
      },
    );
    addTearDown(() => messenger.setMockMethodCallHandler(screenChannel, null));
    // Model the native size change, which center() reads back from the window.
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'setBounds') {
        final args = call.arguments as Map<Object?, Object?>;
        if (args.containsKey('width')) {
          bounds = Rect.fromLTWH(bounds.left, bounds.top, args['width']! as double, args['height']! as double);
        }
      }
      return call.method == 'getBounds'
          ? {'x': bounds.left, 'y': bounds.top, 'width': bounds.width, 'height': bounds.height}
          : null;
    });
    await desktopRestoreWindowBounds(
      settings.currentSettings.copyWith(windowInCenter: true, windowSize: const Size(1200, 800), windowMaximized: true),
    );
    expect(calls.map((call) => call.method), ['setBounds', 'getBounds', 'setBounds', 'maximize']);
    expect(calls[2].arguments, containsPair('x', 360.0));
    expect(calls[2].arguments, containsPair('y', 120.0));
  });

  test('zero is a valid saved position and legacy settings start unmaximized', () async {
    expect(settings.currentSettings.windowMaximized, isFalse);
    bounds = const Rect.fromLTWH(0, 0, 1000, 700);
    await dispatch(listener.onWindowMoved);
    expect(await storage.getOffset('windowPosition'), Offset.zero);
    calls.clear();
    await desktopRestoreWindowBounds(settings.currentSettings);
    expect(calls.map((call) => call.method), ['setBounds', 'setBounds']);
    expect(calls.last.arguments, containsPair('x', 0.0));
    expect(calls.last.arguments, containsPair('y', 0.0));
  });

  // GitHub #54: the reporter wiped the profile before testing again. A profile that never saved a position must
  // not be moved to the top left corner, which `Offset.zero`, the default of the setting, would do.
  test('a profile that never saved a position keeps the position the system gives the window', () async {
    expect(await storage.getOffset('windowPosition'), isNull);
    await desktopRestoreWindowBounds(settings.currentSettings);
    expect(calls.map((call) => call.method), ['setBounds']);
    expect(calls.single.arguments, containsPair('width', 800.0));
  });
}
