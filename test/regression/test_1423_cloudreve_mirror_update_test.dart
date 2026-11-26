import 'dart:convert';
import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/features/update/repository/cloudreve_mirror.dart';
import 'package:tsdm_client/features/update/repository/release_update_repository.dart';

const _info = LatestVersionInfo(version: '1.63.0', versionCode: 182, changelog: 'update');
const _githubUrl = 'https://github.com/Carinoasd/tsdm_client/releases/download/v1.63.0/';
const _signed = 'https://drive.noire.cc/api/v4/file/content/X/0/';
final _bytes = Uint8List.fromList(List<int>.generate(4096, (i) => i % 251));

class _Installer implements UpdateInstaller {
  _Installer(this.path, this.target);
  final String path;
  @override
  final UpdateTarget target;
  @override
  Future<String> directory() async => path;
  @override
  Future<bool> canInstall() async => true;
  @override
  Future<bool> openPermissionSettings() async => true;
  @override
  Future<UpdateDownloadFailure?> preflight() async => null;
  @override
  Future<bool> install(DownloadedUpdate update) async => true;
}

/// Serves GitHub's release API and downloads, and the mirror's signed URLs, `version.json` and assets.
class _Adapter implements HttpClientAdapter {
  _Adapter(this.digest);
  final String digest;
  bool githubDown = false;
  int githubStatus = 200;
  bool mirrorDown = false;
  Uint8List mirrorPayload = _bytes;
  Map<String, Object?>? mirrorInfo;
  final fetched = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    expect(options.headers.keys.map((key) => key.toLowerCase()), isNot(contains('cookie')));
    ResponseBody json(Object? body, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
    if (uri.host == 'api.github.com' || uri.host == 'github.com') {
      if (githubDown) throw DioException.connectionError(requestOptions: options, reason: 'down');
      if (uri.host == 'api.github.com') {
        return json({
          'tag_name': 'v1.63.0',
          'draft': false,
          'prerelease': false,
          'assets': [
            for (final name in ['tsdm_client-universal.apk', 'tsdm_client-windows.zip'])
              {
                'name': name,
                'state': 'uploaded',
                'size': _bytes.length,
                'browser_download_url': '$_githubUrl$name',
                'digest': 'sha256:$digest',
              },
          ],
        }, githubStatus);
      }
      fetched.add('github ${uri.pathSegments.last}');
      return ResponseBody(Stream.value(_bytes), 200);
    }
    expect(uri.host, 'drive.noire.cc');
    if (mirrorDown) throw DioException.connectionError(requestOptions: options, reason: 'down');
    if (uri.path == '/api/v4/file/url') {
      expect(options.method, 'POST');
      final path = ((options.data as Map)['uris'] as List).single as String;
      expect(path, startsWith('cloudreve://${CloudreveMirror.share}@share/'));
      return json({
        'code': 0,
        'data': {
          'urls': [
            {'url': '$_signed${path.split('@share/').last}?sign=x'},
          ],
        },
      });
    }
    final name = uri.path.substring(Uri.parse(_signed).path.length);
    fetched.add('mirror $name');
    if (name == 'version.json') {
      if (mirrorInfo == null) return json(null, 404);
      return ResponseBody.fromBytes(utf8.encode(jsonEncode(mirrorInfo)), 200);
    }
    return ResponseBody(Stream.value(mirrorPayload), 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory directory;
  late _Adapter adapter;
  late String digest;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tsdm-mirror-test-');
    final hash = await const DartSha256().hash(_bytes);
    digest = hash.bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    adapter = _Adapter(digest);
  });
  tearDown(() => directory.delete(recursive: true));

  ReleaseUpdateRepository repository(UpdateTarget target) => ReleaseUpdateRepository(
    dio: Dio()..httpClientAdapter = adapter,
    installer: _Installer(directory.path, target),
    mirror: CloudreveMirror(dio: Dio()..httpClientAdapter = adapter),
  );

  Future<DownloadedUpdate> download(UpdateTarget target) =>
      repository(target).download(_info, cancelToken: CancelToken(), onProgress: (_, _) {}, onVerifying: () {});

