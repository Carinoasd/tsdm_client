import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/diagnostics/abnormal_exit.dart';
import 'package:tsdm_client/features/diagnostics/abnormal_exit_prompt.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

/// E: the home page asks about the abnormal end of the last run with a snack bar offering the diagnostics export; once
/// only, and nothing after a normal end.

void main() {
  late Directory dir;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() {
    dir = Directory.systemTemp.createTempSync('abnormal_exit_prompt_');
    AbnormalExitRecorder.disarm();
  });

  tearDown(() {
    AbnormalExitRecorder.disarm();
    dir.deleteSync(recursive: true);
  });

  AbnormalExitRecorder recorder() =>
      AbnormalExitRecorder(directory: dir, appVersion: '1.57.0', trackForeground: true)..arm();

  Future<BuildContext> pumpHome(WidgetTester tester) async {
    late BuildContext home;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          scaffoldMessengerKey: snackbarKey,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                home = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );
    return home;
  }

  testWidgets('asked once after an uncaught error, with the export', (tester) async {
    recorder().recordError(StateError('x'));
    AbnormalExitRecorder.disarm();
    final next = recorder();

    final home = await pumpHome(tester);
    await askAboutAbnormalExit(home, recorder: next);
    await tester.pump();
    expect(find.text(t.diagnostics.lastRunError), findsOneWidget);
    expect(find.widgetWithText(SnackBarAction, t.diagnostics.export), findsOneWidget);

    ScaffoldMessenger.of(home).removeCurrentSnackBar();
    await tester.pumpAndSettle();
    // The home page built again: not asked again.
    await askAboutAbnormalExit(home, recorder: next);
    await tester.pump();
    expect(find.text(t.diagnostics.lastRunError), findsNothing);
  });

  testWidgets('vanished in the front: told it ended abnormally', (tester) async {
    AbnormalExitRecorder(
      directory: dir,
      appVersion: '1.57.0',
      trackForeground: true,
    ).arm(lifecycle: AppLifecycleState.resumed);
    AbnormalExitRecorder.disarm();
    final next = recorder();

    final home = await pumpHome(tester);
    await askAboutAbnormalExit(home, recorder: next);
    await tester.pump();
    expect(find.text(t.diagnostics.abnormalExit), findsOneWidget);
  });

  testWidgets('nothing after a normal end', (tester) async {
    final home = await pumpHome(tester);
    await askAboutAbnormalExit(home, recorder: recorder());
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
  });
}
