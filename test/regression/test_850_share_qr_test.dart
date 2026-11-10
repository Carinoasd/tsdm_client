/// Share as a QR code: the code holds the page's forum address, the dialog draws in both themes, and the picture saved
/// or shared is a PNG of the card.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/image/utils/image_actions.dart';
import 'package:tsdm_client/features/share_qr/share_qr_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

const _pngSignature = [0x89, 0x50, 0x4E, 0x47];

void main() {
  late Directory tmp;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
    tmp = Directory.systemTemp.createTempSync('tsdm_share_qr_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => switch (call.method) {
        'getTemporaryPath' || 'getTemporaryDirectory' => '${tmp.path}/tmp',
        _ => null,
      },
    );
  });

  tearDownAll(() => tmp.delete(recursive: true));

  setUp(() => debugCanShareImageFiles = true);

  tearDown(() {
    debugCanShareImageFiles = null;
    shareImageFiles = SharePlus.instance.share;
  });

  Future<void> pump(
    WidgetTester tester, {
    ThemeMode mode = ThemeMode.light,
    String url = 'https://forum.test/x',
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          themeMode: mode,
          theme: ThemeData(brightness: Brightness.light),
          darkTheme: ThemeData(brightness: Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => showShareQrDialog(context, url: url, title: '测试标题', fileName: 'tsdm-test'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  test('the addresses are the forum pages', () {
    expect(shareQrThreadUrl('123'), '$baseUrl/forum.php?mod=viewthread&tid=123');
    expect(shareQrForumUrl('8'), '$baseUrl/forum.php?mod=forumdisplay&fid=8');
    expect(shareQrProfileUrl('31'), '$baseUrl/home.php?mod=space&uid=31');
  });

  for (final mode in ThemeMode.values.where((m) => m != ThemeMode.system)) {
    testWidgets('the dialog draws the code of the address under the title in the $mode theme', (tester) async {
      await pump(tester, mode: mode, url: shareQrThreadUrl('123'));
      final code = tester.widget<QrImageView>(find.byKey(const ValueKey('share-qr-code')));
      expect(tester.widget<ShareQrDialog>(find.byType(ShareQrDialog)).url, shareQrThreadUrl('123'));
      expect(find.text('测试标题'), findsOneWidget);
      // Dark modules on white whatever the theme: what scanners read.
      expect(tester.widget<Container>(find.byKey(const ValueKey('share-qr-card'))).color, Colors.white);
      expect(code.eyeStyle.color, Colors.black);
      expect(code.dataModuleStyle.color, Colors.black);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('without file sharing only save is offered', (tester) async {
    debugCanShareImageFiles = false;
    await pump(tester);
    expect(find.byKey(const ValueKey('share-qr-save')), findsOneWidget);
    expect(find.byKey(const ValueKey('share-qr-share')), findsNothing);
  });

  testWidgets('share hands the card over as a PNG', (tester) async {
    final shared = <ShareParams>[];
    shareImageFiles = (params) async {
      shared.add(params);
      return const ShareResult('', ShareResultStatus.success);
    };
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('share-qr-share')));
    for (var i = 0; i < 100 && shared.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    expect(shared, hasLength(1));
    final file = shared.single.files!.single;
    expect(file.mimeType, 'image/png');
    expect(file.name, 'tsdm-test.png');
    expect(File(file.path).readAsBytesSync().sublist(0, 4), _pngSignature);
  });
}
