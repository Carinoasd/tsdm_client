/// The app's database in WAL mode, and the disk work taken off the main isolate.
///
/// * Every connection sets `journal_mode = WAL`, `synchronous = NORMAL` and keeps `busy_timeout`; a second connection
///   reads while the first holds a write open.
/// * A backup is one file: the export holds the writes still in `-wal`, is not in WAL mode itself and leaves nothing
///   beside the database; an import folds the log of the replaced database into its `.bak` copy first, installs the
///   new file out of WAL mode and leaves no `-wal`, `-shm` or copy behind, also when the previous database is put back.
/// * The sizes of the cache directories and emptying them are plain functions (run with `Isolate.run`), the logs older
///   than a week are deleted without blocking, and an emoji read once is kept in memory.
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/models/models.dart';
import 'package:tsdm_client/features/settings/repositories/backup_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_trim.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/connection/native.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Byte 18 of a database file: 2 in WAL mode, 1 otherwise.
int _writeVersion(File file) => file.readAsBytesSync()[18];

List<String> _names(Directory dir) => dir.listSync().map((e) => p.basename(e.path)).toList()..sort();

void main() {
  late Directory dir;
  const repository = BackupRepository();
  late int schemaVersion;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() => dir = Directory.systemTemp.createTempSync('tsdm_wal_'));
  tearDown(() {
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });

  /// An app database at [path] as the app leaves it: in WAL mode, closed.
  Future<File> makeDatabase(String path, {required String username, int uid = 1000}) async {
    final file = File(path);
    final db = AppDatabase(NativeDatabase(file, setup: setupConnection));
    final storage = StorageProvider(db, {}, {});
    await storage.saveCookie(username: username, uid: uid, cookie: {'Ystv_2132_auth': '$username-token'});
    await storage.saveInt(SettingsKeys.loginUid.name, uid);
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

  /// A connection as the app's, with a row written that no checkpoint moved into the file yet.
  Database openWithPendingWrite(File file, {required int tid}) {
    final live = sqlite3.open(file.path);
    setupConnection(live);
    live
      ..execute('PRAGMA wal_autocheckpoint = 0')
      ..execute(
        'INSERT INTO thread_visit_history (uid, tid, username, thread_title, fid, forum_name, visit_time) '
        "VALUES (1000, $tid, 'Alice', 'the last write', 4, 'forum', 1760000000)",
      );
    expect(File('${file.path}-wal').lengthSync(), greaterThan(0), reason: 'the write is in the log');
    return live;
  }

  group('the connection', () {
    test('WAL, synchronous NORMAL and the busy timeout', () {
      final db = sqlite3.open('${dir.path}/a.db');
      addTearDown(db.dispose);
      setupConnection(db);
      expect(db.select('PRAGMA journal_mode').single.values.single, 'wal');
      expect(db.select('PRAGMA synchronous').single.values.single, 1);
      expect(db.select('PRAGMA busy_timeout').single.values.single, 5000);
    });

    test('a second connection reads while the first holds a write open', () {
      final writer = sqlite3.open('${dir.path}/a.db');
      addTearDown(writer.dispose);
      setupConnection(writer);
      writer
        ..execute('CREATE TABLE t (x INTEGER)')
        ..execute('INSERT INTO t VALUES (1)')
        ..execute('BEGIN IMMEDIATE')
        ..execute('INSERT INTO t VALUES (2)');
      final reader = sqlite3.open('${dir.path}/a.db');
      addTearDown(reader.dispose);
      setupConnection(reader);
      reader.execute('PRAGMA busy_timeout = 0');
      expect(reader.select('SELECT count(*) FROM t').single.values.single, 1, reason: 'not locked out, what is committed');
      writer.execute('COMMIT');
      expect(reader.select('SELECT count(*) FROM t').single.values.single, 2);
    });

    test('the mode stays in the file; the log goes when the last connection closes', () async {
      final file = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      expect(_writeVersion(file), 2);
      expect(_names(dir), ['mainV2.db']);
    });
  });

  group('export', () {
    test('holds what is still in the log, is one file out of WAL mode, leaves nothing behind', () async {
      final file = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final live = openWithPendingWrite(file, tid: 77);
      final bytes = await repository.exportSanitized(file);
      expect(_names(dir), ['mainV2.db', 'mainV2.db-shm', 'mainV2.db-wal'], reason: 'only the live database');
      live.dispose();

      final exported = File('${dir.path}/backup.db')..writeAsBytesSync(bytes);
      expect(_writeVersion(exported), 1, reason: 'a backup is never in WAL mode');
      final db = sqlite3.open(exported.path, mode: OpenMode.readOnly);
      try {
        expect(
          db.select('SELECT tid FROM thread_visit_history ORDER BY tid').map((r) => r['tid']),
          [42, 77],
        );
      } finally {
        db.dispose();
      }
      expect(_names(dir), ['backup.db', 'mainV2.db'], reason: 'reading the backup leaves no -wal or -shm');
      expect((await repository.validate(exported, currentSchemaVersion: schemaVersion)).ok, isTrue);
    });
  });

  group('import', () {
    test('a backup in WAL mode is installed as one file out of it', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final sourceDir = Directory('${dir.path}/picked')..createSync();
      // A database file copied by hand: still in WAL mode.
      final source = await makeDatabase('${sourceDir.path}/other.db', username: 'Bob', uid: 2000);
      expect(_writeVersion(source), 2);

      final result = await repository.replaceDatabase(
        target: target,
        source: source,
        currentSchemaVersion: schemaVersion,
      );
      expect(result.ok, isTrue);
      expect(_names(dir), ['mainV2.db', 'picked'], reason: 'no -wal, -shm, .bak or import copy');
      expect(_writeVersion(target), 1);
      final db = sqlite3.open(target.path, mode: OpenMode.readOnly);
      try {
        expect(db.select('SELECT thread_title FROM thread_visit_history').single.values.single, 'thread of Bob');
      } finally {
        db.dispose();
      }

      // The app opens it in WAL mode again.
      final app = sqlite3.open(target.path);
      setupConnection(app);
      expect(app.select('PRAGMA journal_mode').single.values.single, 'wal');
      app.dispose();
      expect(_names(dir), ['mainV2.db', 'picked']);
    });

    test('the log of the replaced database is not applied to the new one', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final source = await makeDatabase('${dir.path}/other.db', username: 'Bob', uid: 2000);
      // The app ended without closing its connection: the last write is in the log only.
      final live = openWithPendingWrite(target, tid: 77);
      addTearDown(live.dispose);

      await repository.replaceDatabase(target: target, source: source, currentSchemaVersion: schemaVersion);
      expect(File('${target.path}-wal').existsSync(), isFalse);
      expect(File('${target.path}-shm').existsSync(), isFalse);
      final db = sqlite3.open(target.path, mode: OpenMode.readOnly);
      try {
        expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
        expect(db.select('SELECT tid FROM thread_visit_history').map((r) => r['tid']), [42], reason: "Bob's only");
        expect(db.select('SELECT thread_title FROM thread_visit_history').single.values.single, 'thread of Bob');
      } finally {
        db.dispose();
      }
    });

    test('a failed verification puts the previous database back with its last writes, nothing left beside', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final sourceDir = Directory('${dir.path}/picked')..createSync();
      final source = await makeDatabase('${sourceDir.path}/other.db', username: 'Bob', uid: 2000);
      final live = openWithPendingWrite(target, tid: 77);

      await expectLater(
        repository.replaceDatabase(
          target: target,
          source: source,
          currentSchemaVersion: schemaVersion,
          verify: (replaced) async {
            // What a check of the new file may leave beside it.
            File('${replaced.path}-wal').writeAsStringSync('of the failed one');
            File('${replaced.path}-shm').writeAsStringSync('of the failed one');
            return false;
          },
        ),
        throwsA(isA<BackupReplaceException>().having((e) => e.restored, 'restored', isTrue)),
      );
      live.dispose();
      expect(_names(dir), ['mainV2.db', 'picked'], reason: 'no log of the failed database, no .bak, no import copy');

      final db = sqlite3.open(target.path);
      try {
        expect(db.select('PRAGMA integrity_check').single.values.single, 'ok');
        expect(
          db.select('SELECT tid FROM thread_visit_history ORDER BY tid').map((r) => r['tid']),
          [42, 77],
          reason: 'the write that was only in the log is in the copy put back',
        );
        expect(db.select('SELECT count(*) FROM cookie').single.values.single, 1, reason: "Alice's login");
      } finally {
        db.dispose();
      }
    });

    test('an invalid source in WAL mode changes nothing and leaves nothing beside the database', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final before = target.readAsBytesSync();
      final sourceDir = Directory('${dir.path}/picked')..createSync();
      final source = File('${sourceDir.path}/other.db');
      sqlite3.open(source.path)
        ..execute('PRAGMA journal_mode = WAL')
        ..execute('CREATE TABLE t (x INTEGER)')
        ..execute('PRAGMA user_version = 1')
        ..dispose();
      expect(_writeVersion(source), 2);

      await expectLater(
        repository.replaceDatabase(target: target, source: source, currentSchemaVersion: schemaVersion),
        throwsA(isA<BackupInvalidException>()),
      );
      expect(target.readAsBytesSync(), before);
      expect(_names(dir), ['mainV2.db', 'picked']);
    });

    test('leftovers: the -wal and -shm of a copy go with it, those of the database stay', () async {
      final target = await makeDatabase('${dir.path}/mainV2.db', username: 'Alice');
      final old = DateTime.now().subtract(const Duration(hours: 2));
      for (final name in [
        'mainV2.db.import.tmp',
        'mainV2.db.import.tmp-wal',
        'mainV2.db.import.tmp-shm',
        'mainV2.db.export-1.tmp-journal',
        'mainV2.db.bak',
        'mainV2.db.bak-wal',
        'mainV2.db-wal',
        'mainV2.db-shm',
        'mainV2.db.bak.kept',
      ]) {
        File('${dir.path}/$name')
          ..writeAsStringSync('x')
          ..setLastModifiedSync(old);
      }
      await BackupRepository.deleteLeftovers(target);
      expect(_names(dir), ['mainV2.db', 'mainV2.db-shm', 'mainV2.db-wal', 'mainV2.db.bak.kept']);
    });
  });

  group('migration', () {
    test('the indexes of schema 21 serve the lists and the clean up', () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      Future<String> plan(String sql) async =>
          (await db.customSelect('EXPLAIN QUERY PLAN $sql').get()).map((r) => r.read<String>('detail')).join('; ');

      expect(
        await plan('SELECT * FROM notice WHERE uid = 1000 ORDER BY timestamp DESC LIMIT 500'),
        allOf(contains('notice_uid_time'), isNot(contains('TEMP B-TREE'))),
      );
      expect(
        await plan('SELECT * FROM personal_message WHERE uid = 1000 AND timestamp >= 5 ORDER BY timestamp DESC'),
        allOf(contains('personal_message_uid_time'), isNot(contains('TEMP B-TREE'))),
      );
      expect(
        await plan('SELECT * FROM thread_visit_history WHERE uid = 1000 ORDER BY visit_time DESC'),
        allOf(contains('thread_visit_history_uid_time'), isNot(contains('TEMP B-TREE'))),
      );
      expect(
        await plan('SELECT count(*) FROM image_cache WHERE last_used_time <= 5'),
        contains('image_cache_last_used'),
      );
      expect(
        await plan('SELECT * FROM broadcast_message WHERE uid = 1000 ORDER BY timestamp DESC LIMIT 500'),
        allOf(contains('sqlite_autoindex_broadcast_message_1'), isNot(contains('TEMP B-TREE'))),
        reason: 'its primary key is (uid, timestamp): no index of its own',
      );
    });
  });

  group('disk work off the main isolate', () {
    test('the size of a directory, and emptying it', () {
      final cache = Directory('${dir.path}/cache')..createSync();
      File('${cache.path}/a').writeAsBytesSync(List.filled(10, 0));
      Directory('${cache.path}/sub').createSync();
      File('${cache.path}/sub/b').writeAsBytesSync(List.filled(32, 0));
      final empty = Directory('${dir.path}/empty')..createSync();
      expect(directorySizeOf(cache.path), greaterThanOrEqualTo(42));
      expect(directorySizeOf(empty.path), 0);
      expect(directorySizeOf('${dir.path}/missing'), 0);

      emptyDirectory(cache.path);
      expect(cache.existsSync(), isTrue, reason: 'the directory stays');
      expect(cache.listSync(), isEmpty);
      emptyDirectory('${dir.path}/missing');
    });

    test('logs older than a week are deleted, the others stay', () async {
      final logs = Directory('${dir.path}/log')..createSync();
      final now = DateTime(2026, 11, 27, 12);
      final old = File('${logs.path}/tsdm_client_20261101.log')
        ..writeAsStringSync('old')
        ..setLastModifiedSync(now.subtract(const Duration(days: 9)));
      final recent = File('${logs.path}/tsdm_client_20261125.log')
        ..writeAsStringSync('recent')
        ..setLastModifiedSync(now.subtract(const Duration(days: 2)));
      await deleteOldLogs(logs, now);
      expect(old.existsSync(), isFalse);
      expect(recent.existsSync(), isTrue);
      await deleteOldLogs(Directory('${dir.path}/missing'), now);
    });
  });

  group('the emoji read for a widget', () {
    late Directory tmp;
    late AppDatabase db;
    late ImageCacheProvider provider;
    final first = Uint8List.fromList([0xff, 0xd8, 0xff, 1]);
    final second = Uint8List.fromList([0xff, 0xd8, 0xff, 2, 2]);

    setUpAll(() async {
      tmp = Directory.systemTemp.createTempSync('tsdm_emoji_lru_');
      TestWidgetsFlutterBinding.ensureInitialized();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => switch (call.method) {
          'getApplicationCachePath' || 'getApplicationCacheDirectory' => '${tmp.path}/cache',
          'getApplicationSupportPath' || 'getApplicationSupportDirectory' => '${tmp.path}/support',
          'getTemporaryPath' || 'getTemporaryDirectory' => '${tmp.path}/tmp',
          _ => null,
        },
      );
      await initCache();
    });
    tearDownAll(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        null,
      );
      tmp.deleteSync(recursive: true);
    });

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      final settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings, dispose: (s) => s.dispose())
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
      await settings.init();
      provider = ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio(), cookie: CookieProvider.buildEmpty()));
    });
    tearDown(() async {
      await provider.dispose();
      await getIt.reset();
      await db.close();
    });

    File fileOf(String name) => File('${tmp.path}/support/emoji/$name.jpg');

    test('is read from the disk once; a new download and a clean up are seen', () async {
      await provider.updateEmojiCache('9', 'a', first);
      expect(provider.getEmojiCacheSync('9', 'a'), first);

      // Not read again: the file is gone, the bytes are still given.
      fileOf('9_a').deleteSync();
      expect(provider.getEmojiCacheSync('9', 'a'), first);

      await provider.updateEmojiCache('9', 'a', second);
      expect(provider.getEmojiCacheSync('9', 'a'), second, reason: 'downloaded again: not the bytes kept');

      await provider.clearEmojiCache();
      expect(fileOf('9_a').existsSync(), isFalse);
      expect(provider.getEmojiCacheSync('9', 'a'), isNull, reason: 'cleared with the files');
    });

    test('the sizes of the caches and clearing them', () async {
      await provider.updateEmojiCache('9', 'a', first);
      File('${tmp.path}/cache/images/x').writeAsBytesSync(List.filled(100, 0));
      Directory('${tmp.path}/support/log').createSync(recursive: true);
      File('${tmp.path}/support/log/l.log').writeAsBytesSync(List.filled(7, 0));

      final sizes = await provider.calculateCache();
      expect(sizes.imageSize, greaterThanOrEqualTo(100));
      expect(sizes.emojiSize, greaterThanOrEqualTo(first.length));
      expect(sizes.logSize, greaterThanOrEqualTo(7));

      await provider.clearCache(const CacheClearInfo(clearImage: true, clearEmoji: true, clearLog: false));
      final after = await provider.calculateCache();
      expect((after.imageSize, after.emojiSize), (0, 0));
      expect(after.logSize, greaterThanOrEqualTo(7), reason: 'the logs are not cleared here');
    });
  });
}
