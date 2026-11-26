/// Follow-ups of PR #162 (in-app updates).
///
/// * The update cache was never cleaned: the installed APK and the partial files of killed downloads stayed in it.
///   Unfinished downloads and the downloads of other versions are removed on every version check now, also when the
///   current version is the latest.
/// * Windows updates in the app: the portable zip of the release is downloaded and verified like the APK, unpacked
///   with every path checked, and a script started outside the app replaces the files once it exits.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:cryptography/dart.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/update/cubit/update_download_cubit.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/features/update/repository/release_update_repository.dart';
import 'package:tsdm_client/features/update/repository/windows_update_installer.dart';
import 'package:tsdm_client/features/update/widgets/update_download_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

const _info = LatestVersionInfo(version: '1.31.0', versionCode: 121, changelog: 'update');

/// Windows installer pointed at temporary folders, recording the started script instead of running it.
class _WindowsInstaller extends WindowsUpdateInstaller {
  _WindowsInstaller({required String updates, String? executable})
    : this._(updates, executable, <List<String>>[], <int>[]);

  _WindowsInstaller._(String updates, String? executable, this.launches, this.quits)
    : super(
        updateDirectory: updates,
        executable: executable,
        launch: (executable, arguments) async {
          launches.add([executable, ...arguments]);
          // What the script does first: report that it runs.
          String arg(String name) => arguments[arguments.indexOf(name) + 1];
          File(arg('-Marker')).writeAsStringSync('${arg('-Nonce')}\r\n');
        },
        quit: () async => quits.add(1),
      );

  final List<List<String>> launches;
  final List<int> quits;
}

