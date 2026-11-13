// Everything the app copies goes through one function, `setClipboardText`, which remembers the forum link copied: the
// clipboard prompt does not offer back a link copied in the app, from "copy link" or anywhere else (a local draft, the
// editor's BBCode, the transfer of a post). Nothing in `lib/` writes the clipboard on its own.
//
// What the system selection menu copies (long press, "copy") never passes the app and stays out of reach.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/open_in_app/clipboard_link_prompt.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/clipboard.dart';

/// The one file allowed to write the clipboard.
const _writer = 'lib/utils/clipboard.dart';

const _url = 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=123';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  test('only $_writer writes the clipboard', () {
    // `Clipboard.setData` and the platform message behind it.
    final write = RegExp(r'''Clipboard\s*\.\s*setData\b|['"]Clipboard\.setData['"]''');
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.endsWith('.g.dart') || path == _writer) {
        continue;
      }
      // The whole file: a call the formatter split over two lines is found too.
      final content = file.readAsStringSync();
      for (final m in write.allMatches(content)) {
        final line = '\n'.allMatches(content.substring(0, m.start)).length + 1;
        offenders.add('$path:$line: ${m.group(0)}');
      }
    }
    expect(offenders, isEmpty, reason: 'copy with setClipboardText (or copyToClipboard) instead');
    expect(File(_writer).readAsStringSync(), contains('Clipboard.setData'));
  });

  group('setClipboardText', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..allowReassignment = true
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings);
      await settings.init();
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      await settings.dispose();
      await db.close();
      await getIt.reset();
      getIt.allowReassignment = false;
    });

    test('copies the text and remembers the forum link in it; text without one leaves it', () async {
      final copied = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );

      // A local draft copied: its subject and body.
      const draft = '求助\n\n看这个 $_url 怎么打开';
      await setClipboardText(draft);
      expect(copied, [draft]);
      expect(await storage.getString(clipboardLinkPromptedKey), _url);

      await setClipboardText('Alice');
      expect(copied, [draft, 'Alice']);
      expect(await storage.getString(clipboardLinkPromptedKey), _url);
    });
  });
}
