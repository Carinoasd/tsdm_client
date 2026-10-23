import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/painting.dart' as painting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_avif/flutter_avif.dart';
import 'package:fpdart/fpdart.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/extensions/int.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/cache/models/models.dart';
import 'package:tsdm_client/features/settings/models/models.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_trim.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/image_cache_info.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/safe_path.dart';

const _contentTypeImageAvif = 'image/avif';

/// Directory to save common image cache.
late final Directory _imageCacheDirectory;

/// Directory to save emoji image cache used in bbcode editor.
///
/// Actually emoji should be managed under cache too. But we decide to put in
/// another directory to keep the state of emoji longer than regular image
/// cache, and of course, clear emoji cache outside regular cache.
///
/// Also, more kinds of image cache is planned to launch in future:
/// * User avatar.
/// * Forum cover.
///
/// When cleaning cache, it is a good choice to show the different cache kinds
/// to let user to decide what to delete like the browser does. This is in plan.
///
/// Emoji on TSDM is separated into different groups and have an id:
///
/// Group      Name
/// "钟梦篱" -> {:16_894:}
///
/// When saving emoji, name the image file with name "${GROUP_ID}_${ID}.jpg"
///
/// All available emojis are parsed from a static cached JS script called
/// common_smilies_var.js
/// https://tsdm39.com/data/cache/common_smilies_var.js?y1Z
late final Directory _emojiCacheDirectory;

/// Info json file contains all emoji group info.
late final File _emojiCacheInfoFile;

/// Init settings, must call before start.
Future<void> initCache() async {
  _imageCacheDirectory = Directory('${(await getApplicationCacheDirectory()).path}/images');
  _emojiCacheDirectory = Directory('${(await getApplicationSupportDirectory()).path}/emoji');
  _emojiCacheInfoFile = File('${_emojiCacheDirectory.path}/emoji.json');

  if (!_imageCacheDirectory.existsSync()) {
    await _imageCacheDirectory.create(recursive: true);
  }
  if (!_emojiCacheDirectory.existsSync()) {
    await _emojiCacheDirectory.create(recursive: true);
  }
}

/// Provider of cached images.
final class ImageCacheProvider with LoggerMixin {
  // Can not be const.
  // ignore: prefer_const_constructor_declarations
  /// Constructor.
  ///
  /// Images are fetched without the user's session on purpose: third-party hosts must not see the forum cookie, and
  /// forum attachments do not need it because the `aid` token already carries the viewer's identity (verified live:
  /// an attachment of a purchased thread loads for the buyer's token with and without the cookie).
  ImageCacheProvider(this._netClientProvider);

  final NetClientProvider _netClientProvider;

  /// Messages the server answered instead of image bytes, by image url (e.g. `附件所在主题需要付费，请您付费后下载`).
  final _htmlMessages = <String, String>{};

  /// The message the server answered instead of an image for [imageUrl], if any.
  String? htmlMessageOf(String imageUrl) => _htmlMessages[imageUrl];

  /// Avatar urls the server has no file for, and the user whose cached avatar is shown instead, by avatar url.
  ///
  /// A thread row has no avatar url, so it is built from the author's uid, and a user who set an external avatar url
  /// has no file under that url. Without remembering the answer every card would ask the server again, because the
  /// widget drops its image as soon as the avatar arrives and then loads it once more.
  ///
  /// Kept in memory only: after a restart the url is tried again, and the entry always resolves to whatever avatar is
  /// cached for the user at that moment, so a new avatar is never hidden behind an old one.
  final _avatarWithoutFile = <String, String>{};

  /// Avatar urls the server answered 404 for, with no avatar cached for the user to show instead, and when: not asked
  /// again for [missingAvatarTtl] (nor before the image is reloaded on purpose, `force`). Every card of such an author
  /// asked the server again on every build, and a thread list is full of authors without an uploaded avatar; an author
  /// who uploads one later shows it after the time is over.
  final _missingAvatarUrls = <String, DateTime>{};

  /// How long an avatar answering 404 is not asked again.
  static const missingAvatarTtl = Duration(minutes: 10);

  /// Source of the current time, for [missingAvatarTtl].
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// Whether [e] is the server's 404 for an image.
  static bool _isNotFound(Object e) => switch (e) {
    HttpRequestFailedException(statusCode: HttpStatus.notFound) => true,
    HttpHandshakeFailedException(statusCode: HttpStatus.notFound) => true,
    _ => false,
  };

  /// Whether the avatar at [url] answered 404 less than [missingAvatarTtl] ago (see [_missingAvatarUrls]).
  bool isKnownMissingAvatar(String url) {
    final since = _missingAvatarUrls[url];
    if (since == null) {
      return false;
    }
    if (clock().difference(since) < missingAvatarTtl) {
      return true;
    }
    _missingAvatarUrls.remove(url);
    return false;
  }