  Matcher fails(UpdateDownloadFailure failure) =>
      throwsA(isA<UpdateDownloadException>().having((error) => error.failure, 'failure', failure));

  Map<String, Object?> listing({String version = '1.63.0', String? sha256}) => {
    'version': version,
    'versionCode': 182,
    'changelog': 'update',
    'assets': {
      'tsdm_client-universal.apk': {'size': _bytes.length, 'sha256': sha256 ?? digest},
      'tsdm_client-windows.zip': {'size': _bytes.length, 'sha256': sha256 ?? digest},
    },
  };

  test('downloads from the mirror, verified against GitHub metadata', () async {
    final result = await download(UpdateTarget.android);
    expect(adapter.fetched, ['mirror v1.63.0/tsdm_client-universal.apk']);
    expect(await File(result.path).readAsBytes(), _bytes);
  });

  test('corrupt mirror bytes fall back to GitHub', () async {
    adapter.mirrorPayload = Uint8List.fromList(List<int>.filled(_bytes.length, 7));
    final result = await download(UpdateTarget.windows);
    expect(adapter.fetched, ['mirror v1.63.0/tsdm_client-windows.zip', 'github tsdm_client-windows.zip']);
    expect(await File(result.path).readAsBytes(), _bytes);
    expect(await directory.list().length, 1);
  });

  test('unreachable mirror falls back to GitHub', () async {
    adapter.mirrorDown = true;
    await download(UpdateTarget.android);
    expect(adapter.fetched, ['github tsdm_client-universal.apk']);
  });

  test('Android takes size and digest from the mirror when GitHub is unreachable', () async {
    adapter
      ..githubDown = true
      ..mirrorInfo = listing();
    final result = await download(UpdateTarget.android);
    expect(adapter.fetched, ['mirror version.json', 'mirror v1.63.0/tsdm_client-universal.apk']);
    expect(await File(result.path).readAsBytes(), _bytes);
  });

  test('a mirror listing of another version is not used', () async {
    adapter
      ..githubDown = true
      ..mirrorInfo = listing(version: '1.62.3');
    await expectLater(download(UpdateTarget.android), fails(UpdateDownloadFailure.network));
  });

  test('a mirror listing that does not match the bytes is rejected', () async {
    adapter
      ..githubDown = true
      ..mirrorInfo = listing(sha256: '0' * 64);
    await expectLater(download(UpdateTarget.android), fails(UpdateDownloadFailure.integrity));
    expect(await directory.list().length, 0);
  });

  test('Windows never installs on the mirror listing alone', () async {
    adapter
      ..githubDown = true
      ..mirrorInfo = listing();
    await expectLater(download(UpdateTarget.windows), fails(UpdateDownloadFailure.network));
    expect(adapter.fetched, isEmpty);
  });

  test('a release GitHub does not have is not taken from the mirror', () async {
    adapter
      ..githubStatus = 404
      ..mirrorInfo = listing();
    await expectLater(download(UpdateTarget.android), fails(UpdateDownloadFailure.releaseUnavailable));
    expect(adapter.fetched, isEmpty);
  });

  test('mirror version info parses as the repository one', () async {
    adapter.mirrorInfo = listing();
    final info = parseLatestVersionInfo(
      await CloudreveMirror(dio: Dio()..httpClientAdapter = adapter).versionInfo(),
    );
    expect(info.version, '1.63.0');
    expect(info.versionCode, 182);
  });

  test('asset listing rejects malformed entries', () {
    expect(CloudreveMirror.assetOf(listing(), 'tsdm_client-universal.apk')?.size, _bytes.length);
    expect(CloudreveMirror.assetOf(listing(sha256: 'XYZ'), 'tsdm_client-universal.apk'), isNull);
    expect(CloudreveMirror.assetOf(listing(), '../tsdm_client-universal.apk'), isNull);
    expect(CloudreveMirror.assetOf({'assets': 1}, 'tsdm_client-universal.apk'), isNull);
  });
}
