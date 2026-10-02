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
const _assetUrl = 'https://github.com/Carinoasd/tsdm_client/releases/download/v1.31.0/tsdm_client-universal.apk';
final _bytes = Uint8List.fromList(List<int>.generate(4096, (index) => index % 251));

class _Installer extends AndroidUpdateInstaller {
  _Installer(this.path);
  final String path;
  bool allowed = true;
  int permissionChecks = 0;
  int settings = 0;
  final installs = <DownloadedUpdate>[];

  @override
  Future<String> directory() async => path;

  @override
  Future<bool> canInstall() async {
    permissionChecks++;
    return allowed;
  }

  @override
  Future<bool> openPermissionSettings() async {
    settings++;
    return true;
  }

  @override
  Future<bool> install(DownloadedUpdate update) async {
    installs.add(update);
    return true;
  }
}

class _MetadataAdapter implements HttpClientAdapter {
  _MetadataAdapter(this.release);
  final Map<String, Object?> release;
  final requests = <RequestOptions>[];
  int status = 200;
  int downloads = 0;
  bool allowInitialDownload = false;

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
      expect(options.uri.toString(), 'https://api.github.com/repos/Carinoasd/tsdm_client/releases/tags/v1.31.0');
      return ResponseBody.fromString(
        jsonEncode(release),
        status,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    downloads++;
    expect(allowInitialDownload, isTrue, reason: 'restore must never request an APK body');
    expect(options.uri.toString(), _assetUrl);
    return ResponseBody(Stream<Uint8List>.value(_bytes), 200);
  }

  @override
  void close({bool force = false}) {}
}

class _PendingRestore {
  _PendingRestore(this.token, this.verify);
  final CancelToken token;
  final void Function() verify;
  final result = Completer<DownloadedUpdate?>();
}

class _DelayedRepository extends AndroidUpdateRepository {
  _DelayedRepository(AndroidUpdateInstaller installer) : super(installer: installer);
  final restores = <_PendingRestore>[];
  final downloads = <Completer<DownloadedUpdate>>[];
  final discarded = <DownloadedUpdate>[];

  @override
  Future<DownloadedUpdate?> restore(
    LatestVersionInfo info, {
    required CancelToken cancelToken,
    required void Function() onVerifying,
  }) {
    final pending = _PendingRestore(cancelToken, onVerifying);
    restores.add(pending);
    return pending.result.future;
  }