  /// The avatar cached for [username] when [imageUrl] is known to have no file on the server.
  ///
  /// Forgets [imageUrl] when nothing is cached for the user any more, so the next load asks the server again.
  Future<Option<Uint8List>> _cachedAvatarInsteadOf(String imageUrl, String username) async {
    if (_avatarWithoutFile[imageUrl] != username) {
      return const Option.none();
    }
    final cached = await getUserAvatarCache(username: username, imageUrl: null);
    if (cached.isNone()) {
      _avatarWithoutFile.remove(imageUrl);
    }
    return cached;
  }

  /// Regexp that matches emoji bbcode.
  ///
  /// {:10_200:} format.
  static final _emojiCodeRe = RegExp(r'{:(?<groupId>\d+)_(?<id>\d+):}');

  /// Provide a stream of [ImageCacheResponse].
  final _controller = BehaviorSubject<ImageCacheResponse>();

  /// [ImageCacheResponse] stream.
  ///
  /// Contains a series of responses to image caching requests.
  ///
  /// Latest image cache state also is here.
  Stream<ImageCacheResponse> get response => _controller.asBroadcastStream();

  /// Record all currently loading images.
  ///
  /// Use this list to avoid duplicate requests.
  final List<String> _loadingImages = [];

  /// Who is told the progress of the images downloading now, by url (`onProgress` of [getOrMakeCache]).
  final _progressListeners = <String, Set<ImageLoadProgress>>{};

  /// Dispose the repository.
  Future<void> dispose() async {
    await _controller.close();
  }

  /// Get the cache info related to [imageUrl]: looked up by its key, never by reading the whole table.
  Future<ImageEntity?> _getCacheInfo(String imageUrl) => getIt.get<StorageProvider>().getImageCache(imageUrl);

  /// The bytes of [file], null when it can not be read (deleted meanwhile: by the clean up of the cache, by Android
  /// clearing the cache directory): the image is then fetched again.
  Future<Uint8List?> _readCacheFile(File file) async {
    try {
      return await file.readAsBytes();
    } on FileSystemException catch (e) {
      warning('cached image file can not be read: ${e.message}');
      return null;
    }
  }

  /// Query the state of user avatar cache specified by [req], the result will be pended as a cache response.
  Future<void> queryUserAvatarCacheState(ImageCacheUserAvatarRequest req) async {
    final cacheInfo = await getIt.get<StorageProvider>().getUserAvatarEntityCache(
      username: req.username,
      imageUrl: req.imageUrl.isEmpty ? null : req.imageUrl,
    );

    final cacheFile = cacheInfo == null ? null : getCacheFile(cacheInfo.cacheName);
    if (cacheInfo == null || cacheFile == null || !cacheFile.existsSync()) {
      // Nothing is cached for this url. It may be an avatar url built from a uid that the server has no file for, in
      // which case the avatar cached for the user is what the card shows.
      switch (await _cachedAvatarInsteadOf(req.imageUrl, req.username)) {
        case Some(:final value):
          _controller.add(ImageCacheSuccessResponse(req.imageId, ImageCacheResponseType.userAvatar, value));
        case None():
          _controller.add(ImageCacheFailedResponse(req.imageId, ImageCacheResponseType.userAvatar));
      }
      return;
    }
    final cacheData = await _readCacheFile(cacheFile);
    if (cacheData == null) {
      _controller.add(ImageCacheFailedResponse(req.imageId, ImageCacheResponseType.userAvatar));
      return;
    }
    if (cacheInfo.imageUrl != null) {
      // Update cache used time as used if cache file exists.
      _updateCacheUsedTime(cacheInfo.imageUrl!);
    }
    _controller.add(ImageCacheSuccessResponse(req.imageId, ImageCacheResponseType.userAvatar, cacheData));
  }

