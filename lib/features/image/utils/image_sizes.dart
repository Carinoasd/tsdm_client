import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

/// The size of an image already decoded once in this run: what a picture takes before it is there again.
@immutable
final class KnownImageSize {
  /// Constructor.
  const KnownImageSize({required this.aspectRatio, this.width});

  /// Width to height.
  final double aspectRatio;

  /// Width of the image in pixels; null when it was decoded no wider than it was shown (the image is at least as wide
  /// as there was room for it).
  final double? width;

  @override
  bool operator ==(Object other) => other is KnownImageSize && other.aspectRatio == aspectRatio && other.width == width;

  @override
  int get hashCode => Object.hash(aspectRatio, width);

  @override
  String toString() => 'KnownImageSize(${aspectRatio.toStringAsFixed(3)}, width: $width)';
}

/// Sizes of the images decoded in this run, by url, kept in memory only (never written anywhere).
///
/// A picture of a post loading again (the floor scrolled back to after its decoded image left the image cache, the
/// thread opened again) takes its place at once: the floor does not move when it comes.
abstract final class ImageSizes {
  /// Images remembered at most, the least recently decoded ones forgotten first.
  static const capacity = 4096;

  /// Least recently recorded first (a map literal keeps the insertion order).
  static final _sizes = <String, KnownImageSize>{};

  /// The size of the image at [url], null when it was not decoded in this run.
  static KnownImageSize? of(String url) => _sizes[url];

  /// Remember the image at [url] decoded at [size] (pixels); [downscaled]: decoded narrower than it is.
  ///
  /// The width of a downscaled image is not its own: only its aspect ratio is kept, unless the image is known wider.
  static void record(String url, Size size, {required bool downscaled}) {
    if (url.isEmpty || size.width <= 0 || size.height <= 0) {
      return;
    }
    final previous = _sizes.remove(url);
    // Decoded whole once (in the gallery): its own width stays known when the floor decodes it narrower.
    final width = downscaled ? previous?.width : size.width;
    _sizes[url] = KnownImageSize(aspectRatio: size.width / size.height, width: width);
    while (_sizes.length > capacity) {
      _sizes.remove(_sizes.keys.first);
    }
  }

  /// Images remembered now.
  static int get length => _sizes.length;

  /// Forget everything (tests).
  @visibleForTesting
  static void clear() => _sizes.clear();
}