class _MetadataAdapter implements HttpClientAdapter {
  _MetadataAdapter(this.release);
  final Map<String, Object?> release;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.uri.host, 'api.github.com', reason: 'restoring never downloads');
    // Windows confirms the offered version code with the tag's own version.json.
    final tagged = options.uri.path.endsWith('/contents/version.json');
    return ResponseBody.fromString(
      jsonEncode(tagged ? {'version': '1.31.0', 'versionCode': 121, 'changelog': ''} : release),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A release zip holding [files] (path in the zip to content).
Uint8List _zip(Map<String, String> files) {
  final archive = Archive();
  for (final MapEntry(:key, :value) in files.entries) {
    archive.addFile(ArchiveFile.bytes(key, utf8.encode(value)));
  }
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

final _release = {
  'tsdm_client/tsdm_client.exe': 'new exe',
  'tsdm_client/flutter_windows.dll': 'new engine',
  'tsdm_client/data/flutter_assets/version.json': '{"version":"1.31.0"}',
};

void main() {
  late Directory root;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() async => root = await Directory.systemTemp.createTemp('tsdm-update-188-'));
  tearDown(() async => root.delete(recursive: true));

  group('cache cleanup', () {
    late Directory updates;
    late ReleaseUpdateRepository repository;

    setUp(() async {
      updates = await Directory(p.join(root.path, 'updates')).create();
      repository = ReleaseUpdateRepository(installer: _WindowsInstaller(updates: updates.path));
      for (final name in [
        'update-120-1.apk',
        'update-121-2.apk',
        'update-121-3.zip',
        'update-121-4.part',
        'update-122-5.zip',
        'apply-update.ps1',
        'update.log',
        'notes.txt',
      ]) {
        await File(p.join(updates.path, name)).writeAsString(name);
      }
      for (final name in ['staging-121', 'backup-120', 'backup-120-1', 'backup-120-2', 'other']) {
        await File(p.join(updates.path, name, 'tsdm_client.exe')).create(recursive: true);
      }
      // Left by an incomplete rollback: that backup is the only copy of the previous files.
      await File(p.join(updates.path, 'backup-120-2.incomplete')).writeAsString('kept');
    });

    tearDown(() => repository.dispose());

    List<String> left() => updates.listSync().map((e) => p.basename(e.path)).toList()..sort();

    test('keeps the downloads of the offered version, drops partial files, other versions and work folders', () async {
      await repository.cleanup(keepVersionCode: 121);
      expect(left(), [
        'apply-update.ps1',
        'backup-120-2',
        'backup-120-2.incomplete',
        'notes.txt',
        'other',
        'update-121-2.apk',
        'update-121-3.zip',
        'update.log',
      ]);
      expect(File(p.join(updates.path, 'other', 'tsdm_client.exe')).existsSync(), isTrue);
    });

    test('nothing to offer (already the latest): every download goes', () async {
      await repository.cleanup();
      expect(left(), [
        'apply-update.ps1',
        'backup-120-2',
        'backup-120-2.incomplete',
        'notes.txt',
        'other',
        'update.log',
      ]);
    });

    test(
      'a work folder that cannot be deleted does not stop the rest of the cleanup',
      () async {
        final locked = Directory(p.join(updates.path, 'staging-121'));
        await Process.run('chmod', ['555', locked.path]);
        addTearDown(() => Process.run('chmod', ['755', locked.path]));
        await repository.cleanup(keepVersionCode: 121);
        expect(left(), contains('staging-121'));
        expect(left(), isNot(contains('update-121-4.part')));
        expect(left(), isNot(contains('update-122-5.zip')));
        expect(left(), isNot(contains('backup-120')));
        expect(left(), isNot(contains('backup-120-1')));
        expect(left(), contains('backup-120-2'), reason: 'marked by an incomplete rollback');
      },
      skip: Platform.isLinux && Process.runSync('id', ['-u']).stdout.toString().trim() == '0',
    );

    test('a missing cache folder is fine', () async {
      await updates.delete(recursive: true);
      await repository.cleanup(keepVersionCode: 121);
      expect(updates.existsSync(), isFalse);
    });

    test('the version check cleans up even when the current version is the latest', () async {
      final cubit = UpdateDownloadCubit(repository: repository, supported: true, currentVersionCode: 121);
      addTearDown(cubit.close);
      await cubit.restore(_info);
      // The cleanup runs in the background: wait for it, a slow file system finishes after the event queue.
      await cubit.cleanupDone;
      expect(left(), [
        'apply-update.ps1',
        'backup-120-2',
        'backup-120-2.incomplete',
        'notes.txt',
        'other',
        'update.log',
      ]);
      expect(cubit.state.status, UpdateDownloadStatus.idle);
    });
  });

  group('Windows release asset', () {
    test('the zip is the asset, the version code has no ABI digit', () {
      expect(UpdateTarget.windows.assetName, 'tsdm_client-windows.zip');
      expect(UpdateTarget.windows.installedVersionCode(121), 121);
      expect(UpdateTarget.android.installedVersionCode(121), 1219);
    });

    test('a verified zip in the cache is restored after a restart', () async {
      final updates = await Directory(p.join(root.path, 'updates')).create();
      final bytes = _zip(_release);
      final digest = (await const DartSha256().hash(
        bytes,
      )).bytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join();
      await File(p.join(updates.path, 'update-121-100.zip')).writeAsBytes(bytes);
      await File(p.join(updates.path, 'update-121-100.apk')).writeAsBytes(bytes);
      final dio = Dio()
        ..httpClientAdapter = _MetadataAdapter({
          'tag_name': 'v1.31.0',
          'draft': false,
          'prerelease': false,
          'assets': [
            {
              'name': 'tsdm_client-windows.zip',
              'state': 'uploaded',
              'size': bytes.length,
              'browser_download_url':
                  'https://github.com/Carinoasd/tsdm_client/releases/download/v1.31.0/tsdm_client-windows.zip',
              'digest': 'sha256:$digest',
            },
          ],
        });
      final repository = ReleaseUpdateRepository(
        dio: dio,
        installer: _WindowsInstaller(updates: updates.path),
      );
      addTearDown(repository.dispose);
      final update = await repository.restore(_info, cancelToken: CancelToken(), onVerifying: () {});
      expect(update?.path, p.join(updates.path, 'update-121-100.zip'));
      expect(update?.versionCode, 121);
    });
  });

  group('unpacking the release', () {
    Future<File> zipFile(Map<String, String> files) => File(p.join(root.path, 'release.zip')).writeAsBytes(_zip(files));

    test('the tsdm_client folder is unpacked without its top folder', () async {
      final out = Directory(p.join(root.path, 'out'));
      await WindowsUpdateInstaller.extractRelease(await zipFile(_release), out);
      expect(File(p.join(out.path, 'tsdm_client.exe')).readAsStringSync(), 'new exe');
      expect(File(p.join(out.path, 'data', 'flutter_assets', 'version.json')).existsSync(), isTrue);
    });

    for (final (reason, files) in [
      ('a path climbing out of the folder', {..._release, 'tsdm_client/../../evil.txt': 'x'}),
      ('an entry outside the release folder', {..._release, 'other/evil.txt': 'x'}),
      ('a backslash path', {..._release, r'tsdm_client\..\evil.txt': 'x'}),
      ('no executable', {'tsdm_client/flutter_windows.dll': 'engine'}),
    ]) {
      test('rejected: $reason', () async {
        final out = Directory(p.join(root.path, 'out'));
        await expectLater(
          WindowsUpdateInstaller.extractRelease(await zipFile(files), out),
          throwsA(isA<UpdateDownloadException>().having((e) => e.failure, 'failure', UpdateDownloadFailure.integrity)),
        );
        expect(File(p.join(root.path, 'evil.txt')).existsSync(), isFalse);
      });
    }

    test('a damaged file is an integrity failure', () async {
      final file = await File(p.join(root.path, 'release.zip')).writeAsString('not a zip');
      await expectLater(
        WindowsUpdateInstaller.extractRelease(file, Directory(p.join(root.path, 'out'))),
        throwsA(isA<UpdateDownloadException>()),
      );
    });
  });

  group('installing on Windows', () {
    late Directory app;
    late String updates;
    late DownloadedUpdate update;

    setUp(() async {
      app = await Directory(p.join(root.path, 'app folder 天使')).create();
      await File(p.join(app.path, 'tsdm_client.exe')).writeAsString('old exe');
      await File(p.join(app.path, 'flutter_windows.dll')).writeAsString('old engine');
      updates = (await Directory(p.join(root.path, 'updates')).create()).path;
      final zip = await File(p.join(updates, 'update-121-100.zip')).writeAsBytes(_zip(_release));
      update = DownloadedUpdate(path: zip.path, version: '1.31.0', versionCode: 121);
    });

    test('unpacks, writes the script and starts it with the folders, then the app exits', () async {
      final installer = _WindowsInstaller(updates: updates, executable: p.join(app.path, 'tsdm_client.exe'));
      expect(await installer.install(update), isTrue);
      final staging = p.join(updates, 'staging-121');
      expect(File(p.join(staging, 'tsdm_client.exe')).readAsStringSync(), 'new exe');
      expect(File(p.join(app.path, 'tsdm_client.exe')).readAsStringSync(), 'old exe', reason: 'the script copies');
      final script = File(p.join(updates, WindowsUpdateInstaller.scriptName)).readAsStringSync();
      expect(script.codeUnits.every((e) => e < 128), isTrue, reason: 'ASCII: read without BOM');
      expect(script, contains('restored the previous version'));
      expect(script, contains('.incomplete'), reason: 'a backup still needed is marked out of the cleanup');
      expect(script, contains('a folder is in the way'));

      final launch = installer.launches.single;
      // The full path on a Windows machine, the name where it does not exist.
      expect(launch.first, anyOf('powershell.exe', endsWith(r'\WindowsPowerShell\v1.0\powershell.exe')));
      String arg(String name) => launch[launch.indexOf(name) + 1];
      expect(arg('-File'), p.join(updates, WindowsUpdateInstaller.scriptName));
      expect(arg('-ProcessId'), '$pid');
      expect(arg('-Source'), staging);
      expect(arg('-Target'), app.path);
      expect(arg('-Backup'), startsWith(p.join(updates, 'backup-121-')));
      expect(installer.quits, isEmpty, reason: 'the page shows the restart first');
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(installer.quits, [1]);
    });

    test('not the portable folder (a debug run): nothing is copied', () async {
      final installer = _WindowsInstaller(updates: updates, executable: p.join(app.path, 'runner.exe'));
      await expectLater(
        installer.install(update),
        throwsA(isA<UpdateDownloadException>().having((e) => e.failure, 'failure', UpdateDownloadFailure.unsupported)),
      );
      expect(installer.launches, isEmpty);
    });

    test(
      'a folder that cannot be written is reported, not attempted',
      () async {
        await Process.run('chmod', ['555', app.path]);
        addTearDown(() => Process.run('chmod', ['755', app.path]));
        final installer = _WindowsInstaller(updates: updates, executable: p.join(app.path, 'tsdm_client.exe'));
        await expectLater(
          installer.install(update),
          throwsA(
            isA<UpdateDownloadException>().having((e) => e.failure, 'failure', UpdateDownloadFailure.installLocation),
          ),
        );
        expect(installer.launches, isEmpty);
      },
      skip: Platform.isLinux && Process.runSync('id', ['-u']).stdout.toString().trim() == '0',
    );
  });

  testWidgets('the Windows card names Windows, not the APK', (tester) async {
    await LocaleSettings.setLocale(AppLocale.en);
    final tr = LocaleSettings.instance.currentTranslations.updatePage.download;
    final cubit = UpdateDownloadCubit(
      repository: ReleaseUpdateRepository(installer: _WindowsInstaller(updates: root.path)),
      supported: true,
      currentVersionCode: 1,
    );
    addTearDown(cubit.close);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: BlocProvider.value(
              value: cubit,
              child: UpdateDownloadCard(cubit: cubit, latest: _info),
            ),
          ),
        ),
      ),
    );
    expect(find.text(tr.windows.title(version: '1.31.0')), findsOneWidget);
    expect(find.text(tr.windows.download(version: '1.31.0')), findsOneWidget);
    expect(find.text(tr.windows.intro), findsOneWidget);
    expect(find.textContaining('APK'), findsNothing);
  });
}
