import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/repositories/webdav_backup_repository.dart';
import 'package:tsdm_client/features/settings/repositories/webdav_client.dart';
import 'package:tsdm_client/features/settings/widgets/webdav_backup_dialogs.dart';
import 'package:tsdm_client/features/settings/widgets/webdav_backup_group.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';

/// Backups of the database to a WebDAV server: the client's requests and answers, the backup files kept on the
/// server, the schedule of the automatic backup and where its settings and password are kept.
const _data = 'test/data/webdav';

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('multistatus', () {
    test('wsgidav answer (ns0 prefix, CJK directory): members only, names decoded', () {
      // A real wsgidav 4.4 answer to PROPFIND Depth 1 (indented, quota and lock properties left out).
      final body = File('$_data/wsgidav_propfind_depth1.xml').readAsStringSync();
      final entries = WebdavClient.parseMultistatus(
        body,
        Uri.parse('https://forum.test/dav/%E5%A4%A9%E4%BD%BF%E5%A4%87%E4%BB%BD/'),
      );
      expect(entries, hasLength(1));
      expect(entries.single.name, 'tsdm_client_data_1.db');
      expect(entries.single.isCollection, isFalse);
      expect(entries.single.size, 6);
      expect(entries.single.lastModified, DateTime.utc(2026, 11, 8, 17, 14, 23));
    });

    test('Nextcloud answer (d: prefix, 404 propstat first, full url href, sub collection)', () {
      final body = File('$_data/nextcloud_propfind_depth1.xml').readAsStringSync();
      final entries = WebdavClient.parseMultistatus(
        body,
        Uri.parse('https://forum.test/remote.php/dav/files/me/tsdm%20backup'),
      );
      expect(entries.map((e) => (e.name, e.isCollection, e.size)), [
        ('tsdm_client_data_2_accounts.db', false, 2048),
        ('old', true, null),
      ]);
    });

    test('only names of this app count as backups, newest first', () {
      final backups = WebdavBackupRepository.backupsOf(const [
        WebdavEntry(name: 'tsdm_client_data_100.db', isCollection: false),
        WebdavEntry(name: 'tsdm_client_data_300_accounts.db', isCollection: false),
        WebdavEntry(name: 'tsdm_client_data_200.db', isCollection: false),
        WebdavEntry(name: 'tsdm_client_data_400.db', isCollection: true),
        WebdavEntry(name: 'notes.txt', isCollection: false),
        WebdavEntry(name: 'tsdm_client_data_x.db', isCollection: false),
      ]);
      expect(backups.map((b) => b.name), [
        'tsdm_client_data_300_accounts.db',
        'tsdm_client_data_200.db',
        'tsdm_client_data_100.db',
      ]);
      expect(backups.first.withAccounts, isTrue);
      expect(backups.first.createdAt, DateTime.fromMicrosecondsSinceEpoch(300));
    });
  });

  group('urls', () {
    test('segments are encoded one by one below the root, with or without its trailing slash', () {
      for (final base in ['https://forum.test/dav', 'https://forum.test/dav/']) {
        final client = WebdavClient(baseUrl: Uri.parse(base), username: 'u', password: 'p');
        expect(client.resolve(const []).toString(), 'https://forum.test/dav/');
        expect(
          client.resolve(const ['天使 备份', 'a#b.db']).toString(),
          'https://forum.test/dav/%E5%A4%A9%E4%BD%BF%20%E5%A4%87%E4%BB%BD/a%23b.db',
        );
        expect(client.resolve(const ['x'], collection: true).toString(), 'https://forum.test/dav/x/');
      }
    });

    test('a typed directory is split into segments, empty and dot segments dropped', () {
      expect(WebdavClient.splitPath('/tsdm//backup/'), ['tsdm', 'backup']);
      expect(WebdavClient.splitPath(r'a\..\b\.'), ['a', 'b']);
      expect(WebdavClient.splitPath(''), isEmpty);
    });

    test('only http(s) urls with a host are a server', () {
      expect(const WebdavBackupConfig(url: 'https://forum.test/dav').configured, isTrue);
      expect(const WebdavBackupConfig(url: ' http://forum.test:8080 ').configured, isTrue);
      expect(const WebdavBackupConfig(url: 'forum.test/dav').configured, isFalse);
      expect(const WebdavBackupConfig(url: 'ftp://forum.test').configured, isFalse);
      expect(const WebdavBackupConfig().configured, isFalse);
    });
  });

  group('schedule', () {
    final now = DateTime(2026, 11, 9, 12);
    const daily = WebdavBackupConfig(url: 'https://forum.test/dav', schedule: WebdavAutoBackup.daily);
    const weekly = WebdavBackupConfig(url: 'https://forum.test/dav', schedule: WebdavAutoBackup.weekly);
    bool due(WebdavBackupConfig c, {DateTime? last, DateTime? attempt}) =>
        WebdavBackupRepository.isDue(c, WebdavBackupState(lastBackupAt: last, lastAttemptAt: attempt), now);

    test('off or without a server: never', () {
      expect(due(const WebdavBackupConfig(url: 'https://forum.test/dav')), isFalse);
      expect(due(const WebdavBackupConfig(schedule: WebdavAutoBackup.daily)), isFalse);
    });

    test('daily and weekly follow the last successful backup', () {
      expect(due(daily), isTrue);
      expect(due(daily, last: now.subtract(const Duration(hours: 23))), isFalse);
      expect(due(daily, last: now.subtract(const Duration(hours: 24))), isTrue);
      expect(due(weekly, last: now.subtract(const Duration(days: 6))), isFalse);
      expect(due(weekly, last: now.subtract(const Duration(days: 7))), isTrue);
    });

    test('an attempt within the retry gap holds the next one back; a clock set back does not stop backups', () {
      expect(due(daily, attempt: now.subtract(const Duration(minutes: 10))), isFalse);
      expect(due(daily, attempt: now.subtract(const Duration(minutes: 61))), isTrue);
      expect(due(daily, last: now.add(const Duration(days: 3))), isTrue);
      expect(due(daily, attempt: now.add(const Duration(days: 3))), isTrue);
    });
  });

  group('server', () {
    late Directory dir;
    late File dbFile;
    late _FakeWebdav server;
    late WebdavBackupStore store;
    late DateTime clock;

    WebdavBackupRepository repo() => WebdavBackupRepository(
      store: store,
      databaseFile: () async => dbFile,
      dio: Dio()..httpClientAdapter = server,
      now: () => clock,
    );

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('tsdm_webdav');
      dbFile = File('${dir.path}/mainV2.db');
      sqlite3.open(dbFile.path)
        ..execute('CREATE TABLE settings (name TEXT PRIMARY KEY, int_value INT, string_value TEXT, bool_value INT)')
        ..execute(
          'CREATE TABLE cookie (uid INT PRIMARY KEY, username TEXT, cookie TEXT, password TEXT, question_id INT, '
          'answer TEXT)',
        )
        ..execute('CREATE TABLE image_cache (url TEXT)')
        ..execute("INSERT INTO cookie VALUES (31, 'alice', '{\"auth\":\"secret-cookie\"}', NULL, NULL, NULL)")
        ..execute("INSERT INTO settings (name, string_value) VALUES ('fontFamily', 'serif')")
        ..userVersion = 1
        ..dispose();
      server = _FakeWebdav(root: '/dav/', username: 'davuser', password: 'davpass');
      store = WebdavBackupStore(Directory('${dir.path}/webdav'));
      clock = DateTime(2026, 11, 9, 12);
      await store.writeConfig(
        const WebdavBackupConfig(
          url: 'https://forum.test/dav',
          username: 'davuser',
          directory: 'tsdm/天使',
          schedule: WebdavAutoBackup.daily,
        ),
      );
      await store.writePassword('davpass');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('connection test: 207 ok, 401 wrong credentials, 404 not found, no answer unreachable', () async {
      final r = repo();
      final config = await store.readConfig();
      expect(await r.testConnection(config, 'davpass'), WebdavCheck.ok);
      expect(await r.testConnection(config, 'wrong'), WebdavCheck.unauthorized);
      expect(
        await r.testConnection(config.copyWith(url: 'https://forum.test/nothing/'), 'davpass'),
        WebdavCheck.notFound,
      );
      server.offline = true;
      expect(await r.testConnection(config, 'davpass'), WebdavCheck.unreachable);
    });

    test('backups create the directory, carry no logins, and only the newest N of this app are kept', () async {
      server.files['/dav/tsdm/%E5%A4%A9%E4%BD%BF/notes.txt'] = utf8.encode('mine');
      await store.writeConfig((await store.readConfig()).copyWith(keep: 3));
      final r = repo();
      // The directory does not exist yet; MKCOL refuses a missing parent, so each level is made in turn.
      await r.backupNow();
      expect(server.collections, containsAll(['/dav/tsdm/', '/dav/tsdm/%E5%A4%A9%E4%BD%BF/']));
      for (var i = 1; i <= 4; i++) {
        clock = clock.add(Duration(days: i));
        await r.backupNow();
      }
      final names = (await r.listBackups()).map((b) => b.name).toList();
      expect(names, hasLength(3));
      expect(names.first, WebdavBackupRepository.fileNameAt(clock, withAccounts: false));
      expect(server.files.keys, contains('/dav/tsdm/%E5%A4%A9%E4%BD%BF/notes.txt'), reason: 'not a backup');
      expect((await store.readState()).lastBackupAt, clock);

      // The upload is the local export: a SQLite file without the session cookie.
      final file = await r.download(names.first, temp: dir);
      final bytes = await file.readAsBytes();
      expect(String.fromCharCodes(bytes.take(15)), 'SQLite format 3');
      expect(latin1.decode(bytes, allowInvalid: true), isNot(contains('secret-cookie')));
      final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
      expect(db.select('SELECT cookie FROM cookie').single['cookie'], '{}');
      db.dispose();
    });

    test('with the clock set back the fresh upload is kept, and backups with logins are counted apart', () async {
      await store.writeConfig((await store.readConfig()).copyWith(keep: 2));
      final r = repo();
      final withLogins = await r.backupNow(secretsPassword: 'long enough password');
      for (var i = 1; i <= 3; i++) {
        clock = clock.add(Duration(days: i));
        await r.backupNow();
      }
      var names = (await r.listBackups()).map((b) => b.name).toList();
      expect(names.where((n) => !n.endsWith('_accounts.db')), hasLength(2));
      expect(names, contains(withLogins.name), reason: 'the automatic backups do not push it out');

      // Set back before every backup on the server: its name sorts oldest, yet it is the one kept.
      clock = DateTime(2020);
      final fresh = await r.backupNow();
      names = (await r.listBackups()).map((b) => b.name).toList();
      expect(names, contains(fresh.name));
      expect(names.where((n) => !n.endsWith('_accounts.db')), hasLength(2));
    });

    test('an unreachable server gets no MKCOL; a suspended repository starts no automatic backup', () async {
      final r = repo();
      server.offline = true;
      await expectLater(
        r.backupNow(),
        throwsA(isA<WebdavException>().having((e) => e.method, 'method', 'PROPFIND')),
      );
      expect(server.methods, isNot(contains('MKCOL')));
      server.offline = false;
      await r.suspend();
      expect(await r.runIfDue(), isFalse);
      expect(server.files, isEmpty);
    });

    test('downloads left by a restore are cleaned, other temporary files stay', () async {
      final temp = Directory('${dir.path}/tmp')..createSync();
      final r = repo();
      await r.backupNow();
      final downloaded = await r.download((await r.listBackups()).first.name, temp: temp);
      final other = File('${temp.path}/other.db')..writeAsStringSync('x');
      await r.deleteStaleDownloads(temp: temp);
      expect(downloaded.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
    });

    test('a backup with wrong credentials fails as unauthorized and uploads nothing', () async {
      await store.writePassword('wrong');
      await expectLater(
        repo().backupNow(),
        throwsA(isA<WebdavException>().having((e) => e.unauthorized, 'unauthorized', isTrue)),
      );
      expect(server.files, isEmpty);
    });

    test('the automatic backup runs once when due, then waits; a failure is retried after the gap', () async {
      final r = repo();
      expect(await r.runIfDue(), isTrue);
      expect(await r.runIfDue(), isFalse, reason: 'backed up just now');
      clock = clock.add(const Duration(days: 1));
      server.offline = true;
      expect(await r.runIfDue(), isFalse);
      expect((await store.readState()).lastAttemptAt, clock);
      server.offline = false;
      clock = clock.add(const Duration(minutes: 30));
      expect(await r.runIfDue(), isFalse, reason: 'within the retry gap');
      clock = clock.add(const Duration(minutes: 31));
      expect(await r.runIfDue(), isTrue);
      expect(await r.listBackups(), hasLength(2));
    });

    test('a name that is not a backup is never downloaded', () async {
      expect(() => repo().download('../../etc/passwd'), throwsArgumentError);
    });
  });

  group('store', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('tsdm_webdav_store'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('the password is stored encrypted and outside the config; an empty one removes it', () async {
      final store = WebdavBackupStore(dir);
      await store.writeConfig(const WebdavBackupConfig(url: 'https://forum.test/dav', username: 'u', keep: 7));
      await store.writePassword('pä55wörd-秘密');
      expect(await store.readPassword(), 'pä55wörd-秘密');
      expect((await store.readConfig()).keep, 7);
      for (final f in dir.listSync().whereType<File>()) {
        final text = latin1.decode(f.readAsBytesSync(), allowInvalid: true);
        expect(text, isNot(contains('pä55')));
        expect(text, isNot(contains(base64Encode(utf8.encode('pä55wörd-秘密')))));
      }
      expect(jsonDecode(File('${dir.path}/config.json').readAsStringSync()), isNot(contains('password')));
      await store.writePassword('');
      expect(await store.readPassword(), '');
    });

    test('broken files fall back to the defaults', () async {
      File('${dir.path}/config.json').writeAsStringSync('{not json');
      File('${dir.path}/password.json').writeAsStringSync('{"nonce":"AA==","mac":"AA==","ciphertext":"AA=="}');
      final store = WebdavBackupStore(dir);
      expect((await store.readConfig()).keep, WebdavBackupConfig.defaultKeep);
      expect(await store.readPassword(), '');
    });
  });

  testWidgets('the settings dialog fits a phone screen', (tester) async {
    tester.view
      ..physicalSize = const Size(360, 640)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('tsdm_webdav_dialog');
    addTearDown(() => dir.deleteSync(recursive: true));
    final repository = WebdavBackupRepository(store: WebdavBackupStore(dir), databaseFile: () async => File(''));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => FilledButton(
                onPressed: () => showWebdavSettingsDialog(
                  context,
                  repository: repository,
                  config: const WebdavBackupConfig(),
                  password: '',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TextFormField), findsNWidgets(5));
    expect(find.byType(SegmentedButton<WebdavAutoBackup>), findsOneWidget);
    // An empty url does not save.
    await tester.tap(find.byType(FilledButton).last);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('the backup and restore rows appear once a server is set', (tester) async {
    final dir = Directory.systemTemp.createTempSync('tsdm_webdav_group');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = WebdavBackupStore(dir);
    final repository = WebdavBackupRepository(store: store, databaseFile: () async => File(''));
    Future<void> show() => tester.runAsync(() async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: WebdavBackupGroup(key: UniqueKey(), repository: repository, importBackup: (_) async {}),
            ),
          ),
        ),
      );
      // The settings are read from their files.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    await show();
    await tester.pump();
    expect(find.byType(SectionListTile), findsOneWidget);
    expect(find.byIcon(Icons.cloud_upload_outlined), findsNothing);

    await tester.runAsync(
      () => store.writeConfig(
        const WebdavBackupConfig(url: 'https://forum.test/dav', schedule: WebdavAutoBackup.weekly),
      ),
    );
    await show();
    await tester.pump();
    expect(find.byType(SectionListTile), findsNWidgets(3));
    expect(find.text('forum.test'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_upload_outlined), findsOneWidget);
    expect(find.byIcon(Icons.cloud_download_outlined), findsOneWidget);
  });
}

