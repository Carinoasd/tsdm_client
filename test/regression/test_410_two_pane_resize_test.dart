/// The divider between the two panes (`TwoPaneLayout`) can be dragged:
///
/// * dragging it sideways moves it at once, the list pane as wide as the pointer took it; let go, the width is saved
///   (`twoPaneListWidth`) and laid out again the next time;
/// * the list pane stays at least 360 wide and leaves at least 480 on the right; a window too narrow for both gives
///   each its share of the two;
/// * never dragged, the list takes 40% of the window within 360–480, as before; tapped twice, the divider goes back
///   there and the saved width is forgotten;
/// * with no settings provided (a page alone) it still drags, nothing is saved.
library;

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/two_pane.dart';

const _listKey = ValueKey<String>('list');
final Finder _divider = find.byKey(const ValueKey('two-pane-divider'));

double _listWidth(WidgetTester tester) => tester.getSize(find.byKey(_listKey)).width;

/// A few frames with real time in between, for the settings database.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}

final class _Settings {
  late AppDatabase db;
  late SettingsRepository repository;
  late SettingsBloc bloc;

  Future<void> setUp() async {
    db = AppDatabase(NativeDatabase.memory());
    repository = SettingsRepository(StorageProvider(db, {}, {}));
    await repository.init();
    bloc = SettingsBloc(settingsRepository: repository, fragmentsRepository: FragmentsRepository());
  }

  Future<void> tearDown() async {
    await bloc.close();
    await repository.dispose();
    await db.close();
  }
}

