/// Review of the in-app update and the interactive post viewer.
///
/// * Cleaning the update cache could throw (no native update folder, no plugin): the error escaped the startup
///   check and left a later download stuck in "resolving".
/// * The downloaded file was hashed on the UI isolate at every startup check; it is hashed in the background now and a
///   cancellation still discards the result.
/// * A Windows run that can never install (not the portable folder, a folder that cannot be written) learned it only
///   after downloading the release.
/// * Windows: the app quit after starting PowerShell even when the script never ran; it waits for the script to report
///   in now. The script no longer starts a second instance when the app did not exit.
/// * Forum helpers on images and links that were not on a fixed list made ordinary posts look interactive.
/// * The native viewer kept its own copy of its texts; the app sends them translated now.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cryptography/dart.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/thread/v1/utils/interactive_post_html.dart';
import 'package:tsdm_client/features/thread/v1/utils/interactive_post_viewer.dart';
import 'package:tsdm_client/features/update/cubit/update_download_cubit.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/features/update/repository/release_update_repository.dart';
import 'package:tsdm_client/features/update/repository/windows_update_installer.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

const _info = LatestVersionInfo(version: '1.31.0', versionCode: 121, changelog: 'update');

/// An Android installer whose native side has no update folder.
class _BrokenInstaller extends AndroidUpdateInstaller {
  _BrokenInstaller(this.error);

  final Exception error;

  @override
  Future<String> directory() async => throw error;
}

/// Records every request; answers the release lookup with [release] or a 404.
class _Adapter implements HttpClientAdapter {
  _Adapter([this.release]);

