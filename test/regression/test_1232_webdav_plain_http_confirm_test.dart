import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/repositories/webdav_backup_repository.dart';
import 'package:tsdm_client/features/settings/widgets/webdav_backup_dialogs.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

/// A WebDAV server at a plain `http://` address outside the local network gets the username and password readable on
/// the way: saving (or testing) it asks first. A NAS on the local network does not ask, `https://` never does.
void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('sendsPasswordInClear', () {
    bool clear(String url) => WebdavBackupConfig(url: url).sendsPasswordInClear;

    test('plain http to the internet', () {
      expect(clear('http://dav.example.com/remote.php/dav'), isTrue);
      expect(clear('HTTP://dav.example.com'), isTrue);
      expect(clear('http://8.8.8.8:5005/dav'), isTrue);
      expect(clear('http://[2001:db8::1]/dav'), isTrue);
      expect(clear('http://172.32.0.1/'), isTrue);
      expect(clear('http://192.169.1.1/'), isTrue);
    });

    test('https, or not a usable url', () {
      expect(clear('https://dav.example.com'), isFalse);
      expect(clear(''), isFalse);
      expect(clear('ftp://dav.example.com'), isFalse);
    });

    test('this device and the local network', () {
      for (final url in [
        'http://localhost:8080',
        'http://127.0.0.1/',
        'http://127.1.2.3/',
        'http://10.0.0.5/dav',
        'http://172.16.0.2/',
        'http://172.31.255.255/',
        'http://192.168.1.10:5005/',
        'http://169.254.10.1/',
        'http://100.100.1.1/',
        'http://[::1]/',
        'http://[fd12:3456::1]/',
        'http://[fe80::1]/',
        'http://[::ffff:192.168.1.2]/',
        'http://nas:5005/',
        'http://nas.local/',
        'http://nas.lan./',
        'http://nas.home.arpa/',
      ]) {
        expect(clear(url), isFalse, reason: url);
      }
    });
  });

  group('the settings dialog', () {
    late Directory dir;
    late WebdavBackupStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('tsdm_webdav_http');
      store = WebdavBackupStore(dir);
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<void> open(WidgetTester tester) async {
      final repository = WebdavBackupRepository(store: store, databaseFile: () async => File(''));
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () => showWebdavSettingsDialog(
                    context,
                    repository: repository,
                    config: const WebdavBackupConfig(),
                    password: '',
                  ),
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

    Future<void> save(WidgetTester tester, String url) async {
      await tester.enterText(find.byType(TextFormField).first, url);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, t.general.ok));
      await tester.pumpAndSettle();
    }

    String question() => t.settingsPage.advancedSection.webdav.plainHttpConfirm;

    /// The settings are being written: the buttons of the settings dialog are off until it closes.
    bool saving(WidgetTester tester) =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, t.general.ok)).onPressed == null;

    testWidgets('plain http to the internet asks before saving; cancelled, nothing is saved', (tester) async {
      await open(tester);
      await save(tester, 'http://dav.example.com/dav');
      expect(find.text(question()), findsOneWidget);
      expect(saving(tester), isFalse);
      await tester.tap(find.text(t.general.cancel).last);
      await tester.pumpAndSettle();
      expect(find.text(question()), findsNothing);
      expect(saving(tester), isFalse);
      expect(await tester.runAsync(store.readConfig).then((c) => c?.url), '');

      await tester.tap(find.widgetWithText(FilledButton, t.general.ok));
      await tester.pumpAndSettle();
      expect(find.text(question()), findsOneWidget, reason: 'asked again');
      await tester.tap(find.text(t.general.ok).last);
      await tester.pumpAndSettle();
      expect(find.text(question()), findsNothing);
      expect(saving(tester), isTrue);
    });

    testWidgets('a NAS on the local network saves without asking', (tester) async {
      await open(tester);
      await save(tester, 'http://192.168.1.10:5005/dav');
      expect(find.text(question()), findsNothing);
      expect(saving(tester), isTrue);
    });

    testWidgets('https saves without asking', (tester) async {
      await open(tester);
      await save(tester, 'https://dav.example.com/dav');
      expect(find.text(question()), findsNothing);
      expect(saving(tester), isTrue);
    });
  });
}
