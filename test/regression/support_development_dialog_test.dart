import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/widgets/support_development_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

class _Picker extends FilePicker {
  String? path;
  bool fail = false;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    if (fail) throw PlatformException(code: 'save_failed');
    return path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Picker picker;
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() {
    picker = _Picker();
    FilePicker.platform = picker;
  });

  Future<void> open(WidgetTester tester, {AppLocale locale = AppLocale.en, double scale = 1}) async {
    await tester.runAsync(() => LocaleSettings.setLocale(locale));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          scaffoldMessengerKey: snackbarKey,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showDialog<void>(context: context, builder: (_) => const SupportDevelopmentDialog()),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  for (final locale in AppLocale.values) {
    testWidgets('small screen and large text remain scrollable and dismissible: ${locale.name}', (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 568));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await open(tester, locale: locale, scale: 2);
      expect(tester.takeException(), isNull);
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.text(t.general.close));
      await tester.pumpAndSettle();
      expect(find.byType(SupportDevelopmentDialog), findsNothing);
    });
  }

  testWidgets('desktop export preserves the original image bytes', (tester) async {
    final directory = Directory.systemTemp.createTempSync('tsdm-donation-test-');
    addTearDown(() => directory.delete(recursive: true));
    picker.path = '${directory.path}/donation.jpg';
    await open(tester);
    final save = tester.widget<TextButton>(find.widgetWithText(TextButton, t.aboutPage.saveDonationCode));
    await tester.runAsync(() => (save.onPressed! as Future<void> Function())());
    await tester.pumpAndSettle();
    final original = await rootBundle.load(SupportDevelopmentDialog.imagePath);
    expect(
      File(picker.path!).readAsBytesSync(),
      original.buffer.asUint8List(original.offsetInBytes, original.lengthInBytes),
    );
    expect(tester.takeException(), isNull);
  }, skip: !(Platform.isWindows || Platform.isLinux || Platform.isMacOS));

  testWidgets('cancel and save error leave the dialog usable for a retry', (tester) async {
    await open(tester);
    await tester.tap(find.text(t.aboutPage.saveDonationCode));
    await tester.pumpAndSettle();
    expect(find.text(t.aboutPage.donationCodeSaved), findsNothing);
    picker.fail = true;
    await tester.tap(find.text(t.aboutPage.saveDonationCode));
    await tester.pumpAndSettle();
    expect(find.text(t.aboutPage.donationCodeSaveFailed), findsOneWidget);
    expect(tester.takeException(), isNull);
    final save = tester.widget<TextButton>(find.widgetWithText(TextButton, t.aboutPage.saveDonationCode));
    expect(save.onPressed, isNotNull);
  });
}