  /// Get the cache image data related to [req].
  ///
  /// Only return the image data.
  ///
  /// [cacheOnly]: only what is cached already, nothing is fetched (a picture of a post loaded when tapped, to save
  /// data). [onProgress] is told how much of the image arrived while it downloads, also when it waits for another
  /// request downloading the same image.
  Future<Option<Uint8List>> getOrMakeCache(
    ImageCacheRequest req, {
    bool force = false,
    bool cacheOnly = false,
    ImageLoadProgress? onProgress,
  }) async {
    final respType = switch (req) {
      ImageCacheGeneralRequest() => ImageCacheResponseType.general,
      ImageCacheUserAvatarRequest() => ImageCacheResponseType.userAvatar,
    };
    final imageId = req.imageId;
    final imageUrl = req.imageUrl;

    if (!force) {
      final cacheInfo = await _getCacheInfo(req.imageUrl);
      final cacheFile = cacheInfo == null ? null : getCacheFile(cacheInfo.fileName);
      final imageData = cacheFile != null && cacheFile.existsSync() ? await _readCacheFile(cacheFile) : null;
      if (imageData != null) {
        // Cached loaded from disk, update last used time.
        _updateCacheUsedTime(imageUrl);

        // Cache file may be deleted by external operations.
        // Only reply a success response when cache is valid.
        _controller.add(ImageCacheSuccessResponse(imageId, respType, imageData));

        // Here the cache update progress is for some special situation:
        //
        // Assume an user's avatar is already cached ever before where was
        // recognized as general image (not specialized as user avatar), here
        // the cache reusing logic just loaded the image and leave the cache
        // info, which is between user avatar cache file, in empty state.
        // This made all same-user avatar cache loading logic in future end
        // with failure because the image is cached while the relationship
        // not.
        //
        // So add a check and update the reference if necessary.
        if (req case ImageCacheUserAvatarRequest()) {
          final cache = await getIt.get<StorageProvider>().getUserAvatarEntityCache(
            username: req.username,
            imageUrl: req.imageUrl,
          );
          if (cache == null) {
            debug('save unrecorded user avatar for user ${req.username}');
            await _saveCache(imageUrl, imageData, usage: ImageUsageInfoUserAvatar(req.username));
          }
        }

        return Option.of(imageData);
      }
    }
    if (cacheOnly) {
      return const Option.none();
    }
    if (imageUrl.isEmpty) {
      return const Option.none();
    }

    if (req case ImageCacheUserAvatarRequest(:final username) when !force) {
      // Already known to have no file on the server: use the avatar cached for the user and do not ask again.
      final cached = await _cachedAvatarInsteadOf(imageUrl, username);
      if (cached case Some(:final value)) {
        return Option.of(value);
      }
    }

    if (req is ImageCacheUserAvatarRequest && !force && isKnownMissingAvatar(imageUrl)) {
      // The server has no file there (404 earlier in this run) and the user has no avatar cached either.
      _controller.add(ImageCacheFailedResponse(imageId, respType));
      return const Option.none();
    }

    if (_loadingImages.contains(imageUrl)) {
      // If already loading, do nothing.
      if (onProgress != null) {
        (_progressListeners[imageUrl] ??= {}).add(onProgress);
      }
      try {
        final x = await response.firstWhere(
          (e) => e.imageId == imageUrl && (e is ImageCacheSuccessResponse || e is ImageCacheFailedResponse),
        );
        return switch (x) {
          ImageCacheSuccessResponse(:final imageData) => Option.of(imageData),
          ImageCacheFailedResponse() => const Option.none(),
          final _ => const Option.none(),
        };
      } finally {
        _progressListeners[imageUrl]?.remove(onProgress);
      }
    }

    // Enter loading state.
    _loadingImages.add(imageUrl);
    if (onProgress != null) {
      (_progressListeners[imageUrl] ??= {}).add(onProgress);
    }
    _controller.add(ImageCacheLoadingResponse(imageId, respType));

    try {
      final respEither = await _netClientProvider
          .getImage(
            imageUrl,
            // Only asked for when someone follows it: the Android client then reads the body in pieces.
            onReceiveProgress: onProgress == null
                ? null
                : (received, total) {
                    for (final listener in [...?_progressListeners[imageUrl]]) {
                      listener(received, total > 0 ? total : null);
                    }
                  },
          )
          .run();
      if (respEither.isLeft()) {
        final err = respEither.unwrapErr();
        if (err is ImageResponseNotImageException) {
          // Remember the server's message so the widget can explain the placeholder.
          _htmlMessages[imageUrl] = err.message ?? '';
          info('image url returned a page instead of an image: $imageUrl: ${err.message}');
        }
        throw err;
      }
      final resp = respEither.unwrap();
      final Uint8List imageData;
      // Handle avif format stuff.
      if (resp.headers.map[Headers.contentTypeHeader]?.firstOrNull == _contentTypeImageAvif) {
        // Avif format is not supported by dart image, parse and convert to
        // normal png ones, so image data is saved in png format that dart image
        // support.
        //
        // Currently only the very first frame is reserved, all other frames
        // are discard during conversion.
        final avifFrames = await decodeAvif(resp.data as Uint8List);
        if (avifFrames.isEmpty) {
          imageData = Uint8List(0);
          warning(
            'image from url is in avif format has no frame, '
            'url: $imageUrl',
          );
        } else {
          if (avifFrames.length != 1) {
            warning(
              'image from url is in avif format has multiple frames, '
              'only reserve the first frame and discarding other frames: '
              'url: $imageUrl',
            );
          }
          final byteData = await avifFrames.first.image.toByteData(format: ImageByteFormat.png);
          if (byteData == null) {
            warning(
              'image from url is in avif format has one invalid frame '
              'url: $imageUrl',
            );
            imageData = Uint8List(0);
          } else {
            imageData = byteData.buffer.asUint8List();
          }
        }
      } else {
        imageData = resp.data as Uint8List;
      }

      final usage = switch (req) {
        ImageCacheGeneralRequest() => const ImageUsageInfoOther(),
        // TODO: Handle this case.
        ImageCacheUserAvatarRequest(:final username) => ImageUsageInfoUserAvatar(username),
      };

      await _saveCache(imageUrl, imageData, usage: usage);
      _controller.add(ImageCacheSuccessResponse(imageId, respType, imageData));
      return Option.of(imageData);
    } on Exception catch (e, st) {
      handleRaw(e, st);
      // The url did not load, but for a user avatar the app may still hold an avatar of the same user, cached from
      // another page that carried a different url for it.
      //
      // This is what happens for a thread row: the row has no avatar url, so the url is built from the author's uid
      // and answers 404 for everyone who set an external avatar url instead of uploading one. Showing the avatar the
      // app already has beats falling back to the text placeholder.
      //
      // The network request stays first on purpose: an avatar that did load is the current one, a cached entry only
      // fills in when nothing else is available.
      if (req case ImageCacheUserAvatarRequest(:final username)) {
        final cached = await getUserAvatarCache(username: username, imageUrl: null);
        if (cached case Some(:final value)) {
          // Remember the answer, otherwise the next build of the card asks the server again.
          _avatarWithoutFile[imageUrl] = username;
          _controller.add(ImageCacheSuccessResponse(imageId, respType, value));
          return Option.of(value);
        }
      }
      if (req is ImageCacheUserAvatarRequest && _isNotFound(e)) {
        _missingAvatarUrls[imageUrl] = clock();
      }
      _controller.add(ImageCacheFailedResponse(imageId, respType));
      return const Option.none();
    } finally {
      // Leave loading state.
      _loadingImages.remove(imageUrl);
      _progressListeners.remove(imageUrl);
    }
  }

