import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Why a backup file can not be imported.
enum BackupProblem {
  /// The file can not be read.
  unreadable,

  /// Not a SQLite database file.
  notSqlite,

  /// The database is damaged (`PRAGMA integrity_check` failed) or can not be opened.
  corrupted,

  /// Tables or columns this app needs are missing.
  missingTables,

  /// The schema version is not a positive number.
  invalidVersion,

  /// The backup was written by a newer app with a newer schema; this app can not migrate it.
  newerSchema,
}

/// Result of checking a backup file.
final class BackupValidation {
  /// A usable backup with the given schema version.
  const BackupValidation.ok(int this.schemaVersion) : problem = null, detail = null;

  /// An unusable backup.
  const BackupValidation.failed(BackupProblem this.problem, [this.detail]) : schemaVersion = null;

  /// Schema version (`PRAGMA user_version`) of a usable backup.
  final int? schemaVersion;

  /// What is wrong, null when the backup is usable.
  final BackupProblem? problem;

  /// Details for the log.
  final String? detail;

  /// The backup can be imported.
  bool get ok => problem == null;

  @override
  String toString() => ok ? 'BackupValidation.ok(v$schemaVersion)' : 'BackupValidation.failed($problem, $detail)';
}

/// The backup file failed [BackupRepository.validate].
final class BackupInvalidException implements Exception {
  /// Constructor.
  const BackupInvalidException(this.validation);

  /// The failed check.
  final BackupValidation validation;

  @override
  String toString() => 'BackupInvalidException($validation)';
}

/// Replacing the database failed; [restored] tells whether the previous database is back in place.
final class BackupReplaceException implements Exception {
  /// Constructor.
  const BackupReplaceException(this.reason, {required this.restored});

  /// What went wrong.
  final String reason;

  /// The previous database was restored from its backup copy.
  final bool restored;

  @override
  String toString() => 'BackupReplaceException($reason, restored=$restored)';
}

/// Backups of the app database (the "匯出資料" / "匯入資料" settings).
///
/// A backup is a copy of the SQLite database file, but never a raw copy: everything that logs a device in is removed
/// first, so a backup can be shared or kept on another device without carrying the accounts of this one. Importing
/// checks the file before anything is overwritten and puts the previous database back when the replacement fails.
final class BackupRepository with LoggerMixin {
  /// Constructor.
  const BackupRepository();

  /// Tables that must exist in every backup this app can import (present since schema version 1).
  static const requiredTables = ['settings', 'cookie', 'image_cache'];

  /// Columns of the settings table this app reads (present since schema version 1).
  static const requiredSettingsColumns = ['name', 'int_value', 'string_value', 'bool_value'];

  /// Tables recording paths of cached files on the device that wrote the backup; meaningless (and, for a crafted
  /// backup, dangerous) on this device, so they are dropped on import and the cache is rebuilt from the network.
  static const cachePathTables = ['image_cache', 'user_avatar'];

  /// SQLite file header.
  static const _sqliteMagic = 'SQLite format 3\u0000';

  /// Suffix of the copy of the previous database kept next to it while importing.
  static const backupSuffix = '.bak';

  /// Credential columns of the `cookie` table: the session cookies of the account and the legacy password / security
  /// answer columns. The rows themselves (username, uid, bookkeeping) stay, so a restored backup still lists the
  /// accounts; each of them has to log in again.
  static const credentialColumns = {'cookie': "'{}'", 'password': 'NULL', 'question_id': 'NULL', 'answer': 'NULL'};

  /// Settings recording which account is logged in on this device.
  static final List<String> loginSettings = [
    SettingsKeys.loginUid.name,
    SettingsKeys.loginUsername.name,
    SettingsKeys.loginEmail.name,
  ];

  /// Make a copy of [databaseFile] for export, without credentials.
  ///
  /// The copy is taken with `VACUUM INTO` through a separate connection, so it is a consistent snapshot even while the
  /// app keeps using the database, and the live database is never modified: the logged in accounts on this device stay
  /// logged in.
  Future<Uint8List> exportSanitized(File databaseFile) async {
    final copy = File('${databaseFile.path}.export-${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      final source = sqlite3.open(databaseFile.path, mode: OpenMode.readOnly);
      try {
        source.execute('VACUUM INTO ?', [copy.path]);
      } finally {
        source.dispose();
      }
      final exported = sqlite3.open(copy.path);
      try {
        stripCredentials(exported);
        // Rewrite the file so removed rows leave no trace in free pages.
        exported.execute('VACUUM');
      } finally {
        exported.dispose();
      }
      info('exported database backup without credentials');
      return await copy.readAsBytes();
    } finally {
      if (copy.existsSync()) {
        await copy.delete();
      }
    }
  }

  /// Remove every credential from [db]: blank the credential columns of every account and delete the settings naming
  /// the logged in account. The list of accounts is kept.
  static void stripCredentials(Database db) {
    if (hasTable(db, 'cookie')) {
      final columns = db.select('PRAGMA table_info(cookie)').map((row) => row['name'].toString()).toSet();
      final assignments = credentialColumns.entries
          .where((e) => columns.contains(e.key))
          .map((e) => '${e.key} = ${e.value}')
          .join(', ');
      if (assignments.isNotEmpty) {
        db.execute('UPDATE cookie SET $assignments');
      }
    }
    if (hasTable(db, 'settings')) {
      final marks = List.filled(loginSettings.length, '?').join(', ');
      db.execute('DELETE FROM settings WHERE name IN ($marks)', loginSettings);
    }
  }

