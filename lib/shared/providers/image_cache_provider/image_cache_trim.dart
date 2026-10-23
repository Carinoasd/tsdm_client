import 'dart:convert';
import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:tsdm_client/constants/url.dart';

/// What the automatic clean up of the image cache keeps ([planImageCacheTrim]), and how much one run of it deletes.
final class ImageCacheLimits {
  /// Constructor.
  const ImageCacheLimits({
    this.maxAge,
    this.maxEntries = defaultMaxEntries,
    this.maxBytes = defaultMaxBytes,
    this.maxDeletesPerRun = defaultMaxDeletesPerRun,
  });

  /// Images kept at most by default.
  static const defaultMaxEntries = 20000;

  /// Bytes of image files kept at most by default.
  static const int defaultMaxBytes = 512 * 1024 * 1024;

  /// Images and files one run deletes at most by default; a larger cache shrinks over the next starts.
  static const defaultMaxDeletesPerRun = 10000;

  /// Images and files one run deletes at most.
  final int maxDeletesPerRun;

  /// Images not shown for longer go, null to keep them whatever their age.
  final Duration? maxAge;

  /// Images kept at most, the least recently shown ones go first.
  final int maxEntries;

  /// Bytes of image files kept at most, the least recently shown ones go first.
  final int maxBytes;
}

/// A file of the image cache directory: its size in bytes and when it was last written (milliseconds since epoch).
typedef ImageCacheFileStat = ({int size, int modifiedMs});

/// One row of the image cache for the clean up: its url, its cache file and when it was last shown (milliseconds since
/// epoch).
typedef ImageCacheTrimRow = ({String url, String fileName, int lastUsedMs});

/// What [planImageCacheTrim] decided.
typedef ImageCacheTrimPlan = ({
  /// The rows to delete, the least recently used first.
  List<ImageCacheTrimRow> rows,

  /// Files of the directory no row names, old enough to be no image being saved right now.
  List<String> orphanFiles,

  /// Rows and bytes of the files before the clean up.
  int countBefore,
  int bytesBefore,

  /// Rows and bytes of their files kept.
  int countAfter,
  int bytesAfter,
});

/// What one clean up of the image cache did (`ImageCacheProvider.trimCache`): rows and bytes of the files before, rows
/// and files deleted, and whether more is left for the next run (it stopped at [ImageCacheLimits.maxDeletesPerRun]).
typedef ImageCacheTrimResult = ({int countBefore, int bytesBefore, int deletedRows, int deletedFiles, bool more});

/// The key an image url is recognised by in a saved page ([imageKeysOfPage]): the last part of its path with its query,
/// without the fragment.
///
/// A page names its pictures in many ways: a full url, a path relative to the forum ("data/attachment/forum/…",
/// "forum.php?mod=attachment&aid=…"), on another host of the forum, in an attribute (`zoomfile`, `file`, `src`…) or a
/// field of a JSON answer, while the cache knows the url the app built from one of them. Their last part is the same:
/// the file name of an attachment is a random hash, an attachment link carries its own `aid` token. The path is cut at
/// its last `/` or `=` the same way on both sides (an attribute without quotes, `src=forum.php?…`), and decoded the
/// same way on both sides: character references (`&amp;`, `&#x26;`) and percent-encoding.
String imageCacheKeyOf(String url) {
  var s = _decodeUrl(url.trim());
  final hash = s.indexOf('#');
  if (hash >= 0) {
    s = s.substring(0, hash);
  }
  final q = s.indexOf('?');
  final path = q >= 0 ? s.substring(0, q) : s;
  final start = (path.lastIndexOf('/') > path.lastIndexOf('=') ? path.lastIndexOf('/') : path.lastIndexOf('=')) + 1;
  return s.substring(start);
}

final _charRefRe = RegExp('&(?:#[xX]([0-9a-fA-F]+)|#([0-9]+)|amp);');