  /// Get the cached user avatar data of user [username].
  Future<Option<Uint8List>> getUserAvatarCache({required String username, required String? imageUrl}) async {
    final url = imageUrl == null || imageUrl.isEmpty ? null : imageUrl;
    final cacheInfo = await getIt.get<StorageProvider>().getUserAvatarEntityCache(username: username, imageUrl: url);
    if (cacheInfo == null) {
      // error('$username user avatar cache file not found');
      return const Option.none();
    }

    // Cache found.

    final cacheFile = getCacheFile(cacheInfo.cacheName);
    if (cacheFile == null || !cacheFile.existsSync()) {
      return const Option.none();
    }

    // Cache data still alive.

    final data = await _readCacheFile(cacheFile);
    if (data == null) {
      return const Option.none();
    }
    if (url != null) {
      _updateCacheUsedTime(url);
    }
    return Option.of(data);
  }

  /// The cache file called [fileName] inside the image cache directory.
  ///
  /// Null when [fileName] is not a plain file name or would resolve outside of the directory: names come back from
  /// the database, which a restored backup may have filled with anything. Callers treat null as "not cached".
  File? getCacheFile(String fileName) {
    final file = fileInside(_imageCacheDirectory, fileName);
    if (file == null) {
      error('refuse cache file name outside the image cache directory (${fileName.length} chars)');
    }
    return file;
  }