  @override
  Future<DownloadedUpdate> download(
    LatestVersionInfo info, {
    required CancelToken cancelToken,
    required void Function(int, int) onProgress,
    required void Function() onVerifying,
  }) {
    final result = Completer<DownloadedUpdate>();
    downloads.add(result);
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
  late _MetadataAdapter adapter;
  late AndroidUpdateRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tsdm-update-restore-test-');
    installer = _Installer(directory.path);
    final digest = await const DartSha256().hash(_bytes);
    asset = {
      'name': 'tsdm_client-universal.apk',
      'state': 'uploaded',
      'size': _bytes.length,
      'browser_download_url': _assetUrl,
      'digest': 'sha256:${digest.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}',
    };
    adapter = _MetadataAdapter({
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

  Future<File> cache({String name = 'update-121-100.apk', List<int>? bytes}) =>
      File('${directory.path}/$name').writeAsBytes(bytes ?? _bytes);

  Future<DownloadedUpdate?> restore({CancelToken? token, void Function()? verify}) => repository.restore(
    _info,
    cancelToken: token ?? CancelToken(),
    onVerifying: verify ?? () {},
  );

  Matcher fails(UpdateDownloadFailure failure) => throwsA(
    isA<UpdateDownloadException>().having((error) => error.failure, 'failure', failure),
  );

  test('fresh process restores permission-settings APK with fresh metadata and explicit installation', () async {
    adapter.allowInitialDownload = true;
    final original = UpdateDownloadCubit(repository: repository, supported: true, currentVersionCode: 120);
    await original.download(_info);
    installer.allowed = false;
    await original.install();
    await original.openPermissionSettings();
    expect(original.state.status, UpdateDownloadStatus.permissionRequired);
    expect(installer.settings, 1);
    expect(installer.installs, isEmpty);
    await original.close();

    final restartedInstaller = _Installer(directory.path);
    final freshMetadata = _MetadataAdapter(adapter.release);
    final restarted = UpdateDownloadCubit(
      repository: AndroidUpdateRepository(
        dio: Dio()..httpClientAdapter = freshMetadata,
        installer: restartedInstaller,
      ),
      supported: true,
      currentVersionCode: 120,
    );
    addTearDown(restarted.close);
    final stages = <UpdateDownloadStatus>[];
    final subscription = restarted.stream.listen((state) => stages.add(state.status));
    addTearDown(subscription.cancel);

    await restarted.restore(_info);
    await Future<void>.delayed(Duration.zero);
    expect(stages, [UpdateDownloadStatus.resolving, UpdateDownloadStatus.verifying, UpdateDownloadStatus.ready]);
    expect(restarted.state.canInstall, isTrue);
    expect(restarted.state.version, _info.version);
    expect(freshMetadata.requests, hasLength(1));
    expect(freshMetadata.downloads, 0);
    expect(restartedInstaller.permissionChecks, 0);
    expect(restartedInstaller.settings, 0);
    expect(restartedInstaller.installs, isEmpty);

    await restarted.install();
    expect(restarted.state.status, UpdateDownloadStatus.installerOpened);
    final installed = restartedInstaller.installs.single;
    expect(installed.version, '1.31.0');
    expect(installed.versionCode, 1219);
    expect(await File(installed.path).readAsBytes(), _bytes);
    expect(freshMetadata.downloads, 0);
  });

  test('missing directory is an empty cache without network access', () async {
    final missing = AndroidUpdateRepository(
      dio: Dio()..httpClientAdapter = adapter,
      installer: _Installer('${directory.path}/not-created'),
    );
    addTearDown(missing.dispose);
    expect(
      await missing.restore(_info, cancelToken: CancelToken(), onVerifying: () => fail('no file to verify')),
      isNull,
    );
    expect(adapter.requests, isEmpty);
  });

  test('empty cache restores cubit to idle without HTTP or installation', () async {
    final cubit = UpdateDownloadCubit(repository: repository, supported: true, currentVersionCode: 120);
    addTearDown(cubit.close);
    await cubit.restore(_info);
    expect(cubit.state.status, UpdateDownloadStatus.idle);
    expect(cubit.state.canInstall, isFalse);
    expect(adapter.requests, isEmpty);
    expect(installer.installs, isEmpty);
  });

  test('only completed exact-version filenames are considered', () async {
    final ignored = <File>[];
    for (final name in [
      'update-121-100.part',
      'update-120-100.apk',
      'update-122-100.apk',
      'update-121-timestamp.apk',
      'update-121-100.apk.backup',
      'other-121-100.apk',
    ]) {
      ignored.add(await cache(name: name));
    }
    await Directory('${directory.path}/update-121-999.apk').create();
    expect(await restore(), isNull);
    expect(adapter.requests, isEmpty);
    for (final file in ignored) {
      expect(file.existsSync(), isTrue);
    }
  });

  test('symbolic-link APK is ignored without HTTP or touching its target', () async {
    final target = await cache(name: 'unrelated-file');
    final link = Link('${directory.path}/update-121-100.apk');
    try {
      await link.create(target.path);
    } on FileSystemException catch (error) {
      if (Platform.isWindows && error.osError?.errorCode == 1314) {
        markTestSkipped('Windows has not granted symbolic-link creation privileges');
        return;
      }
      rethrow;
    }
    expect(await restore(), isNull);
    expect(adapter.requests, isEmpty);
    expect(await link.exists(), isTrue);
    expect(await target.readAsBytes(), _bytes);
  });

  for (final corruption in ['digest', 'short', 'long']) {
    test('corrupt cache $corruption is removed without downloading replacement', () async {
      final bytes = switch (corruption) {
        'digest' => Uint8List(_bytes.length),
        'short' => Uint8List(_bytes.length - 1),
        _ => Uint8List(_bytes.length + 1),
      };
      final candidate = await cache(bytes: bytes);
      expect(await restore(), isNull);
      expect(candidate.existsSync(), isFalse);
      expect(adapter.requests, hasLength(1));
      expect(adapter.downloads, 0);
      expect(installer.installs, isEmpty);
    });
  }

  test('fresh metadata invalidates cached bytes when the published digest changes', () async {
    final candidate = await cache();
    asset['digest'] = 'sha256:${List.filled(64, '0').join()}';
    expect(await restore(), isNull);
    expect(candidate.existsSync(), isFalse);
    expect(adapter.requests, hasLength(1));
    expect(adapter.downloads, 0);
  });

  test('a corrupt candidate does not prevent another verified candidate from restoring', () async {
    await cache(name: 'update-121-200.apk', bytes: Uint8List(_bytes.length));
    final good = await cache();
    final update = await restore();
    expect(update, isNotNull);
    expect(await File(update!.path).readAsBytes(), _bytes);
    expect(await File(update.path).resolveSymbolicLinks(), await good.resolveSymbolicLinks());
    expect(adapter.requests, hasLength(1));
    expect(adapter.downloads, 0);
  });

  for (final status in [404, 403, 500]) {
    test('metadata HTTP $status keeps cache and reports the existing typed failure', () async {
      final candidate = await cache();
      adapter.status = status;
      await expectLater(
        restore(),
        fails(status == 404 ? UpdateDownloadFailure.releaseUnavailable : UpdateDownloadFailure.network),
      );
      expect(await candidate.readAsBytes(), _bytes);
      expect(adapter.downloads, 0);
    });
  }

  for (final invalid in ['tag', 'asset-url', 'digest', 'missing-asset']) {
    test('invalid metadata $invalid cannot approve cached APK', () async {
      final candidate = await cache();
      switch (invalid) {
        case 'tag':
          adapter.release['tag_name'] = 'v1.32.0';
        case 'asset-url':
          asset['browser_download_url'] = 'https://example.com/app.apk';
        case 'digest':
          asset['digest'] = null;
        case 'missing-asset':
          adapter.release['assets'] = <Object>[];
      }
      await expectLater(
        restore(),
        fails(
          invalid == 'missing-asset' ? UpdateDownloadFailure.releaseUnavailable : UpdateDownloadFailure.invalidRelease,
        ),
      );
      expect(await candidate.readAsBytes(), _bytes);
      expect(adapter.downloads, 0);
      expect(installer.installs, isEmpty);
    });
  }

  test('cancelling verification keeps the completed cache for a later restart', () async {
    final candidate = await cache();
    final token = CancelToken();
    await expectLater(restore(token: token, verify: token.cancel), throwsA(isA<DioException>()));
    expect(await candidate.readAsBytes(), _bytes);
    expect(adapter.downloads, 0);
    expect(await restore(), isNotNull);
  });

  group('restore cubit lifecycle', () {
    late _DelayedRepository delayed;
    late UpdateDownloadCubit cubit;

    setUp(() {
      delayed = _DelayedRepository(installer);
      cubit = UpdateDownloadCubit(repository: delayed, supported: true, currentVersionCode: 120);
    });
    tearDown(() async {
      if (!cubit.isClosed) await cubit.close();
    });

    test('only a supported newer version can begin idle restoration', () async {
      const old = LatestVersionInfo(version: '1.30.0', versionCode: 120, changelog: 'old');
      await cubit.restore(old);
      expect(cubit.state.status, UpdateDownloadStatus.idle);
      expect(delayed.restores, isEmpty);
      final unsupported = UpdateDownloadCubit(repository: delayed, supported: false, currentVersionCode: 120);
      await unsupported.restore(_info);
      expect(unsupported.state.status, UpdateDownloadStatus.idle);
      expect(delayed.restores, isEmpty);
      await unsupported.close();
    });

    test('parallel calls and ready-state calls do not start another restore', () async {
      final running = cubit.restore(_info);
      await cubit.restore(_info);
      expect(delayed.restores, hasLength(1));
      final pending = delayed.restores.single;
      pending.verify();
      expect(cubit.state.status, UpdateDownloadStatus.verifying);
      await cubit.restore(_info);
      expect(delayed.restores, hasLength(1));
      pending.result.complete(const DownloadedUpdate(path: 'cached', version: '1.31.0', versionCode: 1219));
      await running;
      await cubit.restore(_info);
      expect(cubit.state.status, UpdateDownloadStatus.ready);
      expect(delayed.restores, hasLength(1));
      expect(installer.installs, isEmpty);
    });

    test('typed restoration failure becomes failed and is not automatically retried', () async {
      final running = cubit.restore(_info);
      delayed.restores.single.result.completeError(const UpdateDownloadException(UpdateDownloadFailure.network));
      await running;
      expect(cubit.state.status, UpdateDownloadStatus.failed);
      expect(cubit.state.failure, UpdateDownloadFailure.network);
      expect(cubit.state.canInstall, isFalse);
      await cubit.restore(_info);
      expect(delayed.restores, hasLength(1));
    });

    test('cancelled restoration cannot replace a later download or discard its cache', () async {
      final candidate = await cache();
      final receipt = DownloadedUpdate(path: candidate.path, version: '1.31.0', versionCode: 1219);
      final restoring = cubit.restore(_info);
      final old = delayed.restores.single;
      cubit.cancel();
      expect(old.token.isCancelled, isTrue);
      expect(cubit.state.status, UpdateDownloadStatus.cancelled);
      final downloading = cubit.download(_info);
      await Future<void>.delayed(Duration.zero);
      old.verify();
      old.result.complete(receipt);
      await restoring;
      expect(cubit.state.status, UpdateDownloadStatus.resolving);
      expect(delayed.discarded, isEmpty);
      expect(await candidate.readAsBytes(), _bytes);
      delayed.downloads.single.complete(const DownloadedUpdate(path: 'new', version: '1.31.0', versionCode: 1219));
      await downloading;
      expect(cubit.state.status, UpdateDownloadStatus.ready);
    });

    test('close cancels restoration and late completion leaves its cache intact', () async {
      final candidate = await cache();
      final restoring = cubit.restore(_info);
      final pending = delayed.restores.single;
      pending.verify();
      await cubit.close();
      expect(pending.token.isCancelled, isTrue);
      pending.verify();
      pending.result.complete(DownloadedUpdate(path: candidate.path, version: '1.31.0', versionCode: 1219));
      await restoring;
      expect(delayed.discarded, isEmpty);
      expect(await candidate.readAsBytes(), _bytes);
      expect(installer.installs, isEmpty);
    });
  });
}
