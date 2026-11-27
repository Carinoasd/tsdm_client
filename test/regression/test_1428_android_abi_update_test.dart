/// The in-app update of Android takes the APK built for the device's ABI, and the universal one when it cannot.
///
/// * [androidUpdateAssets]: arm64 and 32 bit ARM have a split APK, every other ABI (or none told) the universal one;
///   the universal one is always the last resort.
/// * The repository downloads the first of them the release has uploaded: the split APK when it is there, the
///   universal one when the release lacks it. A split APK that is there but wrong (its digest, its link) fails the
///   update; it is not passed over. The same choice is made from the mirror's listing when GitHub cannot be asked.
/// * The version code handed to the installer is the release's times ten plus the digit of the APK downloaded, the
///   digits being the build's (`android/app/build.gradle`). So any APK of a newer release is above every APK of an
///   older one (universal to split across releases is an upgrade), and a split APK is below the universal one of
///   the same release (never offered as an update of it; Android and the native check refuse it).
library;

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/features/update/repository/cloudreve_mirror.dart';
import 'package:tsdm_client/features/update/repository/release_update_repository.dart';
import 'package:tsdm_client/instance.dart';

const _info = LatestVersionInfo(version: '1.63.0', versionCode: 182, changelog: 'update');
const _githubUrl = 'https://github.com/Carinoasd/tsdm_client/releases/download/v1.63.0/';
const _signed = 'https://drive.noire.cc/api/v4/file/content/X/0/';

const _arm64 = 'tsdm_client-arm64_v8a.apk';
const _armV7 = 'tsdm_client-armeabi_v7a.apk';
const _universal = 'tsdm_client-universal.apk';

/// The bytes of each APK: different, so a file is known by what was downloaded.
final _files = <String, Uint8List>{
  _arm64: Uint8List.fromList(List<int>.generate(2048, (i) => i % 251)),
  _armV7: Uint8List.fromList(List<int>.generate(2048, (i) => i % 241)),
  _universal: Uint8List.fromList(List<int>.generate(4096, (i) => i % 239)),
};

String _sha256(Uint8List bytes) =>
    const DartSha256().hashSync(bytes).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();

class _Installer implements UpdateInstaller {
  _Installer(this.path, this.assets);
  final String path;
  @override
  final List<UpdateAsset> assets;
  @override
  UpdateTarget get target => UpdateTarget.android;
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

/// GitHub's release API and downloads, and the mirror's signed URLs, `version.json` and files.
class _Adapter implements HttpClientAdapter {
  /// The assets of the release on GitHub, by name; changed by a test.
  final release = <String, Map<String, Object?>>{
    for (final MapEntry(key: name, value: bytes) in _files.entries)
      name: {
        'name': name,
        'state': 'uploaded',
        'size': bytes.length,
        'browser_download_url': '$_githubUrl$name',
        'digest': 'sha256:${_sha256(bytes)}',
      },
  };

  /// The files the mirror lists in its `version.json`; null for a mirror without one.
  Set<String>? mirrored = _files.keys.toSet();

  /// The files the mirror really has (a release mirrored before the split APKs has only the universal one).
  Set<String> mirrorHas = _files.keys.toSet();
  bool githubDown = false;
  final fetched = <String>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final uri = options.uri;
    ResponseBody json(Object? body, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
    if (uri.host == 'api.github.com') {
      if (githubDown) throw DioException.connectionError(requestOptions: options, reason: 'down');
      return json({
        'tag_name': 'v1.63.0',
        'draft': false,
        'prerelease': false,
        'assets': release.values.toList(),
      });
    }
    if (uri.host == 'github.com') {
      if (githubDown) throw DioException.connectionError(requestOptions: options, reason: 'down');
      final name = uri.pathSegments.last;
      fetched.add('github $name');
      return ResponseBody(Stream.value(_files[name]!), 200);
    }
    expect(uri.host, 'drive.noire.cc');
    if (uri.path == '/api/v4/file/url') {
      final path = ((options.data as Map)['uris'] as List).single as String;
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
      final listed = mirrored;
      if (listed == null) return json(null, 404);
      return ResponseBody.fromBytes(
        utf8.encode(
          jsonEncode({
            'version': '1.63.0',
            'versionCode': 182,
            'changelog': 'update',
            'assets': {
              for (final name in listed) name: {'size': _files[name]!.length, 'sha256': _sha256(_files[name]!)},
            },
          }),
        ),
        200,
      );
    }
    final file = name.split('/').last;
    if (!mirrorHas.contains(file)) return json({'code': 40016}, 404);
    return ResponseBody(Stream.value(_files[file]!), 200);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late Directory directory;
  late _Adapter adapter;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('tsdm-abi-update-test-');
    adapter = _Adapter();
  });
  tearDown(() => directory.delete(recursive: true));