/// [url] with its character references and percent-encoding decoded (kept as it is when that is not valid).
String _decodeUrl(String url) {
  var s = url.contains('&')
      ? url.replaceAllMapped(_charRefRe, (m) {
          final code = m[1] != null ? int.tryParse(m[1]!, radix: 16) : (m[2] != null ? int.tryParse(m[2]!) : 0x26);
          return code == null || code > 0x10FFFF ? m[0]! : String.fromCharCode(code);
        })
      : url;
  if (s.contains('%')) {
    // Runs of percent-encoded bytes as UTF-8 (a broken sequence decodes to U+FFFD, never throws).
    s = s.replaceAllMapped(_percentRunRe, (m) {
      final bytes = [for (final h in m[0]!.split('%').skip(1)) int.parse(h, radix: 16)];
      return utf8.decode(bytes, allowMalformed: true);
    });
  }
  return s;
}

final _percentRunRe = RegExp('(?:%[0-9a-fA-F]{2})+');

/// The whole value of an image attribute, spaces included: `src="…"`, `file='…'`, `zoomfile=\"…\"` in a JSON answer.
final _imageAttributeRe = RegExp(
  r'''(?:src|file|zoomfile|data-src|data-original)\s*=\s*\\?(["'])(.+?)\\?\1''',
);

/// Characters that end a url in a page: quotes, spaces, brackets and the escapes of a JSON string.
final _pageUrlSeparators = RegExp(r'''[\s"'<>\\()\[\]{}|^`]+''');

/// An author named by a JSON answer, `"authorid":"7"` or `"authorid":7`.
final _authorIdRe = RegExp(r'"authorid"\s*:\s*"?(\d+)');

/// Keys ([imageCacheKeyOf]) of every url and path the saved thread page [body] names: a web page or a JSON answer of
/// the forum's app API, as the offline thread pages keep it.
///
/// More than the pictures (every link is there too), so that no picture of the page is missed: an image of the cache
/// whose key is among them is kept. The avatar the app builds from an author's uid ([avatarUrlOfUid]) is added for
/// every author the page names.
Set<String> imageKeysOfPage(String body) {
  final text = body
      .replaceAll(r'\/', '/')
      .replaceAll(r'\u0026', '&')
      .replaceAll('&amp;', '&')
      .replaceAll('&#38;', '&')
      .replaceAll('&#038;', '&');
  final keys = <String>{};
  for (final m in _imageAttributeRe.allMatches(text)) {
    final key = imageCacheKeyOf(m[2]!);
    if (key.isNotEmpty) {
      keys.add(key);
    }
  }
  for (final token in text.split(_pageUrlSeparators)) {
    if (token.length < 3 || (!token.contains('/') && !token.contains('?'))) {
      continue;
    }
    final key = imageCacheKeyOf(token);
    if (key.isNotEmpty) {
      keys.add(key);
    }
  }
  for (final m in _authorIdRe.allMatches(text)) {
    final avatar = avatarUrlOfUid(m[1]);
    if (avatar != null) {
      keys.add(imageCacheKeyOf(avatar));
    }
  }
  return keys;
}

/// [imageKeysOfPage] of every page of [bodies] together.
Set<String> imageKeysOfPages(List<String> bodies) => {for (final body in bodies) ...imageKeysOfPage(body)};

/// Every file of the image cache directory at [path] with its size and time (an empty map when there is none).
Map<String, ImageCacheFileStat> listImageCacheFiles(String path) {
  final dir = Directory(path);
  if (!dir.existsSync()) {
    return {};
  }
  final files = <String, ImageCacheFileStat>{};
  for (final entity in dir.listSync(followLinks: false)) {
    if (entity is! File) {
      continue;
    }
    try {
      final stat = entity.statSync();
      files[entity.uri.pathSegments.last] = (size: stat.size, modifiedMs: stat.modified.millisecondsSinceEpoch);
    } on FileSystemException catch (_) {
      // Gone meanwhile: nothing to count.
    }
  }
  return files;
}

