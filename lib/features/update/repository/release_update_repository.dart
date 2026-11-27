import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:cryptography/dart.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/features/update/repository/cloudreve_mirror.dart';
import 'package:tsdm_client/features/update/repository/windows_update_installer.dart';
import 'package:tsdm_client/instance.dart';

/// Actionable failures, translated by the update page instead of exposing raw network errors.
enum UpdateDownloadFailure {
  /// The download service could not be reached.
  network,

  /// This version does not yet have a published APK.
  releaseUnavailable,

  /// Release metadata does not identify a supported official asset.
  invalidRelease,

  /// Downloaded bytes do not match the published size or digest.
  integrity,

  /// The private update cache could not be written.
  storage,

  /// Android could not open or validate the installer request.
  install,

  /// This platform or version cannot use in-app installation.
  unsupported,

  /// The folder of the running app cannot be written, e.g. it is under Program Files (Windows).
  installLocation,
}

/// A download that cannot safely be offered to the installer.
class UpdateDownloadException implements Exception {
  /// Constructor.
  const UpdateDownloadException(this.failure);

  /// User-facing error category.
  final UpdateDownloadFailure failure;
}

/// One file of an official release that a platform can install.
final class UpdateAsset {
  /// Constructor.
  const UpdateAsset(this.name, {this.abiSuffix});

  /// Android, 64 bit ARM only: a third of the universal APK.
  static const androidArm64 = UpdateAsset('tsdm_client-arm64_v8a.apk', abiSuffix: 3);

  /// Android, 32 bit ARM only.
  static const androidArmV7 = UpdateAsset('tsdm_client-armeabi_v7a.apk', abiSuffix: 2);

  /// Android, every ABI the app is built for: what any device can install.
  static const androidUniversal = UpdateAsset('tsdm_client-universal.apk', abiSuffix: 9);

  /// Windows: the portable zip, holding the `tsdm_client` folder.
  static const windows = UpdateAsset('tsdm_client-windows.zip');

  /// File name of the asset in the GitHub release (and on the mirror).
  final String name;

  /// Android: the digit the build appends to the version code of this APK (`android/app/build.gradle`: 2 for
  /// armeabi-v7a, 3 for arm64-v8a, 9 for the universal one); null where the version code is the release's.
  final int? abiSuffix;

  /// Version code of the installed build for the release [versionCode].
  ///
  /// The release's code times ten plus the digit: any APK of a newer release is above every APK of an older one, so
  /// a device on the universal APK (…9) takes the split one of the next release (…3 of a higher code). Within one
  /// release the split APKs are below the universal one: Android (and the native check before it) refuses to go
  /// from the universal APK to a split one of the same release, which is no update anyway.
  int installedVersionCode(int versionCode) => abiSuffix == null ? versionCode : versionCode * 10 + abiSuffix!;

  @override
  String toString() => 'UpdateAsset($name)';
}

/// The APKs an Android device running the app as [abi] takes, the best first: the one built for that ABI alone, then
/// the universal one (always last, so an update is never left without a file: an ABI the app has no split APK for,
/// an ABI not told, a release that lacks the split APK).
///
/// [abi] is the ABI of the running process (`Abi.current()`): what the installed APK runs as on this device, so the
/// split APK of the same ABI runs on it too.
List<UpdateAsset> androidUpdateAssets(Abi? abi) => [
  if (abi == Abi.androidArm64) UpdateAsset.androidArm64 else if (abi == Abi.androidArm) UpdateAsset.androidArmV7,
  UpdateAsset.androidUniversal,
];

/// The official release asset a platform installs.
enum UpdateTarget {
  /// Android: an APK, the one for the device's ABI or the universal one ([androidUpdateAssets]). [assetName] and
  /// [abiSuffix] are the universal APK's, the one always there.
  android(assetName: 'tsdm_client-universal.apk', extension: 'apk', abiSuffix: 9),

  /// Windows: the portable zip, holding the `tsdm_client` folder.
  windows(assetName: 'tsdm_client-windows.zip', extension: 'zip')
  ;

  const UpdateTarget({required this.assetName, required this.extension, this.abiSuffix});

  /// File name of the asset every device of the platform can install.
  final String assetName;

  /// Extension of a complete download in the update cache.
  final String extension;

