import 'dart:typed_data';

/// The file extension of the image [data] as told by its first bytes (the type the server sent: the cache keeps the
/// bytes, not the content type; an AVIF image is cached as PNG), null when it is none the app knows.
String? imageExtensionOf(Uint8List data) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (data.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (data[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'jpg';
  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'png';
  // GIF87a, GIF89a.
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'gif';
  // RIFF....WEBP
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) && startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) return 'webp';
  if (startsWith(const [0x42, 0x4D])) return 'bmp';
  // ....ftypavif / ftypavis
  if (startsWith(const [0x66, 0x74, 0x79, 0x70, 0x61, 0x76, 0x69], 4)) return 'avif';
  return null;
}

/// Extensions taken as the same type as the one of the bytes.
const _sameExtensions = {
  'jpg': {'jpg', 'jpeg', 'jpe', 'jfif'},
  'png': {'png'},
  'gif': {'gif'},
  'webp': {'webp'},
  'bmp': {'bmp'},
  'avif': {'avif'},
};

/// Name to save the image [data] loaded from [url] under.
///
/// The last segment of the url's path, with the extension of the type the bytes are: an attachment (`forum.php?
/// mod=attachment&aid=…`) was saved as "forum.php", an image served under a wrong extension kept it, and a file
/// without an extension opened with no app. A segment that is a script (`.php`) or empty gives a name of its own
/// ([now] in microseconds). An unknown type keeps the url's extension, or `.jpg` when it has none.
String imageFileNameOf(String url, Uint8List data, {DateTime? now}) {
  final fallbackBase = 'tsdm_client_image_${(now ?? DateTime.now()).microsecondsSinceEpoch}';
  final segment = Uri.tryParse(url)?.pathSegments.where((e) => e.isNotEmpty).lastOrNull ?? '';
  final dot = segment.lastIndexOf('.');
  final urlBase = dot > 0 ? segment.substring(0, dot) : segment;
  final urlExtension = dot > 0 ? segment.substring(dot + 1).toLowerCase() : '';
  final script = const {'php', 'asp', 'aspx', 'jsp', 'cgi', 'html', 'htm'}.contains(urlExtension);
  final base = urlBase.isEmpty || script ? fallbackBase : urlBase;
  final dataExtension = imageExtensionOf(data);
  if (dataExtension == null) {
    return '$base.${urlExtension.isEmpty || script ? 'jpg' : urlExtension}';
  }
  if (_sameExtensions[dataExtension]!.contains(urlExtension)) {
    return '$base.$urlExtension';
  }
  return '$base.$dataExtension';
}
