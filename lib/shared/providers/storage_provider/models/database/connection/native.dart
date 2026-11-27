import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';
import 'package:tsdm_client/instance.dart';

/// Get the database storage file.
Future<File> get databaseFile async {
  final sep = Platform.pathSeparator;
  final dbPath = '${(await getApplicationSupportDirectory()).path}${sep}db${sep}mainV2.db';
  talker.debug('init database file at $dbPath');
  return File(dbPath);
}

/// Connect to database.
LazyDatabase connect() {
  return LazyDatabase(() async {
    if (Platform.isAndroid) {
      await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
      sqlite3.tempDirectory = (await getTemporaryDirectory()).path;
    }

    talker.debug('connect to database');
    return NativeDatabase.createBackgroundConnection(
      await databaseFile,
      setup: setupConnection,
    );
  });
}

/// What every connection to the app's database is opened with.
///
/// * `busy_timeout`: the Android background message service opens the same file from its own isolate: wait for a lock
///   instead of failing with "database is locked" when both write at the same moment (#80). First, the change of
///   the journal mode below waits with it too.
/// * `journal_mode = WAL`: a reader no longer waits for the writer of the other isolate, nor a writer for readers. Kept
///   in the file once set; the `-wal` and `-shm` files beside it are part of the database (`BackupRepository` folds
///   them in before it copies or replaces the file). A mode that could not be changed (the other isolate holds the
///   file in the old mode right after an update) stays as it was, and is changed at the next start.
/// * `synchronous = NORMAL`: with WAL a commit no longer waits for the disk, the checkpoint does. A power cut may
///   lose the last commits, never the consistency of the file.
void setupConnection(Database db) {
  db.execute('PRAGMA busy_timeout = 5000');
  try {
    // Answers the mode it is in afterwards.
    db.select('PRAGMA journal_mode = WAL');
  } on SqliteException catch (_) {
    // Held by the other isolate: stays as it was. Runs in the isolate of the connection, where there is no log.
  }
  db.execute('PRAGMA synchronous = NORMAL');
}