  /// Save latest cache data and info into database.
  Future<void> _saveCache(
    String imageUrl,
    Uint8List imageData, {
    ImageUsageInfo usage = const ImageUsageInfoOther(),
  }) async {
    final fileName = imageUrl.fileNameV5();

    // Make cache.
    final cache = getCacheFile(fileName);
    if (cache == null) {
      return;
    }
    // Android can clear this directory while the app runs (storage pressure, or the cache screen), so make sure it is
    // there again. A cache write is best effort — its bytes are already in hand — but a row written before the file
    // would point at a file that is not there, so the file goes first and a failed write ends the save.
    try {
      await cache.parent.create(recursive: true);
      await cache.writeAsBytes(imageData);
    } on FileSystemException catch (e) {
      warning('could not save the image cache (${imageUrl.length} char url): ${e.message}');
      // A write that failed halfway (a full disk) leaves a truncated file; a row an earlier save left for this url would
      // then serve a broken image, so drop the file and let the next load download it again.
      try {
        if (cache.existsSync()) await cache.delete();
      } on FileSystemException catch (_) {
        // Best effort: the warning above already reports the failed save.
      }
      return;
    }

    // Update image cache info to database.
    await getIt.get<StorageProvider>().updateImageCache(imageUrl, fileName: fileName);

    // Update other cache ref tables, if necessary.
    switch (usage) {
      case ImageUsageInfoOther():
        // Do nothing.
        break;
      case ImageUsageInfoUserAvatar(:final username):
        // Update user avatar cache.
        await getIt
            .get<StorageProvider>()
            .updateUserAvatarCacheInfo(username: username, cacheName: fileName, imageUrl: imageUrl)
            .run();
    }
  }

  /// Update image last used time: in memory now, in the table with the next batch
  /// ([StorageProvider.markImageCacheUsed]).
  ///
  /// Not update the cached file.
  void _updateCacheUsedTime(String imageUrl) => getIt.get<StorageProvider>().markImageCacheUsed(imageUrl);

  int _calculateDirectorySize(Directory dir) {
    final fileList = dir.listSync(recursive: true);
    return fileList.fold<int>(0, (acc, x) {
      return acc + x.statSync().size;
    });
  }

  /// Calculate cache size in bytes.
  Future<CacheStorageInfo> calculateCache() async {
    final imageSize = _calculateDirectorySize(_imageCacheDirectory);
    final emojiSize = _calculateDirectorySize(_emojiCacheDirectory);
    final logSize = _calculateDirectorySize(await getLogDir());
    return CacheStorageInfo(imageSize: imageSize, emojiSize: emojiSize, logSize: logSize);
  }

  /// Clear cache in [_imageCacheDirectory].
  Future<void> clearCache(CacheClearInfo clearInfo) async {
    if (clearInfo.clearImage) {
      await getIt.get<StorageProvider>().clearImageCache();
      for (final f in _imageCacheDirectory.listSync()) {
        await f.delete(recursive: true);
      }
      _avatarWithoutFile.clear();
    }
    if (clearInfo.clearEmoji) {
      for (final f in _emojiCacheDirectory.listSync()) {
        await f.delete(recursive: true);
      }
    }
  }

  /// Rows of the table read at once by [trimCache].
  static const _trimRowsPage = 5000;

  /// Offline thread pages read at once by [trimCache].
  static const _trimBodiesPage = 20;

  /// Images deleted at once by [trimCache], and the pause after each batch.
  static const _trimBatch = 250;
  static const _trimPause = Duration(milliseconds: 100);

  // The work of [trimCache] in other isolates, each through a function of its own: a closure sent to an isolate takes
  // the variables of the scope it was made in along, and those of [trimCache] hold the whole table.

  static Future<Map<String, ImageCacheFileStat>> _listFilesIn(String dir) =>
      Isolate.run(() => listImageCacheFiles(dir));

  static Future<Set<String>> _keysOfPagesIn(List<String> bodies) => Isolate.run(() => imageKeysOfPages(bodies));

  static Future<int> _deleteFilesIn(String dir, List<String> names) =>
      Isolate.run(() => deleteImageCacheFiles(dir, names));

  static Future<ImageCacheTrimPlan> _planIn({
    required List<ImageCacheTrimRow> rows,
    required Map<String, ImageCacheFileStat> files,
    required Set<String> keptUrls,
    required Set<String> keptFiles,
    required Set<String> keptKeys,
    required int nowMs,
    required int? maxAgeMs,
    required int maxEntries,
    required int maxBytes,
  }) => Isolate.run(
    () => planImageCacheTrim(
      rows: rows,
      files: files,
      keptUrls: keptUrls,
      keptFiles: keptFiles,
      keptKeys: keptKeys,
      nowMs: nowMs,
      maxAgeMs: maxAgeMs,
      maxEntries: maxEntries,
      maxBytes: maxBytes,
    ),
  );

  /// The keys ([imageCacheKeyOf]) of [rows], a few thousand at a time so that the isolate keeps drawing frames.
  static Future<Set<String>> _keysOfRows(List<ImageCacheTrimRow> rows) async {
    final keys = <String>{};
    for (var i = 0; i < rows.length; i++) {
      keys.add(imageCacheKeyOf(rows[i].url));
      if (i % _trimRowsPage == _trimRowsPage - 1) {
        await Future<void>.delayed(Duration.zero);
      }
    }
    return keys;
  }

