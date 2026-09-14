import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/tray_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final helper = TrayHelper.instance;
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
    trayCalls = [];
    windowCalls = [];
    messenger
      ..setMockMethodCallHandler(pathChannel, (_) async => temp.path)
      ..setMockMethodCallHandler(trayChannel, (call) async {
        trayCalls.add(call);
        if (call.method == failMethod) {
          throw PlatformException(code: 'test_failure');
        }
        return true;
      })
      ..setMockMethodCallHandler(windowChannel, (call) async {
        windowCalls.add(call.method);
        if (call.method == 'restore') minimized = false;
        return call.method == 'isMinimized' ? minimized : null;
      });
  });

  tearDown(() async {
    await helper.dispose();
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
}
