import 'package:flutter/foundation.dart';

/// A picture of a post: what its floor shows, and what the gallery shows, saves and shares.
@immutable
final class GalleryImage {
  /// Constructor.
  const GalleryImage(this.url, {String? floorUrl, this.width, this.height, this.fileSize, this.linkUrl})
    : floorUrl = floorUrl ?? url;

  /// The picture itself: what the gallery shows, saves and shares (the original of an attachment).
  final String url;

  /// What the floor shows: the thumbnail the forum made of an attachment, [url] when there is none.
  final String floorUrl;

  /// Width of [url] in pixels when the forum tells it (an attachment of the app API), null otherwise.
  final int? width;

  /// Height of [url] in pixels when the forum tells it, null otherwise.
  final int? height;

  /// Size of [url] in bytes when the forum tells it, null otherwise.
  final int? fileSize;

  /// The link the picture is in, null when none.
  final String? linkUrl;

  /// Whether the floor shows a thumbnail of the picture ([floorUrl]).
  bool get hasThumbnail => floorUrl != url;

  @override
  bool operator ==(Object other) =>
      other is GalleryImage &&
      other.url == url &&
      other.floorUrl == floorUrl &&
      other.width == width &&
      other.height == height &&
      other.fileSize == fileSize &&
      other.linkUrl == linkUrl;

  @override
  int get hashCode => Object.hash(url, floorUrl, width, height, fileSize, linkUrl);

  @override
  String toString() => 'GalleryImage($url${hasThumbnail ? ', floor: $floorUrl' : ''})';
}

/// What the gallery page is opened with: the pictures, and the one shown first.
@immutable
final class ImageGalleryArgs {
  /// Constructor.
  const ImageGalleryArgs(this.images, this.initialIndex);

  /// The pictures, in the order of the floor.
  final List<GalleryImage> images;

  /// The picture shown first.
  final int initialIndex;
}
