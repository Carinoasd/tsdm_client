// P13: the Android background message service never stops without the user knowing.
//
// Without the battery optimization exemption Android 12+ refuses the plugin's watchdog the restart of the foreground
// service once the process was killed (`ForegroundServiceStartNotAllowedException`), and nothing polled until the app
// was opened. Dart tells Android whether the service is wanted (`BackgroundSyncGuard.kt`: a periodic job starts it
// again where allowed, else posts one notification; an activity coming to the front starts it again), and the
// settings page marks the service and the battery row while the exemption is missing.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/background_sync/background_sync_controller.dart';
import 'package:tsdm_client/features/settings/bloc/android_permission_cubit.dart';
import 'package:tsdm_client/features/settings/widgets/android_permission_tiles.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:xml/xml.dart';

const _android = 'http://schemas.android.com/apk/res/android';

final class _FakeGateway implements AndroidPermissionGateway {
  final statuses = <Permission, PermissionStatus>{};

  @override
  Future<PermissionStatus> status(Permission permission) async => statuses[permission] ?? PermissionStatus.denied;

  @override
  Future<PermissionStatus> request(Permission permission) async => status(permission);

  @override
  Future<bool> openSettings() async => true;

  @override
  Future<bool> shouldShowRationale(Permission permission) async => false;
}