/// Delete the files [names] of the image cache directory at [path]; returns how many were deleted.
int deleteImageCacheFiles(String path, List<String> names) {
  var deleted = 0;
  for (final name in names) {
    // Names come from the database and the listing of the directory; never a path out of it.
    if (name.isEmpty || name.contains('/') || name.contains(r'\') || name == '.' || name == '..') {
      continue;
    }
    final file = File('$path${Platform.pathSeparator}$name');
    try {
      if (file.existsSync()) {
        file.deleteSync();
        deleted++;
      }
    } on FileSystemException catch (_) {
      // Best effort: the next clean up finds it again.
    }
  }
  return deleted;
}

/// Decide what the clean up of the image cache deletes.
///
/// [rows] are the rows of the table, [files] the files of the cache directory ([listImageCacheFiles]). The images that
/// must stay ([keptUrls], [keptFiles], and any whose key [imageCacheKeyOf] is in [keptKeys]: the image stickers, the
/// avatars of the saved accounts, the pictures of the offline thread pages) are kept first, whatever their age, and
/// count against the limits; then the others, from the most recently shown one, while they fit in [maxEntries] and
/// [maxBytes] and were shown within [maxAgeMs] (any time when null). Everything else goes, the least recently shown
/// first: the rows past the limits or the age, and rows whose file is gone (nothing would show them). Files no row
/// names (left by a write that never finished, a restored backup) go too, when older than [orphanGraceMs]: a younger
/// one may be an image being saved right now.
ImageCacheTrimPlan planImageCacheTrim({
  required List<ImageCacheTrimRow> rows,
  required Map<String, ImageCacheFileStat> files,
  required Set<String> keptUrls,
  required Set<String> keptFiles,
  required Set<String> keptKeys,
  required int nowMs,
  required int? maxAgeMs,
  required int maxEntries,
  required int maxBytes,
  int orphanGraceMs = 60 * 60 * 1000,
}) {
  bool mustStay(ImageCacheTrimRow row) =>
      keptUrls.contains(row.url) ||
      keptFiles.contains(row.fileName) ||
      (keptKeys.isNotEmpty && keptKeys.contains(imageCacheKeyOf(row.url)));

  final byRecency = [...rows]
    ..sort((a, b) {
      final c = b.lastUsedMs.compareTo(a.lastUsedMs);
      return c != 0 ? c : a.url.compareTo(b.url);
    });
  final keep = List<bool>.filled(byRecency.length, false);
  var count = 0;
  var bytes = 0;
  for (final (i, row) in byRecency.indexed) {
    final file = files[row.fileName];
    if (file != null && mustStay(row)) {
      keep[i] = true;
      count++;
      bytes += file.size;
    }
  }
  final oldestKept = maxAgeMs == null ? null : nowMs - maxAgeMs;
  var full = false;
  for (final (i, row) in byRecency.indexed) {
    final file = files[row.fileName];
    if (keep[i] || file == null || full) {
      continue;
    }
    if (oldestKept != null && row.lastUsedMs <= oldestKept) {
      // Older ones follow: none of them is kept either.
      break;
    }
    if (count >= maxEntries || bytes + file.size > maxBytes) {
      full = true;
      continue;
    }
    keep[i] = true;
    count++;
    bytes += file.size;
  }

  final named = {for (final row in rows) row.fileName};
  final orphans = [
    for (final MapEntry(key: name, value: file) in files.entries)
      if (!named.contains(name) && file.modifiedMs < nowMs - orphanGraceMs) name,
  ];
  var bytesBefore = 0;
  for (final file in files.values) {
    bytesBefore += file.size;
  }
  return (
    rows: [
      for (var i = byRecency.length - 1; i >= 0; i--)
        if (!keep[i]) byRecency[i],
    ],
    orphanFiles: orphans,
    countBefore: rows.length,
    bytesBefore: bytesBefore,
    countAfter: count,
    bytesAfter: bytes,
  );
}
