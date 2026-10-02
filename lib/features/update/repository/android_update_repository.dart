import 'dart:io';

import 'package:cryptography/dart.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:tsdm_client/features/update/models/latest_version_info.dart';

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

  /// This platform or version cannot use APK installation.
  unsupported,
}

/// A download that cannot safely be offered to the installer.
class UpdateDownloadException implements Exception {
  /// Constructor.
  const UpdateDownloadException(this.failure);

  /// User-facing error category.
  final UpdateDownloadFailure failure;
}

/// An APK whose size and SHA-256 matched the exact published release asset.
class DownloadedUpdate {
  /// Constructor.
  const DownloadedUpdate({required this.path, required this.version, required this.versionCode});

  /// File in the application's private update cache.
  final String path;

  /// Expected APK version name.
  final String version;

  /// Expected Android version code, including the universal ABI suffix.
  final int versionCode;
}

class _ReleaseAsset {
  const _ReleaseAsset({required this.url, required this.size, required this.digest});

  final String url;
  final int size;
  final String digest;
}

/// Native operations are separate from downloading, allowing offline verification of both layers.
class AndroidUpdateInstaller {
  static const _channel = MethodChannel('kzs.th000.tsdm_client/updateChannel');

  /// Returns the private directory exposed only to the system installer.
  Future<String> directory() async {
    final path = await _channel.invokeMethod<String>('getUpdateDirectory');
    if (path == null || path.isEmpty) {
      throw const UpdateDownloadException(UpdateDownloadFailure.storage);
    }
    return path;
  }

  /// Whether the user has allowed this application to request installation.
  Future<bool> canInstall() async => await _channel.invokeMethod<bool>('canInstallPackages') ?? false;

  /// Opens Android's per-application installation permission settings.
  Future<bool> openPermissionSettings() async => await _channel.invokeMethod<bool>('openInstallPermission') ?? false;

  /// Native code rechecks the private path, package, version and signer before granting temporary read access.
  Future<bool> install(DownloadedUpdate update) async =>
      await _channel.invokeMethod<bool>('installUpdate', {
        'path': update.path,
        'version': update.version,
        'versionCode': update.versionCode,
      }) ??
      false;
}

/// Downloads only the universal APK from an exact official GitHub release.
///
/// Uses an independent streaming Dio client: forum cookies and the native forum client's buffered GET transport
/// must never be used for update downloads. Network failures retain the external GitHub fallback in the UI.
class AndroidUpdateRepository {
  /// Optional dependencies support offline release/download/installer tests.
  AndroidUpdateRepository({Dio? dio, AndroidUpdateInstaller? installer})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
            ),
          ),
      installer = installer ?? AndroidUpdateInstaller();

  final Dio _dio;

  /// Platform bridge for private cache access and explicit installation actions.
  final AndroidUpdateInstaller installer;

  static const _repository = 'Carinoasd/tsdm_client';
  static const _assetName = 'tsdm_client-universal.apk';
  static const int _maxSize = 512 * 1024 * 1024;

  Future<_ReleaseAsset> _resolve(LatestVersionInfo info, CancelToken cancelToken) async {
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(info.version) || info.versionCode <= 0) {
      throw const UpdateDownloadException(UpdateDownloadFailure.invalidRelease);
    }
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
    final assets = (release['assets'] as List<dynamic>).whereType<Map<String, dynamic>>().where(
      (asset) => asset['name'] == _assetName && asset['state'] == 'uploaded',
    );
    if (assets.length != 1) {
      throw const UpdateDownloadException(UpdateDownloadFailure.releaseUnavailable);
    }
    final asset = assets.single;
    final expectedUrl = 'https://github.com/$_repository/releases/download/$tag/$_assetName';
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
    return _ReleaseAsset(url: expectedUrl, size: size, digest: digest.substring(7).toLowerCase());
  }

  Future<bool> _matchesAsset(File file, _ReleaseAsset asset, CancelToken cancelToken) async {
    if (cancelToken.cancelError case final error?) throw error;
    if (FileSystemEntity.typeSync(file.path, followLinks: false) != FileSystemEntityType.file ||
        await file.length() != asset.size) {
      return false;
    }
    final hash = const DartSha256().newHashSink();
    var received = 0;
    await for (final bytes in file.openRead()) {
      if (cancelToken.cancelError case final error?) throw error;
      received += bytes.length;
      if (received > asset.size) return false;
      hash.add(bytes);
    }
    hash.close();
    final actual = (await hash.hash()).bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    if (cancelToken.cancelError case final error?) throw error;
    return received == asset.size && actual == asset.digest;
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
      final name = RegExp('^update-${info.versionCode}-[0-9]+\\.apk\$');
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
            versionCode: info.versionCode * 10 + 9,
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
    RandomAccessFile? writer;
    var success = false;
    try {
      final asset = await _resolve(info, cancelToken);
      final size = asset.size;
      if (cancelToken.cancelError case final error?) throw error;
      final directory = Directory(await installer.directory());
      await directory.create(recursive: true);
      final name = 'update-${info.versionCode}-${DateTime.now().microsecondsSinceEpoch}';
      partial = File('${directory.path}/$name.part');
      complete = File('${directory.path}/$name.apk');
      writer = await partial.open(mode: FileMode.writeOnly);
      final body = await _dio.get<ResponseBody>(
        asset.url,
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
      await writer.close();
      writer = null;
      if (cancelToken.cancelError case final error?) throw error;
      if (received != size) {
        throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
      }
      onVerifying();
      if (!await _matchesAsset(partial, asset, cancelToken)) {
        throw const UpdateDownloadException(UpdateDownloadFailure.integrity);
      }
      if (cancelToken.cancelError case final error?) throw error;
      await partial.rename(complete.path);
      success = true;
      return DownloadedUpdate(path: complete.path, version: info.version, versionCode: info.versionCode * 10 + 9);
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
      if (writer != null) await writer.close();
      if (!success) {
        await _delete(partial);
        await _delete(complete);
      }
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
  void dispose() => _dio.close(force: true);
}
