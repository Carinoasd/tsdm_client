part of 'dao.dart';

/// DAO for table [Image].
@DriftAccessor(tables: [Image])
final class ImageDao extends DatabaseAccessor<AppDatabase> with _$ImageDaoMixin {
  /// Constructor.
  ImageDao(super.attachedDatabase);

  /// Get all image cache.
  Future<List<ImageEntity>> selectAll() async {
    return select(image).get();
  }

  /// Get image cache info by image's [url].
  Future<ImageEntity?> selectImageByUrl(String url) async {
    return (select(image)..where((e) => e.url.equals(url))).getSingleOrNull();
  }

  /// Save image cache info [imageCompanion].
  ///
  /// If you are sure to update only part of fields for an item in database, use [updateImageCache].
  Future<int> upsertImageCache(ImageCompanion imageCompanion) async {
    return into(image).insertOnConflictUpdate(imageCompanion);
  }

  /// Update part of the image cache info.
  ///
  /// Not all fields are required, unlike [upsertImageCache].
  Future<int> updateImageCache({
    required String url,
    String? fileName,
    DateTime? lastCachedTime,
    DateTime? lastUsedTime,
    ImageUsage? usage,
  }) async {
    final curr = await selectImageByUrl(url);
    if (curr == null) {
      return 0;
    }

    return (update(image)..where((e) => e.url.equals(url))).write(
      curr
          .toCompanion(false)
          .copyWith(
            fileName: Value(fileName ?? curr.fileName),
            lastCachedTime: Value(lastCachedTime ?? curr.lastCachedTime),
            lastUsedTime: Value(lastUsedTime ?? curr.lastUsedTime),
            usage: Value(usage ?? curr.usage),
          ),
    );
  }

  /// Delete image cache by [url].
  Future<int> deleteImageByUrl(String url) async {
    return (delete(image)..where((e) => e.url.equals(url))).go();
  }

  /// Delete all records.
  Future<int> deleteAll() async {
    return delete(image).go();
  }

  /// Delete image cache have an older last used time than [dateTime].
  Future<List<ImageEntity>> deleteByLastUsedDuration(DateTime dateTime) async {
    return (delete(image)..where((e) => e.lastUsedTime.isSmallerOrEqualValue(dateTime))).goAndReturn();
  }

  /// Write the times the images of [usedTimes] were last shown, in one batch.
  ///
  /// Only moves a time forward: a row cached again since (its time is newer) keeps its time, and a url without a row
  /// (deleted meanwhile) writes nothing.
  Future<void> updateLastUsedTimes(Map<String, DateTime> usedTimes) async {
    if (usedTimes.isEmpty) {
      return;
    }
    await batch((b) {
      for (final MapEntry(key: url, value: time) in usedTimes.entries) {
        b.update(
          image,
          ImageCompanion(lastUsedTime: Value(time)),
          where: (e) => e.url.equals(url) & e.lastUsedTime.isSmallerThanValue(time),
        );
      }
    });
  }

  /// Number of rows.
  Future<int> countAll() async {
    final count = image.url.count();
    final row = await (selectOnly(image)..addColumns([count])).getSingle();
    return row.read(count) ?? 0;
  }

  /// Number of rows last used at [time] or before.
  Future<int> countUsedNoLaterThan(DateTime time) async {
    final count = image.url.count();
    final row =
        await (selectOnly(image)
              ..addColumns([count])
              ..where(image.lastUsedTime.isSmallerOrEqualValue(time)))
            .getSingle();
    return row.read(count) ?? 0;
  }

  /// Up to [limit] rows after [afterUrl] in the order of their url (from the first one when null), with only what the
  /// clean up of the cache reads: the whole table is read page by page through its key, never at once.
  Future<List<({String url, String fileName, DateTime lastUsedTime})>> selectPageAfter(String? afterUrl, int limit) async {
    final rows = await customSelect(
      'SELECT url, file_name, last_used_time FROM image_cache '
      '${afterUrl == null ? '' : 'WHERE url > ?1 '}ORDER BY url LIMIT ${afterUrl == null ? '?1' : '?2'}',
      variables: [if (afterUrl != null) Variable.withString(afterUrl), Variable.withInt(limit)],
      readsFrom: {image},
    ).get();
    return rows
        .map(
          (r) => (
            url: r.read<String>('url'),
            fileName: r.read<String>('file_name'),
            lastUsedTime: r.read<DateTime>('last_used_time'),
          ),
        )
        .toList();
  }

  /// Delete the rows of [urls] that were last used at [usedNoLaterThan] or before (a row shown or cached again since
  /// stays); returns the deleted rows.
  Future<List<ImageEntity>> deleteUrlsUsedNoLaterThan(List<String> urls, DateTime usedNoLaterThan) async {
    if (urls.isEmpty) {
      return const [];
    }
    return (delete(image)..where((e) => e.url.isIn(urls) & e.lastUsedTime.isSmallerOrEqualValue(usedNoLaterThan)))
        .goAndReturn();
  }

  /// The images the clean up of the cache never deletes besides the pictures of the offline thread pages: the user's
  /// own image stickers (by url) and the avatars of the accounts saved on this device (by cache file name).
  Future<({Set<String> urls, Set<String> fileNames})> selectKeepers() async {
    final stickers = await customSelect('SELECT url FROM custom_image').get();
    final avatars = await customSelect(
      'SELECT cache_name FROM user_avatar WHERE username IN (SELECT username FROM cookie)',
    ).get();
    return (
      urls: {for (final r in stickers) r.read<String>('url')},
      fileNames: {for (final r in avatars) r.read<String>('cache_name')},
    );
  }
}
