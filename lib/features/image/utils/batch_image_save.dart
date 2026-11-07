import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:tsdm_client/features/image/models/gallery_image.dart';
import 'package:tsdm_client/utils/image_file_name.dart';

/// Fetches the bytes of the image at a url: from the cache, downloaded when not cached. Null when it can not be had.
typedef ImageFetcher = Future<Uint8List?> Function(String url);

/// Where the pictures of a batch go: one file each, under the name given.
// ignore: one_member_abstracts
abstract interface class ImageSaveSink {
  /// Write [data] as [fileName] (a plain name, never a path).
  Future<void> save(String fileName, Uint8List data);
}

/// Stops a batch ([saveImagesInBatch]): the picture being saved is finished, the rest is left.
final class BatchSaveCancel {
  bool _cancelled = false;

  /// Whether the batch was asked to stop.
  bool get isCancelled => _cancelled;

  /// Ask the batch to stop.
  void cancel() => _cancelled = true;
}

/// What a batch came to.
@immutable
final class BatchSaveResult {
  /// Constructor.
  const BatchSaveResult({required this.total, required this.saved, required this.failed, required this.cancelled});

  /// Pictures the batch was given.
  final int total;

  /// Pictures saved.
  final int saved;

  /// Pictures skipped for failing (not fetched, not a picture, not written).
  final int failed;

  /// The batch was stopped before the last picture.
  final bool cancelled;

  @override
  bool operator ==(Object other) =>
      other is BatchSaveResult &&
      other.total == total &&
      other.saved == saved &&
      other.failed == failed &&
      other.cancelled == cancelled;

  @override
  int get hashCode => Object.hash(total, saved, failed, cancelled);

  @override
  String toString() => 'BatchSaveResult(total: $total, saved: $saved, failed: $failed, cancelled: $cancelled)';
}

/// [images] without the repeated ones (the same url), in their order.
List<GalleryImage> distinctGalleryImages(Iterable<GalleryImage> images) {
  final seen = <String>{};
  return [
    for (final image in images)
      if (seen.add(image.url)) image,
  ];
}

/// Which pictures "save all" offers: `floor` alone, or ask between the floor and `page` (the pictures of every floor of
/// the page, the floor's own ones too).
///
/// `pageImages` is the union of `floor` and `page`, without the repeated ones; the floor is asked about only when the
/// page has pictures beyond it.
({List<GalleryImage> floorImages, List<GalleryImage> pageImages, bool ask}) saveScopesOf(
  List<GalleryImage> floor,
  List<GalleryImage>? page,
) {
  final floorImages = distinctGalleryImages(floor);
  final pageImages = distinctGalleryImages([...floorImages, ...?page]);
  return (
    floorImages: floorImages,
    pageImages: pageImages,
    ask: floorImages.isNotEmpty && pageImages.length > floorImages.length,
  );
}

/// [fileName], or the first of "name (2).ext", "name (3).ext"... that [isTaken] does not say is taken.
///
/// Names are compared without their case: Windows and macOS keep `A.png` and `a.png` as one file.
String uniqueFileName(String fileName, bool Function(String candidate) isTaken) {
  if (!isTaken(fileName)) {
    return fileName;
  }
  final dot = fileName.lastIndexOf('.');
  final base = dot > 0 ? fileName.substring(0, dot) : fileName;
  final extension = dot > 0 ? fileName.substring(dot) : '';
  var counter = 2;
  while (true) {
    final candidate = '$base ($counter)$extension';
    if (!isTaken(candidate)) {
      return candidate;
    }
    counter += 1;
  }
}

/// Save [images] one after another into [sink], the url of each fetched by [fetch].
///
/// A picture that fails (not fetched, not a picture by its bytes, [sink] throws) is skipped and counted, the batch goes
/// on. The same url is saved once; names that meet get a counter ([uniqueFileName]). [onProgress] hears how many
/// pictures are done (saved or failed) after each one. [cancel] stops it between two pictures.
Future<BatchSaveResult> saveImagesInBatch({
  required List<GalleryImage> images,
  required ImageFetcher fetch,
  required ImageSaveSink sink,
  BatchSaveCancel? cancel,
  void Function(int done, int total)? onProgress,
}) async {
  final pictures = distinctGalleryImages(images);
  final taken = <String>{};
  var saved = 0;
  var failed = 0;
  var cancelled = false;
  for (final image in pictures) {
    if (cancel?.isCancelled ?? false) {
      cancelled = true;
      break;
    }
    try {
      final data = await fetch(image.url);
      if (data == null || imageExtensionOf(data) == null) {
        failed += 1;
      } else {
        final name = uniqueFileName(imageFileNameOf(image.url, data), (e) => taken.contains(e.toLowerCase()));
        taken.add(name.toLowerCase());
        await sink.save(name, data);
        saved += 1;
      }
    } on Object {
      // Whatever went wrong with one picture (an exception, or a bug in its way) must not end the batch.
      failed += 1;
    }
    onProgress?.call(saved + failed, pictures.length);
  }
  return BatchSaveResult(total: pictures.length, saved: saved, failed: failed, cancelled: cancelled);
}

/// Writes the pictures into a folder, a file that is there already is not overwritten (the name gets a counter).
final class FolderImageSink implements ImageSaveSink {
  /// Constructor.
  FolderImageSink(this.directory);

  /// The folder.
  final String directory;

  /// Paths written so far.
  final savedPaths = <String>[];

  @override
  Future<void> save(String fileName, Uint8List data) async {
    await Directory(directory).create(recursive: true);
    final name = uniqueFileName(fileName, (e) => File(path.join(directory, e)).existsSync());
    final target = path.normalize(path.join(directory, name));
    // The name is a plain one ([imageFileNameOf]); this checks it again before anything is written.
    if (path.dirname(target) != path.normalize(directory)) {
      throw FileSystemException('refuse to write an image outside its folder', fileName);
    }
    await File(target).writeAsBytes(data, flush: true);
    savedPaths.add(target);
  }
}
