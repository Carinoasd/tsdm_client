import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tsdm_client/features/post/utils/pasted_image.dart';

/// The longest side an image is scaled down to before it is uploaded, 0 for the size it has.
const uploadImageMaxSides = [1280, 1920, 0];

/// The JPEG quality an edited image is written with when nothing else is chosen.
const defaultUploadImageQuality = 90;

/// One stroke of the mosaic brush: the [points] it went through and its [radius], both in fractions of the image
/// as it is shown (turned by [ImageEdits.quarterTurns], not cropped): x of the width, y of the height, the radius of
/// the shorter side.
@immutable
final class MosaicStroke {
  /// Constructor.
  const MosaicStroke(this.points, this.radius);

  /// Where the brush went.
  final List<Offset> points;

  /// Half the width of the brush.
  final double radius;

  /// The stroke on the image turned once more clockwise.
  MosaicStroke turned() => MosaicStroke([for (final p in points) _turnPoint(p)], radius);

  @override
  bool operator ==(Object other) => other is MosaicStroke && other.radius == radius && listEquals(other.points, points);

  @override
  int get hashCode => Object.hash(radius, Object.hashAll(points));
}

Offset _turnPoint(Offset p) => Offset(1 - p.dy, p.dx);

/// The crop [rect] (fractions of the shown image) on the image turned once more clockwise.
Rect turnCropRect(Rect rect) => Rect.fromPoints(_turnPoint(rect.topLeft), _turnPoint(rect.bottomRight));

/// What is done to an image before it goes up: turned [quarterTurns] times clockwise, the [strokes] pixelated, cut to
/// [crop], scaled down to [maxSide] at most and written with JPEG [quality] (an image with transparency stays PNG).
@immutable
final class ImageEdits {
  /// Constructor.
  const ImageEdits({
    this.quarterTurns = 0,
    this.crop,
    this.strokes = const [],
    this.maxSide = 0,
    this.quality = defaultUploadImageQuality,
  });

  /// Clockwise quarter turns.
  final int quarterTurns;

  /// The part kept, in fractions of the turned image; null for all of it.
  final Rect? crop;

  /// The mosaic brush strokes, on the turned image.
  final List<MosaicStroke> strokes;

  /// The longest side at most, in pixels; 0 for any.
  final int maxSide;

  /// The JPEG quality, 1 to 100.
  final int quality;

  /// Whether the picture itself changes (turned, cut or pixelated), whatever its size.
  bool get changesPicture => quarterTurns % 4 != 0 || crop != null || strokes.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ImageEdits &&
      other.quarterTurns == quarterTurns &&
      other.crop == crop &&
      listEquals(other.strokes, strokes) &&
      other.maxSide == maxSide &&
      other.quality == quality;

  @override
  int get hashCode => Object.hash(quarterTurns, crop, Object.hashAll(strokes), maxSide, quality);
}

/// An image written by [applyImageEdits].
@immutable
final class EditedImage {
  /// Constructor.
  const EditedImage(this.bytes, this.extension, {required this.width, required this.height});

  /// The file.
  final Uint8List bytes;

  /// `png` or `jpg`.
  final String extension;

  /// Size in pixels.
  final int width;

  /// Size in pixels.
  final int height;
}

/// The side of a mosaic cell on an image whose shorter side is [shorterSide] pixels: the same share of the picture
/// whatever its size, so the preview pixelates as the upload does.
int mosaicCellSize(int shorterSide) => math.max(4, (shorterSide / 40).round());

