import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fpdart/fpdart.dart' show Either;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/attachment_download/utils/attachment_protocol.dart';
import 'package:tsdm_client/features/audio_player/models/audio_track.dart';
import 'package:tsdm_client/features/audio_player/utils/audio_attachment.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Why a track could not be fetched.
enum AudioFetchFailure {
  /// The request failed.
  network,

  /// The forum answered with a page, not the file: no permission, credits asked for, the file gone; NetEase Cloud
  /// Music's page for a song it does not let everyone play.
  notAudio,
}

/// A track could not be fetched ([failure]).
final class AudioFetchException implements Exception {
  /// Constructor.
  const AudioFetchException(this.failure);

  /// Why.
  final AudioFetchFailure failure;

  @override
  String toString() => 'AudioFetchException(${failure.name})';
}

/// Fetches the file of a track to play. Tests give a fake one.
// ignore: one_member_abstracts
abstract interface class AudioFetcher {
  /// The local file of [track], fetched when not kept yet, telling [onProgress] the part fetched (null when the size
  /// is unknown). Throws [AudioFetchException]; a cancel through [cancelToken] throws a cancelled [DioException].
  Future<String> fetch(
    AudioTrack track, {
    required CancelToken cancelToken,
    void Function(double? progress)? onProgress,
  });
}

/// Whether the first bytes [head] of a file are those of a sound file: MP3 (an ID3 tag or a frame), AAC (ADTS), FLAC,
/// Ogg, WAV, MP4 (`ftyp`). A page of the forum (an error, the confirmation that credits are taken) is none of them.
bool looksLikeAudio(Uint8List head) {
  bool at(int offset, String magic) {
    if (head.length < offset + magic.length) {
      return false;
    }
    for (var i = 0; i < magic.length; i++) {
      if (head[offset + i] != magic.codeUnitAt(i)) {
        return false;
      }
    }
    return true;
  }

  if (at(0, 'ID3') || at(0, 'fLaC') || at(0, 'OggS') || (at(0, 'RIFF') && at(8, 'WAVE')) || at(4, 'ftyp')) {
    return true;
  }
  // An MPEG audio frame or an ADTS header: 11 bits of sync.
  return head.length >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0;
}

/// The most redirects of an audio attachment followed.
const maxAudioAttachmentHops = 5;

/// Where a request of an audio attachment to [url] answered with [status] and [location] goes next: the redirect
/// target on the canonical forum host when it is the forum's ([canonicalAttachmentUrl]), as named otherwise; null when
/// the answer is no redirect.
@visibleForTesting
String? nextAudioAttachmentHop(String url, int status, String? location) {
  if (status < 300 || status >= 400 || location == null || location.isEmpty) {
    return null;
  }
  return canonicalAttachmentUrl('${Uri.parse(url).resolve(location)}');
}

/// [AudioFetcher] through the app's net client: the attachments with the account's cookie, as a download is (the
/// forum takes the credits and counts the download of an attachment for each request, and does not serve a range of
/// one: streaming would ask again at each seek), the songs of NetEase Cloud Music without a cookie. The files are kept
/// in the temporary directory (the last [maxCacheBytes]) and played from there.
final class NetAudioFetcher with LoggerMixin implements AudioFetcher {
  /// Constructor.
  NetAudioFetcher({this.maxCacheBytes = 300 * 1024 * 1024});

  /// The most kept, in bytes.
  final int maxCacheBytes;

  /// Fetches of the same track at once share one request, until it is cancelled.
  final _running = <String, (CancelToken, Future<String>)>{};

  Future<Directory> _dir() async {
    final dir = Directory(path.join((await getTemporaryDirectory()).path, 'audio_cache'));
    await dir.create(recursive: true);
    return dir;
  }