Future<void> _pump(WidgetTester tester, {required double width, SettingsBloc? bloc, Widget? body}) async {
  tester.view
    ..physicalSize = Size(width, 800)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final layout = TwoPaneLayout(
    list: Scaffold(key: _listKey, body: body ?? const SizedBox.expand()),
  );
  // The layout listens to the system back through the router.
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => bloc == null ? layout : BlocProvider.value(value: bloc, child: layout),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(MaterialApp.router(routerConfig: router));
  await tester.pump();
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('twoPaneListWidthFor', () {
    test('never dragged: 40% of the window within 360–480', () {
      expect(twoPaneListWidthFor(840, 0), 360);
      expect(twoPaneListWidthFor(1000, 0), 400);
      expect(twoPaneListWidthFor(1900, 0), 480);
    });

    test('dragged: as wide as dragged, at least 360, at least 480 left on the right', () {
      expect(twoPaneListWidthFor(1900, 900), 900);
      expect(twoPaneListWidthFor(1900, 100), 360);
      expect(twoPaneListWidthFor(1900, 1800), 1900 - 480);
      expect(twoPaneListWidthFor(1000, 700), 520, reason: 'a width saved on a wider window');
      expect(twoPaneListWidthFor(840, 700), 360);
    });

    test('too narrow for both panes: each its share of the two least widths', () {
      expect(twoPaneListWidthFor(700, 0), closeTo(700 * 360 / 840, 1e-9));
      expect(twoPaneListWidthFor(700, 600), closeTo(700 * 360 / 840, 1e-9));
    });
  });

  group('dragging the divider', () {
    late _Settings settings;

    setUp(() async {
      settings = _Settings();
      await settings.setUp();
    });

    tearDown(() async => settings.tearDown());

    testWidgets('moves the divider while dragged and saves the width on release', (tester) async {
      await _pump(tester, width: 1900, bloc: settings.bloc);
      expect(_listWidth(tester), 480);

      final gesture = await tester.startGesture(tester.getCenter(_divider));
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(200, 0));
      await tester.pump();
      expect(_listWidth(tester), 780, reason: 'the list follows the pointer while dragged');
      expect(settings.repository.currentSettings.twoPaneListWidth, 0, reason: 'nothing saved before the release');

      await gesture.up();
      await _settle(tester);
      expect(settings.repository.currentSettings.twoPaneListWidth, 780);
      expect(_listWidth(tester), 780);

      // Laid out again from the setting.
      await tester.pumpWidget(const SizedBox());
      await _pump(tester, width: 1900, bloc: settings.bloc);
      expect(_listWidth(tester), 780);
    });

    testWidgets('follows the pointer back from beyond a limit', (tester) async {
      await _pump(tester, width: 1200, bloc: settings.bloc);
      final gesture = await tester.startGesture(tester.getCenter(_divider));
      await gesture.moveBy(const Offset(-50, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(-300, 0));
      await tester.pump();
      expect(_listWidth(tester), 360, reason: 'the pointer at 130');
      // Back 150: the pointer is at 280, still left of 360.
      await gesture.moveBy(const Offset(150, 0));
      await tester.pump();
      expect(_listWidth(tester), 360, reason: 'the divider waits for the pointer');
      await gesture.moveBy(const Offset(140, 0));
      await tester.pump();
      expect(_listWidth(tester), 420);
      await gesture.up();
      await _settle(tester);
      expect(settings.repository.currentSettings.twoPaneListWidth, 420);
    });

    testWidgets('a scroll started on the strip reaches the pane below', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await _pump(
        tester,
        width: 1200,
        bloc: settings.bloc,
        body: ListView.builder(controller: controller, itemExtent: 50, itemBuilder: (_, i) => Text('row $i')),
      );
      final strip = tester.getRect(_divider);
      expect(strip.top, greaterThanOrEqualTo(kToolbarHeight), reason: 'the app bars are not covered');
      // On the strip, over the list's right edge.
      final start = Offset(_listWidth(tester) - 1, 400);
      expect(strip.contains(start), isTrue);
      await tester.dragFrom(start, const Offset(0, -300));
      await tester.pump();
      expect(controller.offset, greaterThan(0), reason: 'a vertical drag scrolls the list');
      final scrolled = controller.offset;

      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(start));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 100)));
      await tester.pump();
      expect(controller.offset, greaterThan(scrolled), reason: 'the wheel scrolls the list');
      expect(settings.repository.currentSettings.twoPaneListWidth, 0);
      // The fling and the double tap wait.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('the divider shows a resize cursor', (tester) async {
      await _pump(tester, width: 1200, bloc: settings.bloc);
      final region = tester.widget<MouseRegion>(
        find.ancestor(of: _divider, matching: find.byType(MouseRegion)).first,
      );
      expect(region.cursor, SystemMouseCursors.resizeColumn);
    });

    testWidgets('stays within 360 on the left and 480 on the right', (tester) async {
      await _pump(tester, width: 1200, bloc: settings.bloc);
      expect(_listWidth(tester), 480);

      await tester.drag(_divider, const Offset(-400, 0));
      await _settle(tester);
      expect(_listWidth(tester), 360);
      expect(settings.repository.currentSettings.twoPaneListWidth, 360);

      await tester.drag(_divider, const Offset(1000, 0));
      await _settle(tester);
      expect(_listWidth(tester), 1200 - 480);
      expect(tester.getRect(find.byType(TwoPaneEmptyDetail)).width, 479, reason: 'the divider is 1 of the 480');
      expect(settings.repository.currentSettings.twoPaneListWidth, 720);
    });

    testWidgets('a width saved on a wider window is held within the narrower one, kept as saved', (tester) async {
      await settings.repository.setValue<double>(SettingsKeys.twoPaneListWidth, 900);
      await _settle(tester);
      await _pump(tester, width: 1000, bloc: settings.bloc);
      expect(_listWidth(tester), 520);
      expect(settings.repository.currentSettings.twoPaneListWidth, 900);

      tester.view.physicalSize = const Size(1900, 800);
      await tester.pump();
      expect(_listWidth(tester), 900);
    });

    testWidgets('tapped twice, the divider goes back to the share of the window', (tester) async {
      await settings.repository.setValue<double>(SettingsKeys.twoPaneListWidth, 900);
      await _settle(tester);
      await _pump(tester, width: 1900, bloc: settings.bloc);
      expect(_listWidth(tester), 900);

      await tester.tap(_divider);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(_divider);
      await tester.pump();
      expect(_listWidth(tester), 480, reason: 'back at once, before the setting is saved');
      await _settle(tester);
      expect(settings.repository.currentSettings.twoPaneListWidth, 0);
      expect(_listWidth(tester), 480);
    });

    testWidgets('a single tap on the divider keeps the share of the window', (tester) async {
      await _pump(tester, width: 1000, bloc: settings.bloc);
      await tester.tap(_divider);
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      expect(settings.repository.currentSettings.twoPaneListWidth, 0);
      tester.view.physicalSize = const Size(1100, 800);
      await tester.pump();
      expect(_listWidth(tester), 440);
    });
  });

  testWidgets('drags with no settings provided, nothing saved', (tester) async {
    await _pump(tester, width: 1600);
    expect(_listWidth(tester), 480);
    await tester.drag(_divider, const Offset(150, 0));
    await tester.pump();
    expect(_listWidth(tester), 630);
    // The double tap waits for a second tap.
    await tester.pump(const Duration(seconds: 1));
  });
}
