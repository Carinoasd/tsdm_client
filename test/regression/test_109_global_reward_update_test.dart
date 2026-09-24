import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:responsive_framework/responsive_framework.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/home/cubit/init_cubit.dart';
import 'package:tsdm_client/features/home/view/home_page.dart';
import 'package:tsdm_client/features/points/stream.dart';
import 'package:tsdm_client/features/root/bloc/points_changes_cubit.dart';
import 'package:tsdm_client/features/root/bloc/root_location_cubit.dart';
import 'package:tsdm_client/features/root/models/models.dart';
import 'package:tsdm_client/features/root/stream/root_location_stream.dart';
import 'package:tsdm_client/features/root/view/singleton.dart';
import 'package:tsdm_client/features/update/cubit/update_cubit.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/features/update/view/update_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/git_info.dart';

void main() {
  late PointsChangesCubit points;
  late UpdateCubit updates;
  late RootLocationCubit location;
  late InitCubit init;
  late StreamSubscription<PointsChangesValue> subscription;
  final rewards = <PointsChangesValue>[];

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });
  setUp(() {
    points = PointsChangesCubit();
    updates = UpdateCubit();
    location = RootLocationCubit();
    init = InitCubit()..skipAutoClearImageCache();
    rewards.clear();
    subscription = points.stream.where((value) => value != PointsChangesValue.empty).listen(rewards.add);
  });
  tearDown(() async {
    await subscription.cancel();
    await points.close();
    await updates.close();
    await location.close();
    await init.close();
  });

  Future<void> pumpHost(WidgetTester tester, {bool home = true}) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: points),
            BlocProvider.value(value: updates),
            BlocProvider.value(value: location),
            BlocProvider.value(value: init),
          ],
          // Match App: the singleton is outside MaterialApp, and HomePage stays mounted below it.
          child: Stack(
            alignment: Alignment.topLeft,
            children: [
              MaterialApp(
                navigatorKey: router.routerDelegate.navigatorKey,
                scaffoldMessengerKey: snackbarKey,
                builder: (context, child) => ResponsiveBreakpoints.builder(
                  breakpoints: const [Breakpoint(start: 0, end: double.infinity, name: 'compact')],
                  child: child!,
                ),
                home: home
                    ? const HomePage(showNavigationBar: false, child: Text('home'))
                    : const Scaffold(body: Text('other page')),
              ),
              const RootSingleton(),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> checkFinished(WidgetTester tester, UpdateCubitState result) async {
    // Drive the real listeners at the update-request completion boundary.
    // ignore: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member
    updates.emit(const UpdateCubitState(loading: true));
    await tester.pump();
    // ignore: invalid_use_of_visible_for_testing_member, invalid_use_of_protected_member
    updates.emit(result);
    await tester.pumpAndSettle();
  }

  testWidgets('each separate reply with the same credit reward reaches the notification listener', (tester) async {
    await pumpHost(tester, home: false);
    const cookie = '0D1D1D0D0D0D0D0D0D2234424';
    final tr = LocaleSettings.instance.currentTranslations.pointsChangesDialog;
    final message = [tr.points.ww(value: '+1'), tr.points.tsb(value: '+1')].join(tr.sep);
    pointsChangesStream.add(cookie);
    await tester.pumpAndSettle();
    expect(rewards, hasLength(1));
    expect(find.text(message), findsOneWidget);
    snackbarKey.currentState!.removeCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.text(message), findsNothing);
    pointsChangesStream.add(cookie);
    await tester.pumpAndSettle();
    expect(rewards, hasLength(2));
    expect(find.text(message), findsOneWidget);
    expect(rewards.every((value) => value.ww == 1 && value.tsb == 1), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('an available update is announced once while the home page is mounted', (tester) async {
    await pumpHost(tester);
    await checkFinished(
      tester,
      const UpdateCubitState(
        latestVersionInfo: LatestVersionInfo(version: '99.0.0', versionCode: 999999, changelog: 'test update'),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.text(LocaleSettings.instance.currentTranslations.updatePage.availableDialog.title), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed manual update check does not queue a second identical error', (tester) async {
    await pumpHost(tester);
    await checkFinished(tester, const UpdateCubitState(notice: true));
    final message = LocaleSettings.instance.currentTranslations.updatePage.failed;
    expect(find.text(message), findsOneWidget);
    snackbarKey.currentState!.removeCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.text(message), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('zero and malformed awards show nothing and do not break the next valid reward', (tester) async {
    await pumpHost(tester, home: false);
    pointsChangesStream
      ..add('0D0D0D0D0D0D0D0D0D42')
      ..add('invalid')
      ..add('0DxD1D0D0D0D0D0D0D42');
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(rewards, isEmpty);
    pointsChangesStream.add('0D0D0D0D0D0D0D0D2D42');
    await tester.pumpAndSettle();
    expect(
      find.text(LocaleSettings.instance.currentTranslations.pointsChangesDialog.points.specialAttr2(value: '+2')),
      findsOneWidget,
    );
    expect(rewards.single.specialAttr2, 2);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('disposing and remounting the singleton does not leak a points subscription', (tester) async {
    await pumpHost(tester, home: false);
    await tester.pumpWidget(const SizedBox.shrink());
    pointsChangesStream.add('0D1D1D0D0D0D0D0D0D42');
    await tester.pump();
    expect(rewards, isEmpty);
    expect(tester.takeException(), isNull);
    await pumpHost(tester, home: false);
    pointsChangesStream.add('0D1D1D0D0D0D0D0D0D42');
    await tester.pumpAndSettle();
    expect(rewards, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a newer version is announced outside the home page with an update action', (tester) async {
    await pumpHost(tester, home: false);
    await checkFinished(
      tester,
      const UpdateCubitState(
        latestVersionInfo: LatestVersionInfo(version: '99.0.0', versionCode: 999999, changelog: 'test update'),
      ),
    );
    final tr = LocaleSettings.instance.currentTranslations;
    expect(find.text(tr.updatePage.availableDialog.title), findsOneWidget);
    expect(find.widgetWithText(TextButton, tr.settingsPage.othersSection.update), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('new version details survive reward notices and remain until dismissed', (tester) async {
    await pumpHost(tester, home: false);
    await checkFinished(
      tester,
      const UpdateCubitState(
        latestVersionInfo: LatestVersionInfo(
          version: '99.0.0',
          versionCode: 999999,
          changelog: 'Important update notes',
        ),
      ),
    );
    final tr = LocaleSettings.instance.currentTranslations;
    expect(find.text(tr.updatePage.availableDialog.version(version: '99.0.0')), findsOneWidget);
    expect(location.isIn(DialogPaths.updateNotice), isTrue);
    expect(find.text('Important update notes'), findsOneWidget);
    pointsChangesStream.add('0D1D1D0D0D0D0D0D0D42');
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text(tr.updatePage.availableDialog.title), findsOneWidget);
    expect(find.text('Important update notes'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, tr.general.cancel));
    await tester.pumpAndSettle();
    expect(find.text(tr.updatePage.availableDialog.title), findsNothing);
    expect(location.state.locations, isNot(contains(DialogPaths.updateNotice)));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a reward does not erase the available update announcement', (tester) async {
    await pumpHost(tester);
    await checkFinished(
      tester,
      const UpdateCubitState(
        latestVersionInfo: LatestVersionInfo(version: '99.0.0', versionCode: 999999, changelog: 'test update'),
      ),
    );
    final title = LocaleSettings.instance.currentTranslations.updatePage.availableDialog.title;
    expect(find.text(title), findsOneWidget);
    pointsChangesStream.add('0D1D1D0D0D0D0D0D0D42');
    await tester.pumpAndSettle();
    expect(find.text(title), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('another check while the update dialog is open does not stack dialogs', (tester) async {
    await pumpHost(tester);
    const result = UpdateCubitState(
      latestVersionInfo: LatestVersionInfo(version: '99.0.0', versionCode: 999999, changelog: 'test update'),
    );
    await checkFinished(tester, result);
    await checkFinished(tester, result);
    expect(find.byType(AlertDialog, skipOffstage: false), findsOneWidget);
    final tr = LocaleSettings.instance.currentTranslations;
    await tester.tap(find.widgetWithText(TextButton, tr.general.cancel));
    await tester.pumpAndSettle();
    expect(find.text(tr.updatePage.availableDialog.title), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a failed automatic update check remains silent', (tester) async {
    await pumpHost(tester);
    await checkFinished(tester, const UpdateCubitState());
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('already latest remains silent outside the update page', (tester) async {
    await pumpHost(tester);
    await checkFinished(
      tester,
      UpdateCubitState(
        latestVersionInfo: LatestVersionInfo(
          version: 'current',
          versionCode: int.parse(appVersion.split('+').last),
          changelog: '',
        ),
      ),
    );
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('already latest is announced once on the update page', (tester) async {
    await pumpHost(tester);
    rootLocationStream.add(RootLocationEventEnter(ScreenPaths.update));
    await tester.pump();
    await checkFinished(
      tester,
      UpdateCubitState(
        latestVersionInfo: LatestVersionInfo(
          version: 'current',
          versionCode: int.parse(appVersion.split('+').last),
          changelog: '',
        ),
      ),
    );
    expect(find.text(LocaleSettings.instance.currentTranslations.updatePage.alreadyLatest), findsOneWidget);
    snackbarKey.currentState!.removeCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a newer version does not prompt to open the update page already displayed', (tester) async {
    await pumpHost(tester, home: false);
    rootLocationStream.add(RootLocationEventEnter(ScreenPaths.update));
    await tester.pump();
    await checkFinished(
      tester,
      const UpdateCubitState(
        latestVersionInfo: LatestVersionInfo(version: '99.0.0', versionCode: 999999, changelog: 'test update'),
      ),
    );
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the real app router opens update from the dialog and leaves no duplicate route', (tester) async {
    router.go(ScreenPaths.debugLog);
    await tester.pumpWidget(
      TranslationProvider(
        child: MultiBlocProvider(
          providers: [
            BlocProvider.value(value: points),
            BlocProvider.value(value: updates),
            BlocProvider.value(value: location),
          ],
          child: Stack(
            alignment: Alignment.topLeft,
            children: [
              MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
              const RootSingleton(),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(location.isIn(ScreenPaths.debugLog), isTrue);
    const result = UpdateCubitState(
      latestVersionInfo: LatestVersionInfo(version: '99.0.0', versionCode: 999999, changelog: 'test update'),
    );
    await checkFinished(tester, result);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(location.isIn(DialogPaths.updateNotice), isTrue);
    await tester.tap(
      find.widgetWithText(TextButton, LocaleSettings.instance.currentTranslations.settingsPage.othersSection.update),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UpdatePage), findsOneWidget);
    expect(location.isIn(ScreenPaths.update), isTrue);
    expect(location.state.locations, isNot(contains(DialogPaths.updateNotice)));
    await checkFinished(tester, result);
    expect(find.byType(AlertDialog), findsNothing);
    router.pop();
    await tester.pumpAndSettle();
    expect(location.isIn(ScreenPaths.debugLog), isTrue);
    expect(find.byType(UpdatePage), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
