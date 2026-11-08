import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

/// The answer of a WebDAV server to [WebdavClient.check].
enum WebdavCheck {
  /// The url answered a `PROPFIND` (207 Multi-Status) with these credentials.
  ok,

  /// The server refused the credentials (401 / 403).
  unauthorized,

  /// Nothing at that url (404), or it is not a WebDAV collection (405 and other refusals of `PROPFIND`).
  notFound,

  /// No answer at all: wrong host, no network, TLS failure, timeout.
  unreachable,

  /// Any other status.
  failed,
}

/// A WebDAV request answered with an unexpected status, or not answered at all ([statusCode] null).
final class WebdavException implements Exception {
  /// Constructor.
  const WebdavException(this.method, this.statusCode, [this.reason]);

  /// Request method.
  final String method;

  /// Status of the answer, null when there was none.
  final int? statusCode;

  /// What went wrong, for the log.
  final String? reason;

  /// The server refused the credentials.
  bool get unauthorized => statusCode == 401 || statusCode == 403;

  @override
  String toString() => 'WebdavException($method, $statusCode${reason == null ? '' : ', $reason'})';
}

/// One member of a WebDAV collection, from a `PROPFIND` (`Depth: 1`) answer.
final class WebdavEntry {
  /// Constructor.
  const WebdavEntry({required this.name, required this.isCollection, this.size, this.lastModified});

  /// Decoded last path segment.
  final String name;

  /// Whether this is a collection (directory).
  final bool isCollection;

  /// `getcontentlength`, when given.
  final int? size;

  /// `getlastmodified`, when given and readable.
  final DateTime? lastModified;

  @override
  String toString() => 'WebdavEntry($name, collection=$isCollection, size=$size, lastModified=$lastModified)';
}

