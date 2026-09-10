import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';
import 'dart:typed_data';
import 'dart:ui';

import 'package:dio/dio.dart';
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

  /// Dispose the repository.
  Future<void> dispose() async {
    await _controller.close();
  }

  /// Get the cache info related to [imageUrl].
  ImageEntity? _getCacheInfo(String imageUrl) => getIt.get<StorageProvider>().getImageCacheSync(imageUrl);

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
    if (cacheInfo.imageUrl != null) {
      // Update cache used time as used if cache file exists.
      await _updateCacheUsedTime(cacheInfo.imageUrl!);
    }
    final cacheData = await cacheFile.readAsBytes();
    _controller.add(ImageCacheSuccessResponse(req.imageId, ImageCacheResponseType.userAvatar, cacheData));
  }

  /// Get the cache image data related to [req].
  ///
  /// Only return the image data.
  Future<Option<Uint8List>> getOrMakeCache(ImageCacheRequest req, {bool force = false}) async {
    final respType = switch (req) {
      ImageCacheGeneralRequest() => ImageCacheResponseType.general,
      ImageCacheUserAvatarRequest() => ImageCacheResponseType.userAvatar,
    };
    final imageId = req.imageId;
    final imageUrl = req.imageUrl;

    if (!force) {
      final cacheInfo = _getCacheInfo(req.imageUrl);
      if (cacheInfo != null) {
        final cacheFile = getCacheFile(cacheInfo.fileName);
        if (cacheFile != null && cacheFile.existsSync()) {
          final imageData = await cacheFile.readAsBytes();

          // Cached loaded from disk, update last used time.
          await _updateCacheUsedTime(imageUrl);

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

    if (_loadingImages.contains(imageUrl)) {
      // If already loading, do nothing.
      final x = await response.firstWhere(
        (e) => e.imageId == imageUrl && (e is ImageCacheSuccessResponse || e is ImageCacheFailedResponse),
      );
      return switch (x) {
        ImageCacheSuccessResponse(:final imageData) => Option.of(imageData),
        ImageCacheFailedResponse() => const Option.none(),
        final _ => const Option.none(),
      };
    }

    // Enter loading state.
    _loadingImages.add(imageUrl);
    _controller.add(ImageCacheLoadingResponse(imageId, respType));

    try {
      final respEither = await _netClientProvider.getImage(imageUrl).run();
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
      _controller.add(ImageCacheFailedResponse(imageId, respType));
      return const Option.none();
    } finally {
      // Leave loading state.
      _loadingImages.remove(imageUrl);
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

    if (url != null) {
      await _updateCacheUsedTime(url);
    }

    return Option.of(await cacheFile.readAsBytes());
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

    // Update image cache info to database.
    await getIt.get<StorageProvider>().updateImageCache(imageUrl, fileName: fileName);

    // Make cache.
    final cache = getCacheFile(fileName);
    if (cache == null) {
      return;
    }
    await cache.writeAsBytes(imageData);

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

  /// Update image last used time.
  ///
  /// Not update the cached file.
  Future<void> _updateCacheUsedTime(String imageUrl) async {
    await getIt.get<StorageProvider>().updateImageCacheUsedTime(imageUrl);
  }

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

  /// Clear all image cache with last used time older than [dateTime].
  ///
  ///
  /// Return the count of deleted cache.
  Future<int> clearOutdatedCache(DateTime dateTime) async {
    final storage = getIt.get<StorageProvider>();
    final clearedCache = await storage.clearImageCacheOutdated(dateTime);
    for (final cache in clearedCache) {
      final cacheFile = getCacheFile(cache.fileName);
      if (cacheFile != null && cacheFile.existsSync()) {
        await cacheFile.delete();
      }
    }
    return clearedCache.length;
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
    final cacheInfo = _getCacheInfo(url);
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
