import 'dart:async';
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
  const browserChannel = MethodChannel('kzs.th000.tsdm_client/mainChannel');
  const featureRequestUrl = 'https://github.com/Carinoasd/tsdm_client/issues/new?template=02_feedback.yml';
  final browserCalls = <MethodCall>[];
  late Future<Object?> Function() browserAnswer;
  late _Picker picker;
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() {
    picker = _Picker();
    FilePicker.platform = picker;
    browserCalls.clear();
    browserAnswer = () async => true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(browserChannel, (
      call,
    ) async {
      browserCalls.add(call);
      return browserAnswer();
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(browserChannel, null);
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

  testWidgets('feature request opens the feedback form and keeps the donation dialog available', (tester) async {
    await open(tester);
    final request = find.widgetWithText(OutlinedButton, t.aboutPage.featureRequestAction);
    await tester.ensureVisible(request);
    await tester.tap(request);
    await tester.pumpAndSettle();

    expect(browserCalls.single.method, 'openInBrowser');
    expect(browserCalls.single.arguments, {'url': featureRequestUrl});
    expect(find.byType(SupportDevelopmentDialog), findsOneWidget);
    expect(find.text(t.aboutPage.featureRequestOpenFailed), findsNothing);
    expect(tester.widget<OutlinedButton>(request).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refused and failed browser launches show a link in the dialog and allow retry', (tester) async {
    await open(tester);
    final request = find.widgetWithText(OutlinedButton, t.aboutPage.featureRequestAction);
    final dialog = find.byType(SupportDevelopmentDialog);

    for (final answer in <Future<Object?> Function()>[
      () async => false,
      () async => throw PlatformException(code: 'no_browser'),
    ]) {
      browserAnswer = answer;
      await tester.ensureVisible(request);
      await tester.tap(request);
      await tester.pumpAndSettle();

      expect(find.descendant(of: dialog, matching: find.text(t.aboutPage.featureRequestOpenFailed)), findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.widgetWithText(SelectableText, featureRequestUrl)),
        findsOneWidget,
      );
      expect(tester.widget<OutlinedButton>(request).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    }

    browserAnswer = () async => true;
    await tester.ensureVisible(request);
    await tester.tap(request);
    await tester.pumpAndSettle();
    expect(browserCalls, hasLength(3));
    expect(find.text(t.aboutPage.featureRequestOpenFailed), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
    expect(dialog, findsOneWidget);
  });

  testWidgets('pending launch disables repeat requests and can finish after the dialog is closed', (tester) async {
    final pending = Completer<Object?>();
    browserAnswer = () => pending.future;
    await open(tester);
    final request = find.widgetWithText(OutlinedButton, t.aboutPage.featureRequestAction);
    await tester.ensureVisible(request);
    await tester.tap(request);
    await tester.pumpAndSettle();

    expect(tester.widget<OutlinedButton>(request).onPressed, isNull);
    await tester.tap(request);
    await tester.pump();
    expect(browserCalls, hasLength(1));

    await tester.tap(find.text(t.general.close));
    await tester.pumpAndSettle();
    expect(find.byType(SupportDevelopmentDialog), findsNothing);
    pending.complete(false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(t.aboutPage.featureRequestOpenFailed), findsNothing);
    expect(browserCalls, hasLength(1));
  });

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
