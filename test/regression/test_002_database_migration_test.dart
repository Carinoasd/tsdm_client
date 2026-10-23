import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';

import '../data/generated_migrations/schema.dart';

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init();
  });

  test('upgrade from 1 to 2', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(1);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 2);
    await db.close();
  });

  test('upgrade from 2 to 3', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(2);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 3);
    await db.close();
  });

  test('upgrade from 3 to 4', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(3);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 4);
    await db.close();
  });

  test('upgrade from 4 to 5', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(4);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 5);
    await db.close();
  });

  // This test is skipped because it fails to run in github actions but passed
  // on a local machine:
  // ❌ /home/runner/work/tsdm_client/tsdm_client/test/regression/test_002_database_migration_test.dart: upgrade from 5 to 6 (failed)
  //   SqliteException(1): while executing, SQL logic error, SQL logic error (code 1)
  //     Causing statement: ALTER TABLE "broadcast_message" ADD COLUMN "already_read" INTEGER NULL CHECK ("already_read" IN (0, 1));, parameters:
  //   package:sqlite3/src/implementation/exception.dart 75:3                                                     throwException
  //   package:sqlite3/src/implementation/database.dart 244:9                                                     DatabaseImplementation.execute
  //   package:drift/src/sqlite3/database.dart 145:16                                                             Sqlite3Delegate.runWithArgsSync
  //   package:drift/native.dart 378:30                                                                           _NativeDelegate.runCustom.<fn>
  //   dart:async                                                                                                 new Future.sync
  //   package:drift/native.dart 378:19                                                                           _NativeDelegate.runCustom
  //   package:drift/src/runtime/executor/helpers/engines.dart 115:19                                             _BaseExecutor.runCustom.<fn>
  test('upgrade from 5 to 6', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(5);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 6);
    await db.close();
  }, skip: true);

  test('upgrade from 6 to 7', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(6);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 7);
    await db.close();
  });

  test('upgrade from 7 to 8', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(7);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 8);
    await db.close();
  });

  test('upgrade from 8 to 9', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(8);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 9);
    await db.close();
  });

  test('upgrade from 9 to 10', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(9);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 10);
    await db.close();
  });

  test('upgrade from 10 to 11', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(10);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 11);
    await db.close();
  });

  test('upgrade from 11 to 12', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(11);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 12);
    await db.close();
  });

  test('upgrade from 12 to 13', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(12);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 13);
    await db.close();
  });

  test('upgrade from 13 to 14', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(13);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 14);
    await db.close();
  });

  test('the 13 to 14 step runs again safely when another connection already added the columns', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    // The columns are there but the version is still 13: the other connection is between its ALTER TABLE and its
    // version write (the background service isolate and the app opening the file together after an update).
    final schema = await verifier.schemaAt(14);
    schema.rawDatabase.execute('PRAGMA user_version = 13');
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 14);
    await db.close();
  });

  test('upgrade from 13 to 14 keeps stored notices and leaves their metadata unknown', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(13);
    schema.rawDatabase.execute(
      'INSERT INTO notice (uid, nid, timestamp, data, already_read) VALUES (1000, 1984, 100, '
      '\'<a href="home.php?mod=space&uid=2000">x</a>\', 0)',
    );
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 14);
    final rows = await db.select(db.notice).get();
    expect(rows, hasLength(1));
    expect(rows.single.nid, 1984);
    expect(rows.single.alreadyRead, false);
    // Old rows never get an author guessed from the links in the body.
    expect(rows.single.authorId, isNull);
    expect(rows.single.ignoreType, isNull);
    await db.close();
  });

  test('upgrade from 14 to 15', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(14);
    final db = AppDatabase(connection);
    await verifier.migrateAndValidate(db, 15);
    await db.close();
  });

  test(
    'upgrade from 13 to 15 in one go keeps stored notices and adds the offline thread table with its index',
    () async {
      final verifier = SchemaVerifier(GeneratedHelper());
      final schema = await verifier.schemaAt(13);
      schema.rawDatabase
        ..execute(
          'INSERT INTO notice (uid, nid, timestamp, data, already_read) VALUES (1000, 1984, 100, '
          '\'<a href="home.php?mod=space&uid=2000">x</a>\', 0)',
        )
        ..execute(
          'INSERT INTO thread_visit_history (uid, tid, username, thread_title, fid, forum_name, visit_time) '
          "VALUES (1000, 42, 'Alice', 'a thread', 4, 'a forum', 1760000000)",
        );
      final db = AppDatabase(schema.newConnection());
      await verifier.migrateAndValidate(db, 15);
      expect((await db.select(db.notice).get()).single.nid, 1984);
      expect((await db.select(db.threadVisitHistory).get()).single.threadTitle, 'a thread');
      expect(await db.select(db.offlineThread).get(), isEmpty);
      final index = await db
          .customSelect("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'offline_thread_recent'")
          .getSingle();
      expect(index.read<String>('sql'), contains('(uid, tid, last_used_at, size)'));
      await db.close();
    },
  );

  test('a database at schema 15 without the eviction index (a development build) gets it on open', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(15);
    schema.rawDatabase.execute('DROP INDEX offline_thread_recent');
    final db = AppDatabase(schema.newConnection());
    final index = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'offline_thread_recent'")
        .get();
    expect(index, hasLength(1));
    await db.close();
  });

  test('the 14 to 15 step runs again safely when another connection already created the table', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    // The table is there but the version is still 14: the background service isolate and the app opening the file
    // together after an update.
    final schema = await verifier.schemaAt(15);
    schema.rawDatabase.execute('PRAGMA user_version = 14');
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 15);
    await db.close();
  });

  test('upgrade from 14 to 15 keeps every stored row and starts with no offline thread page', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(14);
    schema.rawDatabase
      ..execute(
        'INSERT INTO cookie (username, uid, cookie, last_checkin, session_expired_at) '
        "VALUES ('Alice', 1000, '{\"auth\":\"x\"}', 1760000000, NULL)",
      )
      ..execute("INSERT INTO settings (name, bool_value) VALUES ('enableDebugOperations', 1)")
      ..execute(
        'INSERT INTO thread_visit_history (uid, tid, username, thread_title, fid, forum_name, visit_time) '
        "VALUES (1000, 42, 'Alice', 'a thread', 4, 'a forum', 1760000000)",
      )
      ..execute('INSERT INTO replied_thread (uid, tid, fid, time) VALUES (1000, 42, 4, 1760000000)')
      ..execute(
        'INSERT INTO notice (uid, nid, timestamp, data, already_read, ignore_type, author_id) '
        "VALUES (1000, 7, 100, 'x', 1, 'post', 2000)",
      )
      ..execute(
        "INSERT INTO custom_image (id, name, url, sort_order, added_at) VALUES (1, 's', 'https://example.com/s.png', 0, 1)",
      );
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 15);

    final cookies = await db.select(db.cookie).get();
    expect(cookies.single.username, 'Alice');
    expect(cookies.single.cookie, '{"auth":"x"}');
    expect(cookies.single.lastCheckin, DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000));
    expect((await db.select(db.settings).get()).single.boolValue, isTrue);
    final history = await db.select(db.threadVisitHistory).get();
    expect(history.single.threadTitle, 'a thread');
    expect((await db.select(db.repliedThread).get()).single.tid, 42);
    final notices = await db.select(db.notice).get();
    expect(notices.single.authorId, 2000);
    expect(notices.single.ignoreType, 'post');
    expect((await db.select(db.customImage).get()).single.url, 'https://example.com/s.png');
    expect(await db.select(db.offlineThread).get(), isEmpty);
    await db.close();
  });

  test('upgrade from 15 to 16 keeps the notices, the new columns empty', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(15);
    schema.rawDatabase.execute(
      'INSERT INTO notice (uid, nid, timestamp, data, already_read, ignore_type, author_id) '
      "VALUES (1000, 7, 100, 'x', 0, 'post', 2000)",
    );
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 16);
    final row = (await db.select(db.notice).get()).single;
    expect((row.authorId, row.ignoreType, row.alreadyRead), (2000, 'post', false));
    expect((row.author, row.fromId, row.fromIdType), (null, null, null));
    await db.close();
  });

  test('the 15 to 16 step runs again safely when another connection already added the columns', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    // Every column there, the version still 15: the background service isolate and the app opening the file together.
    final schema = await verifier.schemaAt(16);
    schema.rawDatabase.execute('PRAGMA user_version = 15');
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 16);
    await db.close();
  });

  test('the 15 to 16 step adds what another connection left out', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(15);
    schema.rawDatabase.execute('ALTER TABLE notice ADD COLUMN "author" TEXT NULL');
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 16);
    await db.close();
  });

  for (final from in [10, 13, 14]) {
    test('upgrade from $from to 16 in one go', () async {
      final verifier = SchemaVerifier(GeneratedHelper());
      final connection = await verifier.startAt(from);
      final db = AppDatabase(connection);
      await verifier.migrateAndValidate(db, 16);
      await db.close();
    });
  }

  test('upgrade from 16 to 17 keeps the visits, where the reading stopped not known yet', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(16);
    schema.rawDatabase.execute(
      'INSERT INTO thread_visit_history (uid, tid, username, thread_title, fid, forum_name, visit_time) '
      "VALUES (1000, 1264975, 'Alice', 'title', 2, 'forum', 100)",
    );
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 17);
    final row = (await db.select(db.threadVisitHistory).get()).single;
    expect((row.uid, row.tid, row.threadTitle, row.fid), (1000, 1264975, 'title', 2));
    expect((row.lastPage, row.lastPid, row.lastFloor, row.seenReplies), (null, null, null, null));
    await db.close();
  });

  test('the 16 to 17 step runs again safely when another connection already added the columns', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    // Every column there, the version still 16: the background service isolate and the app opening the file together.
    final schema = await verifier.schemaAt(17);
    schema.rawDatabase.execute('PRAGMA user_version = 16');
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 17);
    await db.close();
  });

  test('the 16 to 17 step adds what another connection left out', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(16);
    schema.rawDatabase.execute('ALTER TABLE thread_visit_history ADD COLUMN "last_page" INTEGER NULL');
    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 17);
    await db.close();
  });

  for (final from in [10, 14, 15]) {
    test('upgrade from $from to 17 in one go', () async {
      final verifier = SchemaVerifier(GeneratedHelper());
      final connection = await verifier.startAt(from);
      final db = AppDatabase(connection);
      await verifier.migrateAndValidate(db, 17);
      await db.close();
    });
  }
}