/// An in-memory WebDAV server with basic authentication below [root]: `PROPFIND` (depth 0 / 1), `MKCOL`, `PUT`,
/// `GET`, `DELETE`, answering as wsgidav does (404 for a missing collection, 409 for `MKCOL` without its parent, 405
/// for `MKCOL` on an existing one).
final class _FakeWebdav implements HttpClientAdapter {
  _FakeWebdav({required this.root, required String username, required String password})
    : _auth = 'Basic ${base64Encode(utf8.encode('$username:$password'))}' {
    collections.add(root);
  }

  final String root;
  final String _auth;

  /// Paths (percent-encoded as requested) of collections, ending in `/`.
  final collections = <String>{};

  /// Files by path.
  final files = <String, List<int>>{};

  bool offline = false;

  /// Methods of the requests that reached the server.
  final methods = <String>[];

  String _parent(String path) {
    final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    return trimmed.substring(0, trimmed.lastIndexOf('/') + 1);
  }

  ResponseBody _answer(int status, [String body = '']) => ResponseBody.fromBytes(
    utf8.encode(body),
    status,
    headers: {
      Headers.contentTypeHeader: ['application/xml; charset=utf-8'],
    },
  );

  String _response(String href, {required bool collection, int? size}) =>
      '<D:response><D:href>$href</D:href><D:propstat><D:prop>'
      '${collection ? '<D:resourcetype><D:collection/></D:resourcetype>' : '<D:resourcetype/>'}'
      '${size == null ? '' : '<D:getcontentlength>$size</D:getcontentlength>'}'
      '</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (offline) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    methods.add(options.method);
    final body = <int>[];
    if (requestStream != null) {
      await requestStream.forEach(body.addAll);
    }
    if (options.headers['Authorization'] != _auth) {
      return _answer(401);
    }
    final path = options.uri.path;
    if (!path.startsWith(root)) {
      return _answer(404);
    }
    switch (options.method) {
      case 'PROPFIND':
        final dirPath = path.endsWith('/') ? path : '$path/';
        if (!collections.contains(dirPath)) {
          return _answer(404);
        }
        final out = StringBuffer('<?xml version="1.0"?><D:multistatus xmlns:D="DAV:">')
          ..write(_response(dirPath, collection: true));
        if (options.headers['Depth'] == '1') {
          for (final c in collections.where((c) => c != dirPath && _parent(c) == dirPath)) {
            out.write(_response(c, collection: true));
          }
          for (final f in files.entries.where((f) => _parent(f.key) == dirPath)) {
            out.write(_response(f.key, collection: false, size: f.value.length));
          }
        }
        out.write('</D:multistatus>');
        return _answer(207, out.toString());
      case 'MKCOL':
        if (collections.contains(path)) return _answer(405);
        if (!collections.contains(_parent(path))) return _answer(409);
        collections.add(path);
        return _answer(201);
      case 'PUT':
        if (!collections.contains(_parent(path))) return _answer(409);
        final existed = files.containsKey(path);
        files[path] = body;
        return _answer(existed ? 204 : 201);
      case 'GET':
        final data = files[path];
        if (data == null) return _answer(404);
        return ResponseBody.fromBytes(Uint8List.fromList(data), 200);
      case 'DELETE':
        return _answer(files.remove(path) == null ? 404 : 204);
    }
    return _answer(405);
  }

  @override
  void close({bool force = false}) {}
}
