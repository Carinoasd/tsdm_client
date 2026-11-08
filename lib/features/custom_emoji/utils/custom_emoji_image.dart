import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';
import 'package:image/image.dart' as img;
import 'package:tsdm_client/features/custom_emoji/models/custom_emoji.dart';

/// The longest side of a saved pack image; a larger one is scaled down to it.
const customEmojiMaxSide = 512;

/// An image ready to be saved in a pack.
final class PreparedCustomEmoji {
  /// Constructor.
  const PreparedCustomEmoji({required this.bytes, required this.ext, required this.sha256});

  /// What is saved.
  final Uint8List bytes;

  /// One of [customEmojiExts].
  final String ext;

  /// SHA-256 of [bytes], lower case hex.
  final String sha256;

  /// The emoji of the saved file.
  CustomEmoji get emoji => CustomEmoji(sha256: sha256, ext: ext);
}

/// The lower case hex SHA-256 of [bytes].
String sha256Hex(List<int> bytes) =>
    const DartSha256().hashSync(bytes).bytes.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

/// The format of the image in [bytes] by its first bytes, one of [customEmojiExts]; null for any other.
String? customEmojiFormatOf(List<int> bytes) {
  bool starts(List<int> magic) {
    if (bytes.length < magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  if (starts(ascii.encode('GIF87a')) || starts(ascii.encode('GIF89a'))) return 'gif';
  if (starts(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'png';
  if (starts(const [0xFF, 0xD8, 0xFF])) return 'jpg';
  return null;
}

/// The image in [bytes] as a pack keeps it, null when it is no image this can read.
///
/// A GIF is kept as it is (its frames); a PNG or JPEG whose longest side is at most [customEmojiMaxSide] too. A
/// larger one is scaled down to that side in its own format; any other format the decoder reads (WebP, BMP…) becomes a
/// PNG, scaled down as well when larger: the forum takes JPEG, PNG and GIF images only.
///
/// Synchronous and slow on large images: run it in an isolate.
PreparedCustomEmoji? prepareCustomEmoji(Uint8List bytes) {
  final format = customEmojiFormatOf(bytes);
  if (format == 'gif') {
    return PreparedCustomEmoji(bytes: bytes, ext: 'gif', sha256: sha256Hex(bytes));
  }
  final img.Image? image;
  try {
    image = img.decodeImage(bytes);
  } on Object {
    return null;
  }
  if (image == null || image.width <= 0 || image.height <= 0) {
    return null;
  }
  final large = image.width > customEmojiMaxSide || image.height > customEmojiMaxSide;
  if (!large && format != null) {
    return PreparedCustomEmoji(bytes: bytes, ext: format, sha256: sha256Hex(bytes));
  }
  var out = image;
  if (large) {
    out = image.width >= image.height
        ? img.copyResize(image, width: customEmojiMaxSide, interpolation: img.Interpolation.average)
        : img.copyResize(image, height: customEmojiMaxSide, interpolation: img.Interpolation.average);
  }
  final ext = format == 'jpg' ? 'jpg' : 'png';
  final encoded = ext == 'jpg' ? img.encodeJpg(out, quality: 90) : img.encodePng(out);
  return PreparedCustomEmoji(bytes: encoded, ext: ext, sha256: sha256Hex(encoded));
}
