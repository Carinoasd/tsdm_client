import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:tsdm_client/features/video_player/models/post_video.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Why a video attachment could not be fetched.
enum VideoFetchFailure {
  /// The request failed.
  network,

  /// The forum answered with a page, not the file: no permission, credits asked for, the file gone.
  notVideo,
}

/// A video attachment could not be fetched ([failure]).
final class VideoFetchException implements Exception {
  /// Constructor.
  const VideoFetchException(this.failure);

  /// Why.
  final VideoFetchFailure failure;

  @override
  String toString() => 'VideoFetchException(${failure.name})';
}

/// Fetches the file of a video attachment to play. Tests give a fake one.
// ignore: one_member_abstracts
abstract interface class VideoFetcher {
  /// The local file of the attachment [video], fetched when not kept yet, telling [onProgress] the part fetched (null
  /// when the size is unknown). Throws [VideoFetchException]; a cancel through [cancelToken] throws a cancelled
  /// [DioException].
  Future<String> fetch(
    PostVideo video, {
    required CancelToken cancelToken,
    void Function(double? progress)? onProgress,
  });
}

/// Whether the first bytes [head] of a file are those of a video file: MP4 and QuickTime (`ftyp`, also a `moov`, `mdat`,
/// `wide` or `free` box first), WebM and Matroska (EBML). A page of the forum (an error, the confirmation that credits
/// are taken) is none of them.
bool looksLikeVideo(Uint8List head) {
  bool at(int offset, List<int> magic) {
    if (head.length < offset + magic.length) {
      return false;
    }
    for (var i = 0; i < magic.length; i++) {
      if (head[offset + i] != magic[i]) {
        return false;
      }
    }
    return true;
  }

  return const ['ftyp', 'moov', 'mdat', 'wide', 'free'].any((box) => at(4, box.codeUnits)) ||
      at(0, const [0x1A, 0x45, 0xDF, 0xA3]);
}

/// [VideoFetcher] through the app's net client, with the account's cookie, as a download of the attachment is (see
/// [PostVideo] for why it is not streamed). The files are kept in the temporary directory (the last [maxCacheBytes])
/// and played from there.
final class NetVideoFetcher with LoggerMixin implements VideoFetcher {
  /// Constructor.
  NetVideoFetcher({this.maxCacheBytes = 1024 * 1024 * 1024});

  /// The most kept, in bytes.
  final int maxCacheBytes;

  Future<Directory> _dir() async {
    final dir = Directory(path.join((await getTemporaryDirectory()).path, 'video_cache'));
    await dir.create(recursive: true);
    return dir;
  }

  /// Kept for each account: what one may fetch, another may not.
  String _fileName(PostVideo video) {
    final uid = getIt.get<CookieProvider>().userLoginInfo.uid ?? 0;
    final ext = path.extension(video.title ?? '').toLowerCase();
    final known = playableVideoExtensions.contains(ext.isEmpty ? '' : ext.substring(1));
    // libmpv goes by the content, the extension only helps.
    return '${video.aid}_$uid${known ? ext : '.mp4'}';
  }

  @override
  Future<String> fetch(
    PostVideo video, {
    required CancelToken cancelToken,
    void Function(double? progress)? onProgress,
  }) async {
    final file = File(path.join((await _dir()).path, _fileName(video)));
    if (file.existsSync() && file.lengthSync() > 0) {
      // Kept the longest when played last.
      await file.setLastModified(DateTime.now());
      return file.path;
    }
    // One part file per request: a cancelled one still finishing does not write into the next.
    final part = File('${file.path}.${cancelToken.hashCode}.part');
    final url = video.url.toString();
    final result = await getIt
        .get<NetClientProvider>()
        .download(
          url,
          part.path,
          cancelToken: cancelToken,
          onReceiveProgress: (received, total) => onProgress?.call(total > 0 ? received / total : null),
        )
        .run();
    if (result.isLeft()) {
      if (part.existsSync()) {
        await part.delete();
      }
      if (cancelToken.isCancelled) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: url),
          reason: 'cancelled',
        );
      }
      result.mapLeft((e) => error('failed to fetch video ${video.aid}: $e'));
      throw const VideoFetchException(VideoFetchFailure.network);
    }
    final head = await _head(part);
    if (!looksLikeVideo(head)) {
      warning('fetched video ${video.aid} is not a video');
      await part.delete();
      throw const VideoFetchException(VideoFetchFailure.notVideo);
    }
    await part.rename(file.path);
    unawaited(_trim(file.parent, keep: file.path));
    return file.path;
  }

  static Future<Uint8List> _head(File file) async {
    final raf = await file.open();
    try {
      return await raf.read(16);
    } finally {
      await raf.close();
    }
  }

  /// Delete the files played the longest ago until the rest fit in [maxCacheBytes].
  Future<void> _trim(Directory dir, {required String keep}) async {
    try {
      final files = <(File, FileStat)>[];
      // A part file left by a request the app did not live to finish is deleted.
      final stale = DateTime.now().subtract(const Duration(hours: 1));
      await for (final e in dir.list()) {
        if (e is! File) {
          continue;
        }
        final stat = e.statSync();
        if (!e.path.endsWith('.part')) {
          files.add((e, stat));
        } else if (stat.modified.isBefore(stale)) {
          await e.delete();
        }
      }
      files.sort((a, b) => b.$2.modified.compareTo(a.$2.modified));
      var total = 0;
      for (final (f, stat) in files) {
        total += stat.size;
        if (total > maxCacheBytes && f.path != keep) {
          await f.delete();
        }
      }
    } on FileSystemException catch (e) {
      warning('failed to trim the video cache: $e');
    }
  }
}