  String _fileName(AudioTrack track) {
    final uid = track.source == AudioTrackSource.attachment ? getIt.get<CookieProvider>().userLoginInfo.uid ?? 0 : 0;
    final key = '${track.id}_$uid'.replaceAll(RegExp('[^A-Za-z0-9_]'), '_');
    // The players of Apple go by the extension; a song of NetEase Cloud Music is named by its title, not a file.
    final ext = path.extension(track.title).toLowerCase();
    final known =
        track.source == AudioTrackSource.attachment &&
        playableAudioExtensions().contains(ext.substring(ext.isEmpty ? 0 : 1));
    return '$key${known ? ext : '.mp3'}';
  }

  @override
  Future<String> fetch(
    AudioTrack track, {
    required CancelToken cancelToken,
    void Function(double? progress)? onProgress,
  }) async {
    final file = File(path.join((await _dir()).path, _fileName(track)));
    if (file.existsSync() && file.lengthSync() > 0) {
      // Kept the longest when played last.
      await file.setLastModified(DateTime.now());
      return file.path;
    }
    if (_running[file.path] case (final token, final running) when !token.isCancelled) {
      return running;
    }
    late final Future<String> running;
    running = _download(track, file, cancelToken, onProgress).whenComplete(() {
      if (identical(_running[file.path]?.$2, running)) {
        _running.remove(file.path);
      }
    });
    _running[file.path] = (cancelToken, running);
    return running;
  }

  Future<String> _download(
    AudioTrack track,
    File file,
    CancelToken cancelToken,
    void Function(double? progress)? onProgress,
  ) async {
    // One part file per request: a cancelled one still finishing does not write into the next.
    final part = File('${file.path}.${cancelToken.hashCode}.part');
    // An attachment goes with the account's session to the canonical https host only ([canonicalAttachmentUrl]): a
    // track kept in the queue by an earlier version may name `http` or the host without www. Its redirects are
    // followed here, one by one ([nextAudioAttachmentHop]): a hop anywhere else goes without the session.
    final attachment = track.source == AudioTrackSource.attachment;
    var url = attachment ? canonicalAttachmentUrl(track.url) : track.url;
    void progress(int received, int total) => onProgress?.call(total > 0 ? received / total : null);
    late Either<AppException, Response<dynamic>> result;
    for (var hop = 0; hop < maxAudioAttachmentHops; hop++) {
      final client = attachment && isCanonicalForumUrl(url)
          ? getIt.get<NetClientProvider>()
          : getIt.get<NetClientProvider>(instanceName: ServiceKeys.noCookie);
      result = await client
          .download(
            url,
            part.path,
            cancelToken: cancelToken,
            onReceiveProgress: progress,
            options: attachment
                ? Options(followRedirects: false, validateStatus: (s) => s != null && s < HttpStatus.badRequest)
                : null,
          )
          .run();
      final resp = result.toNullable();
      final next = resp == null || !attachment
          ? null
          : nextAudioAttachmentHop(url, resp.statusCode ?? 0, resp.headers.value(HttpHeaders.locationHeader));
      if (next == null) {
        break;
      }
      url = next;
    }
    if (result.isLeft()) {
      if (part.existsSync()) {
        await part.delete();
      }
      if (cancelToken.isCancelled) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: track.url),
          reason: 'cancelled',
        );
      }
      result.mapLeft((e) => error('failed to fetch ${track.id}: $e'));
      throw const AudioFetchException(AudioFetchFailure.network);
    }
    final status = result.toNullable()?.statusCode ?? 0;
    if (status >= 300 && status < 400) {
      // Redirected more than [maxAudioAttachmentHops] times, or nowhere.
      await part.delete();
      throw const AudioFetchException(AudioFetchFailure.network);
    }
    final head = await _head(part);
    if (!looksLikeAudio(head)) {
      warning('fetched ${track.id} is not audio');
      await part.delete();
      throw const AudioFetchException(AudioFetchFailure.notAudio);
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
      warning('failed to trim the audio cache: $e');
    }
  }
}
