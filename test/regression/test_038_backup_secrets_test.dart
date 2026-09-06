import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/repositories/backup_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// A backup exported with a password carries the account logins encrypted (PBKDF2-HMAC-SHA256, AES-256-GCM) in the
/// `backup_secrets` table: nothing that logs a device in appears in the clear, the right password restores the
/// accounts on import, a wrong one is refused before anything is touched, and the table never reaches the installed
/// database. Without a password the export is exactly what it was.
void main() {
  late Directory dir;
  late File dbFile;
  late AppDatabase db;
  late StorageProvider storage;
  const password = 'correct horse battery';
  // Few iterations keep the tests fast; imports read the cost back from the file.
  const repository = BackupRepository(kdfIterations: 1000);

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    // Two databases on purpose: the exporting device and the importing one.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  });
  setUp(() async {
    dir = Directory.systemTemp.createTempSync('tsdm_backup_secrets');
    dbFile = File('${dir.path}/mainV2.db');
    db = AppDatabase(NativeDatabase(dbFile));
    storage = StorageProvider(db, {}, {});
    await storage.saveCookie(
      username: 'Alice',
      uid: 1000,
      cookie: {'Ystv_2132_auth': 'alice-auth-token', 'Ystv_2132_saltkey': 'alice-salt'},
    );
    await storage.saveCookie(username: 'Bob', uid: 1001, cookie: {'Ystv_2132_auth': 'bob-auth-token'});
    await storage.saveInt(SettingsKeys.loginUid.name, 1000);
    await storage.saveString(SettingsKeys.loginUsername.name, 'Alice');
    await storage.saveBool(SettingsKeys.enableDebugOperations.name, value: true);
  });
  tearDown(() async {
    await db.close();
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  Future<File> exportWith(String? secretsPassword) async {
    final bytes = await repository.exportSanitized(dbFile, secretsPassword: secretsPassword);
    return File('${dir.path}/backup-${secretsPassword == null ? 'plain' : 'secret'}.db')..writeAsBytesSync(bytes);
  }

  test('with a password the logins travel encrypted and nothing appears in the clear', () async {
    final file = await exportWith(password);
    final text = String.fromCharCodes(file.readAsBytesSync());
    for (final needle in ['alice-auth-token', 'bob-auth-token', 'alice-salt', password]) {
      expect(text, isNot(contains(needle)), reason: needle);
    }
    final exported = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      expect(BackupRepository.hasSecrets(exported), isTrue);
      expect(exported.select('SELECT cookie FROM cookie').map((r) => r['cookie']), everyElement('{}'));
      expect(
        exported.select('SELECT name FROM settings').map((r) => r['name']),
        isNot(contains(SettingsKeys.loginUid.name)),
      );
      final row = exported
          .select('SELECT kdf, iterations, length(salt) AS s, length(nonce) AS n, length(mac) AS m FROM backup_secrets')
          .first;
      expect(row['kdf'], 'pbkdf2-hmac-sha256');
      expect(row['iterations'], 1000);
      expect(row['s'], 16);
      expect(row['n'], 12);
      expect(row['m'], 16);
    } finally {
      exported.dispose();
    }
    expect(await repository.containsSecrets(file), isTrue);
    // The live database is untouched.
    expect(storage.getCookieByUidSync(1000), containsPair('Ystv_2132_auth', 'alice-auth-token'));
    expect(await storage.getInt(SettingsKeys.loginUid.name), 1000);
  });

  test('without a password the export is what it was: no secrets table', () async {
    final file = await exportWith(null);
    expect(await repository.containsSecrets(file), isFalse);
    final exported = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      expect(BackupRepository.hasTable(exported, BackupRepository.secretsTable), isFalse);
    } finally {
      exported.dispose();
    }
    expect(await repository.containsSecrets(File('${dir.path}/missing.db')), isFalse);
  });

  test('the right password unlocks the accounts and the logged in account', () async {
    final file = await exportWith(password);
    final payload = await repository.unlockSecrets(file, password: password);
    expect(payload.accounts.map((a) => a['uid']), [1000, 1001]);
    expect(payload.accounts.map((a) => a['username']), ['Alice', 'Bob']);
    expect(payload.accounts.first['cookie'], contains('alice-auth-token'));
    expect(payload.loginSettings[SettingsKeys.loginUid.name], 1000);
    expect(payload.loginSettings[SettingsKeys.loginUsername.name], 'Alice');
  });

  test('a wrong password is refused; a plain backup has nothing to unlock', () async {
    final file = await exportWith(password);
    await expectLater(
      repository.unlockSecrets(file, password: 'wrong horse'),
      throwsA(isA<BackupSecretsPasswordException>().having((e) => e.unsupported, 'unsupported', isFalse)),
    );
    final plain = await exportWith(null);
    await expectLater(repository.unlockSecrets(plain, password: password), throwsArgumentError);
  });

  test('secrets in a newer format are reported as unsupported, not as a wrong password', () async {
    final file = await exportWith(password);
    final writable = sqlite3.open(file.path);
    try {
      writable.execute('UPDATE backup_secrets SET version = 99');
    } finally {
      writable.dispose();
    }
    await expectLater(
      repository.unlockSecrets(file, password: password),
      throwsA(isA<BackupSecretsPasswordException>().having((e) => e.unsupported, 'unsupported', isTrue)),
    );
  });

  group('replaceDatabase', () {
    late File target;

    setUp(() async {
      // Another device with an account of its own; the import replaces it.
      target = File('${dir.path}/other/mainV2.db');
      target.parent.createSync();
      final other = AppDatabase(NativeDatabase(target));
      await StorageProvider(other, {}, {}).saveCookie(username: 'Carol', uid: 1002, cookie: {'Ystv_2132_auth': 'carol-token'});
      await other.close();
    });

    test('unlocked logins are restored and the secrets table is dropped', () async {
      final file = await exportWith(password);
      final payload = await repository.unlockSecrets(file, password: password);
      final result = await repository.replaceDatabase(
        target: target,
        source: file,
        currentSchemaVersion: db.schemaVersion,
        secrets: payload,
      );
      expect(result.ok, isTrue, reason: '$result');
      final installed = sqlite3.open(target.path, mode: OpenMode.readOnly);
      try {
        expect(BackupRepository.hasTable(installed, BackupRepository.secretsTable), isFalse);
        final rows = installed.select('SELECT uid, cookie FROM cookie ORDER BY uid');
        expect(rows.map((r) => r['uid']), [1000, 1001]);
        expect(rows.first['cookie'], contains('alice-auth-token'));
        expect(rows.last['cookie'], contains('bob-auth-token'));
        expect(
          installed.select('SELECT int_value FROM settings WHERE name = ?', [SettingsKeys.loginUid.name]).first['int_value'],
          1000,
        );
        expect(
          installed
              .select('SELECT string_value FROM settings WHERE name = ?', [SettingsKeys.loginUsername.name])
              .first['string_value'],
          'Alice',
        );
      } finally {
        installed.dispose();
      }
      expect(String.fromCharCodes(target.readAsBytesSync()), isNot(contains('carol-token')));
    });

    test('importing without unlocking keeps every account logged out and drops the table', () async {
      final file = await exportWith(password);
      final result = await repository.replaceDatabase(target: target, source: file, currentSchemaVersion: db.schemaVersion);
      expect(result.ok, isTrue, reason: '$result');
      final installed = sqlite3.open(target.path, mode: OpenMode.readOnly);
      try {
        expect(BackupRepository.hasTable(installed, BackupRepository.secretsTable), isFalse);
        expect(installed.select('SELECT cookie FROM cookie').map((r) => r['cookie']), everyElement('{}'));
        expect(
          installed.select('SELECT name FROM settings').map((r) => r['name']),
          isNot(contains(SettingsKeys.loginUid.name)),
        );
      } finally {
        installed.dispose();
      }
      expect(String.fromCharCodes(target.readAsBytesSync()), isNot(contains('alice-auth-token')));
    });
  });
}
