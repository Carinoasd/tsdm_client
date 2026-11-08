import 'dart:io';
import 'dart:isolate';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show immutable, visibleForTesting;
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:tsdm_client/features/update/repository/release_update_repository.dart';

/// Where the font of the PDF can be had: an exact file, known by its size and SHA-256.
@immutable
final class PdfFontSource {
  /// Constructor.
  const PdfFontSource({required this.url, required this.size, required this.sha256});

  /// Download url.
  final String url;

  /// Size of the file in bytes.
  final int size;

  /// Lowercase hex SHA-256 of the file.
  final String sha256;
}

/// The name of the font file kept on the device.
const pdfFontFileName = 'NotoSansSC-Regular.ttf';

/// Where the font of the PDF (Noto Sans SC Regular, SIL Open Font License 1.1) is downloaded from, in order.
///
/// It is not bundled with the app: about 10 MB that only the PDF export needs. The pdf package reads TrueType
/// outlines (`glyf`) of a static font only: the font of the Google Fonts repository is a variable one (drawn at its
/// default weight, Thin, by the package) and the font of the Noto CJK repository has CFF outlines, so the static
/// TrueType instance of Google Fonts is taken from repositories that keep it in Git LFS, each at a fixed commit.
/// `raw.githubusercontent.com` serves a file of LFS as its pointer: `media.githubusercontent.com` serves the file.
/// The first source is the same file kept as an asset of a release of this repository (tag `assets-fonts-1`, not an
/// app version): the others are the places it was taken from, in case ours is unreachable.
const pdfFontSources = [
  PdfFontSource(
    url: 'https://github.com/Carinoasd/tsdm_client/releases/download/assets-fonts-1/NotoSansSC-Regular.ttf',
    size: 10560076,
    sha256: 'dc71173babc38dfd019912965f2b4b3421fb347ebd854e7b96f64ad63673924a',
  ),
  PdfFontSource(
    url:
        'https://media.githubusercontent.com/media/SixLabors/Fonts/17de1119b61c05a91dddbb4484f3f36a32b1d464/'
        'tests/Fonts/NotoSansSC-Regular.ttf',
    size: 10560076,
    sha256: 'dc71173babc38dfd019912965f2b4b3421fb347ebd854e7b96f64ad63673924a',
  ),
  PdfFontSource(
    url:
        'https://media.githubusercontent.com/media/open-pencil/open-pencil/0d1f42f0b1b2112b283fae8f85b6e1c7c4e81adf/'
        'tests/fixtures/fonts/NotoSansSC-Regular.ttf',
    size: 10540644,
    sha256: '450625c8d46ab3df97b7904ded955ec2746d17ec76740cb1e91d1ba63a0f89af',
  ),
];

/// The font could not be had from any source.
final class PdfFontUnavailableException implements Exception {
  /// Constructor.
  const PdfFontUnavailableException();
}

/// Keeps the font of the PDF export in the app's own files, downloaded the first time it is needed.
///
/// Uses a Dio client of its own: the forum's cookies are never sent to another site.
final class PdfFontRepository {
  /// [dio], [directory] and [sources] are given in tests.
  PdfFontRepository({Dio? dio, Future<Directory> Function()? directory, List<PdfFontSource> sources = pdfFontSources})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 20),
              receiveTimeout: const Duration(seconds: 60),
            ),
          ),
      _directory = directory ?? _defaultDirectory,
      _sources = sources;

  final Dio _dio;
  final Future<Directory> Function() _directory;
  final List<PdfFontSource> _sources;

  static Future<Directory> _defaultDirectory() async =>
      Directory(path.join((await getApplicationSupportDirectory()).path, 'fonts'));

  Future<File> _file() async => File(path.join((await _directory()).path, pdfFontFileName));

  /// The font file when it is on the device already.
  ///
  /// Only its size is checked: it was hashed when it was downloaded.
  Future<File?> cached() async {
    final file = await _file();
    if (!file.existsSync()) {
      return null;
    }
    final length = await file.length();
    return _sources.any((s) => s.size == length) ? file : null;
  }

  /// The font file, downloaded when it is not on the device yet.
  ///
  /// [onProgress] is told the bytes received of the total. Throws [PdfFontUnavailableException] when no source gave
  /// the right file, and the [DioException] of a cancellation through [cancelToken].
  Future<File> obtain({CancelToken? cancelToken, void Function(int received, int total)? onProgress}) async {
    final cached = await this.cached();
    if (cached != null) {
      return cached;
    }
    final file = await _file();
    await file.parent.create(recursive: true);
    final part = File('${file.path}.part');
    for (final source in _sources) {
      try {
        if (part.existsSync()) {
          await part.delete();
        }
        await _dio.download(
          source.url,
          part.path,
          cancelToken: cancelToken,
          onReceiveProgress: onProgress == null
              ? null
              : (received, total) => onProgress(received, total > 0 ? total : source.size),
        );
        if (await verifyFontFile(part, source)) {
          return await part.rename(file.path);
        }
      } on DioException catch (e) {
        if (CancelToken.isCancel(e)) {
          await _deleteQuietly(part);
          rethrow;
        }
      } on FileSystemException {
        // The next source.
      }
    }
    await _deleteQuietly(part);
    throw const PdfFontUnavailableException();
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (file.existsSync()) {
        await file.delete();
      }
    } on FileSystemException {
      // Nothing more to do.
    }
  }
}

/// Whether [file] is exactly the file of [source] (hashed off the UI isolate).
@visibleForTesting
Future<bool> verifyFontFile(File file, PdfFontSource source) async {
  if (!file.existsSync() || await file.length() != source.size) {
    return false;
  }
  final filePath = file.path;
  final size = source.size;
  final digest = await Isolate.run(() => ReleaseUpdateRepository.hashFile(filePath, size));
  return digest == source.sha256;
}
