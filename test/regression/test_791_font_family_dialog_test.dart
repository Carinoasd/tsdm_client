/// The font dialog lists the imported fonts, picks one and deletes it (clearing the field when it was selected).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/settings/repositories/custom_font_store.dart';
import 'package:tsdm_client/features/settings/widgets/font_family_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('font_dialog_test');
    Directory('${root.path}/fonts').createSync();
    File('${root.path}/fonts/Alpha.ttf').writeAsBytesSync([1]);
    File('${root.path}/fonts/Beta.otf').writeAsBytesSync([1]);
  });

  tearDown(() => root.deleteSync(recursive: true));

  testWidgets('lists imported fonts, selecting fills the field and deleting the selected one clears it', (
    tester,
  ) async {
    final store = CustomFontStore(Directory('${root.path}/fonts'), registerFont: (_, _) async {});
    await tester.runAsync(() async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(body: FontFamilyDialog('', store: store)),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Beta'), findsOneWidget);

    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Alpha');

    await tester.runAsync(() async {
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Beta'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
  });
}
