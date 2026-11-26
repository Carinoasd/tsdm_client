import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Size and SHA-256 of a release asset as the mirror's `version.json` lists it.
class MirroredAsset {
  /// Constructor.
  const MirroredAsset({required this.size, required this.sha256});

  /// Length in bytes.
  final int size;

  /// Lowercase hex SHA-256.
  final String sha256;
}

/// Releases mirrored by the Release build to a public Cloudreve share, which is reachable where GitHub is not.
///
/// The share holds `version.json` (the repository's file plus `assets`: name → size and SHA-256) and one folder per
/// release tag with the release's assets. Files are fetched through short-lived signed URLs the share hands out to
/// anyone; nothing of the reader (cookies, forum session) is ever sent.
class CloudreveMirror {
  /// [dio] must be a client of its own, not the forum client.
  CloudreveMirror({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 60),
            ),
          );

  final Dio _dio;

  /// Site of the share.
  static const origin = 'https://drive.noire.cc';

  /// Id of the public share of the release folder.
  static const share = 'x7L2S3';

  static const int _maxVersionInfoSize = 1024 * 1024;

  static final _assetName = RegExp(r'^[A-Za-z0-9_.-]+$');
  static final _sha256 = RegExp(r'^[0-9a-f]{64}$');

  /// A signed download URL of [path] (relative to the shared folder), valid for a while.
  Future<Uri> urlOf(String path, {CancelToken? cancelToken}) async {
    final response = await _dio.post<Object?>(
      '$origin/api/v4/file/url',
      data: {
        'uris': ['cloudreve://$share@share/$path'],
        'download': true,
      },
      options: Options(contentType: Headers.jsonContentType, responseType: ResponseType.json),
      cancelToken: cancelToken,
    );
    final body = response.data;
    if (body case {'code': 0, 'data': {'urls': [{'url': final String url}, ...]}}) {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.scheme == 'https' && uri.host.isNotEmpty) return uri;
    }
    throw DioException(requestOptions: response.requestOptions, response: response, message: 'no mirror url');
  }

  /// The mirror's `version.json`, decoded.
  Future<Map<String, dynamic>> versionInfo({CancelToken? cancelToken}) async {
    final url = await urlOf('version.json', cancelToken: cancelToken);
    final response = await _dio.getUri<ResponseBody>(
      url,
      options: Options(responseType: ResponseType.stream),
      cancelToken: cancelToken,
    );
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.data?.stream ?? const Stream<Uint8List>.empty()) {
      bytes.add(chunk);
      if (bytes.length > _maxVersionInfoSize) throw const FormatException('mirror version info too large');
    }
    final decoded = jsonDecode(utf8.decode(bytes.takeBytes()));
    if (decoded is! Map<String, dynamic>) throw const FormatException('mirror version info is not a JSON object');
    return decoded;
  }

  /// The listed size and SHA-256 of [name] in [info] (a mirror `version.json`), null when missing or malformed.
  static MirroredAsset? assetOf(Map<dynamic, dynamic> info, String name) {
    if (!_assetName.hasMatch(name)) return null;
    final assets = info['assets'];
    if (assets is! Map<dynamic, dynamic>) return null;
    final asset = assets[name];
    if (asset is! Map<dynamic, dynamic>) return null;
    final size = asset['size'];
    final sha256 = asset['sha256'];
    if (size is! int || size <= 0 || sha256 is! String || !_sha256.hasMatch(sha256)) return null;
    return MirroredAsset(size: size, sha256: sha256);
  }

  /// Path of [name] of release [version] inside the share.
  static String assetPath(String version, String name) => 'v$version/$name';

  /// Closes the client.
  void dispose() => _dio.close(force: true);
}
