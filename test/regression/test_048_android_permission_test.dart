// Copyright (C) 2026 Carinoasd. MIT License.
//
// Issues #13 and #3: the auto sync push depends on the Android notification permission, which the app only asked for
// once at boot and never surfaced; the battery optimization dialog needs a manifest permission and an entry point.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/bloc/android_permission_cubit.dart';
import 'package:tsdm_client/features/settings/widgets/android_permission_tiles.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

/// Fake permission_handler: scripted statuses and a log of what the cubit asked for.
final class _FakeGateway implements AndroidPermissionGateway {
  final statuses = <Permission, PermissionStatus>{};

  /// Status a request resolves to (and leaves behind), per permission.
  final requestResults = <Permission, PermissionStatus>{};

  final requested = <Permission>[];
  int openedSettings = 0;

  /// What `shouldShowRequestRationale` answers after a request; false = the system showed no dialog and never will.
  bool rationale = true;
  int rationaleChecks = 0;

  /// Delay before every status read resolves, to model a platform call still in flight.
  Duration statusDelay = Duration.zero;

  @override
  Future<PermissionStatus> status(Permission permission) async {
    if (statusDelay > Duration.zero) {
      await Future<void>.delayed(statusDelay);
    }
    return statuses[permission] ?? PermissionStatus.denied;
  }

  @override
  Future<PermissionStatus> request(Permission permission) async {
    requested.add(permission);
    final result = requestResults[permission] ?? PermissionStatus.granted;
    statuses[permission] = result;
    return result;
  }

  @override
  Future<bool> openSettings() async {
    openedSettings++;
    return true;
  }