  final Map<String, Object?>? release;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.uri);
    if (release == null) return ResponseBody.fromString('{}', 404);
    // Windows confirms the offered version code with the tag's own version.json.
    final tagged = options.uri.path.endsWith('/contents/version.json');
    return ResponseBody.fromString(
      jsonEncode(tagged ? {'version': _info.version, 'versionCode': _info.versionCode, 'changelog': ''} : release),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// A Windows installer in temporary folders; the launcher stands in for PowerShell.
class _WindowsInstaller extends WindowsUpdateInstaller {
  _WindowsInstaller({required String updates, required String executable, required bool scriptRuns})
    : this._(updates, executable, scriptRuns, <List<String>>[], <int>[]);

  _WindowsInstaller._(String updates, String executable, bool scriptRuns, this.launches, this.quits)
    : super(
        updateDirectory: updates,
        executable: executable,
        startTimeout: const Duration(milliseconds: 400),
        launch: (executable, arguments) async {
          launches.add(arguments);
          if (scriptRuns) {
            String arg(String name) => arguments[arguments.indexOf(name) + 1];
            File(arg('-Marker')).writeAsStringSync('${arg('-Nonce')}\r\n');
          }
        },
        quit: () async => quits.add(1),
      );

  final List<List<String>> launches;
  final List<int> quits;
}

String _hex(List<int> bytes) => bytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

String _message(String html) => '<div class="t_f" id="postmessage_42">$html</div>';

void main() {
  late Directory root;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() async => root = await Directory.systemTemp.createTemp('tsdm-update-192-'));
  tearDown(() async => root.delete(recursive: true));

  group('cache cleanup never throws', () {
    for (final error in <Exception>[
      const UpdateDownloadException(UpdateDownloadFailure.storage),
      MissingPluginException(),
      PlatformException(code: 'unavailable'),
    ]) {
      test('${error.runtimeType}: the check goes on and a download still ends', () async {
        final adapter = _Adapter();
        final repository = ReleaseUpdateRepository(
          dio: Dio()..httpClientAdapter = adapter,
          installer: _BrokenInstaller(error),
        );
        await repository.cleanup(keepVersionCode: 121);

        final cubit = UpdateDownloadCubit(repository: repository, supported: true, currentVersionCode: 120);
        addTearDown(cubit.close);
        // Not newer: only the cleanup runs, nobody awaits it.
        await cubit.restore(const LatestVersionInfo(version: '1.30.0', versionCode: 120, changelog: ''));
        await cubit.download(_info);
        expect(cubit.state.status, UpdateDownloadStatus.failed, reason: 'not stuck in resolving');
        expect(cubit.state.failure, UpdateDownloadFailure.releaseUnavailable);
      });
    }
  });

  group('hashing in the background', () {
    test('the digest is the SHA-256 of exactly the published size', () async {
      final bytes = List.generate(300000, (i) => i % 251);
      final file = await File(p.join(root.path, 'update-121-1.zip')).writeAsBytes(bytes);
      final expected = _hex((await const DartSha256().hash(bytes)).bytes);
      expect(await ReleaseUpdateRepository.hashFile(file.path, bytes.length), expected);
      expect(await ReleaseUpdateRepository.hashFile(file.path, bytes.length - 1), isNull, reason: 'longer');
      expect(await ReleaseUpdateRepository.hashFile(file.path, bytes.length + 1), isNull, reason: 'shorter');
    });

    test('a cancellation while hashing discards the result and keeps the file', () async {
      final updates = await Directory(p.join(root.path, 'updates')).create();
      final bytes = Uint8List.fromList(List.generate(200000, (i) => i % 7));
      final file = await File(p.join(updates.path, 'update-121-5.zip')).writeAsBytes(bytes);
      final digest = _hex((await const DartSha256().hash(bytes)).bytes);
      final dio = Dio()
        ..httpClientAdapter = _Adapter({
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
        installer: WindowsUpdateInstaller(updateDirectory: updates.path),
      );
      addTearDown(repository.dispose);
      final token = CancelToken();
      // Cancelled once the hash has started, not before.
      await expectLater(
        repository.restore(_info, cancelToken: token, onVerifying: () => scheduleMicrotask(token.cancel)),
        throwsA(isA<DioException>()),
      );
      expect(file.existsSync(), isTrue);
      expect(
        (await repository.restore(_info, cancelToken: CancelToken(), onVerifying: () {}))?.path,
        file.path,
        reason: 'not cancelled: the same file verifies',
      );
    });
  });

  group('checked before downloading', () {
    late Directory app;

    setUp(() async {
      app = await Directory(p.join(root.path, 'app')).create();
      await File(p.join(app.path, 'tsdm_client.exe')).writeAsString('exe');
      await File(p.join(app.path, 'flutter_windows.dll')).writeAsString('engine');
    });

    Future<(UpdateDownloadCubit, _Adapter)> start(String executable) async {
      final adapter = _Adapter();
      final cubit = UpdateDownloadCubit(
        repository: ReleaseUpdateRepository(
          dio: Dio()..httpClientAdapter = adapter,
          installer: _WindowsInstaller(updates: root.path, executable: executable, scriptRuns: true),
        ),
        supported: true,
        currentVersionCode: 120,
      );
      addTearDown(cubit.close);
      await cubit.download(_info);
      return (cubit, adapter);
    }

    test('not the portable folder: fails at once without downloading', () async {
      final (cubit, adapter) = await start(p.join(app.path, 'runner.exe'));
      expect(cubit.state.status, UpdateDownloadStatus.failed);
      expect(cubit.state.failure, UpdateDownloadFailure.unsupported);
      expect(adapter.requests, isEmpty);
    });

    test(
      'a folder that cannot be written: fails at once without downloading',
      () async {
        await Process.run('chmod', ['555', app.path]);
        addTearDown(() => Process.run('chmod', ['755', app.path]));
        final (cubit, adapter) = await start(p.join(app.path, 'tsdm_client.exe'));
        expect(cubit.state.failure, UpdateDownloadFailure.installLocation);
        expect(adapter.requests, isEmpty);
      },
      skip: Platform.isLinux && Process.runSync('id', ['-u']).stdout.toString().trim() == '0',
    );

    test('the portable folder goes on to the download', () async {
      final (cubit, adapter) = await start(p.join(app.path, 'tsdm_client.exe'));
      expect(adapter.requests, isNotEmpty);
      expect(cubit.state.failure, UpdateDownloadFailure.releaseUnavailable);
    });

    test('Android has nothing to check', () async {
      expect(await AndroidUpdateInstaller().preflight(), isNull);
      expect(
        await WindowsUpdateInstaller(executable: p.join(app.path, 'tsdm_client.exe')).preflight(),
        isNull,
      );
    });
  });

  group('the Windows script must report in before the app quits', () {
    late Directory app;
    late String updates;
    late DownloadedUpdate update;

    setUp(() async {
      app = await Directory(p.join(root.path, 'app')).create();
      await File(p.join(app.path, 'tsdm_client.exe')).writeAsString('old exe');
      await File(p.join(app.path, 'flutter_windows.dll')).writeAsString('old engine');
      updates = (await Directory(p.join(root.path, 'updates')).create()).path;
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('tsdm_client/tsdm_client.exe', utf8.encode('new exe')))
        ..addFile(ArchiveFile.bytes('tsdm_client/flutter_windows.dll', utf8.encode('new engine')));
      final zip = await File(p.join(updates, 'update-121-1.zip')).writeAsBytes(ZipEncoder().encodeBytes(archive));
      update = DownloadedUpdate(path: zip.path, version: '1.31.0', versionCode: 121);
    });

    _WindowsInstaller installer({required bool scriptRuns}) =>
        _WindowsInstaller(updates: updates, executable: p.join(app.path, 'tsdm_client.exe'), scriptRuns: scriptRuns);

    test('the script reported in with this nonce: the app quits', () async {
      final windows = installer(scriptRuns: true);
      expect(await windows.install(update), isTrue);
      final arguments = windows.launches.single;
      String arg(String name) => arguments[arguments.indexOf(name) + 1];
      expect(arg('-Marker'), p.join(updates, WindowsUpdateInstaller.startedMarkerName));
      expect(arg('-Nonce'), matches(RegExp(r'^[0-9a-f]{32}$')));
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(windows.quits, [1]);
    });

    test('PowerShell started but the script never ran: an install failure and the app stays open', () async {
      final windows = installer(scriptRuns: false);
      await expectLater(
        windows.install(update),
        throwsA(isA<UpdateDownloadException>().having((e) => e.failure, 'failure', UpdateDownloadFailure.install)),
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(windows.quits, isEmpty);
    });

    test('a marker left by an earlier attempt does not count', () async {
      final marker = File(p.join(updates, WindowsUpdateInstaller.startedMarkerName));
      await marker.writeAsString('0123456789abcdef0123456789abcdef');
      final windows = installer(scriptRuns: false);
      await expectLater(windows.install(update), throwsA(isA<UpdateDownloadException>()));
      expect(marker.existsSync(), isFalse, reason: 'removed before launching');
      expect(windows.quits, isEmpty);
    });

    test('the script reports in first and relaunches only an app that exited', () {
      const script = WindowsUpdateInstaller.updateScript;
      expect(script.codeUnits.every((e) => e < 128), isTrue);
      final body = script.substring(script.indexOf(')\n') + 2).trimLeft();
      final firstStatement = body.split('\n').firstWhere((line) => !line.trimLeft().startsWith('#'));
      expect(firstStatement, startsWith(r'Set-Content -LiteralPath $Marker -Value $Nonce'));
      // Only an exit the script saw counts: false until the wait returned.
      expect(script, contains(r'$exited = $false'));
      expect(script, contains(r"if ($app -and -not $app.WaitForExit(600000)) { throw 'the app did not exit' }"));
      expect(script.indexOf(r'$exited = $true'), greaterThan(script.indexOf('WaitForExit(600000)')));
      const relaunchCall = '[System.Diagnostics.Process]::Start(';
      final relaunch = script.indexOf(relaunchCall);
      expect(relaunch, greaterThan(script.indexOf(r'if ($exited) {')));
      expect(script.indexOf(relaunchCall, relaunch + 1), -1, reason: 'one guarded relaunch');
      expect(script, isNot(contains('Start-Process')));
      expect(script, contains('not starting another instance'));
    });
  });

  group('forum handlers on images and links', () {
    for (final html in [
      '<img src="a.png" onload="thumbImg(this, 600, \'x\')">',
      '<img src="a.png" onclick="someForumHelper(this)">',
      '<img src="a.png" onmouseover="return showPreview(this, \'a=b&c=d\', 0);">',
      '<a href="forum.php?mod=viewthread&amp;tid=1" onclick="someForumHelper(this, \'tid=1\');return false;">t</a>',
    ]) {
      test('not interactive: $html', () {
        expect(interactivePostHtml(_message(html), postId: '42'), isNull);
      });
    }

    for (final html in [
      '<script>function reveal(e) { e.style.opacity = 1; }</script><img src="a.png" onclick="reveal(this)">',
      '<img src="a.png" onclick="this.src=\'b.png\'">',
      '<img src="a.png" onclick="helper(this); other()">',
      '<img src="a.png" onclick="helper(x = 1)">',
      '<img src="a.png" onclick="alert(\'answer\')">',
      '<img src="a.png" onclick="document.body.remove()">',
      '<a href="javascript:;" onclick="someFunction()">Play</a>',
      '<a onclick="someFunction()">Play</a>',
    ]) {
      test('interactive: $html', () {
        expect(interactivePostHtml(_message(html), postId: '42'), isNotNull);
      });
    }
  });

  group('viewer texts', () {
    tearDown(() => LocaleSettings.setLocale(AppLocale.en));

    test('the app sends every text of the viewer in its own language', () async {
      const keys = [
        'title',
        'back',
        'original',
        'originalDescription',
        'loading',
        'loadFailed',
        'openFailed',
        'linkFailed',
        'browserFailed',
        'downloadInOriginal',
        'pageMessage',
      ];
      final titles = <String>[];
      for (final locale in [AppLocale.zhCn, AppLocale.zhTw, AppLocale.en]) {
        await LocaleSettings.setLocale(locale);
        final labels = interactivePostViewerLabels();
        expect(labels.keys, keys, reason: 'the keys the native viewer reads');
        expect(labels.values.every((e) => e.trim().isNotEmpty), isTrue);
        titles.add(labels['title']!);
      }
      expect(titles, ['互动内容', '互動內容', 'Interactive content']);
    });
  });
}