  ReleaseUpdateRepository repository(Abi? abi, {bool mirror = false}) => ReleaseUpdateRepository(
    dio: Dio()..httpClientAdapter = adapter,
    installer: _Installer(directory.path, androidUpdateAssets(abi)),
    mirror: mirror ? CloudreveMirror(dio: Dio()..httpClientAdapter = adapter) : null,
  );

  Future<DownloadedUpdate> download(Abi? abi, {bool mirror = false}) => repository(
    abi,
    mirror: mirror,
  ).download(_info, cancelToken: CancelToken(), onProgress: (_, _) {}, onVerifying: () {});

  Matcher fails(UpdateDownloadFailure failure) =>
      throwsA(isA<UpdateDownloadException>().having((error) => error.failure, 'failure', failure));

  group('which APK a device takes', () {
    test('the split APK of its ABI first, the universal one always last', () {
      expect(androidUpdateAssets(Abi.androidArm64), [UpdateAsset.androidArm64, UpdateAsset.androidUniversal]);
      expect(androidUpdateAssets(Abi.androidArm), [UpdateAsset.androidArmV7, UpdateAsset.androidUniversal]);
      expect(UpdateAsset.androidArm64.name, _arm64);
      expect(UpdateAsset.androidArmV7.name, _armV7);
      expect(UpdateAsset.androidUniversal.name, _universal);
    });

    test('an ABI without a split APK, or none told: the universal one alone', () {
      for (final abi in [Abi.androidX64, Abi.androidIA32, Abi.androidRiscv64, Abi.linuxX64, Abi.windowsX64, null]) {
        expect(androidUpdateAssets(abi), [UpdateAsset.androidUniversal], reason: '$abi');
      }
      expect(UpdateTarget.android.asset.name, _universal);
      expect(UpdateTarget.android.asset.abiSuffix, 9);
    });
  });

  group('version codes', () {
    test('the digits are the ones the build gives each APK', () {
      final gradle = File('android/app/build.gradle').readAsStringSync();
      expect(gradle, contains('"armeabi-v7a": ${UpdateAsset.androidArmV7.abiSuffix}'));
      expect(gradle, contains('"arm64-v8a": ${UpdateAsset.androidArm64.abiSuffix}'));
      expect(gradle, contains('ext.universalAbiCode = ${UpdateAsset.androidUniversal.abiSuffix}'));
      expect(gradle, contains('variant.versionCode * 10 + abiVersionCode'));
      expect(UpdateAsset.androidArm64.installedVersionCode(182), 1823);
      expect(UpdateAsset.androidArmV7.installedVersionCode(182), 1822);
      expect(UpdateAsset.androidUniversal.installedVersionCode(182), 1829);
      expect(UpdateAsset.windows.installedVersionCode(182), 182, reason: 'no digit where there is one build');
    });

    test('a newer release is an upgrade from any APK of an older one, the universal one too', () {
      const apks = [UpdateAsset.androidArmV7, UpdateAsset.androidArm64, UpdateAsset.androidUniversal];
      for (final installed in apks) {
        for (final offered in apks) {
          expect(
            offered.installedVersionCode(183),
            greaterThan(installed.installedVersionCode(182)),
            reason: '$installed of 182 to $offered of 183',
          );
        }
      }
    });

    test('within one release a split APK is below the universal one: never an update of it', () {
      final universal = UpdateAsset.androidUniversal.installedVersionCode(182);
      expect(UpdateAsset.androidArm64.installedVersionCode(182), lessThan(universal));
      expect(UpdateAsset.androidArmV7.installedVersionCode(182), lessThan(universal));
      // The native check (`UpdateInstaller.validateIdentity`) and Android refuse an APK that is not above the
      // installed one; the same file again is refused the same way.
      expect(universal, isNot(greaterThan(universal)));
    });
  });

