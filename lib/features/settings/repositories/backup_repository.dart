import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
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

/// The password can not open the account logins of a backup, or they were written in a form this app does not read.
final class BackupSecretsPasswordException implements Exception {
  /// Constructor.
  const BackupSecretsPasswordException({this.unsupported = false});

  /// The secrets use a version or algorithm this app does not know (a newer app wrote them); a password can not help.
  final bool unsupported;

  @override
  String toString() => 'BackupSecretsPasswordException(unsupported=$unsupported)';
}

/// The account logins of a backup exported with a password: exactly what [BackupRepository.stripCredentials] removes.
final class BackupSecretsPayload {
  /// Constructor.
  const BackupSecretsPayload({required this.accounts, required this.loginSettings});

  /// Decode from the JSON written by [toJson].
  factory BackupSecretsPayload.fromJson(Map<String, dynamic> json) => BackupSecretsPayload(
    accounts: [
      for (final e in (json['accounts'] as List<dynamic>? ?? const [])) Map<String, Object?>.from(e as Map),
    ],
    loginSettings: Map<String, Object?>.from(json['login_settings'] as Map? ?? const {}),
  );

  /// One map per account that had anything to log in with, keyed by `cookie` table column (`uid`, `username`,
  /// `cookie`, `password`, `question_id`, `answer`).
  final List<Map<String, Object?>> accounts;

  /// The settings naming the logged in account, setting name to value.
  final Map<String, Object?> loginSettings;

  /// Number of accounts carried.
  int get accountCount => accounts.length;

  /// Encode for encryption.
  Map<String, dynamic> toJson() => {'version': 1, 'accounts': accounts, 'login_settings': loginSettings};
}

/// Encrypted [BackupSecretsPayload] as stored in the backup.
final class _SealedSecrets {
  const _SealedSecrets({
    required this.iterations,
    required this.salt,
    required this.nonce,
    required this.mac,
    required this.cipherText,
  });

  final int iterations;
  final List<int> salt;
  final List<int> nonce;
  final List<int> mac;
  final List<int> cipherText;
}

/// Backups of the app database (the "匯出資料" / "匯入資料" settings).
///
/// A backup is a copy of the SQLite database file, but never a raw copy: everything that logs a device in is removed
/// first, so a backup can be shared or kept on another device without carrying the accounts of this one. On request
/// the removed logins travel inside the backup all the same, but encrypted with a password the user chooses
/// (PBKDF2-HMAC-SHA256 key, AES-256-GCM, see [secretsTable]); the password is never stored. Importing checks the file
/// before anything is overwritten and puts the previous database back when the replacement fails.
final class BackupRepository with LoggerMixin {
  /// Constructor. [kdfIterations] is the PBKDF2 cost used when exporting; imports read the cost from the backup.
  const BackupRepository({this.kdfIterations = defaultKdfIterations});

  /// PBKDF2 iterations for new exports; about a second of work on a phone, enough to make guessing expensive.
  static const defaultKdfIterations = 200000;

  /// PBKDF2 iterations used by [exportSanitized] when a password is given.
  final int kdfIterations;

  /// Table carrying the encrypted account logins in a backup exported with a password (one row, `id = 1`). It only
  /// ever exists in backup files: [replaceDatabase] drops it from the copy it installs.
  static const secretsTable = 'backup_secrets';

  static const _secretsVersion = 1;
  static const _kdfName = 'pbkdf2-hmac-sha256';
  static const _saltLength = 16;