  /// Android ABI digit appended to the version code of the installed package, of [assetName].
  final int? abiSuffix;

  /// The asset every device of the platform can install.
  UpdateAsset get asset => UpdateAsset(assetName, abiSuffix: abiSuffix);

  /// Version code of the installed build of [asset] for the release [versionCode].
  int installedVersionCode(int versionCode) => asset.installedVersionCode(versionCode);
}

/// An asset whose size and SHA-256 matched the exact published release asset.
class DownloadedUpdate {
  /// Constructor.
  const DownloadedUpdate({required this.path, required this.version, required this.versionCode});

  /// File in the application's private update cache.
  final String path;

  /// Expected APK version name.
  final String version;

  /// Expected version code of the installed build (Android: including the ABI digit of the APK downloaded).
  final int versionCode;
}

class _ReleaseAsset {
  const _ReleaseAsset({required this.asset, required this.sources, required this.size, required this.digest});

  /// Which file of the release it is.
  final UpdateAsset asset;

  /// Where the asset can be fetched, tried in order: each resolves to a URL only when its turn comes.
  final List<Future<Uri> Function()> sources;
  final int size;
  final String digest;
}

/// The platform side of an update: where downloads are kept and how a verified one is installed.
abstract interface class UpdateInstaller {
  /// The release asset this platform installs.
  UpdateTarget get target;

  /// The files of a release this device can install, the best first: the first one the release has is downloaded.
  /// The last is one every device of the platform installs.
  List<UpdateAsset> get assets;

  /// Directory holding downloads; only this app writes to it.
  Future<String> directory();

  /// Whether the app may request installation now.
  Future<bool> canInstall();

  /// Opens the settings that allow installation, false when the platform has none.
  Future<bool> openPermissionSettings();

  /// Why an update downloaded now could not be installed, null when nothing is known to stand in the way.
  ///
  /// Checked before downloading, so a run that can never install (e.g. not the portable Windows folder, or a folder
  /// that cannot be written) does not download the release first.
  Future<UpdateDownloadFailure?> preflight();

  /// Installs [update] after the user asked for it.
  Future<bool> install(DownloadedUpdate update);
}

/// Native operations are separate from downloading, allowing offline verification of both layers.
class AndroidUpdateInstaller implements UpdateInstaller {
  static const _channel = MethodChannel('kzs.th000.tsdm_client/updateChannel');

  @override
  UpdateTarget get target => UpdateTarget.android;

  /// The APK of the ABI the app runs as, then the universal one.
  @override
  List<UpdateAsset> get assets => androidUpdateAssets(Abi.current());

  /// Returns the private directory exposed only to the system installer.
  @override
  Future<String> directory() async {
    final path = await _channel.invokeMethod<String>('getUpdateDirectory');
    if (path == null || path.isEmpty) {
      throw const UpdateDownloadException(UpdateDownloadFailure.storage);
    }
    return path;
  }

  /// Whether the user has allowed this application to request installation.
  @override
  Future<bool> canInstall() async => await _channel.invokeMethod<bool>('canInstallPackages') ?? false;

  /// Opens Android's per-application installation permission settings.
  @override
  Future<bool> openPermissionSettings() async => await _channel.invokeMethod<bool>('openInstallPermission') ?? false;

  /// The system installer checks the package itself; the installation permission is asked for at Install.
  @override
  Future<UpdateDownloadFailure?> preflight() async => null;

  /// Native code rechecks the private path, package, version and signer before granting temporary read access.
  @override
  Future<bool> install(DownloadedUpdate update) async =>
      await _channel.invokeMethod<bool>('installUpdate', {
        'path': update.path,
        'version': update.version,
        'versionCode': update.versionCode,
      }) ??
      false;
}

