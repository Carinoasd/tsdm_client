import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/update/cubit/update_download_cubit.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/features/update/repository/android_update_repository.dart';

const _info = LatestVersionInfo(version: '1.31.0', versionCode: 121, changelog: 'update');
const _url = 'https://github.com/Carinoasd/tsdm_client/releases/download/v1.31.0/tsdm_client-universal.apk';
final _bytes = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));

class _Installer extends AndroidUpdateInstaller {
  _Installer(this.path);
  final String path;
  bool allowed = true;
  bool settingsResult = true;
  bool installResult = true;
  String? error;
  int installs = 0;
  int settings = 0;
  DownloadedUpdate? installed;
  @override
  Future<String> directory() async => path;
  @override
  Future<bool> canInstall() async => allowed;
  @override
  Future<bool> openPermissionSettings() async {
    settings++;
    return settingsResult;
  }

  @override
  Future<bool> install(DownloadedUpdate update) async {
    installs++;
    installed = update;
    if (error != null) throw PlatformException(code: error!);
    return installResult;
  }
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.release);
  final Map<String, Object?> release;
  Uint8List payload = _bytes;
  int status = 200;
  int downloads = 0;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    expect(options.method, 'GET');
    expect(options.headers.keys.map((key) => key.toLowerCase()), isNot(contains('cookie')));
    expect(options.headers.keys.map((key) => key.toLowerCase()), isNot(contains('authorization')));
    if (options.uri.host == 'api.github.com') {
      expect(options.uri.path, '/repos/Carinoasd/tsdm_client/releases/tags/v1.31.0');
      return ResponseBody.fromString(
        jsonEncode(release),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    expect(options.uri.toString(), _url);
    downloads++;
    return ResponseBody(Stream<Uint8List>.fromIterable([payload]), 200);
  }

  @override
  void close({bool force = false}) {}
}

class _DelayedRepository extends AndroidUpdateRepository {
  _DelayedRepository(AndroidUpdateInstaller installer) : super(installer: installer);
  final pending = <Completer<DownloadedUpdate>>[];
  final discarded = <DownloadedUpdate>[];
  @override
  Future<DownloadedUpdate> download(
    LatestVersionInfo info, {
    required CancelToken cancelToken,
    required void Function(int, int) onProgress,
    required void Function() onVerifying,
  }) {
    final result = Completer<DownloadedUpdate>();
    pending.add(result);
    return result.future;
  }

  @override
  Future<void> discard(DownloadedUpdate? update) async {
    if (update != null) discarded.add(update);
  }
}

