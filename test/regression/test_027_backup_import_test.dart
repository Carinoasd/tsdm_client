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

/// Importing a backup checks the file first, never overwrites with an invalid file and restores when the swap fails.
void main() {
  late Directory dir;
  const repository = BackupRepository();
  late int schemaVersion;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() => dir = Directory.systemTemp.createTempSync('tsdm_backup_import'));
  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// A real app database at [path] with an account, login settings, cache records and user data.
  Future<File> makeDatabase(String path, {required String username, int uid = 1000}) async {
    final file = File(path);
    final db = AppDatabase(NativeDatabase(file));
    final storage = StorageProvider(db, {}, {});
    await storage.saveCookie(username: username, uid: uid, cookie: {'Ystv_2132_auth': '$username-token'});
    await storage.saveInt(SettingsKeys.loginUid.name, uid);
    await storage.saveString(SettingsKeys.loginUsername.name, username);
    await storage.saveBool(SettingsKeys.enableDebugOperations.name, value: true);
    await storage.updateImageCache('https://example.com/$username.png', fileName: '../../outside-$username');
    await storage.updateUserAvatarCacheInfo(username: username, cacheName: '../escape', imageUrl: 'x').run();
    await storage.updateThreadVisitHistory(
      uid: uid,
      tid: 42,
      fid: 4,
      username: username,
      threadTitle: 'thread of $username',
      forumName: 'forum',
      visitTime: DateTime(2026, 9, 6),
    );
    schemaVersion = db.schemaVersion;
    await db.close();
    return file;
  }

  int count(Database d, String table) => d.select('SELECT count(*) AS c FROM $table').first['c'] as int;
  List<String> settingNames(Database d) => d.select('SELECT name FROM settings').map((r) => r['name'] as String).toList();

  group('validate', () {
    test('accepts a database written by this app', () async {
      final file = await makeDatabase('${dir.path}/good.db', username: 'Alice');
      final check = await repository.validate(file, currentSchemaVersion: schemaVersion);
      expect(check.ok, isTrue, reason: '$check');
      expect(check.schemaVersion, schemaVersion);
    });

    test('rejects files that are not sqlite databases', () async {
      final text = File('${dir.path}/text.db')..writeAsStringSync('hello, this is not a database at all, really');
      expect((await repository.validate(text, currentSchemaVersion: 11)).problem, BackupProblem.notSqlite);
      final empty = File('${dir.path}/empty.db')..writeAsBytesSync([]);
      expect((await repository.validate(empty, currentSchemaVersion: 11)).problem, BackupProblem.notSqlite);
      final missing = File('${dir.path}/missing.db');
      expect((await repository.validate(missing, currentSchemaVersion: 11)).problem, BackupProblem.unreadable);
    });

    test('rejects a truncated (damaged) database', () async {
      final file = await makeDatabase('${dir.path}/good.db', username: 'Alice');
      final bytes = file.readAsBytesSync();
      final damaged = File('${dir.path}/damaged.db')..writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      final check = await repository.validate(damaged, currentSchemaVersion: schemaVersion);
      expect(check.ok, isFalse);
      expect(check.problem, BackupProblem.corrupted);
    });

    test('rejects a database with the required tables missing', () async {
      final path = '${dir.path}/other.db';
      sqlite3.open(path)
        ..execute('CREATE TABLE notes (id INTEGER PRIMARY KEY, text TEXT)')
        ..userVersion = 3
        ..dispose();
      final check = await repository.validate(File(path), currentSchemaVersion: 11);
      expect(check.problem, BackupProblem.missingTables);
      expect(check.detail, contains('settings'));
    });

    test('rejects newer schemas and non positive versions', () async {
      final file = await makeDatabase('${dir.path}/good.db', username: 'Alice');
      sqlite3.open(file.path)
        ..userVersion = schemaVersion + 1
        ..dispose();
      final newer = await repository.validate(file, currentSchemaVersion: schemaVersion);
      expect(newer.problem, BackupProblem.newerSchema);

      sqlite3.open(file.path)
        ..userVersion = 0
        ..dispose();
      expect((await repository.validate(file, currentSchemaVersion: schemaVersion)).problem, BackupProblem.invalidVersion);
    });
  });

  group('replaceDatabase', () {
    test('an invalid source changes nothing', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final before = target.readAsBytesSync();
      final bad = File('${dir.path}/bad.db')..writeAsStringSync('not a database');
      await expectLater(
        repository.replaceDatabase(target: target, source: bad, currentSchemaVersion: schemaVersion),
        throwsA(isA<BackupInvalidException>()),
      );
      expect(target.readAsBytesSync(), before, reason: 'target untouched');
      expect(File('${target.path}.bak').existsSync(), isFalse);
      expect(File('${target.path}.import.tmp').existsSync(), isFalse);
    });

    test('a valid backup replaces the database without credentials or cache paths', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final source = await makeDatabase('${dir.path}/from-other-device.db', username: 'Bob', uid: 2000);
      final sourceBefore = source.readAsBytesSync();

      final result = await repository.replaceDatabase(target: target, source: source, currentSchemaVersion: schemaVersion);
      expect(result.ok, isTrue);
      expect(result.schemaVersion, schemaVersion);

      final db = sqlite3.open(target.path, mode: OpenMode.readOnly);
      try {
        // The account list of the backup is kept, its credentials are not: every account logs in again.
        expect(db.select('SELECT username, cookie, password FROM cookie').first.values, ['Bob', '{}', null]);
        expect(String.fromCharCodes(target.readAsBytesSync()), isNot(contains('Bob-token')));
        expect(settingNames(db), isNot(contains(SettingsKeys.loginUid.name)));
        expect(settingNames(db), isNot(contains(SettingsKeys.loginUsername.name)));
        expect(settingNames(db), contains(SettingsKeys.enableDebugOperations.name));
        expect(count(db, 'image_cache'), 0, reason: 'cache path records of the other device are dropped');
        expect(count(db, 'user_avatar'), 0);
        expect(count(db, 'thread_visit_history'), 1);
        expect(db.select('SELECT thread_title FROM thread_visit_history').first['thread_title'], 'thread of Bob');
        expect(String.fromCharCodes(target.readAsBytesSync()), isNot(contains('Bob-token')));
      } finally {
        db.dispose();
      }
      // The previous database is kept next to the new one, the source file is not modified.
      final previous = sqlite3.open('${target.path}.bak', mode: OpenMode.readOnly);
      try {
        expect(count(previous, 'cookie'), 1);
        expect(previous.select('SELECT thread_title FROM thread_visit_history').first['thread_title'], 'thread of Alice');
      } finally {
        previous.dispose();
      }
      expect(source.readAsBytesSync(), sourceBefore);
      expect(File('${target.path}.import.tmp').existsSync(), isFalse);

      // The app opens the imported database like its own.
      final reopened = AppDatabase(NativeDatabase(target));
      final storage = StorageProvider(reopened, await preloadCookie(reopened), {});
      expect((await storage.getAllUsers()).map((e) => e.username), ['Bob'], reason: 'listed for a new login');
      expect(storage.getCookieByUidSync(2000), isEmpty, reason: 'no usable session');
      expect(await storage.getInt(SettingsKeys.loginUid.name), isNull, reason: 'nobody is logged in');
      expect(await storage.getBool(SettingsKeys.enableDebugOperations.name), isTrue);
      await reopened.close();
    });

    test('a failed verification restores the previous database', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final before = target.readAsBytesSync();
      final source = await makeDatabase('${dir.path}/from-other-device.db', username: 'Bob', uid: 2000);

      await expectLater(
        repository.replaceDatabase(
          target: target,
          source: source,
          currentSchemaVersion: schemaVersion,
          verify: (_) async => false,
        ),
        throwsA(isA<BackupReplaceException>().having((e) => e.restored, 'restored', isTrue)),
      );
      expect(target.readAsBytesSync(), before, reason: 'previous database is back');
      final db = sqlite3.open(target.path, mode: OpenMode.readOnly);
      try {
        expect(count(db, 'cookie'), 1);
        expect(db.select('SELECT thread_title FROM thread_visit_history').first['thread_title'], 'thread of Alice');
      } finally {
        db.dispose();
      }
    });

    test('stale journal files of the previous database are removed', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final source = await makeDatabase('${dir.path}/other.db', username: 'Bob', uid: 2000);
      File('${target.path}-wal').writeAsStringSync('stale');
      File('${target.path}-shm').writeAsStringSync('stale');
      await repository.replaceDatabase(target: target, source: source, currentSchemaVersion: schemaVersion);
      expect(File('${target.path}-wal').existsSync(), isFalse);
      expect(File('${target.path}-shm').existsSync(), isFalse);
    });
  });
}
