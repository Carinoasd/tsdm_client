import 'dart:convert';
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

/// A backup to import may only hold what this app creates: tables of its schema (no virtual ones) and indexes on
/// them. A trigger would run inside the app on the next write — the export "without logins" strips the cookies
/// with an UPDATE, a trigger on it writes them back somewhere the export keeps — and a view would pose as a table.
/// The copy of the replaced database (`.bak`, it holds the logins of then) does not stay behind.
void main() {
  late Directory dir;
  const repository = BackupRepository();
  late int schemaVersion;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() => dir = Directory.systemTemp.createTempSync('tsdm_backup_schema'));
  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  Future<File> makeDatabase(String path, {required String username, int uid = 1000}) async {
    final file = File(path);
    final db = AppDatabase(NativeDatabase(file));
    final storage = StorageProvider(db, {}, {});
    await storage.saveCookie(username: username, uid: uid, cookie: {'Ystv_2132_auth': '$username-token'});
    await storage.saveInt(SettingsKeys.loginUid.name, uid);
    await storage.saveBool(SettingsKeys.enableDebugOperations.name, value: true);
    schemaVersion = db.schemaVersion;
    await db.close();
    return file;
  }

  void edit(File file, String sql) {
    final db = sqlite3.open(file.path);
    try {
      db.execute(sql);
    } finally {
      db.dispose();
    }
  }

  /// Copies the cookie column into a setting on every UPDATE of the cookie table: the strip of the export runs it.
  const leakTrigger =
      'CREATE TRIGGER leak AFTER UPDATE ON cookie BEGIN '
      "INSERT OR REPLACE INTO settings (name, string_value) VALUES ('leak_' || old.uid, old.cookie); END";

  group('validate refuses schema objects the app does not create', () {
    test('a trigger', () async {
      final file = await makeDatabase('${dir.path}/trigger.db', username: 'Bob');
      edit(file, leakTrigger);
      final check = await repository.validate(file, currentSchemaVersion: schemaVersion);
      expect(check.problem, BackupProblem.unexpectedObjects, reason: '$check');
      expect(check.detail, 'trigger leak');
    });

    test('a view, also one named like a table of the app', () async {
      final file = await makeDatabase('${dir.path}/view.db', username: 'Bob');
      edit(file, 'CREATE VIEW extra AS SELECT * FROM settings');
      expect(
        (await repository.validate(file, currentSchemaVersion: schemaVersion)).problem,
        BackupProblem.unexpectedObjects,
      );

      final posing = await makeDatabase('${dir.path}/posing.db', username: 'Bob');
      edit(posing, 'DROP TABLE read_later');
      edit(posing, 'CREATE VIEW read_later AS SELECT * FROM cookie');
      final check = await repository.validate(posing, currentSchemaVersion: schemaVersion);
      expect(check.problem, BackupProblem.unexpectedObjects);
      expect(check.detail, 'view read_later');
    });

    test('a table the app does not know', () async {
      final file = await makeDatabase('${dir.path}/unknown.db', username: 'Bob');
      edit(file, 'CREATE TABLE payload (x TEXT)');
      final check = await repository.validate(file, currentSchemaVersion: schemaVersion);
      expect(check.problem, BackupProblem.unexpectedObjects);
      expect(check.detail, 'table payload');
    });

    test('a virtual table, whatever its name', () async {
      final file = await makeDatabase('${dir.path}/virtual.db', username: 'Bob');
      edit(file, 'DROP TABLE read_later');
      try {
        edit(file, 'CREATE VIRTUAL TABLE read_later USING fts5(x)');
      } on SqliteException {
        markTestSkipped('fts5 not compiled into this sqlite');
        return;
      }
      final check = await repository.validate(file, currentSchemaVersion: schemaVersion);
      expect(check.problem, BackupProblem.unexpectedObjects, reason: '$check');
    });

    test('a virtual table whose sql text and rootpage were rewritten by hand', () async {
      final file = await makeDatabase('${dir.path}/disguised.db', username: 'Bob');
      edit(file, 'DROP TABLE read_later');
      try {
        edit(file, 'CREATE VIRTUAL TABLE read_later USING dbstat');
      } on SqliteException {
        markTestSkipped('dbstat not compiled into this sqlite');
        return;
      }
      final db = sqlite3.open(file.path);
      try {
        final rootpage = db.select("SELECT rootpage FROM sqlite_master WHERE name = 'cookie'").first['rootpage'];
        db
          ..execute('PRAGMA writable_schema = ON')
          ..execute(
            "UPDATE sqlite_master SET sql = 'CREATE/**/VIRTUAL TABLE read_later USING dbstat', rootpage = ? "
            "WHERE name = 'read_later'",
            [rootpage],
          )
          ..execute('PRAGMA writable_schema = OFF');
      } finally {
        db.dispose();
      }
      final check = await repository.validate(file, currentSchemaVersion: schemaVersion);
      expect(check.ok, isFalse, reason: '$check');
    });

    test('an index on a table of the app, and the indexes sqlite makes itself, pass', () async {
      final file = await makeDatabase('${dir.path}/index.db', username: 'Bob');
      edit(file, 'CREATE INDEX extra_index ON settings (string_value)');
      edit(file, 'ANALYZE');
      final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
      try {
        expect(db.select("SELECT 1 FROM sqlite_master WHERE name LIKE 'sqlite_autoindex_%'"), isNotEmpty);
      } finally {
        db.dispose();
      }
      final check = await repository.validate(file, currentSchemaVersion: schemaVersion);
      expect(check.ok, isTrue, reason: '$check');
    });

    test('a backup exported with the account logins encrypted passes', () async {
      final live = await makeDatabase('${dir.path}/live.db', username: 'Bob');
      final bytes = await const BackupRepository(kdfIterations: 10).exportSanitized(live, secretsPassword: 'pw');
      final file = File('${dir.path}/exported.db')..writeAsBytesSync(bytes);
      final check = await repository.validate(file, currentSchemaVersion: schemaVersion);
      expect(check.ok, isTrue, reason: '$check');
    });
  });

  test('the known tables are every table of every schema version of the app', () async {
    final tables = <String>{};
    final schemas = Directory(
      'lib/shared/providers/storage_provider/models/database/schema/migration',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.json'));
    for (final file in schemas) {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final entity in json['entities'] as List<dynamic>) {
        final e = entity as Map<String, dynamic>;
        expect(e['type'], anyOf('table', 'index'), reason: '${file.path} has a ${e['type']}: allow it on import');
        if (e['type'] == 'table') {
          tables.add((e['data'] as Map<String, dynamic>)['name'] as String);
        }
      }
    }
    final db = AppDatabase(NativeDatabase.memory());
    tables.addAll(db.allTables.map((t) => t.actualTableName));
    await db.close();
    expect(tables, isNotEmpty);
    expect(BackupRepository.knownTables.difference({BackupRepository.secretsTable}), tables);
  });

  group('replaceDatabase', () {
    test('a backup with a trigger is refused before anything changes', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final before = target.readAsBytesSync();
      final source = await makeDatabase('${dir.path}/crafted.db', username: 'Bob', uid: 2000);
      edit(source, leakTrigger);
      await expectLater(
        repository.replaceDatabase(target: target, source: source, currentSchemaVersion: schemaVersion),
        throwsA(
          isA<BackupInvalidException>().having((e) => e.validation.problem, 'problem', BackupProblem.unexpectedObjects),
        ),
      );
      expect(target.readAsBytesSync(), before);
      expect(File('${target.path}${BackupRepository.backupSuffix}').existsSync(), isFalse);
      expect(File('${target.path}${BackupRepository.importSuffix}').existsSync(), isFalse);
    });

    test('the copy of the replaced database is deleted once the import succeeded', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final source = await makeDatabase('${dir.path}/other.db', username: 'Bob', uid: 2000);
      final result = await repository.replaceDatabase(
        target: target,
        source: source,
        currentSchemaVersion: schemaVersion,
      );
      expect(result.ok, isTrue);
      expect(File('${target.path}${BackupRepository.backupSuffix}').existsSync(), isFalse);
      expect(String.fromCharCodes(target.readAsBytesSync()), isNot(contains('Alice-token')));
    });

    test('and once the previous database is back after a failed import', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final before = target.readAsBytesSync();
      final source = await makeDatabase('${dir.path}/other.db', username: 'Bob', uid: 2000);
      await expectLater(
        repository.replaceDatabase(
          target: target,
          source: source,
          currentSchemaVersion: schemaVersion,
          verify: (_) async => false,
        ),
        throwsA(isA<BackupReplaceException>().having((e) => e.restored, 'restored', isTrue)),
      );
      expect(target.readAsBytesSync(), before);
      expect(File('${target.path}${BackupRepository.backupSuffix}').existsSync(), isFalse);
    });
  });

  test('a copy that could not be put back is kept on the next start', () async {
    final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
    final source = await makeDatabase('${dir.path}/other.db', username: 'Bob', uid: 2000);
    final bak = File('${target.path}${BackupRepository.backupSuffix}');
    await expectLater(
      repository.replaceDatabase(
        target: target,
        source: source,
        currentSchemaVersion: schemaVersion,
        // The import fails verification and the database path can not be written back (a directory took it).
        verify: (replaced) async {
          replaced.deleteSync();
          Directory(replaced.path).createSync();
          return false;
        },
      ),
      throwsA(isA<BackupReplaceException>().having((e) => e.restored, 'restored', isFalse)),
    );
    // Moved out of the way: the next start and a later import do not touch it.
    final kept = File('${bak.path}${BackupRepository.keptSuffix}');
    expect(bak.existsSync(), isFalse);
    expect(kept.existsSync(), isTrue);
    Directory(target.path).deleteSync();
    target.writeAsStringSync('whatever is there now');
    await BackupRepository.deleteLeftovers(target);
    expect(kept.existsSync(), isTrue);
    expect(String.fromCharCodes(kept.readAsBytesSync()), contains('Alice-token'));
  });

  group('deleteLeftovers', () {
    test('removes the copies an interrupted import or export left next to the database', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final bak = File('${target.path}.bak')..writeAsStringSync('Alice-token');
      final import = File('${target.path}.import.tmp')..writeAsStringSync('x');
      final export = File('${target.path}.export-1700000000.tmp')..writeAsStringSync('x');
      final other = File('${dir.path}/other.bak')..writeAsStringSync('kept');
      final wal = File('${target.path}-wal')..writeAsStringSync('kept');
      final later = DateTime.now().add(BackupRepository.staleCopyAge + const Duration(minutes: 1));
      await BackupRepository.deleteLeftovers(target, now: later);
      expect(bak.existsSync(), isFalse);
      expect(import.existsSync(), isFalse);
      expect(export.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
      expect(wal.existsSync(), isTrue);
      expect(target.existsSync(), isTrue);
    });

    test('keeps a recent export copy: the background isolate may be writing it', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final bak = File('${target.path}.bak')..writeAsStringSync('Alice-token');
      final export = File('${target.path}.export-1700000000.tmp')..writeAsStringSync('x');
      await BackupRepository.deleteLeftovers(target);
      expect(bak.existsSync(), isFalse);
      expect(export.existsSync(), isTrue);
    });

    test('keeps the copy while there is no database to fall back from', () async {
      final target = File('${dir.path}/mainV2.db');
      final bak = File('${target.path}.bak')..writeAsStringSync('only copy');
      await BackupRepository.deleteLeftovers(target);
      expect(bak.existsSync(), isTrue);
      await BackupRepository.deleteLeftovers(File('${dir.path}/missing/mainV2.db'));
    });
  });

  test('an export drops triggers already in the database before it strips the logins', () async {
    // A database that took in a crafted backup before imports were checked.
    final live = await makeDatabase('${dir.path}/live.db', username: 'Alice');
    edit(live, leakTrigger);
    edit(live, 'CREATE VIEW extra AS SELECT cookie FROM cookie');
    expect(String.fromCharCodes(live.readAsBytesSync()), contains('Alice-token'));
    final bytes = await repository.exportSanitized(live);
    final file = File('${dir.path}/exported.db')..writeAsBytesSync(bytes);
    expect(String.fromCharCodes(bytes), isNot(contains('Alice-token')));
    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      expect(db.select("SELECT name FROM sqlite_master WHERE type IN ('trigger', 'view')"), isEmpty);
      expect(db.select("SELECT name FROM settings WHERE name LIKE 'leak_%'"), isEmpty);
    } finally {
      db.dispose();
    }
    expect((await repository.validate(file, currentSchemaVersion: schemaVersion)).ok, isTrue);
  });
}