  /// Clean up the image cache within [limits] ([planImageCacheTrim]): the images not shown for its age and the least
  /// recently shown ones beyond its count or size go, with the rows whose file is gone and the files no row names.
  ///
  /// The pictures of the offline thread pages stay (the saved pages are read a few at a time, and an image of the cache
  /// is kept when one of them names it, [imageKeysOfPage]), with the user's image stickers and the avatars of the
  /// accounts saved on this device.
  ///
  /// Meant to run in the background long after the first frame. When the cache is within its limits only a listing
  /// of the directory (in another isolate) and two counts run; the table is never read again whole. Otherwise the
  /// table is read page by page through its key, the plan made in another isolate, and at most
  /// [ImageCacheLimits.maxDeletesPerRun] images deleted, the least recently shown first, in small batches with a pause
  /// after each: the files of a batch first (in another isolate), then its rows. A run stopped halfway leaves rows
  /// without their file, which load the image again when shown and go with the next run, never a file no run would
  /// find. A row shown or cached again meanwhile stays ([StorageProvider.beginImageCacheTouchLog]); the rows in memory
  /// only lose the deleted ones. Null when it failed (logged).
  Future<ImageCacheTrimResult?> trimCache(ImageCacheLimits limits) async {
    final storage = getIt.get<StorageProvider>();
    final dirPath = _imageCacheDirectory.path;
    storage.beginImageCacheTouchLog();
    try {
      // The rows must tell when their images were last shown.
      await storage.flushImageCacheUsedTimes();
      final now = DateTime.now();
      final files = await _listFilesIn(dirPath);
      var bytes = 0;
      for (final file in files.values) {
        bytes += file.size;
      }
      final count = await storage.countImageCache();
      final maxAge = limits.maxAge;
      final outdated = maxAge == null ? 0 : await storage.countImageCacheUsedNoLaterThan(now.subtract(maxAge));
      if (outdated == 0 && count <= limits.maxEntries && bytes <= limits.maxBytes && files.length == count) {
        debug('image cache within its limits: $count images, $bytes bytes');
        return (countBefore: count, bytesBefore: bytes, deletedRows: 0, deletedFiles: 0, more: false);
      }

      final rows = <ImageCacheTrimRow>[];
      String? after;
      while (true) {
        final page = await storage.imageCacheRowsAfter(after, _trimRowsPage);
        rows.addAll(
          page.map((e) => (url: e.url, fileName: e.fileName, lastUsedMs: e.lastUsedTime.millisecondsSinceEpoch)),
        );
        if (page.length < _trimRowsPage) {
          break;
        }
        after = page.last.url;
      }
      final keepers = await storage.imageCacheKeepers();
      // Only the keys of images in the cache are kept: a saved page names many more urls (every link) than pictures,
      // and a thousand pages would hold hundreds of thousands of them.
      final keptKeys = <String>{};
      Set<String>? rowKeys;
      var afterRow = 0;
      while (true) {
        final page = await storage.offlineThreadBodiesAfter(afterRow, _trimBodiesPage);
        if (page.isEmpty) {
          break;
        }
        rowKeys ??= await _keysOfRows(rows);
        final bodies = [for (final e in page) e.body];
        final keys = await _keysOfPagesIn(bodies);
        keptKeys.addAll(keys.where(rowKeys.contains));
        afterRow = page.last.rowId;
      }

      final nowMs = now.millisecondsSinceEpoch;
      final plan = await _planIn(
        rows: rows,
        files: files,
        keptUrls: keepers.urls,
        keptFiles: keepers.fileNames,
        keptKeys: keptKeys,
        nowMs: nowMs,
        maxAgeMs: maxAge?.inMilliseconds,
        maxEntries: limits.maxEntries,
        maxBytes: limits.maxBytes,
      );

      var budget = limits.maxDeletesPerRun;
      var deletedRows = 0;
      var deletedFiles = 0;
      final doomedRows = plan.rows.take(budget).toList();
      budget -= doomedRows.length;
      for (var i = 0; i < doomedRows.length; i += _trimBatch) {
        final batch = doomedRows.sublist(i, math.min(i + _trimBatch, doomedRows.length));
        // Shown or cached again since the table was read: stays.
        final touched = storage.touchedImageUrls;
        final targets = [
          for (final e in batch)
            if (!touched.contains(e.url)) e,
        ];
        if (targets.isEmpty) {
          continue;
        }
        // Files first: a run stopped here leaves rows without their file (the image loads again when shown, the
        // next run deletes the row), never a file no row names.
        final names = [for (final e in targets) e.fileName];
        deletedFiles += await _deleteFilesIn(dirPath, names);
        deletedRows += await storage.deleteImageCacheRows(
          [for (final e in targets) e.url],
          usedNoLaterThan: DateTime.fromMillisecondsSinceEpoch(targets.map((e) => e.lastUsedMs).reduce(math.max)),
        );
        await Future<void>.delayed(_trimPause);
      }
      final orphans = plan.orphanFiles.take(math.max(0, budget)).toList();
      for (var i = 0; i < orphans.length; i += _trimBatch) {
        // Not a file of an image cached again meanwhile: its row may be on its way.
        final saved = {for (final url in storage.touchedImageUrls) url.fileNameV5()};
        final batch = [
          for (final name in orphans.sublist(i, math.min(i + _trimBatch, orphans.length)))
            if (!saved.contains(name)) name,
        ];
        deletedFiles += await _deleteFilesIn(dirPath, batch);
        await Future<void>.delayed(_trimPause);
      }
      final more = plan.rows.length > doomedRows.length || plan.orphanFiles.length > orphans.length;
      info(
        'image cache cleaned up: ${plan.countBefore} images ($bytes bytes, ${files.length} files), '
        '$deletedRows rows and $deletedFiles files deleted${more ? ', more left for the next run' : ''}; kept '
        '${keepers.urls.length} stickers, ${keepers.fileNames.length} account avatars, ${keptKeys.length} offline '
        'page keys',
      );
      return (
        countBefore: plan.countBefore,
        bytesBefore: bytes,
        deletedRows: deletedRows,
        deletedFiles: deletedFiles,
        more: more,
      );
    } on Object catch (e, st) {
      error('failed to clean up the image cache: $e');
      handleRaw(e, st);
      return null;
    } finally {
      storage.endImageCacheTouchLog();
    }
  }

