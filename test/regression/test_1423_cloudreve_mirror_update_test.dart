import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/update/cubit/update_cubit.dart';
import 'package:tsdm_client/features/update/cubit/update_download_cubit.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/features/update/models/update_channel.dart';
import 'package:tsdm_client/features/update/repository/cloudreve_mirror.dart';
import 'package:tsdm_client/features/update/repository/release_update_repository.dart';
import 'package:tsdm_client/instance.dart';

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
  List<UpdateAsset> get assets => [target.asset];
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
  bool mirrorHangs = false;
  Uint8List mirrorPayload = _bytes;
  Map<String, Object?>? mirrorInfo;

  /// Version code in the tag's version.json on GitHub.
  int taggedVersionCode = 182;
  final fetched = <String>[];

  /// Requests that reached GitHub, the API included.
  int githubRequests = 0;

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
      githubRequests++;
      if (githubDown) throw DioException.connectionError(requestOptions: options, reason: 'down');
      if (uri.host == 'api.github.com' && uri.path.endsWith('/contents/version.json')) {
        expect(uri.queryParameters['ref'], 'v1.63.0');
        fetched.add('github version.json');
        return json({'version': '1.63.0', 'versionCode': taggedVersionCode, 'changelog': 'update'});
      }
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
    if (mirrorHangs) return Completer<ResponseBody>().future;
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

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

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

  Future<DownloadedUpdate> download(UpdateTarget target, {UpdateChannel channel = UpdateChannel.auto}) =>
      (repository(target)..channel = channel).download(
        _info,
        cancelToken: CancelToken(),
        onProgress: (_, _) {},
        onVerifying: () {},
      );

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
    expect(adapter.fetched, [
      'github version.json',
      'mirror v1.63.0/tsdm_client-windows.zip',
      'github tsdm_client-windows.zip',
    ]);
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

  test('Windows rejects a release whose tagged version code differs from the offer', () async {
    adapter.taggedVersionCode = 150;
    await expectLater(download(UpdateTarget.windows), fails(UpdateDownloadFailure.invalidRelease));
    expect(adapter.fetched, ['github version.json']);
  });

  test('a release GitHub does not have is not taken from the mirror', () async {
    adapter
      ..githubStatus = 404
      ..mirrorInfo = listing();
    await expectLater(download(UpdateTarget.android), fails(UpdateDownloadFailure.releaseUnavailable));
    expect(adapter.fetched, isEmpty);
  });

  group('channel', () {
    test('GitHub only: the mirror is not asked, and is no fallback', () async {
      await download(UpdateTarget.android, channel: UpdateChannel.github);
      expect(adapter.fetched, ['github tsdm_client-universal.apk']);
      adapter
        ..fetched.clear()
        ..githubDown = true
        ..mirrorInfo = listing();
      await expectLater(
        download(UpdateTarget.android, channel: UpdateChannel.github),
        fails(UpdateDownloadFailure.network),
      );
      expect(adapter.fetched, isEmpty);
    });

    test('mirror only on Android: GitHub is not asked at all', () async {
      adapter.mirrorInfo = listing();
      final result = await download(UpdateTarget.android, channel: UpdateChannel.mirror);
      expect(adapter.fetched, ['mirror version.json', 'mirror v1.63.0/tsdm_client-universal.apk']);
      expect(adapter.githubRequests, 0);
      expect(await File(result.path).readAsBytes(), _bytes);
    });

    test('mirror only on Android: no fallback to GitHub for a release or bytes the mirror lacks', () async {
      adapter.mirrorInfo = listing(version: '1.62.3');
      await expectLater(
        download(UpdateTarget.android, channel: UpdateChannel.mirror),
        fails(UpdateDownloadFailure.releaseUnavailable),
      );
      adapter
        ..mirrorInfo = listing()
        ..mirrorPayload = Uint8List.fromList(List<int>.filled(_bytes.length, 7));
      await expectLater(
        download(UpdateTarget.android, channel: UpdateChannel.mirror),
        fails(UpdateDownloadFailure.integrity),
      );
      expect(adapter.githubRequests, 0);
      expect(await directory.list().length, 0);
    });

    test("mirror only on Windows: the bytes are the mirror's, GitHub still vouches for them", () async {
      adapter.mirrorInfo = listing();
      await download(UpdateTarget.windows, channel: UpdateChannel.mirror);
      expect(adapter.fetched, ['github version.json', 'mirror v1.63.0/tsdm_client-windows.zip']);
      adapter
        ..fetched.clear()
        ..mirrorPayload = Uint8List.fromList(List<int>.filled(_bytes.length, 7));
      await expectLater(
        download(UpdateTarget.windows, channel: UpdateChannel.mirror),
        fails(UpdateDownloadFailure.integrity),
      );
      expect(adapter.fetched, ['github version.json', 'mirror v1.63.0/tsdm_client-windows.zip']);
      adapter
        ..fetched.clear()
        ..githubDown = true;
      await expectLater(
        download(UpdateTarget.windows, channel: UpdateChannel.mirror),
        fails(UpdateDownloadFailure.network),
      );
      expect(adapter.fetched, isEmpty);
    });

    test('a stored index this version does not know is the automatic channel', () {
      expect(UpdateChannel.of(1), UpdateChannel.mirror);
      expect(UpdateChannel.of(2), UpdateChannel.github);
      expect(UpdateChannel.of(7), UpdateChannel.auto);
      expect(UpdateChannel.of(-1), UpdateChannel.auto);
    });
  });

  test('mirror version info parses as the repository one', () async {
    adapter.mirrorInfo = listing();
    final info = parseLatestVersionInfo(
      await CloudreveMirror(dio: Dio()..httpClientAdapter = adapter).versionInfo(),
    );
    expect(info.version, '1.63.0');
    expect(info.versionCode, 182);
  });

  group('version check', () {
    const github = {'version': '1.63.0', 'versionCode': 182, 'changelog': 'github'};
    final saved = <UpdateChannel>[];
    setUp(saved.clear);
    UpdateCubit cubit(AsyncEither<Object?> Function() githubInfo, {UpdateChannel channel = UpdateChannel.auto}) =>
        UpdateCubit(
          download: UpdateDownloadCubit(supported: false),
          mirror: CloudreveMirror(dio: Dio()..httpClientAdapter = adapter),
          githubVersionInfo: githubInfo,
          channel: channel,
          saveChannel: (channel) async => saved.add(channel),
        );
    AsyncEither<Object?> ok() => TaskEither.right(github);
    AsyncEither<Object?> down() => TaskEither.left(HttpRequestFailedException(503));

    test('GitHub decides when it can be read, even if the mirror names something newer', () async {
      adapter.mirrorInfo = {...listing(), 'version': '1.50.0', 'versionCode': 999};
      final updates = cubit(ok);
      await updates.checkUpdate(notice: false);
      expect(updates.state.latestVersionInfo?.changelog, 'github');
      await updates.close();
    });

    test("GitHub's answer does not wait for a mirror that never answers", () async {
      adapter.mirrorHangs = true;
      final updates = cubit(ok);
      await updates.checkUpdate(notice: false).timeout(const Duration(seconds: 5));
      expect(updates.state.latestVersionInfo?.changelog, 'github');
      await updates.close();
    });

    test('the mirror answers when GitHub cannot be read', () async {
      adapter.mirrorInfo = listing();
      final updates = cubit(down);
      await updates.checkUpdate();
      expect(updates.state.latestVersionInfo?.versionCode, 182);
      expect(updates.state.notice, isFalse);
      await updates.close();
    });

    test('mirror only: GitHub is not asked, even where it would answer', () async {
      adapter.mirrorInfo = {...listing(), 'changelog': 'mirror'};
      var asked = 0;
      final updates = cubit(() {
        asked++;
        return ok();
      }, channel: UpdateChannel.mirror);
      await updates.checkUpdate();
      expect(updates.state.latestVersionInfo?.changelog, 'mirror');
      expect(asked, 0);
      adapter.mirrorDown = true;
      await updates.checkUpdate();
      expect(updates.state.latestVersionInfo, isNull);
      expect(updates.state.notice, isTrue);
      expect(asked, 0);
      await updates.close();
    });

    test('GitHub only: the mirror is not asked and does not answer for it', () async {
      adapter.mirrorInfo = listing();
      final updates = cubit(ok, channel: UpdateChannel.github);
      await updates.checkUpdate();
      expect(updates.state.latestVersionInfo?.changelog, 'github');
      expect(adapter.fetched, isEmpty);
      await updates.close();
      final offline = cubit(down, channel: UpdateChannel.github);
      await offline.checkUpdate();
      expect(offline.state.latestVersionInfo, isNull);
      expect(offline.state.notice, isTrue);
      expect(adapter.fetched, isEmpty);
      await offline.close();
    });

    test('a new choice is kept, reaches the downloads and drops the answer of the old channel', () async {
      final updates = cubit(ok);
      expect(updates.download.channel, UpdateChannel.auto);
      await updates.checkUpdate();
      expect(updates.state.latestVersionInfo, isNotNull);
      await updates.setChannel(UpdateChannel.mirror);
      expect(updates.state.channel, UpdateChannel.mirror);
      expect(updates.state.latestVersionInfo, isNull);
      expect(updates.download.channel, UpdateChannel.mirror);
      expect(saved, [UpdateChannel.mirror]);
      await updates.setChannel(UpdateChannel.mirror);
      expect(saved, [UpdateChannel.mirror]);
      await updates.close();
      final restored = cubit(ok, channel: UpdateChannel.github);
      expect(restored.state.channel, UpdateChannel.github);
      expect(restored.download.channel, UpdateChannel.github);
      await restored.close();
    });

    test('neither source: a failure notice', () async {
      adapter.mirrorDown = true;
      final updates = cubit(down);
      await updates.checkUpdate();
      expect(updates.state.latestVersionInfo, isNull);
      expect(updates.state.notice, isTrue);
      expect(updates.state.loading, isFalse);
      await updates.close();
    });
  });

  test('asset listing rejects malformed entries', () {
    expect(CloudreveMirror.assetOf(listing(), 'tsdm_client-universal.apk')?.size, _bytes.length);
    expect(CloudreveMirror.assetOf(listing(sha256: 'XYZ'), 'tsdm_client-universal.apk'), isNull);
    expect(CloudreveMirror.assetOf(listing(), '../tsdm_client-universal.apk'), isNull);
    expect(CloudreveMirror.assetOf({'assets': 1}, 'tsdm_client-universal.apk'), isNull);
  });
}