  group('the download', () {
    test('arm64: the split APK, its bytes and its version code; the universal one is not fetched', () async {
      final result = await download(Abi.androidArm64);
      expect(adapter.fetched, ['github $_arm64']);
      expect(await File(result.path).readAsBytes(), _files[_arm64]);
      expect(result.versionCode, 1823);
      expect(result.version, '1.63.0');
    });

    test('32 bit ARM: its split APK', () async {
      final result = await download(Abi.androidArm);
      expect(adapter.fetched, ['github $_armV7']);
      expect(result.versionCode, 1822);
    });

    test('an ABI not known: the universal APK, as before', () async {
      final result = await download(null);
      expect(adapter.fetched, ['github $_universal']);
      expect(await File(result.path).readAsBytes(), _files[_universal]);
      expect(result.versionCode, 1829);
    });

    test('the release lacks the split APK: the universal one, with its own version code', () async {
      adapter.release.remove(_arm64);
      final result = await download(Abi.androidArm64);
      expect(adapter.fetched, ['github $_universal']);
      expect(result.versionCode, 1829);
    });

    test('the split APK still uploading counts as missing', () async {
      adapter.release[_arm64]!['state'] = 'starter';
      final result = await download(Abi.androidArm64);
      expect(adapter.fetched, ['github $_universal']);
      expect(result.versionCode, 1829);
    });

    test('a split APK that is there but wrong fails the update, it is not passed over', () async {
      adapter.release[_arm64]!['digest'] = 'sha256:nope';
      await expectLater(download(Abi.androidArm64), fails(UpdateDownloadFailure.invalidRelease));
      adapter.release[_arm64]!
        ..['digest'] = 'sha256:${_sha256(_files[_arm64]!)}'
        ..['browser_download_url'] = '$_githubUrl$_universal';
      await expectLater(download(Abi.androidArm64), fails(UpdateDownloadFailure.invalidRelease));
      expect(adapter.fetched, isEmpty, reason: 'nothing downloaded');
    });

    test('bytes that are not the split APK are refused (the universal file under its name)', () async {
      adapter.release[_arm64]!
        ..['size'] = _files[_universal]!.length
        ..['digest'] = 'sha256:${_sha256(_files[_armV7]!)}';
      await expectLater(download(Abi.androidArm64), fails(UpdateDownloadFailure.integrity));
    });

    test('neither the split nor the universal APK: no update file', () async {
      adapter.release
        ..remove(_arm64)
        ..remove(_universal);
      await expectLater(download(Abi.androidArm64), fails(UpdateDownloadFailure.releaseUnavailable));
    });
  });

  group('the mirror', () {
    test('the split APK comes from the mirror first, checked against GitHub', () async {
      final result = await download(Abi.androidArm64, mirror: true);
      expect(adapter.fetched, ['mirror v1.63.0/$_arm64']);
      expect(await File(result.path).readAsBytes(), _files[_arm64]);
      expect(result.versionCode, 1823);
    });

    test('a mirror without the split APK: the same APK from GitHub, not the universal one', () async {
      adapter.mirrorHas = {_universal};
      final result = await download(Abi.androidArm64, mirror: true);
      expect(adapter.fetched, ['mirror v1.63.0/$_arm64', 'github $_arm64']);
      expect(result.versionCode, 1823);
    });

    test('GitHub cannot be asked: the split APK the mirror lists', () async {
      adapter.githubDown = true;
      final result = await download(Abi.androidArm64, mirror: true);
      expect(adapter.fetched, ['mirror version.json', 'mirror v1.63.0/$_arm64']);
      expect(await File(result.path).readAsBytes(), _files[_arm64]);
      expect(result.versionCode, 1823);
    });

    test('GitHub cannot be asked and the mirror lists only the universal APK: that one', () async {
      adapter
        ..githubDown = true
        ..mirrored = {_universal};
      final result = await download(Abi.androidArm64, mirror: true);
      expect(adapter.fetched, ['mirror version.json', 'mirror v1.63.0/$_universal']);
      expect(result.versionCode, 1829);
    });
  });

  group('a download kept from before', () {
    Future<DownloadedUpdate?> restore(Abi? abi) =>
        repository(abi).restore(_info, cancelToken: CancelToken(), onVerifying: () {});

    test('is taken again with the version code of the APK it is', () async {
      final first = await download(Abi.androidArm64);
      adapter.fetched.clear();
      final again = await restore(Abi.androidArm64);
      expect(again!.path, first.path);
      expect(again.versionCode, 1823);
      expect(adapter.fetched, isEmpty, reason: 'checked against the release, not downloaded again');
    });

    test('the universal APK kept while the split one is wanted is not passed for it', () async {
      // Downloaded when the release had no split APK yet.
      adapter.release.remove(_arm64);
      final universal = await download(Abi.androidArm64);
      expect(universal.versionCode, 1829);
      adapter.release[_arm64] = {
        'name': _arm64,
        'state': 'uploaded',
        'size': _files[_arm64]!.length,
        'browser_download_url': '$_githubUrl$_arm64',
        'digest': 'sha256:${_sha256(_files[_arm64]!)}',
      };
      expect(await restore(Abi.androidArm64), isNull, reason: 'never handed to the installer as the split APK');
      expect(File(universal.path).existsSync(), isFalse, reason: 'dropped: the split APK is downloaded instead');
    });
  });
}