/// Downloads only the platform's asset ([UpdateTarget]) of an exact official release.
///
/// The bytes come from the Cloudreve mirror first and from GitHub when the mirror fails; either way they must match
/// the length and SHA-256 GitHub's release metadata publishes. Only when that metadata cannot be had (anything but a
/// 404: no connection, rate limits, server errors) does Android take them from the mirror's `version.json`: the
/// native installer then still rejects any APK not signed with the official key or not of the expected version.
/// Windows has no such check, so it never installs on the mirror's word alone, and it also confirms with GitHub that
/// the tag's `version.json` names the version code it was offered (the offer may come from the mirror).
///
/// Uses an independent streaming Dio client: forum cookies and the native forum client's buffered GET transport
/// must never be used for update downloads. Network failures retain the external GitHub fallback in the UI.
class ReleaseUpdateRepository {
  /// Optional dependencies support offline release/download/installer tests.
  ///
  /// A test that hands in its own [dio] gets no mirror unless it passes one, so it never reaches the network.
  ReleaseUpdateRepository({Dio? dio, UpdateInstaller? installer, CloudreveMirror? mirror})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
            ),
          ),
      _mirror = mirror ?? (dio == null ? CloudreveMirror() : null),
      _ownsMirror = mirror == null && dio == null,
      installer = installer ?? (Platform.isWindows ? WindowsUpdateInstaller() : AndroidUpdateInstaller());

  final Dio _dio;
  final CloudreveMirror? _mirror;
  final bool _ownsMirror;

  /// Platform bridge for private cache access and explicit installation actions.
  final UpdateInstaller installer;

  UpdateTarget get _target => installer.target;

  static const _repository = 'Carinoasd/tsdm_client';
  static const int _maxSize = 512 * 1024 * 1024;

  Future<_ReleaseAsset> _resolve(LatestVersionInfo info, CancelToken cancelToken) async {
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(info.version) || info.versionCode <= 0) {
      throw const UpdateDownloadException(UpdateDownloadFailure.invalidRelease);
    }
    final mirror = _mirror;
    Future<Uri> Function() fromMirror(UpdateAsset asset) =>
        () => mirror!.urlOf(CloudreveMirror.assetPath(info.version, asset.name), cancelToken: cancelToken);
    final ({UpdateAsset asset, int size, String digest, Uri url}) github;
    try {
      github = await _resolveGithub(info, cancelToken);
    } on DioException catch (error) {
      // A release GitHub does not have (404) is not one to take from the mirror either.
      if (CancelToken.isCancel(error) ||
          error.response?.statusCode == 404 ||
          mirror == null ||
          _target != UpdateTarget.android) {
        rethrow;
      }
      final listed = await _resolveMirror(mirror, info, cancelToken);
      if (listed == null) rethrow;
      return _ReleaseAsset(
        asset: listed.asset,
        sources: [fromMirror(listed.asset)],
        size: listed.file.size,
        digest: listed.file.sha256,
      );
    }
    if (_target == UpdateTarget.windows) await _confirmVersionCode(info, cancelToken);
    return _ReleaseAsset(
      asset: github.asset,
      // The mirror may not have the file GitHub has (a release mirrored before the split APKs were): the transfer
      // fails there and goes on from GitHub.
      sources: [if (mirror != null) fromMirror(github.asset), () async => github.url],
      size: github.size,
      digest: github.digest,
    );
  }

  /// Rejects [info] unless the release tag's own `version.json` on GitHub names the same version and version code, so
  /// an older release cannot be offered as a newer one.
  Future<void> _confirmVersionCode(LatestVersionInfo info, CancelToken cancelToken) async {
    final response = await _dio.get<List<int>>(
      'https://api.github.com/repos/$_repository/contents/version.json',
      queryParameters: {'ref': 'v${info.version}'},
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Accept': 'application/vnd.github.raw+json', 'X-GitHub-Api-Version': '2022-11-28'},
      ),
      cancelToken: cancelToken,
    );
    final LatestVersionInfo tagged;
    try {
      tagged = parseLatestVersionInfo(response.data);
    } on FormatException {
      throw const UpdateDownloadException(UpdateDownloadFailure.invalidRelease);
    }
    if (tagged.version != info.version || tagged.versionCode != info.versionCode) {
      throw const UpdateDownloadException(UpdateDownloadFailure.invalidRelease);
    }
  }

  /// The mirror's listing of this exact release's asset (the first of the installer's the mirror lists), null when
  /// the mirror is unreachable, lists another release or none of them.
  Future<({UpdateAsset asset, MirroredAsset file})?> _resolveMirror(
    CloudreveMirror mirror,
    LatestVersionInfo info,
    CancelToken cancelToken,
  ) async {
    try {
      final listed = await mirror.versionInfo(cancelToken: cancelToken);
      if (listed['version'] != info.version || listed['versionCode'] != info.versionCode) return null;
      for (final asset in installer.assets) {
        final file = CloudreveMirror.assetOf(listed, asset.name);
        if (file != null) {
          return file.size > _maxSize ? null : (asset: asset, file: file);
        }
      }
      return null;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      return null;
    } on FormatException {
      return null;
    }
  }

  /// The release's file to download: the first of the installer's the release has uploaded. A file that is there
  /// but not as it must be (its link, size or digest) fails the update; it is not passed over for the next one.
  Future<({UpdateAsset asset, int size, String digest, Uri url})> _resolveGithub(
    LatestVersionInfo info,
    CancelToken cancelToken,
  ) async {
    final tag = 'v${info.version}';
    final response = await _dio.get<Object?>(
      'https://api.github.com/repos/$_repository/releases/tags/$tag',
      options: Options(headers: {'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2022-11-28'}),
      cancelToken: cancelToken,
    );
    final release = response.data;
    if (release is! Map<String, dynamic> ||
        release['tag_name'] != tag ||
        release['draft'] != false ||
        release['prerelease'] != false ||
        release['assets'] is! List<dynamic>) {
      throw const UpdateDownloadException(UpdateDownloadFailure.invalidRelease);
    }
    final uploaded = (release['assets'] as List<dynamic>)
        .whereType<Map<String, dynamic>>()
        .where((asset) => asset['state'] == 'uploaded')
        .toList();
    UpdateAsset? wanted;
    Map<String, dynamic>? asset;
    for (final candidate in installer.assets) {
      final named = uploaded.where((e) => e['name'] == candidate.name).toList();
      if (named.length > 1) {
        throw const UpdateDownloadException(UpdateDownloadFailure.releaseUnavailable);
      }
      if (named.length == 1) {
        wanted = candidate;
        asset = named.single;
        break;
      }
    }
    if (wanted == null || asset == null) {
      throw const UpdateDownloadException(UpdateDownloadFailure.releaseUnavailable);
    }
    final expectedUrl = 'https://github.com/$_repository/releases/download/$tag/${wanted.name}';
    final size = asset['size'];
    final digest = asset['digest'];
    if (asset['browser_download_url'] != expectedUrl ||
        size is! int ||
        size <= 0 ||
        size > _maxSize ||
        digest is! String ||
        !RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(digest)) {
      throw const UpdateDownloadException(UpdateDownloadFailure.invalidRelease);
    }
    return (asset: wanted, size: size, digest: digest.substring(7).toLowerCase(), url: Uri.parse(expectedUrl));
  }

  /// Streams one [source] into [partial] (replacing what an earlier source left) and verifies it against [asset].
  Future<void> _fetch(
    Future<Uri> Function() source,
    File partial,
    _ReleaseAsset asset,
    CancelToken cancelToken,
    void Function(int received, int total) onProgress,
    void Function() onVerifying,
  ) async {
    final size = asset.size;
    final url = await source();
    if (cancelToken.cancelError case final error?) throw error;
    final writer = await partial.open(mode: FileMode.writeOnly);
    try {
      final body = await _dio.getUri<ResponseBody>(
        url,
        options: Options(responseType: ResponseType.stream),
        cancelToken: cancelToken,
      );
      if (body.data == null) {
        throw const UpdateDownloadException(UpdateDownloadFailure.network);
      }
      var received = 0;
      onProgress(0, size);
      await for (final bytes in body.data!.stream) {
        if (cancelToken.cancelError case final error?) throw error;
        received += bytes.length;
        if (received > size) {
          throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
        }
        await writer.writeFrom(bytes);
        onProgress(received, size);
      }
      if (cancelToken.cancelError case final error?) throw error;
      if (received != size) {
        throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
      }
    } finally {
      await writer.close();
    }
    onVerifying();
    if (!await _matchesAsset(partial, asset, cancelToken)) {
      throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
    }
  }

  Future<bool> _matchesAsset(File file, _ReleaseAsset asset, CancelToken cancelToken) async {
    if (cancelToken.cancelError case final error?) throw error;
    if (FileSystemEntity.typeSync(file.path, followLinks: false) != FileSystemEntityType.file ||
        await file.length() != asset.size) {
      return false;
    }
    // Hashing tens of megabytes in pure Dart takes seconds: keep it off the UI isolate, restore() runs at startup.
    // A cancellation cannot stop the background hash, but its result is never used then.
    final path = file.path;
    final size = asset.size;
    final actual = await Isolate.run(() => hashFile(path, size));
    if (cancelToken.cancelError case final error?) throw error;
    return actual != null && actual == asset.digest;
  }

  /// Lowercase hex SHA-256 of the file at [path], null when it does not hold exactly [size] bytes.
  ///
  /// Runs in a background isolate; only the path and size are sent to it.
  static Future<String?> hashFile(String path, int size) async {
    final hash = const DartSha256().newHashSink();
    var received = 0;
    await for (final bytes in File(path).openRead()) {
      received += bytes.length;
      if (received > size) return null;
      hash.add(bytes);
    }
    hash.close();
    if (received != size) return null;
    return (await hash.hash()).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Recover a completed download after Android restarts the app when installation permission changes.
  ///
  /// Only matching regular APK files in the native private update directory are candidates. No cached receipt or
  /// manifest is trusted: the exact official release metadata is fetched again and every byte is rehashed against
  /// its current published length and SHA-256. APK download and installation never start here. Native package,
  /// version and signer checks still run when the reader explicitly presses Install.
  Future<DownloadedUpdate?> restore(
    LatestVersionInfo info, {
    required CancelToken cancelToken,
    required void Function() onVerifying,
  }) async {
    try {
      if (cancelToken.cancelError case final error?) throw error;
      if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(info.version) || info.versionCode <= 0) {
        throw const UpdateDownloadException(UpdateDownloadFailure.invalidRelease);
      }
      final directory = Directory(await installer.directory());
      if (!directory.existsSync()) return null;
      final name = RegExp('^update-${info.versionCode}-[0-9]+\\.${_target.extension}\$');
      final candidates = await directory
          .list(followLinks: false)
          .where((entry) => entry is File && name.hasMatch(p.basename(entry.path)))
          .cast<File>()
          .toList();
      if (cancelToken.cancelError case final error?) throw error;
      if (candidates.isEmpty) return null;
      final asset = await _resolve(info, cancelToken);
      onVerifying();
      // Try the most recent complete file first; an interrupted replacement may leave an older valid candidate.
      candidates.sort((a, b) => b.path.compareTo(a.path));
      for (final candidate in candidates) {
        if (cancelToken.cancelError case final error?) throw error;
        if (await _matchesAsset(candidate, asset, cancelToken)) {
          return DownloadedUpdate(
            path: candidate.path,
            version: info.version,
            versionCode: asset.asset.installedVersionCode(info.versionCode),
          );
        }
        await _delete(candidate);
      }
      return null;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw UpdateDownloadException(
        error.response?.statusCode == 404 ? UpdateDownloadFailure.releaseUnavailable : UpdateDownloadFailure.network,
      );
    } on FileSystemException {
      throw const UpdateDownloadException(UpdateDownloadFailure.storage);
    } on PlatformException {
      throw const UpdateDownloadException(UpdateDownloadFailure.storage);
    }
  }

  /// Resolve metadata, stream to a partial file, verify, then atomically make the APK available for installation.
  Future<DownloadedUpdate> download(
    LatestVersionInfo info, {
    required CancelToken cancelToken,
    required void Function(int received, int total) onProgress,
    required void Function() onVerifying,
  }) async {
    File? partial;
    File? complete;
    var success = false;
    try {
      final asset = await _resolve(info, cancelToken);
      if (cancelToken.cancelError case final error?) throw error;
      final directory = Directory(await installer.directory());
      await directory.create(recursive: true);
      final name = 'update-${info.versionCode}-${DateTime.now().microsecondsSinceEpoch}';
      partial = File('${directory.path}/$name.part');
      complete = File('${directory.path}/$name.${_target.extension}');
      // Each source in turn: a failed or corrupt transfer from the mirror falls back to GitHub.
      Exception? failure;
      for (final source in asset.sources) {
        try {
          await _fetch(source, partial, asset, cancelToken, onProgress, onVerifying);
          failure = null;
          break;
        } on DioException catch (error) {
          if (CancelToken.isCancel(error)) rethrow;
          failure = error;
        } on UpdateDownloadException catch (error) {
          if (error.failure != UpdateDownloadFailure.integrity && error.failure != UpdateDownloadFailure.network) {
            rethrow;
          }
          failure = error;
        }
      }
      if (failure != null) throw failure;
      if (cancelToken.cancelError case final error?) throw error;
      await partial.rename(complete.path);
      success = true;
      return DownloadedUpdate(
        path: complete.path,
        version: info.version,
        versionCode: asset.asset.installedVersionCode(info.versionCode),
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      throw UpdateDownloadException(
        error.response?.statusCode == 404 ? UpdateDownloadFailure.releaseUnavailable : UpdateDownloadFailure.network,
      );
    } on FileSystemException {
      throw const UpdateDownloadException(UpdateDownloadFailure.storage);
    } on PlatformException {
      throw const UpdateDownloadException(UpdateDownloadFailure.storage);
    } finally {
      if (!success) {
        await _delete(partial);
        await _delete(complete);
      }
    }
  }

  static final _artifact = RegExp(r'^update-([0-9]+)-[0-9]+\.(apk|zip|part)$');
  static final _windowsWorkDirectory = RegExp(r'^(staging-[0-9]+|backup-[0-9]+(-[0-9]+)?)$');

  /// A cancel marker of a Windows update attempt (see `WindowsUpdateInstaller.cancelledMarkerName`); kept for an
  /// hour, far longer than the script it is for could still be waiting.
  static final _windowsCancelMarker = RegExp(r'^apply-update\.started\.[0-9a-f]+\.cancelled$');

  /// Removes what no later step will use: unfinished downloads, and downloads of any version but [keepVersionCode]
  /// (an installed or replaced release). Windows also leaves the unpacked and backed up folders of an applied update;
  /// a backup marked by an incomplete rollback (`<backup>.incomplete` next to it) is kept with its marker.
  ///
  /// Only direct entries named by this repository are touched; the cache directory itself is kept. Call it only when
  /// no download is running.
  Future<void> cleanup({int? keepVersionCode}) async {
    try {
      final directory = Directory(await installer.directory());
      if (!directory.existsSync()) return;
      await for (final entry in directory.list(followLinks: false)) {
        final name = p.basename(entry.path);
        if (entry is File) {
          final match = _artifact.firstMatch(name);
          if (match != null && (match.group(2) == 'part' || int.parse(match.group(1)!) != keepVersionCode)) {
            await _delete(entry);
          } else if (_windowsCancelMarker.hasMatch(name) &&
              DateTime.now().difference(entry.statSync().modified) > const Duration(hours: 1)) {
            await _delete(entry);
          }
        } else if (entry is Directory &&
            _windowsWorkDirectory.hasMatch(name) &&
            !File('${entry.path}.incomplete').existsSync()) {
          try {
            await entry.delete(recursive: true);
          } on FileSystemException {
            // Held by another program (e.g. antivirus): retried next time, the other entries are still cleaned.
          }
        }
      }
    } on Exception catch (e, st) {
      // Leftovers are retried at the next check; they never block an update. Besides file system errors this also
      // covers a native side that has no update folder (UpdateDownloadException, MissingPluginException): the
      // result is awaited by nobody at startup, so nothing may escape from here.
      _logCleanupFailure(e, st);
    }
  }

  static void _logCleanupFailure(Exception error, StackTrace stackTrace) {
    try {
      talker.warning('update cache cleanup failed: $error', error, stackTrace);
      // Logging must not throw either, also where no logger was set up (tests, a check before initLogger).
      // ignore: avoid_catching_errors
    } on Error {
      // Nothing to log to.
    }
  }

  /// Removes only the receipt's file, never recursively removing the private directory.
  Future<void> discard(DownloadedUpdate? update) => _delete(update == null ? null : File(update.path));

  Future<void> _delete(File? file) async {
    try {
      if (file != null && file.existsSync()) await file.delete();
    } on FileSystemException {
      // A cache cleanup failure must not mask the original download failure.
    }
  }

  /// Closes the download-only client, without touching the forum session.
  void dispose() {
    _dio.close(force: true);
    if (_ownsMirror) _mirror?.dispose();
  }
}