  /// Bound to the ciphertext so the secrets of one context can not be replayed as another.
  static final List<int> _aad = utf8.encode('tsdm_client.backup_secrets.v1');

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
  ///
  /// With [secretsPassword] the credentials are removed from the tables all the same, but stored encrypted with that
  /// password in [secretsTable], so another device can restore them with [unlockSecrets] and [replaceDatabase].
  Future<Uint8List> exportSanitized(File databaseFile, {String? secretsPassword}) async {
    final copy = File('${databaseFile.path}.export-${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      final source = sqlite3.open(databaseFile.path, mode: OpenMode.readOnly);
      try {
        source.execute('VACUUM INTO ?', [copy.path]);
      } finally {
        source.dispose();
      }
      final exported = sqlite3.open(copy.path);
      var accounts = 0;
      try {
        final password = secretsPassword;
        final payload = password == null ? null : readCredentials(exported);
        stripCredentials(exported);
        if (payload != null && password != null) {
          accounts = payload.accountCount;
          _writeSecrets(exported, await _seal(payload, password));
        }
        // Rewrite the file so removed rows leave no trace in free pages.
        exported.execute('VACUUM');
      } finally {
        exported.dispose();
      }
      if (secretsPassword == null) {
        info('exported database backup without credentials');
      } else {
        info('exported database backup with the logins of $accounts accounts encrypted');
      }
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

  /// Collect what [stripCredentials] would remove from [db]: every account row that has a session cookie or a
  /// password, and the settings naming the logged in account.
  static BackupSecretsPayload readCredentials(Database db) {
    final accounts = <Map<String, Object?>>[];
    if (hasTable(db, 'cookie')) {
      final columns = db.select('PRAGMA table_info(cookie)').map((row) => row['name'].toString()).toSet();
      final wanted = ['uid', 'username', ...credentialColumns.keys].where(columns.contains).toList();
      for (final row in db.select('SELECT ${wanted.join(', ')} FROM cookie')) {
        final cookie = row['cookie']?.toString() ?? '';
        final loggedIn = cookie.isNotEmpty && cookie != '{}';
        if (!loggedIn && row['password'] == null) {
          continue;
        }
        accounts.add({for (final column in wanted) column: row[column]});
      }
    }
    final login = <String, Object?>{};
    if (hasTable(db, 'settings')) {
      final marks = List.filled(loginSettings.length, '?').join(', ');
      for (final row in db.select(
        'SELECT name, int_value, string_value FROM settings WHERE name IN ($marks)',
        loginSettings,
      )) {
        login[row['name'].toString()] = row['int_value'] ?? row['string_value'];
      }
    }
    return BackupSecretsPayload(accounts: accounts, loginSettings: login);
  }

  /// Put the logins of [payload] back into [db]: the credential columns of every account row that still exists (by
  /// `uid`) and the settings naming the logged in account. Returns the number of account rows updated.
  static int applyCredentials(Database db, BackupSecretsPayload payload) {
    var restored = 0;
    if (hasTable(db, 'cookie')) {
      final columns = db.select('PRAGMA table_info(cookie)').map((row) => row['name'].toString()).toSet();
      for (final account in payload.accounts) {
        final uid = account['uid'];
        final present = credentialColumns.keys.where((c) => columns.contains(c) && account.containsKey(c)).toList();
        if (uid == null || present.isEmpty) {
          continue;
        }
        db.execute('UPDATE cookie SET ${present.map((c) => '$c = ?').join(', ')} WHERE uid = ?', [
          ...present.map((c) => account[c]),
          uid,
        ]);
        restored += db.updatedRows;
      }
    }
    if (hasTable(db, 'settings')) {
      for (final entry in payload.loginSettings.entries) {
        final value = entry.value;
        if (!loginSettings.contains(entry.key) || value == null) {
          continue;
        }
        final column = value is int ? 'int_value' : 'string_value';
        db.execute('INSERT OR REPLACE INTO settings (name, $column) VALUES (?, ?)', [entry.key, value]);
      }
    }
    return restored;
  }

  /// Whether [db] carries encrypted account logins, see [secretsTable].
  static bool hasSecrets(Database db) =>
      hasTable(db, secretsTable) && db.select('SELECT 1 FROM $secretsTable WHERE id = 1').isNotEmpty;

  /// Whether the backup [file] carries encrypted account logins. False for anything that is not a readable database.
  Future<bool> containsSecrets(File file) async {
    try {
      final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
      try {
        return hasSecrets(db);
      } finally {
        db.dispose();
      }
    } on SqliteException {
      return false;
    }
  }

  /// Decrypt the account logins of the backup [file] with [password].
  ///
  /// The file is opened read-only and nothing else is touched, so this can run before an import is committed to.
  /// Throws [BackupSecretsPasswordException] when the password is wrong (the authentication tag does not verify) or
  /// the secrets were written in a form this app does not read; [ArgumentError] when the file has no secrets.
  Future<BackupSecretsPayload> unlockSecrets(File file, {required String password}) async {
    final Row row;
    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      if (!hasSecrets(db)) {
        throw ArgumentError('backup has no encrypted account logins');
      }
      row = db.select('SELECT version, kdf, iterations, salt, nonce, mac, ciphertext FROM $secretsTable WHERE id = 1').first;
    } finally {
      db.dispose();
    }
    final iterations = row['iterations'];
    if (row['version'] != _secretsVersion || row['kdf'] != _kdfName || iterations is! int || iterations < 1) {
      warning('backup secrets use version ${row['version']} kdf ${row['kdf']}, not supported');
      throw const BackupSecretsPasswordException(unsupported: true);
    }
    final key = await _deriveKey(password, row['salt'] as Uint8List, iterations);
    final List<int> clear;
    try {
      clear = await AesGcm.with256bits().decrypt(
        SecretBox(row['ciphertext'] as Uint8List, nonce: row['nonce'] as Uint8List, mac: Mac(row['mac'] as Uint8List)),
        secretKey: key,
        aad: _aad,
      );
    } on SecretBoxAuthenticationError {
      warning('backup secrets: wrong password');
      throw const BackupSecretsPasswordException();
    }
    final payload = BackupSecretsPayload.fromJson(jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
    info('unlocked the logins of ${payload.accountCount} accounts from the backup');
    return payload;
  }

  Future<_SealedSecrets> _seal(BackupSecretsPayload payload, String password) async {
    final salt = _randomBytes(_saltLength);
    final key = await _deriveKey(password, salt, kdfIterations);
    final algorithm = AesGcm.with256bits();
    final nonce = algorithm.newNonce();
    final box = await algorithm.encrypt(
      utf8.encode(jsonEncode(payload.toJson())),
      secretKey: key,
      nonce: nonce,
      aad: _aad,
    );
    return _SealedSecrets(
      iterations: kdfIterations,
      salt: salt,
      nonce: nonce,
      mac: box.mac.bytes,
      cipherText: box.cipherText,
    );
  }

  static Future<SecretKey> _deriveKey(String password, List<int> salt, int iterations) =>
      Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
          .deriveKeyFromPassword(password: password, nonce: salt);

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  static void _writeSecrets(Database db, _SealedSecrets sealed) {
    db
      ..execute('DROP TABLE IF EXISTS $secretsTable')
      ..execute(
        'CREATE TABLE $secretsTable (id INTEGER PRIMARY KEY, version INTEGER NOT NULL, kdf TEXT NOT NULL, '
        'iterations INTEGER NOT NULL, salt BLOB NOT NULL, nonce BLOB NOT NULL, mac BLOB NOT NULL, '
        'ciphertext BLOB NOT NULL)',
      )
      ..execute(
        'INSERT INTO $secretsTable (id, version, kdf, iterations, salt, nonce, mac, ciphertext) '
        'VALUES (1, ?, ?, ?, ?, ?, ?, ?)',
        [
          _secretsVersion,
          _kdfName,
          sealed.iterations,
          Uint8List.fromList(sealed.salt),
          Uint8List.fromList(sealed.nonce),
          Uint8List.fromList(sealed.mac),
          Uint8List.fromList(sealed.cipherText),
        ],
      );
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
  ///
  /// [secrets], obtained with [unlockSecrets], are written back into the import copy in step 2 so the accounts are
  /// logged in after the import; [secretsTable] is dropped from the copy either way.
  Future<BackupValidation> replaceDatabase({
    required File target,
    required File source,
    required int currentSchemaVersion,
    Future<bool> Function(File replaced)? verify,
    BackupSecretsPayload? secrets,
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
        if (secrets != null) {
          final restored = applyCredentials(db, secrets);
          info('restored the logins of $restored accounts into the import copy');
        }
        db
          ..execute('DROP TABLE IF EXISTS $secretsTable')
          ..execute('VACUUM');
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
