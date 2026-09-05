import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/repositories/backup_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Exported backups must not carry anything that logs a device in.
void main() {
  late Directory dir;
  late File dbFile;
  late AppDatabase db;
  late StorageProvider storage;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('tsdm_backup_export');
    dbFile = File('${dir.path}/mainV2.db');
    db = AppDatabase(NativeDatabase(dbFile));
    storage = StorageProvider(db, {}, {});
    // Two logged in accounts, the current one recorded in settings, plus ordinary user data.
    await storage.saveCookie(username: 'Alice', uid: 1000, cookie: {'Ystv_2132_auth': 'alice-auth-token', 'Ystv_2132_saltkey': 'alice-salt'});
    await storage.saveCookie(username: 'Bob', uid: 1001, cookie: {'Ystv_2132_auth': 'bob-auth-token'});
    await storage.saveInt(SettingsKeys.loginUid.name, 1000);
    await storage.saveString(SettingsKeys.loginUsername.name, 'Alice');
    await storage.saveBool(SettingsKeys.enableDebugOperations.name, value: true);
    await storage.updateThreadVisitHistory(
      uid: 1000,
      tid: 42,
      fid: 4,
      username: 'Alice',
      threadTitle: 'a thread',
      forumName: 'a forum',
      visitTime: DateTime(2026, 9, 6),
    );
    await storage.updateImageCache('https://example.com/a.png', fileName: 'cache-a');
  });
  tearDown(() async {
    await db.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  int count(Database d, String table) => d.select('SELECT count(*) AS c FROM $table').first['c'] as int;

  test('the export has no cookies, passwords or logged in account, the live database keeps them', () async {
    final bytes = await const BackupRepository().exportSanitized(dbFile);
    expect(bytes, isNotEmpty);
    expect(String.fromCharCodes(bytes.sublist(0, 15)), 'SQLite format 3');

    final exportedFile = File('${dir.path}/exported.db')..writeAsBytesSync(bytes);
    final exported = sqlite3.open(exportedFile.path, mode: OpenMode.readOnly);
    try {
      expect(count(exported, 'cookie'), 0, reason: 'no account cookies in the backup');
      final settingNames = exported.select('SELECT name FROM settings').map((r) => r['name'] as String).toList();
      expect(settingNames, isNot(contains(SettingsKeys.loginUid.name)));
      expect(settingNames, isNot(contains(SettingsKeys.loginUsername.name)));
      expect(settingNames, contains(SettingsKeys.enableDebugOperations.name), reason: 'other settings are kept');
      expect(count(exported, 'thread_visit_history'), 1, reason: 'user data is kept');
      expect(count(exported, 'image_cache'), 1);
      expect(exported.userVersion, db.schemaVersion);
      // Nothing that looks like a token anywhere in the file, including free pages.
      final text = String.fromCharCodes(bytes);
      expect(text, isNot(contains('alice-auth-token')));
      expect(text, isNot(contains('bob-auth-token')));
      expect(text, isNot(contains('alice-salt')));
    } finally {
      exported.dispose();
    }

    // The device stays logged in: the live database is untouched.
    expect(storage.getCookieByUidSync(1000), containsPair('Ystv_2132_auth', 'alice-auth-token'));
    expect((await storage.getAllUsers()).map((e) => e.uid), containsAll([1000, 1001]));
    expect(await storage.getInt(SettingsKeys.loginUid.name), 1000);
    expect(await storage.getString(SettingsKeys.loginUsername.name), 'Alice');
    // No temporary file left behind.
    expect(dir.listSync().map((e) => e.path.split('/').last), unorderedEquals(['mainV2.db', 'exported.db']));
  });

  test('stripCredentials also works on a database without the optional tables', () {
    final other = sqlite3.openInMemory();
    try {
      other
        ..execute('CREATE TABLE settings (name TEXT PRIMARY KEY, int_value INTEGER, string_value TEXT)')
        ..execute("INSERT INTO settings (name, int_value) VALUES ('${SettingsKeys.loginUid.name}', 7)")
        ..execute("INSERT INTO settings (name, string_value) VALUES ('other', 'x')");
      BackupRepository.stripCredentials(other);
      expect(other.select('SELECT name FROM settings').map((r) => r['name']), ['other']);
    } finally {
      other.dispose();
    }
  });
}