/// The image [source] with [edits] done, in the orientation its EXIF tells; null when nothing changes (no edit, not
/// larger than [ImageEdits.maxSide]: the file goes up as it is) or [source] is no image.
///
/// Synchronous and slow on a large photo: run it in another isolate.
EditedImage? applyImageEdits(Uint8List source, ImageEdits edits) {
  if (!edits.changesPicture && edits.maxSide <= 0) return null;
  img.Image? decoded;
  try {
    decoded = img.decodeImage(source);
  } on Object {
    decoded = null;
  }
  if (decoded == null) return null;
  final longest = math.max(decoded.width, decoded.height);
  final scales = edits.maxSide > 0 && longest > edits.maxSide;
  if (!edits.changesPicture && !scales) return null;
  var image = _edited(decoded, edits);
  if (edits.maxSide > 0) {
    image = _scaledDown(image, edits.maxSide);
  }
  // Written without the EXIF: the orientation is in the pixels now, and where the photo was taken stays home.
  image.exif = img.ExifData();
  if (_hasTransparency(image)) {
    return EditedImage(img.encodePng(image), 'png', width: image.width, height: image.height);
  }
  return EditedImage(
    img.encodeJpg(image, quality: edits.quality.clamp(1, 100)),
    'jpg',
    width: image.width,
    height: image.height,
  );
}

/// The picture of [source] turned, pixelated and cut as [edits] say, at its size; for the preview of the editor too.
img.Image _edited(img.Image source, ImageEdits edits) {
  // One frame (an animation is never edited), true colors, EXIF orientation applied.
  var image = img.Image.from(source, noAnimation: true);
  if (image.hasPalette) {
    image = image.convert(numChannels: image.numChannels);
  }
  image = img.bakeOrientation(image);
  final turns = edits.quarterTurns % 4;
  if (turns != 0) {
    image = img.copyRotate(image, angle: 90 * turns);
  }
  if (edits.strokes.isNotEmpty) {
    _pixelate(image, edits.strokes);
  }
  final crop = edits.crop;
  if (crop != null) {
    final left = (crop.left.clamp(0.0, 1.0) * image.width).round();
    final top = (crop.top.clamp(0.0, 1.0) * image.height).round();
    final right = (crop.right.clamp(0.0, 1.0) * image.width).round();
    final bottom = (crop.bottom.clamp(0.0, 1.0) * image.height).round();
    if (right - left >= 1 && bottom - top >= 1) {
      image = img.copyCrop(image, x: left, y: top, width: right - left, height: bottom - top);
    }
  }
  return image;
}

/// [source] turned and pixelated as [edits] say (not cut), scaled to [maxSide] at most, as PNG: what the editor shows.
/// Null when [source] is no image.
EditedImage? previewImageEdits(Uint8List source, ImageEdits edits, {required int maxSide}) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(source);
  } on Object {
    decoded = null;
  }
  if (decoded == null) return null;
  // Scaled before the strokes: the cells are a share of the picture, so they look the same as on the upload.
  final image = _edited(
    _scaledDown(img.bakeOrientation(img.Image.from(decoded, noAnimation: true)), maxSide),
    ImageEdits(quarterTurns: edits.quarterTurns, strokes: edits.strokes),
  );
  return EditedImage(img.encodePng(image, level: 1), 'png', width: image.width, height: image.height);
}

/// [image] with its longest side [maxSide] at most.
img.Image _scaledDown(img.Image image, int maxSide) {
  if (math.max(image.width, image.height) <= maxSide) return image;
  return image.width >= image.height
      ? img.copyResize(image, width: maxSide, interpolation: img.Interpolation.average)
      : img.copyResize(image, height: maxSide, interpolation: img.Interpolation.average);
}

/// Whether the image [bytes] has a side longer than [maxSide], told by its header; true when the header does not tell.
bool _largerThan(Uint8List bytes, int maxSide) {
  try {
    final info = img.findDecoderForData(bytes)?.startDecode(bytes);
    if (info == null || info.width <= 0 || info.height <= 0) return true;
    return math.max(info.width, info.height) > maxSide;
  } on Object {
    return true;
  }
}

/// Whether any pixel of [image] is not fully opaque.
bool _hasTransparency(img.Image image) {
  if (!image.hasAlpha) return false;
  final max = image.maxChannelValue;
  for (final pixel in image) {
    if (pixel.a < max) return true;
  }
  return false;
}