  ///////////////////////// Emoji Cache /////////////////////////

  /// Validate emoji cache.
  ///
  /// * Check the existence of cache folder and cache info file.
  /// * Check the all emojis described in emoji info file.
  ///
  /// # Return Value
  ///
  /// Return true when passed validation.
  /// Return false when failed the validation.
  Future<bool> validateEmojiCache() async {
    // Check cache directory and emoji info file exists or not.
    if (!_emojiCacheDirectory.existsSync() || !_emojiCacheInfoFile.existsSync()) {
      return false;
    }
    try {
      final info = EmojiGroupListMapper.fromJson(await _emojiCacheInfoFile.readAsString());
      // Validate all cached emoji files exists.
      final validateResult = info.validateCache(_emojiCacheDirectory.path);
      return validateResult;
      // Intend to be a muter on all types of exception.
      // ignore: avoid_catches_without_on_clauses
    } catch (e) {
      warning('validate emoji cache failed: invalid emoji info: $e');
      return false;
    }
  }

  /// Save the emoji info.
  ///
  /// This is useful when reloading the emoji from cache.
  Future<void> saveEmojiInfo(List<EmojiGroup> emojiGroupList) async {
    final jsonData = EmojiGroupList(emojiGroupList).toJson();
    await _emojiCacheInfoFile.create(recursive: true);
    await _emojiCacheInfoFile.writeAsString(jsonData);
  }

  /// Load all emoji data from cache.
  ///
  ///
  /// Return null if no such cached emoji info or info is invalid.
  Future<List<EmojiGroup>?> loadEmojiInfo() async {
    if (!_emojiCacheInfoFile.existsSync()) {
      return null;
    }
    try {
      final info = EmojiGroupListMapper.fromJson(_emojiCacheInfoFile.readAsStringSync());
      return info.emojiGroupList;
      // Intend to be a muter on all types of exception.
      // ignore: avoid_catches_without_on_clauses
    } catch (e) {
      warning('failed to load emoji info when decoding json: $e');
      return null;
    }
  }

  /// Load emoji info and emoji images from assert.
  ///
  /// Copy to legacy emoji data dir so that existing emoji validation logic
  /// does not need to change.
  Future<List<EmojiGroup>?> loadEmojiFromAsset() async {
    final infoBytes = await rootBundle.loadString(assetEmojiInfoPath);
    final info = EmojiGroupListMapper.fromJson(infoBytes);
    await _emojiCacheInfoFile.writeAsString(infoBytes);

    for (final emojiGroup in info.emojiGroupList) {
      for (final emoji in emojiGroup.emojiList) {
        // All emoji are saved with ".jpg" suffix.
        final cacheTarget = _formatEmojiCachePath(emojiGroup.id, emoji.id);
        if (cacheTarget == null) {
          warning('skip emoji with unsafe id (${emojiGroup.id.length}/${emoji.id.length} chars)');
          continue;
        }
        final emojiBytes = await rootBundle.load('$assetEmojiDir${emojiGroup.id}_${emoji.id}.jpg');
        await File(cacheTarget).writeAsBytes(emojiBytes.buffer.asUint8List());
      }
    }

    return info.emojiGroupList;
  }

