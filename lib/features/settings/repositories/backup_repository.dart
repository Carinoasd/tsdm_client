import 'dart:io';
import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Backups of the app database (the "匯出資料" / "匯入資料" settings).
///
/// A backup is a copy of the SQLite database file, but never a raw copy: everything that logs a device in is removed
/// first, so a backup can be shared or kept on another device without carrying the accounts of this one.
final class BackupRepository with LoggerMixin {
  /// Constructor.
  const BackupRepository();

  /// Tables holding credentials: session cookies of every account and the legacy password / security answer columns.
  static const credentialTables = ['cookie'];

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

  /// Remove every credential from [db]: the cookie table and the settings naming the logged in account.
  static void stripCredentials(Database db) {
    for (final table in credentialTables) {
      if (hasTable(db, table)) {
        db.execute('DELETE FROM $table');
      }
    }
    if (hasTable(db, 'settings')) {
      final marks = List.filled(loginSettings.length, '?').join(', ');
      db.execute('DELETE FROM settings WHERE name IN ($marks)', loginSettings);
    }
  }

  /// Whether [db] has a table named [name].
  static bool hasTable(Database db, String name) =>
      db.select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [name]).isNotEmpty;
}