void main() {
  late Directory directory;
  late _Installer installer;
  late Map<String, Object?> asset;
  late _Adapter adapter;
  late AndroidUpdateRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tsdm-update-test-');
    installer = _Installer(directory.path);
    final hash = await const DartSha256().hash(_bytes);
    asset = {
      'name': 'tsdm_client-universal.apk',
      'state': 'uploaded',
      'size': _bytes.length,
      'browser_download_url': _url,
      'digest': 'sha256:${hash.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}',
    };
    adapter = _Adapter({
      'tag_name': 'v1.31.0',
      'draft': false,
      'prerelease': false,
      'assets': [asset],
    });
    repository = AndroidUpdateRepository(dio: Dio()..httpClientAdapter = adapter, installer: installer);
  });
  tearDown(() async {
    repository.dispose();
    await directory.delete(recursive: true);
  });

  Future<DownloadedUpdate> download({CancelToken? token, void Function()? verify}) => repository.download(
    _info,
    cancelToken: token ?? CancelToken(),
    onProgress: (_, _) {},
    onVerifying: verify ?? () {},
  );

  Matcher fails(UpdateDownloadFailure failure) => throwsA(
    isA<UpdateDownloadException>().having((error) => error.failure, 'failure', failure),
  );

  test('exact release, digest and length verified before private APK is ready', () async {
    final steps = <String>[];
    final result = await repository.download(
      _info,
      cancelToken: CancelToken(),
      onProgress: (received, total) {
        expect(total, _bytes.length);
        steps.add('progress $received');
      },
      onVerifying: () => steps.add('verify'),
    );
    expect(result.version, '1.31.0');
    expect(result.versionCode, 1219);
    expect(result.path, endsWith('.apk'));
    expect(await File(result.path).readAsBytes(), _bytes);
    expect(steps.last, 'verify');
    expect(installer.installs, 0);
    expect(await directory.list().length, 1);
  });

  for (final mutation in ['tag', 'draft', 'prerelease', 'host', 'digest', 'oversized']) {
    test('reject invalid release metadata: $mutation', () async {
      switch (mutation) {
        case 'tag':
          adapter.release['tag_name'] = 'v1.32.0';
        case 'draft':
          adapter.release['draft'] = true;
        case 'prerelease':
          adapter.release['prerelease'] = true;
        case 'host':
          asset['browser_download_url'] = 'https://evil.example/app.apk';
        case 'digest':
          asset['digest'] = null;
        case 'oversized':
          asset['size'] = 1024 * 1024 * 1024;
      }
      await expectLater(download(), fails(UpdateDownloadFailure.invalidRelease));
      expect(adapter.downloads, 0);
      expect(await directory.list().isEmpty, isTrue);
    });
  }
  test('release asset not uploaded yet has a specific recoverable error', () async {
    adapter.release['assets'] = <Object>[];
    await expectLater(download(), fails(UpdateDownloadFailure.releaseUnavailable));
  });
  test('release 404 is distinguishable from network failure', () async {
    adapter.status = 404;
    await expectLater(download(), fails(UpdateDownloadFailure.releaseUnavailable));
  });
  test('GitHub rate limit remains a network error for browser fallback', () async {
    adapter.status = 403;
    await expectLater(download(), fails(UpdateDownloadFailure.network));
  });
  for (final corruption in ['hash', 'short', 'long']) {
    test('corrupt download $corruption is deleted and never installable', () async {
      switch (corruption) {
        case 'hash':
          adapter.payload = Uint8List(_bytes.length);
        case 'short':
          adapter.payload = Uint8List(4);
        case 'long':
          adapter.payload = Uint8List(_bytes.length + 1);
      }
      await expectLater(download(), fails(UpdateDownloadFailure.integrity));
      expect(await directory.list().isEmpty, isTrue);
      expect(installer.installs, 0);
    });
  }
  test('cancel during verification removes partial file', () async {
    final token = CancelToken();
    await expectLater(download(token: token, verify: token.cancel), throwsA(isA<DioException>()));
    expect(await directory.list().isEmpty, isTrue);
  });

  test('permission denial preserves ready APK, settings never auto-installs', () async {
    final cubit = UpdateDownloadCubit(repository: repository, supported: true, currentVersionCode: 120);
    addTearDown(cubit.close);
    await cubit.download(_info);
    expect(cubit.state.status, UpdateDownloadStatus.ready);
    installer.allowed = false;
    await cubit.install();
    expect(cubit.state.status, UpdateDownloadStatus.permissionRequired);
    expect(installer.installs, 0);
    await cubit.openPermissionSettings();
    expect(installer.settings, 1);
    expect(installer.installs, 0);
    installer.allowed = true;
    await cubit.install();
    expect(cubit.state.status, UpdateDownloadStatus.installerOpened);
    expect(installer.installed!.versionCode, 1219);
    await cubit.install(); // The user may have cancelled Android's installer.
    expect(installer.installs, 2);
  });
  test('install failure is retryable without redownloading', () async {
    final cubit = UpdateDownloadCubit(repository: repository, supported: true, currentVersionCode: 120);
    addTearDown(cubit.close);
    await cubit.download(_info);
    installer.error = 'installer_unavailable';
    await cubit.install();
    expect(cubit.state.failure, UpdateDownloadFailure.install);
    expect(cubit.state.canInstall, isTrue);
    installer.error = null;
    await cubit.install();
    expect(cubit.state.status, UpdateDownloadStatus.installerOpened);
    expect(adapter.downloads, 1);
  });
  test('same-version and non-Android cannot start a download', () async {
    final same = UpdateDownloadCubit(repository: repository, supported: true, currentVersionCode: 121);
    await same.download(_info);
    expect(same.state.failure, UpdateDownloadFailure.unsupported);
    expect(adapter.requests, isEmpty);
    await same.close();
    final desktop = UpdateDownloadCubit(supported: false);
    await desktop.download(_info);
    expect(desktop.state.failure, UpdateDownloadFailure.unsupported);
    await desktop.close();
  });
  test('duplicate clicks and cancelled stale completion cannot overwrite new download', () async {
    final delayed = _DelayedRepository(installer);
    final cubit = UpdateDownloadCubit(repository: delayed, supported: true, currentVersionCode: 120);
    addTearDown(cubit.close);
    final first = cubit.download(_info);
    await Future<void>.delayed(Duration.zero);
    await cubit.download(_info);
    expect(delayed.pending.length, 1);
    cubit.cancel();
    expect(cubit.state.status, UpdateDownloadStatus.cancelled);
    final second = cubit.download(_info);
    await Future<void>.delayed(Duration.zero);
    const old = DownloadedUpdate(path: 'old', version: '1.31.0', versionCode: 1219);
    delayed.pending[0].complete(old);
    await first;
    expect(cubit.state.status, UpdateDownloadStatus.resolving);
    expect(delayed.discarded, contains(old));
    delayed.pending[1].complete(const DownloadedUpdate(path: 'new', version: '1.31.0', versionCode: 1219));
    await second;
    expect(cubit.state.status, UpdateDownloadStatus.ready);
  });
}