  @override
  Future<bool> shouldShowRationale(Permission permission) async {
    rationaleChecks++;
    return rationale;
  }
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('AndroidManifest.xml', () {
    test('declares the notification and battery optimization permissions', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android.permission.POST_NOTIFICATIONS'));
      expect(manifest, contains('android.permission.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'));
    });
  });

  group('AndroidPermissionCubit', () {
    late _FakeGateway gateway;
    late AndroidPermissionCubit cubit;

    setUp(() {
      gateway = _FakeGateway()
        ..statuses[Permission.notification] = PermissionStatus.denied
        ..statuses[Permission.ignoreBatteryOptimizations] = PermissionStatus.denied;
      cubit = AndroidPermissionCubit(enabled: true, gateway: gateway);
    });

    tearDown(() async => cubit.close());

    test('starts unknown and refresh reads both statuses', () async {
      expect(cubit.state, const AndroidPermissionState());
      gateway.statuses[Permission.notification] = PermissionStatus.granted;
      await cubit.refresh();
      expect(
        cubit.state,
        const AndroidPermissionState(notification: PermissionStatus.granted, ignoreBattery: PermissionStatus.denied),
      );
      expect(gateway.requested, isEmpty);
    });

    test('requestNotification asks the system when denied and refreshes', () async {
      await cubit.refresh();
      await cubit.requestNotification();
      expect(gateway.requested, [Permission.notification]);
      expect(gateway.openedSettings, 0);
      expect(cubit.state.notification, PermissionStatus.granted);
    });

    test('requestNotification opens app settings when permanently denied', () async {
      gateway.statuses[Permission.notification] = PermissionStatus.permanentlyDenied;
      await cubit.refresh();
      await cubit.requestNotification();
      expect(gateway.requested, isEmpty);
      expect(gateway.openedSettings, 1);
      expect(cubit.state.notification, PermissionStatus.permanentlyDenied);
    });

    test('requestNotification can be told not to leave the app when permanently denied', () async {
      gateway.statuses[Permission.notification] = PermissionStatus.permanentlyDenied;
      // No refresh first: the cubit reads the status itself (the auto sync path calls it right after start).
      await cubit.requestNotification(openSettingsWhenPermanentlyDenied: false);
      expect(gateway.requested, isEmpty);
      expect(gateway.openedSettings, 0);
      expect(cubit.state.notification, PermissionStatus.permanentlyDenied);
    });

    test('denied without a dialog (Android < 13, boot-prompt denials) counts as permanently denied', () async {
      // permission_handler answers plain `denied` forever here; the rationale flag tells the two cases apart.
      gateway
        ..requestResults[Permission.notification] = PermissionStatus.denied
        ..rationale = false;
      await cubit.refresh();
      await cubit.requestNotification();
      expect(gateway.requested, [Permission.notification]);
      expect(gateway.rationaleChecks, 1);
      expect(gateway.openedSettings, 1);
      expect(cubit.state.notification, PermissionStatus.permanentlyDenied);

      // Stays permanently denied across refreshes until the user turns notifications on in settings.
      await cubit.refresh();
      expect(cubit.state.notification, PermissionStatus.permanentlyDenied);
      await cubit.requestNotification();
      expect(gateway.requested, [Permission.notification]);
      expect(gateway.openedSettings, 2);

      gateway.statuses[Permission.notification] = PermissionStatus.granted;
      await cubit.refresh();
      expect(cubit.state.notification, PermissionStatus.granted);
    });

    test('denied without a dialog does not leave the app when told not to (auto sync path)', () async {
      gateway
        ..requestResults[Permission.notification] = PermissionStatus.denied
        ..rationale = false;
      await cubit.requestNotification(openSettingsWhenPermanentlyDenied: false);
      expect(gateway.requested, [Permission.notification]);
      expect(gateway.openedSettings, 0);
      expect(cubit.state.notification, PermissionStatus.permanentlyDenied);
    });

    test('a first real denial through the system dialog stays denied and does not open settings', () async {
      gateway
        ..requestResults[Permission.notification] = PermissionStatus.denied
        ..rationale = true;
      await cubit.refresh();
      await cubit.requestNotification();
      expect(gateway.requested, [Permission.notification]);
      expect(gateway.rationaleChecks, 1);
      expect(gateway.openedSettings, 0);
      expect(cubit.state.notification, PermissionStatus.denied);
    });

    test('a second real denial reported by the plugin is not escalated to settings by itself', () async {
      gateway
        ..requestResults[Permission.notification] = PermissionStatus.permanentlyDenied
        ..rationale = false;
      await cubit.refresh();
      await cubit.requestNotification();
      expect(gateway.rationaleChecks, 0);
      expect(gateway.openedSettings, 0);
      expect(cubit.state.notification, PermissionStatus.permanentlyDenied);
    });

    test('refresh does not emit after the cubit is closed while a status call is pending', () async {
      gateway.statusDelay = const Duration(milliseconds: 20);
      final states = <AndroidPermissionState>[];
      cubit.stream.listen(states.add);
      final pending = cubit.refresh();
      await cubit.close();
      await pending;
      expect(states, isEmpty);
      expect(cubit.state, const AndroidPermissionState());

      // Once closed, the other entry points skip the platform entirely.
      await cubit.requestNotification();
      await cubit.requestIgnoreBattery();
      expect(gateway.requested, isEmpty);
    });

    test('requestIgnoreBattery requests the exemption and refreshes', () async {
      await cubit.refresh();
      await cubit.requestIgnoreBattery();
      expect(gateway.requested, [Permission.ignoreBatteryOptimizations]);
      expect(cubit.state.ignoreBattery, PermissionStatus.granted);
    });

    test('does nothing when disabled (non-Android)', () async {
      final off = AndroidPermissionCubit(enabled: false, gateway: gateway);
      await off.refresh();
      await off.requestNotification();
      await off.requestIgnoreBattery();
      expect(off.state, const AndroidPermissionState());
      expect(gateway.requested, isEmpty);
      expect(gateway.openedSettings, 0);
      await off.close();
    });

    test('default construction follows the platform gate', () async {
      final auto = AndroidPermissionCubit();
      expect(auto.enabled, Platform.isAndroid);
      await auto.close();
    });
  });

  group('AndroidPermissionTiles', () {
    late _FakeGateway gateway;
    late AndroidPermissionCubit cubit;

    setUp(() {
      gateway = _FakeGateway();
      cubit = AndroidPermissionCubit(enabled: true, gateway: gateway);
    });

    tearDown(() async => cubit.close());

    Widget host() => TranslationProvider(
      child: BlocProvider<AndroidPermissionCubit>.value(
        value: cubit,
        child: const MaterialApp(home: Scaffold(body: AndroidPermissionTiles())),
      ),
    );

    testWidgets('shows the granted labels', (tester) async {
      gateway.statuses[Permission.notification] = PermissionStatus.granted;
      gateway.statuses[Permission.ignoreBatteryOptimizations] = PermissionStatus.granted;
      await cubit.refresh();
      await tester.pumpWidget(host());
      expect(find.text('Notification permission'), findsOneWidget);
      expect(find.text('Ignore battery optimizations'), findsOneWidget);
      expect(find.text('Allowed'), findsOneWidget);
      expect(find.text('Ignored'), findsOneWidget);
    });

    testWidgets('shows the denied labels and tapping asks the system', (tester) async {
      gateway.statuses[Permission.notification] = PermissionStatus.denied;
      gateway.statuses[Permission.ignoreBatteryOptimizations] = PermissionStatus.denied;
      await cubit.refresh();
      await tester.pumpWidget(host());
      expect(find.text('Not allowed'), findsOneWidget);
      expect(find.text('Not ignored'), findsOneWidget);

      await tester.tap(find.text('Notification permission'));
      await tester.pumpAndSettle();
      expect(gateway.requested, [Permission.notification]);
      expect(find.text('Allowed'), findsOneWidget);

      await tester.tap(find.text('Ignore battery optimizations'));
      await tester.pumpAndSettle();
      expect(gateway.requested, [Permission.notification, Permission.ignoreBatteryOptimizations]);
      expect(find.text('Ignored'), findsOneWidget);
    });

    testWidgets('denied without a dialog explains first, then opens app settings', (tester) async {
      gateway
        ..statuses[Permission.notification] = PermissionStatus.denied
        ..requestResults[Permission.notification] = PermissionStatus.denied
        ..rationale = false;
      await cubit.refresh();
      await tester.pumpWidget(host());
      expect(find.text('Not allowed'), findsOneWidget);

      await tester.tap(find.text('Notification permission'));
      await tester.pumpAndSettle();
      // The request came back denied with no dialog: the row flips and the explanation shows before leaving.
      expect(gateway.requested, [Permission.notification]);
      expect(gateway.openedSettings, 0);
      expect(find.text('Permanently denied'), findsOneWidget);
      expect(find.text('Ok'), findsOneWidget);
      await tester.tap(find.text('Ok'));
      await tester.pumpAndSettle();
      expect(gateway.openedSettings, 1);
      expect(gateway.requested, [Permission.notification]);
    });

    testWidgets('a first real denial keeps the row at not allowed without a dialog', (tester) async {
      gateway
        ..statuses[Permission.notification] = PermissionStatus.denied
        ..requestResults[Permission.notification] = PermissionStatus.denied
        ..rationale = true;
      await cubit.refresh();
      await tester.pumpWidget(host());
      await tester.tap(find.text('Notification permission'));
      await tester.pumpAndSettle();
      expect(gateway.requested, [Permission.notification]);
      expect(gateway.openedSettings, 0);
      expect(find.text('Not allowed'), findsOneWidget);
      expect(find.text('Ok'), findsNothing);
    });

    testWidgets('permanently denied explains first, then opens app settings', (tester) async {
      gateway.statuses[Permission.notification] = PermissionStatus.permanentlyDenied;
      await cubit.refresh();
      await tester.pumpWidget(host());
      expect(find.text('Permanently denied'), findsOneWidget);

      await tester.tap(find.text('Notification permission'));
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(gateway.openedSettings, 0);
      expect(gateway.requested, isEmpty);

      await tester.tap(find.text('Notification permission'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ok'));
      await tester.pumpAndSettle();
      expect(gateway.openedSettings, 1);
      expect(gateway.requested, isEmpty);
    });
  });
}
