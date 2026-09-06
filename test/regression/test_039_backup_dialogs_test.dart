import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/widgets/backup_secrets_dialogs.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

/// Two device reports on the first build of the password protected backup:
///
/// - The unlock dialog vanished the moment it appeared after the file picker closed (a touch outside it), so the
///   import went ahead without the logins. Both dialogs now close only through their buttons.
/// - The export dialog overflowed by 20 pixels once the keyboard came up; it scrolls now.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  Widget host(Future<void> Function(BuildContext context) open) => TranslationProvider(
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(onPressed: () => open(context), child: const Text('open')),
          ),
        ),
      ),
    ),
  );

  testWidgets('the unlock dialog ignores taps outside and the back button; only its buttons close it', (tester) async {
    Object? result = 'unset';
    await tester.pumpWidget(host((context) async => result = await showUnlockBackupDialog(context, wrongPassword: true)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'a tap on the barrier must not close it');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'the back button must not close it');
    expect(result, 'unset');

    // Restore with nothing typed does nothing; with a password it returns it.
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hunter2 hunter2');
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(result, 'hunter2 hunter2');
  });

  testWidgets('skipping the unlock dialog returns null', (tester) async {
    Object? result = 'unset';
    await tester.pumpWidget(host((context) async => result = await showUnlockBackupDialog(context)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(result, isNull);
  });

  testWidgets('the export dialog fits with the keyboard up and ignores taps outside', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    Object? result = 'unset';
    await tester.pumpWidget(host((context) async => result = await showExportBackupDialog(context)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNWidgets(2));

    // The password field takes focus and a soft keyboard covers the lower 420 logical pixels, as on the tester's
    // phone: the dialog must shrink and scroll rather than overflow.
    tester.view.viewInsets = const FakeViewPadding(bottom: 1260);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'no overflow with two fields and the keyboard');
    expect(find.byType(TextFormField), findsNWidgets(2));

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget, reason: 'a tap on the barrier must not close it');
    expect(result, 'unset');

    await tester.enterText(find.byType(TextFormField).at(0), 'correct horse');
    await tester.enterText(find.byType(TextFormField).at(1), 'correct horse');
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect((result! as ExportBackupChoice).password, 'correct horse');
  });

  testWidgets('cancelling the export dialog returns null and exporting without the switch returns no password', (
    tester,
  ) async {
    Object? result = 'unset';
    await tester.pumpWidget(host((context) async => result = await showExportBackupDialog(context)));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(result, isNull);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    expect((result! as ExportBackupChoice).password, isNull);
  });
}