  /// Remove the cache path records from [db], see [cachePathTables].
  static void stripCachePaths(Database db) {
    for (final table in cachePathTables) {
      if (hasTable(db, table)) {
        db.execute('DELETE FROM $table');
      }
    }
  }

  /// Whether [db] has a table named [name].
  static bool hasTable(Database db, String name) =>
      db.select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [name]).isNotEmpty;

  /// Check whether [file] is a backup this app can import.
  ///
  /// The file is opened read-only and never modified. It passes when it is a SQLite database, `PRAGMA integrity_check`
  /// answers `ok`, the schema version is between 1 and [currentSchemaVersion] (older versions are migrated by the app on
  /// the next start, newer ones can not be) and the tables and columns this app relies on exist.
  Future<BackupValidation> validate(File file, {required int currentSchemaVersion}) async {
    final List<int> head;
    try {
      if (!file.existsSync()) {
        return const BackupValidation.failed(BackupProblem.unreadable, 'file not found');
      }
      final raf = await file.open();
      try {
        head = await raf.read(16);
      } finally {
        await raf.close();
      }
    } on FileSystemException catch (e) {
      return BackupValidation.failed(BackupProblem.unreadable, e.message);
    }
    if (head.length < 16 || String.fromCharCodes(head) != _sqliteMagic) {
      return const BackupValidation.failed(BackupProblem.notSqlite, 'header mismatch');
    }

    Database db;
    try {
      db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    } on SqliteException catch (e) {
      return BackupValidation.failed(BackupProblem.corrupted, e.message);
    }
    try {
      final integrity = db.select('PRAGMA integrity_check');
      final verdict = integrity.isEmpty ? null : integrity.first.columnAt(0)?.toString();
      if (verdict != 'ok') {
        return BackupValidation.failed(BackupProblem.corrupted, 'integrity_check: ${verdict ?? 'no answer'}');
      }
      final version = db.userVersion;
      if (version < 1) {
        return BackupValidation.failed(BackupProblem.invalidVersion, 'user_version=$version');
      }
      if (version > currentSchemaVersion) {
        return BackupValidation.failed(BackupProblem.newerSchema, 'user_version=$version > $currentSchemaVersion');
      }
      final tables = db
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((row) => row.columnAt(0).toString())
          .toSet();
      final missingTables = requiredTables.where((t) => !tables.contains(t)).toList();
      if (missingTables.isNotEmpty) {
        return BackupValidation.failed(BackupProblem.missingTables, 'tables: ${missingTables.join(', ')}');
      }
      final settingsColumns = db.select('PRAGMA table_info(settings)').map((row) => row['name'].toString()).toSet();
      final missingColumns = requiredSettingsColumns.where((c) => !settingsColumns.contains(c)).toList();
      if (missingColumns.isNotEmpty) {
        return BackupValidation.failed(BackupProblem.missingTables, 'settings columns: ${missingColumns.join(', ')}');
      }
      return BackupValidation.ok(version);
    } on SqliteException catch (e) {
      return BackupValidation.failed(BackupProblem.corrupted, e.message);
    } finally {
      db.dispose();
    }
  }

  /// Replace the app database [target] with the backup [source].
  ///
  /// The caller must have closed the database connection. Steps:
  ///
  /// 1. [validate] the source; an invalid file changes nothing ([BackupInvalidException]).
  /// 2. Prepare an import copy of the source with credentials and cache path records removed.
  /// 3. Copy the current database to `target.bak` and remove stale journal files.
  /// 4. Move the import copy into place and [validate] the result (plus [verify], if given).
  /// 5. When step 4 fails, put the copy from step 3 back ([BackupReplaceException] with `restored: true`).
  ///
  /// The `.bak` copy is kept after a successful import as a last resort.
  Future<BackupValidation> replaceDatabase({
    required File target,
    required File source,
    required int currentSchemaVersion,
    Future<bool> Function(File replaced)? verify,
  }) async {
    final check = await validate(source, currentSchemaVersion: currentSchemaVersion);
    if (!check.ok) {
      warning('refuse to import backup: $check');
      throw BackupInvalidException(check);
    }

    final importCopy = File('${target.path}.import.tmp');
    final previous = File('${target.path}$backupSuffix');
    try {
      await source.copy(importCopy.path);
      final db = sqlite3.open(importCopy.path);
      try {
        stripCredentials(db);
        stripCachePaths(db);
        db.execute('VACUUM');
      } finally {
        db.dispose();
      }

      if (target.existsSync()) {
        await target.copy(previous.path);
      }
      for (final suffix in ['-wal', '-shm', '-journal']) {
        final stale = File('${target.path}$suffix');
        if (stale.existsSync()) {
          await stale.delete();
        }
      }
      await importCopy.rename(target.path);

      final result = await validate(target, currentSchemaVersion: currentSchemaVersion);
      final verified = result.ok && (verify == null || await verify(target));
      if (!verified) {
        final restored = await _restore(previous, target);
        error('imported database failed verification ($result), restored=$restored');
        throw BackupReplaceException('verification failed: $result', restored: restored);
      }
      info('imported database backup (schema v${result.schemaVersion}), previous copy kept at ${previous.path}');
      return result;
    } on FileSystemException catch (e) {
      final restored = await _restore(previous, target);
      error('failed to replace database: $e, restored=$restored');
      throw BackupReplaceException(e.message, restored: restored);
    } finally {
      if (importCopy.existsSync()) {
        await importCopy.delete();
      }
    }
  }

  Future<bool> _restore(File previous, File target) async {
    if (!previous.existsSync()) {
      return false;
    }
    try {
      await previous.copy(target.path);
      return true;
    } on FileSystemException catch (e) {
      error('failed to restore previous database: $e');
      return false;
    }
  }
}
