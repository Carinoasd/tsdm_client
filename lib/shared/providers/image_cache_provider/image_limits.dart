import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_avif/flutter_avif.dart' show SingleFrameAvifCodec;

/// The most bytes an image of a post (or any image but an avatar or an emoji) is downloaded with: long pictures and
/// GIFs of 20 MB are common, twice that is taken. A larger one is not downloaded (whole) and shows as failed.
const int maxImageBytes = 40 * 1024 * 1024;

/// The most bytes an avatar or an emoji of the forum is downloaded with.
const int maxSmallImageBytes = 4 * 1024 * 1024;

/// The most pixels a picture is decoded at: the largest the gallery decodes a picture at (4096 by 16384, 256 MB). A
/// picture declaring more is decoded smaller ([decodeWithinPixels]), an AVIF one not at all.
const int maxDecodedImagePixels = 4096 * 16384;

/// The most pixels an avatar is decoded at (it is shown a few hundred pixels wide).
const int maxAvatarDecodePixels = 2048 * 2048;

/// The widest a picture declaring more than its limit of pixels is decoded: the widest the gallery decodes one.
const _maxCappedWidth = 4096;

/// The size to decode a picture of [width] by [height] at, within [maxPixels] and its proportions kept, no wider than
/// 4096; null when it is within the limit already (decoded as asked).
ui.TargetImageSize? cappedDecodeSize(int width, int height, {required int maxPixels}) {
  // Compared without multiplying: two sizes read from a file can overflow their product.
  if (width <= 0 || height <= 0 || width <= maxPixels ~/ height) {
    return null;
  }
  final scale = math.min(math.sqrt(maxPixels / (width.toDouble() * height)), _maxCappedWidth / width);
  final w = math.max(1, (width * scale).floor());
  final h = math.max(1, math.min((height * scale).floor(), maxPixels ~/ w));
  return ui.TargetImageSize(width: w, height: h);
}

/// What a picture is decoded at by a provider taking at most [maxPixels] (`CachedImageProvider`, its `getTargetSize`):
/// its own size within them, else [cappedDecodeSize].
ui.TargetImageSizeCallback decodeWithinPixels(int maxPixels) =>
    (width, height) => cappedDecodeSize(width, height, maxPixels: maxPixels) ?? const ui.TargetImageSize();

/// The size a picture of [width] by [height] is decoded at when a provider around it asks for [outer] (a resize to the
/// size it is shown at) and the provider inside takes [inner] at most ([decodeWithinPixels]): [outer], made smaller
/// still when the size it comes to is over what [inner] takes.
ui.TargetImageSize composeTargetSize(
  ui.TargetImageSize outer,
  int width,
  int height, {
  ui.TargetImageSizeCallback? inner,
}) {
  if (inner == null || width <= 0 || height <= 0) {
    return outer;
  }
  final (w, h) = switch ((outer.width, outer.height)) {
    (null, null) => (width, height),
    (final int w, null) => (w, math.max(1, (height * w / width).round())),
    (null, final int h) => (math.max(1, (width * h / height).round()), h),
    (final int w, final int h) => (w, h),
  };
  final bounded = inner(w, h);
  return bounded.width == null && bounded.height == null ? outer : bounded;
}

/// The size of the picture [bytes] holds, read from its header without decoding it; null when it is no picture the
/// engine knows.
Future<({int width, int height})?> encodedImageSize(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = (width: descriptor.width, height: descriptor.height);
    descriptor.dispose();
    return size;
  } on Exception {
    return null;
  } finally {
    buffer.dispose();
  }
}

/// The boxes of an AVIF holding the boxes [avifDeclaredSize] looks for, and how many bytes (version and flags) come
/// before their children.
const _containers = {'meta': 4, 'iprp': 0, 'ipco': 0, 'moov': 0, 'trak': 0};

/// The size an AVIF [bytes] declares: the largest of its `ispe` properties (an image, a grid, an alpha plane) and of
/// the `tkhd` of its tracks (an image sequence); null when it declares none or its boxes are broken.
///
/// The decoder of `flutter_avif` tells no size before it decodes (its `AvifInfo` width and height are always 0), so it
/// is read here, from the boxes only (not from bytes of the data looking like one).
({int width, int height})? avifDeclaredSize(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var width = 0;
  var height = 0;
  var broken = false;

  void walk(int start, int end, int depth) {
    var at = start;
    while (!broken && at + 8 <= end) {
      var size = data.getUint32(at);
      final type = String.fromCharCodes(bytes, at + 4, at + 8);
      var header = 8;
      if (size == 1) {
        if (at + 16 > end) {
          broken = true;
          return;
        }
        final large = data.getUint32(at + 8) * 0x100000000 + data.getUint32(at + 12);
        size = large > end - at ? -1 : large;
        header = 16;
      } else if (size == 0) {
        size = end - at;
      }
      if (size < header || at + size > end) {
        broken = true;
        return;
      }
      final boxEnd = at + size;
      final body = at + header;
      if (type == 'ispe' && body + 12 <= boxEnd) {
        width = math.max(width, data.getUint32(body + 4));
        height = math.max(height, data.getUint32(body + 8));
      } else if (type == 'tkhd' && body + 4 <= boxEnd) {
        // After the version and flags: the times, 8 reserved bytes, layer, group, volume, 2 reserved, the matrix.
        final extent = body + 4 + (bytes[body] == 1 ? 32 : 20) + 52;
        if (extent + 8 <= boxEnd) {
          width = math.max(width, data.getUint32(extent) >> 16);
          height = math.max(height, data.getUint32(extent + 4) >> 16);
        }
      } else if (_containers[type] case final skip? when depth < 8) {
        walk(body + skip, boxEnd, depth + 1);
      }
      at = boxEnd;
    }
  }

  walk(0, bytes.length, 0);
  if (width == 0 || height == 0) {
    return null;
  }
  return (width: width, height: height);
}

/// The first frame of the AVIF [bytes], decoded alone (the other frames of an animation are not).
Future<ui.Image> _firstAvifFrame(Uint8List bytes) async =>
    (await SingleFrameAvifCodec(bytes: bytes).getNextFrame()).image;

/// The AVIF [bytes] as a PNG of its first frame, the only one decoded ([firstFrame]); null when it declares more than
/// [maxPixels] ([avifDeclaredSize]) or no size, or the frame did not decode.
Future<Uint8List?> avifToPng(
  Uint8List bytes, {
  int maxPixels = maxDecodedImagePixels,
  Future<ui.Image> Function(Uint8List bytes)? firstFrame,
}) async {
  final size = avifDeclaredSize(bytes);
  // Compared without multiplying: the sizes of the file can overflow their product.
  if (size == null || size.width > maxPixels ~/ size.height) {
    return null;
  }
  final image = await (firstFrame ?? _firstAvifFrame)(bytes);
  try {
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    return png?.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
  } finally {
    image.dispose();
  }
}