/// A minimal WebDAV client on dio: `PROPFIND`, `MKCOL`, `PUT`, `GET` and `DELETE` with HTTP basic authentication, all
/// a backup needs.
///
/// [baseUrl] is the WebDAV root the user entered (`https://dav.jianguoyun.com/dav/`,
/// `https://cloud.example/remote.php/dav/files/me/`); paths below it are given as segments and percent-encoded one by
/// one, so names with spaces, `#` or CJK characters stay names.
///
/// The dio instance is a bare one of its own, never the forum client: the forum cookies and interceptors must not
/// reach another host, and no log interceptor prints the `Authorization` header.
final class WebdavClient {
  /// Constructor. [dio] is replaced in tests.
  WebdavClient({required Uri baseUrl, required String username, required String password, Dio? dio})
    : baseUrl = _withTrailingSlash(baseUrl),
      _authorization = 'Basic ${base64Encode(utf8.encode('$username:$password'))}',
      _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              sendTimeout: const Duration(minutes: 5),
              receiveTimeout: const Duration(minutes: 5),
            ),
          );

  /// WebDAV root, always ending in `/`.
  final Uri baseUrl;

  final String _authorization;
  final Dio _dio;

  static const _propfindBody =
      '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>';

  static Uri _withTrailingSlash(Uri uri) => uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');

  /// Split a directory as the user typed it (`tsdm/backup`, `/tsdm/backup/`) into its segments.
  static List<String> splitPath(String path) =>
      path.split(RegExp(r'[/\\]')).map((s) => s.trim()).where((s) => s.isNotEmpty && s != '.' && s != '..').toList();

  /// The url of [segments] below [baseUrl]; a collection url ends in `/` when [collection].
  Uri resolve(List<String> segments, {bool collection = false}) {
    if (segments.isEmpty) {
      return baseUrl;
    }
    final encoded = segments.map(Uri.encodeComponent).join('/');
    return baseUrl.resolve('$encoded${collection ? '/' : ''}');
  }

  Future<Response<T>> _send<T>(
    String method,
    Uri url, {
    Object? data,
    Map<String, Object> headers = const {},
    ResponseType responseType = ResponseType.plain,
  }) async {
    try {
      return await _dio.requestUri<T>(
        url,
        data: data,
        options: Options(
          method: method,
          headers: {'Authorization': _authorization, ...headers},
          responseType: responseType,
          followRedirects: false,
          validateStatus: (_) => true,
        ),
      );
    } on DioException catch (e) {
      throw WebdavException(method, null, e.type.name);
    }
  }

  /// Whether the collection [segments] (the root when empty) answers a `PROPFIND` with these credentials.
  Future<WebdavCheck> check([List<String> segments = const []]) async {
    final Response<String> resp;
    try {
      resp = await _send<String>(
        'PROPFIND',
        resolve(segments, collection: true),
        data: _propfindBody,
        headers: {'Depth': '0', 'Content-Type': 'application/xml; charset=utf-8'},
      );
    } on WebdavException {
      return WebdavCheck.unreachable;
    }
    return switch (resp.statusCode) {
      207 => WebdavCheck.ok,
      401 || 403 => WebdavCheck.unauthorized,
      404 || 405 || 501 => WebdavCheck.notFound,
      _ => WebdavCheck.failed,
    };
  }

  /// Make sure the collection [segments] exists, creating every missing level (`MKCOL` refuses a missing parent).
  Future<void> ensureCollection(List<String> segments) async {
    for (var i = 1; i <= segments.length; i++) {
      final level = segments.sublist(0, i);
      final state = await check(level);
      if (state == WebdavCheck.ok) {
        continue;
      }
      if (state == WebdavCheck.unauthorized) {
        throw const WebdavException('PROPFIND', 401);
      }
      final resp = await _send<String>('MKCOL', resolve(level, collection: true));
      // 405: it exists already (made meanwhile, or the server does not answer PROPFIND on it).
      if (resp.statusCode != 201 && resp.statusCode != 405) {
        throw WebdavException('MKCOL', resp.statusCode);
      }
    }
  }

  /// Members of the collection [segments], without the collection itself.
  Future<List<WebdavEntry>> list(List<String> segments) async {
    final url = resolve(segments, collection: true);
    final resp = await _send<String>(
      'PROPFIND',
      url,
      data: _propfindBody,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
    );
    if (resp.statusCode != 207) {
      throw WebdavException('PROPFIND', resp.statusCode);
    }
    return parseMultistatus(resp.data ?? '', url);
  }

  /// Upload [bytes] as [segments].
  Future<void> put(List<String> segments, Uint8List bytes) async {
    final resp = await _send<String>(
      'PUT',
      resolve(segments),
      data: Stream.value(bytes),
      headers: {Headers.contentLengthHeader: bytes.length, Headers.contentTypeHeader: 'application/octet-stream'},
    );
    if (resp.statusCode != 200 && resp.statusCode != 201 && resp.statusCode != 204) {
      throw WebdavException('PUT', resp.statusCode);
    }
  }

  /// Download [segments] into [target].
  Future<void> download(List<String> segments, File target) async {
    final resp = await _send<List<int>>('GET', resolve(segments), responseType: ResponseType.bytes);
    if (resp.statusCode != 200) {
      throw WebdavException('GET', resp.statusCode);
    }
    await target.writeAsBytes(resp.data ?? const [], flush: true);
  }

  /// Delete [segments]; already gone counts as deleted.
  Future<void> delete(List<String> segments) async {
    final resp = await _send<String>('DELETE', resolve(segments));
    if (resp.statusCode != 200 && resp.statusCode != 204 && resp.statusCode != 404) {
      throw WebdavException('DELETE', resp.statusCode);
    }
  }

  /// Read the members of the collection at [collection] from a `PROPFIND` multistatus answer [body].
  ///
  /// Namespace prefixes differ between servers (`d:`, `D:`, `ns0:`, none), so elements are matched by local name in
  /// the `DAV:` namespace. An `href` is a path (`/dav/%E5%A4%87%E4%BB%BD/a.db`) or a full url; the entry whose path is
  /// the collection itself is left out, and names are the decoded last segment.
  static List<WebdavEntry> parseMultistatus(String body, Uri collection) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(body);
    } on XmlException catch (e) {
      throw WebdavException('PROPFIND', 207, 'bad multistatus: ${e.message}');
    }
    const dav = 'DAV:';
    String normalize(String path) {
      var p = path;
      try {
        p = Uri.decodeFull(p);
      } on Object {
        // A bad percent escape: keep it as it is.
      }
      return p.endsWith('/') ? p.substring(0, p.length - 1) : p;
    }

    final self = normalize(collection.path);
    final entries = <WebdavEntry>[];
    for (final response in doc.findAllElements('response', namespace: dav)) {
      final href = response.findElements('href', namespace: dav).firstOrNull?.innerText.trim();
      if (href == null || href.isEmpty) {
        continue;
      }
      final path = normalize(Uri.tryParse(href)?.path ?? href);
      if (path == self || path.isEmpty) {
        continue;
      }
      XmlElement? okProp;
      for (final propstat in response.findElements('propstat', namespace: dav)) {
        final status = propstat.findElements('status', namespace: dav).firstOrNull?.innerText ?? '';
        if (status.isEmpty || status.contains(' 200')) {
          okProp = propstat.findElements('prop', namespace: dav).firstOrNull;
          break;
        }
      }
      final isCollection =
          okProp
              ?.findElements('resourcetype', namespace: dav)
              .firstOrNull
              ?.findElements('collection', namespace: dav)
              .isNotEmpty ??
          false;
      final size = int.tryParse(
        okProp?.findElements('getcontentlength', namespace: dav).firstOrNull?.innerText.trim() ?? '',
      );
      final modifiedText = okProp?.findElements('getlastmodified', namespace: dav).firstOrNull?.innerText.trim();
      DateTime? modified;
      if (modifiedText != null && modifiedText.isNotEmpty) {
        try {
          modified = HttpDate.parse(modifiedText);
        } on HttpException {
          modified = DateTime.tryParse(modifiedText);
        } on FormatException {
          modified = DateTime.tryParse(modifiedText);
        }
      }
      entries.add(
        WebdavEntry(
          name: path.substring(path.lastIndexOf('/') + 1),
          isCollection: isCollection,
          size: size,
          lastModified: modified,
        ),
      );
    }
    return entries;
  }
}