  /// Emoji cache is save as jpg file no matter the real content.
  ///
  /// Null when an id is not a plain `[A-Za-z0-9_-]` token: ids come from the forum's smilies script and from the cache
  /// info file, and must never form a path outside the emoji cache directory.
  String? _formatEmojiCachePath(String groupId, String id) {
    if (!isSafeEmojiId(groupId) || !isSafeEmojiId(id)) {
      return null;
    }
    return '${_emojiCacheDirectory.path}/${groupId}_$id.jpg';
  }

  /// Check have the cache file for emoji with [groupId] and [id].
  bool hasEmojiCacheFile(String groupId, String id) {
    final cachePath = _formatEmojiCachePath(groupId, id);
    return cachePath != null && File(cachePath).existsSync();
  }

  /// Try get the emoji cache from raw bbcode.
  ///
  /// Only valid when code in {:${GROUP_ID}_${EMOJI_ID}:} format.
  Future<Uint8List?> getEmojiCacheFromRawCode(String code) async {
    if (!_emojiCodeRe.hasMatch(code)) {
      return null;
    }
    final m = _emojiCodeRe.firstMatch(code)!;
    final groupId = m.namedGroup('groupId')!;
    final id = m.namedGroup('id')!;
    return getEmojiCache(groupId, id);
  }

  /// Try get the emoji cache from raw bbcode.
  ///
  /// Synchronously.
  Uint8List? getEmojiCacheFromRawCodeSync(String code) {
    if (!_emojiCodeRe.hasMatch(code)) {
      return null;
    }
    final m = _emojiCodeRe.firstMatch(code)!;
    final groupId = m.namedGroup('groupId')!;
    final id = m.namedGroup('id')!;
    return getEmojiCacheSync(groupId, id);
  }

  /// Get the cached file of emoji with specified [groupId] and [id].
  Future<Uint8List?> getEmojiCache(String groupId, String id) async {
    final cachePath = _formatEmojiCachePath(groupId, id);
    if (cachePath == null) {
      return null;
    }
    final cacheFile = File(cachePath);
    if (!cacheFile.existsSync()) {
      warning('$cacheFile cache file not exists');
      return null;
    }
    return cacheFile.readAsBytes();
  }

  /// Get the cached file of emoji with specified [groupId] and [id].
  Uint8List? getEmojiCacheSync(String groupId, String id) {
    final cachePath = _formatEmojiCachePath(groupId, id);
    if (cachePath == null) {
      return null;
    }
    final cacheFile = File(cachePath);
    if (!cacheFile.existsSync()) {
      warning('$cacheFile cache file not exists');
      return null;
    }
    return cacheFile.readAsBytesSync();
  }

  /// Clear all emoji cache files.
  Future<void> clearEmojiCache() async {
    for (final f in _emojiCacheDirectory.listSync()) {
      await f.delete(recursive: true);
    }
  }

  /// Update emoji cache.
  Future<void> updateEmojiCache(String groupId, String id, List<int> imageData) async {
    final fileName = _formatEmojiCachePath(groupId, id);
    if (fileName == null) {
      warning('refuse to cache emoji with unsafe id (${groupId.length}/${id.length} chars)');
      return;
    }
    // Make cache.
    final cache = File(fileName);
    await cache.writeAsBytes(imageData);
  }

  /// Return the full cache info of image referred to `url`.
  ///
  /// Including image property like cache file size and image pixel size.
  ///
  /// Ensures the url is cache if cache is invalid.
  Future<ImageCacheInfo?> getEnsureCachedFullInfo(String url) async {
    final imageData = switch (await getOrMakeCache(ImageCacheGeneralRequest(url))) {
      Some<Uint8List>(:final value) => value,
      None() => null,
    };
    if (imageData == null) {
      return null;
    }
    final uiImage = await painting.decodeImageFromList(imageData);
    final cacheInfo = await _getCacheInfo(url);
    if (cacheInfo == null) {
      return null;
    }

    return ImageCacheInfo(
      url: url,
      fileName: cacheInfo.fileName,
      lastCachedTime: cacheInfo.lastCachedTime,
      lastUsedTime: cacheInfo.lastUsedTime,
      usage: cacheInfo.usage,
      width: uiImage.width,
      height: uiImage.height,
      cacheSize: File(
        '${_imageCacheDirectory.path}${path.separator}${cacheInfo.fileName}',
      ).statSync().size.withSizeHint(),
    );
  }
}
