import 'dart:io';

import 'package:dio/dio.dart';
import 'package:tsdm_client/features/attachment_download/utils/attachment_protocol.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// What one request of a download address answered: its `status`, the redirect `location`, the
/// `Content-Disposition` (`disposition`) and the size (`length`) it told. The body is in the file asked for.
typedef AttachmentFetchAnswer = ({int status, String? location, String? disposition, int? length});

/// A request of an attachment failed: the network, the account changed meanwhile ([message] the error).
final class AttachmentFetchException implements Exception {
  /// Constructor.
  const AttachmentFetchException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'AttachmentFetchException($message)';
}

/// The requests of a download. Tests give a fake one.
abstract interface class AttachmentFetcher {
  /// GET [url] for account [uid] into the file [savePath], without following a redirect (a download costing credits
  /// redirects to the page taking them), telling [onProgress] the bytes received and the size (null when unknown).
  ///
  /// Throws [AttachmentFetchException]; a cancel through [cancelToken] throws a cancelled [DioException].
  Future<AttachmentFetchAnswer> fetch(
    String url,
    String savePath, {
    required int uid,
    required CancelToken cancelToken,
    void Function(int received, int? total)? onProgress,
  });

  /// GET the page [url] for account [uid] once (no retry, no redirect: it takes the credits of a download), its body.
  ///
  /// Throws [AttachmentFetchException].
  Future<String> fetchPage(String url, {required int uid});
}

/// [AttachmentFetcher] through a client of the account in use with the `dart:io` adapter on every platform: the body
/// streams into the file as it comes (the Kotlin client of Android holds a whole answer in memory and can not be
/// cancelled), as the background service does.
final class NetAttachmentFetcher implements AttachmentFetcher {
  /// Constructor.
  const NetAttachmentFetcher();

  /// The client for [url]: with the session of account [uid] on the canonical forum host only
  /// ([isCanonicalForumUrl]), without any cookie anywhere else (a storage host the forum redirected to).
  NetClientProvider _client(int uid, String url) {
    final account = getIt.get<CookieProvider>().userLoginInfo;
    if ((account.uid ?? 0) != uid) {
      throw const AttachmentFetchException('account changed');
    }
    final dio = getIt.get<SettingsRepository>().buildDefaultDio(nativeHttp: false);
    if (!isCanonicalForumUrl(url)) {
      return NetClientProvider.buildNoCookie(dio: dio);
    }
    return NetClientProvider.build(dio: dio, userLoginInfo: account);
  }

  static bool _accepted(int? status) => status != null && status < HttpStatus.badRequest;

  @override
  Future<AttachmentFetchAnswer> fetch(
    String url,
    String savePath, {
    required int uid,
    required CancelToken cancelToken,
    void Function(int received, int? total)? onProgress,
  }) async {
    final result = await _client(uid, url)
        .download(
          url,
          savePath,
          cancelToken: cancelToken,
          onReceiveProgress: (received, total) => onProgress?.call(received, total > 0 ? total : null),
          options: Options(followRedirects: false, validateStatus: _accepted),
        )
        .run();
    return result.match(
      (e) {
        if (cancelToken.isCancelled) {
          throw DioException.requestCancelled(
            requestOptions: RequestOptions(path: url),
            reason: 'cancelled',
          );
        }
        throw AttachmentFetchException('$e');
      },
      (resp) => (
        status: resp.statusCode ?? 0,
        location: resp.headers.value(HttpHeaders.locationHeader),
        disposition: resp.headers.value('content-disposition'),
        length: int.tryParse(resp.headers.value(HttpHeaders.contentLengthHeader) ?? ''),
      ),
    );
  }

  @override
  Future<String> fetchPage(String url, {required int uid}) async {
    final result = await _client(uid, url)
        .get(
          url,
          singleAttempt: true,
          options: Options(responseType: ResponseType.plain, validateStatus: _accepted),
        )
        .run();
    return result.match((e) => throw AttachmentFetchException('$e'), (resp) => '${resp.data ?? ''}');
  }
}