/// Fill every mosaic cell of [image] a stroke touches with the cell's average color.
void _pixelate(img.Image image, List<MosaicStroke> strokes) {
  final w = image.width;
  final h = image.height;
  final shorter = math.min(w, h);
  final cell = mosaicCellSize(shorter);
  final cols = (w / cell).ceil();
  final rows = (h / cell).ceil();
  final marked = Uint8List(cols * rows);
  for (final stroke in strokes) {
    // Half the diagonal of a cell added: the cell under any point of the way is always taken.
    final r = stroke.radius * shorter + cell * math.sqrt1_2;
    final points = [for (final p in stroke.points) Offset(p.dx * w, p.dy * h)];
    if (points.isEmpty) continue;
    final segments = points.length == 1
        ? [(points.first, points.first)]
        : [
            for (var i = 1; i < points.length; i++) (points[i - 1], points[i]),
          ];
    for (final (a, b) in segments) {
      final c0 = (math.max(0, math.min(a.dx, b.dx) - r) / cell).floor();
      final c1 = (math.min(w - 1, math.max(a.dx, b.dx) + r) / cell).floor();
      final r0 = (math.max(0, math.min(a.dy, b.dy) - r) / cell).floor();
      final r1 = (math.min(h - 1, math.max(a.dy, b.dy) + r) / cell).floor();
      for (var row = r0; row <= r1; row++) {
        for (var col = c0; col <= c1; col++) {
          final center = Offset((col + 0.5) * cell, (row + 0.5) * cell);
          if (_distanceToSegment(center, a, b) <= r) marked[row * cols + col] = 1;
        }
      }
    }
  }
  for (var row = 0; row < rows; row++) {
    for (var col = 0; col < cols; col++) {
      if (marked[row * cols + col] == 0) continue;
      final x0 = col * cell;
      final y0 = row * cell;
      final x1 = math.min(w, x0 + cell);
      final y1 = math.min(h, y0 + cell);
      num rs = 0;
      num gs = 0;
      num bs = 0;
      num as = 0;
      final n = (x1 - x0) * (y1 - y0);
      for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
          final p = image.getPixel(x, y);
          rs += p.r;
          gs += p.g;
          bs += p.b;
          as += p.a;
        }
      }
      final color = image.getColor(rs / n, gs / n, bs / n, as / n);
      img.fillRect(image, x1: x0, y1: y0, x2: x1 - 1, y2: y1 - 1, color: color, alphaBlend: false);
    }
  }
}

double _distanceToSegment(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final length2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (length2 == 0) return (p - a).distance;
  final t = (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / length2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

/// Whether [bytes] are an image the editor takes: not a GIF (its animation would be lost) and not unknown.
bool isEditableImage(List<int> bytes) {
  final ext = sniffImageExtension(bytes);
  return ext != null && ext != 'gif';
}

/// [file] with [edits] done ([applyImageEdits], in another isolate), written into [dir] as `<stem>.<ext>`: a
/// temporary file, [file] is left as it is. [file] itself when nothing changes, when it is no image the editor takes
/// ([isEditableImage]: a GIF goes up as it is) or when the forum does not take what it became ([accepts]).
Future<UploadImageFile> writeEditedImage(
  UploadImageFile file,
  ImageEdits edits, {
  required Directory dir,
  required String stem,
  required bool Function(String filename) accepts,
}) async {
  // The size it has and nothing done: not even read.
  if (!edits.changesPicture && edits.maxSide <= 0) return file;
  final bytes = await File(file.path).readAsBytes();
  if (!isEditableImage(bytes)) return file;
  if (!edits.changesPicture && !_largerThan(bytes, edits.maxSide)) return file;
  final edited = await Isolate.run(() => applyImageEdits(bytes, edits));
  if (edited == null) return file;
  final name = '$stem.${edited.extension}';
  if (!accepts(name)) return file;
  await dir.create(recursive: true);
  final out = File('${dir.path}${Platform.pathSeparator}$name');
  await out.writeAsBytes(edited.bytes, flush: true);
  return UploadImageFile(out.path, temporary: true);
}