/// A controller whose plugin calls and guard calls are recorded in [log], in order.
BackgroundSyncController _controller(
  List<String> log, {
  bool running = false,
  bool startOk = true,
  bool stopOk = true,
  bool guardThrows = false,
}) {
  var isUp = running;
  return BackgroundSyncController(
    configure: ({required autoStartOnBoot}) async => log.add('configure $autoStartOnBoot'),
    start: () async {
      log.add('start');
      isUp = startOk;
      return startOk;
    },
    stop: () async {
      log.add('stop');
      if (stopOk) isUp = false;
      return stopOk;
    },
    isRunning: () async => isUp,
    notifySettingsChanged: () => log.add('notify'),
    guard: ({required wanted}) async {
      log.add('guard $wanted');
      if (guardThrows) throw StateError('no activity');
    },
  );
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('the controller tells the guard', () {
    test('wanted once the service runs', () async {
      final log = <String>[];
      final result = await _controller(log).apply(enabled: true, intervalSeconds: 600);
      expect(result, BackgroundSyncApplyResult.running);
      expect(log, ['configure true', 'start', 'notify', 'guard true']);
    });

    test('wanted when it was running already', () async {
      final log = <String>[];
      await _controller(log, running: true).apply(enabled: true, intervalSeconds: 600);
      expect(log, ['configure true', 'notify', 'guard true']);
    });

    test('not wanted before the stop, so the guard never starts what is being stopped', () async {
      final log = <String>[];
      final result = await _controller(log, running: true).apply(enabled: false, intervalSeconds: 600);
      expect(result, BackgroundSyncApplyResult.stopped);
      expect(log, ['guard false', 'configure false', 'stop']);
    });

    test('an interval of "never" is not wanted either', () async {
      final log = <String>[];
      await _controller(log, running: true).apply(enabled: true, intervalSeconds: 0);
      expect(log.first, 'guard false');
    });

    test('not wanted when the service did not start: the switch goes back to off', () async {
      final log = <String>[];
      final result = await _controller(log, startOk: false).apply(enabled: true, intervalSeconds: 600);
      expect(result, BackgroundSyncApplyResult.failed);
      expect(log, ['configure true', 'start', 'guard false']);
    });

    test('a guard that cannot be told (no activity) changes nothing of the result', () async {
      final log = <String>[];
      final controller = _controller(log, guardThrows: true);
      expect(await controller.apply(enabled: true, intervalSeconds: 600), BackgroundSyncApplyResult.running);
      expect(await controller.apply(enabled: false, intervalSeconds: 600), BackgroundSyncApplyResult.stopped);
    });
  });

  group('backgroundReceiveAtRisk', () {
    test('only with the service on and the exemption known to be missing', () {
      expect(backgroundReceiveAtRisk(serviceOn: true, ignoreBattery: PermissionStatus.denied), isTrue);
      expect(backgroundReceiveAtRisk(serviceOn: true, ignoreBattery: PermissionStatus.permanentlyDenied), isTrue);
      expect(backgroundReceiveAtRisk(serviceOn: true, ignoreBattery: PermissionStatus.restricted), isTrue);
      expect(backgroundReceiveAtRisk(serviceOn: true, ignoreBattery: PermissionStatus.granted), isFalse);
      expect(backgroundReceiveAtRisk(serviceOn: true, ignoreBattery: null), isFalse);
      expect(backgroundReceiveAtRisk(serviceOn: false, ignoreBattery: PermissionStatus.denied), isFalse);
    });
  });

  group('the battery row', () {
    Future<Color?> trailingColor(
      WidgetTester tester, {
      required bool serviceOn,
      required PermissionStatus battery,
    }) async {
      final gateway = _FakeGateway()
        ..statuses[Permission.notification] = PermissionStatus.granted
        ..statuses[Permission.ignoreBatteryOptimizations] = battery;
      final cubit = AndroidPermissionCubit(enabled: true, gateway: gateway);
      addTearDown(cubit.close);
      await cubit.refresh();
      await tester.pumpWidget(
        TranslationProvider(
          child: BlocProvider.value(
            value: cubit,
            child: MaterialApp(
              home: Scaffold(body: AndroidPermissionTiles(backgroundServiceOn: serviceOn)),
            ),
          ),
        ),
      );
      await tester.pump();
      final row = tester.widget<ListTile>(find.byKey(const ValueKey('settings-ignore-battery')));
      return (row.trailing! as Text).style?.color;
    }

    testWidgets('is drawn in the error color with the service on and no exemption', (tester) async {
      final color = await trailingColor(tester, serviceOn: true, battery: PermissionStatus.denied);
      final error = Theme.of(tester.element(find.byType(Scaffold))).colorScheme.error;
      expect(color, error);
    });

    testWidgets('stays as it was with the exemption, or with the service off', (tester) async {
      final error = ThemeData().colorScheme.error;
      expect(await trailingColor(tester, serviceOn: true, battery: PermissionStatus.granted), isNot(error));
      expect(await trailingColor(tester, serviceOn: false, battery: PermissionStatus.denied), isNot(error));
    });
  });

  group('Android side', () {
    final manifest = XmlDocument.parse(File('android/app/src/main/AndroidManifest.xml').readAsStringSync());
    final activity = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/MainActivity.kt').readAsStringSync();
    final guard = File('android/app/src/main/kotlin/kzs/th000/tsdm_client/BackgroundSyncGuard.kt').readAsStringSync();
    final channel = File('lib/utils/method_channel.dart').readAsStringSync();

    test('the guard is a job service only the system binds', () {
      final service = manifest
          .findAllElements('service')
          .singleWhere((e) => e.getAttribute('name', namespace: _android) == '.BackgroundSyncGuard');
      expect(service.getAttribute('permission', namespace: _android), 'android.permission.BIND_JOB_SERVICE');
      expect(service.getAttribute('exported', namespace: _android), 'false');
    });

    test('no new sensitive permission: no exact alarm, the persisted job needs the boot permission only', () {
      final permissions = manifest
          .findAllElements('uses-permission')
          .map((e) => e.getAttribute('name', namespace: _android))
          .toSet();
      expect(permissions, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
      expect(permissions, isNot(contains('android.permission.SCHEDULE_EXACT_ALARM')));
      expect(permissions, isNot(contains('android.permission.USE_EXACT_ALARM')));
    });

    test('the main channel takes the wanted state under the name Dart sends', () {
      expect(channel, contains("_methodSetBackgroundSyncGuard = 'setBackgroundSyncGuard'"));
      expect(activity, contains('SET_BACKGROUND_SYNC_GUARD = "setBackgroundSyncGuard"'));
      expect(activity, contains('BackgroundSyncGuard.setWanted(applicationContext, wanted,'));
    });

    test('an activity coming to the front starts a service that went while the process lived', () {
      final onResume = RegExp(r'override fun onResume\(\) \{[\s\S]*?\n    \}').firstMatch(activity)!.group(0)!;
      expect(onResume, contains('BackgroundSyncGuard.onActivityResumed(applicationContext)'));
    });

    test('the notice goes to the quiet channel of the service and to the notification next to it', () {
      expect(guard, contains('CHANNEL_ID = "tsdm_foreground"'));
      expect(
        File('lib/features/background_sync/background_sync_service.dart').readAsStringSync(),
        allOf(
          contains("backgroundSyncChannelId = 'tsdm_foreground'"),
          contains('backgroundSyncNotificationId = 888'),
        ),
      );
      expect(guard, contains('NOTIFICATION_ID = 889'));
    });
  });
}
