import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';
import 'package:tsdm_client/utils/platform.dart';

/// An image file to upload as an attachment of the post being written.
///
/// A [temporary] file was written by the app (a pasted image, a converted copy, a shared image) and is deleted once
/// it went up or failed; any other is the member's own file (dropped, copied in the file manager) and is kept.
@immutable
final class UploadImageFile {
  /// Constructor.
  const UploadImageFile(this.path, {required this.temporary});

  /// Where the file is.
  final String path;

  /// Whether the app wrote the file and deletes it after the upload.
  final bool temporary;

  @override
  bool operator ==(Object other) => other is UploadImageFile && other.path == path && other.temporary == temporary;

  @override
  int get hashCode => Object.hash(path, temporary);

  @override
  String toString() => 'UploadImageFile($path, temporary: $temporary)';
}

/// The image extensions read from a file name: what may be dropped or copied in to upload.
const imageFileExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};

/// Whether [path] names an image file by its extension ([imageFileExtensions]).
bool isImageFilePath(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  final dot = name.lastIndexOf('.');
  return dot > 0 && imageFileExtensions.contains(name.substring(dot + 1).toLowerCase());
}

/// The extension of the image format [bytes] are in, by their first bytes: `png`, `jpg`, `gif`, `webp`, `bmp`; null
/// for anything else.
String? sniffImageExtension(List<int> bytes) {
  bool startsWith(List<int> magic, [int offset = 0]) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (startsWith(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) return 'png';
  if (startsWith(const [0xFF, 0xD8, 0xFF])) return 'jpg';
  if (startsWith(const [0x47, 0x49, 0x46, 0x38])) return 'gif';
  if (startsWith(const [0x52, 0x49, 0x46, 0x46]) && startsWith(const [0x57, 0x45, 0x42, 0x50], 8)) return 'webp';
  if (startsWith(const [0x42, 0x4D])) return 'bmp';
  return null;
}

/// [bytes] of an image the forum does not take as they are (a bitmap from the Windows clipboard, a WebP), as a PNG;
/// null when they are no image the `image` package reads. Run off the UI isolate by [writeUploadImage].
Uint8List? convertToPng(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    return decoded == null ? null : img.encodePng(decoded);
  } on Object {
    // The decoders guessing at short or broken data throw instead of answering null.
    return null;
  }
}

/// Write [bytes] of a pasted image into [dir] as `<stem>.<ext>` for the upload: the format they are in when the forum
/// takes it ([accepts] tells by a file name), else converted to PNG ([convertToPng], in another isolate). Null when
/// they are no image, or one the forum takes in neither form.
Future<UploadImageFile?> writeUploadImage(
  Uint8List bytes, {
  required Directory dir,
  required String stem,
  required bool Function(String filename) accepts,
}) async {
  final ext = sniffImageExtension(bytes);
  var data = bytes;
  var name = '$stem.$ext';
  if (ext == null || !accepts(name)) {
    name = '$stem.png';
    if (!accepts(name)) return null;
    final converted = await Isolate.run(() => convertToPng(bytes));
    if (converted == null) return null;
    data = converted;
  }
  await dir.create(recursive: true);
  final file = File('${dir.path}${Platform.pathSeparator}$name');
  await file.writeAsBytes(data, flush: true);
  return UploadImageFile(file.path, temporary: true);
}

/// The image file at [path] (dropped, copied in the file manager) ready to upload: the file itself when the forum
/// takes its type ([accepts]), else a PNG copy in [dir] named `<stem>.png` ([writeUploadImage]). Null when it is
/// unreadable or no image.
Future<UploadImageFile?> prepareImageFile(
  String path, {
  required Directory dir,
  required String stem,
  required bool Function(String filename) accepts,
}) async {
  final name = path.split(RegExp(r'[/\\]')).last;
  if (accepts(name)) return UploadImageFile(path, temporary: false);
  final Uint8List bytes;
  try {
    bytes = await File(path).readAsBytes();
  } on Object {
    return null;
  }
  return writeUploadImage(bytes, dir: dir, stem: stem, accepts: accepts);
}

/// What a paste in the post editor takes from the clipboard instead of text.
sealed class ClipboardImages {
  const ClipboardImages();
}

/// Image files copied in the file manager (desktop): the member's own files.
final class ClipboardImagePaths extends ClipboardImages {
  /// Constructor.
  const ClipboardImagePaths(this.paths);

  /// The files, all images ([isImageFilePath]).
  final List<String> paths;
}

/// An image copied as such (a screenshot, "copy image" in a browser or a viewer).
final class ClipboardImageBytes extends ClipboardImages {
  /// Constructor.
  const ClipboardImageBytes(this.bytes);

  /// The image data, in whatever format the platform gives it.
  final Uint8List bytes;
}

/// Reads the clipboard for a paste in the post editor.
///
/// Text wins: a clipboard with text (alone, or beside a picture as office programs copy cells) pastes the text as
/// before. Files copied in the file manager are taken when all of them are images; with any other file among them the
/// paste is left to the editor. A picture is taken only without text. The readers are injectable for tests; each one
/// failing counts as nothing there.
final class ClipboardImageReader {
  /// Constructor.
  const ClipboardImageReader({required this.readText, required this.readFiles, required this.readImage});

  /// The clipboard of the platform: text through Flutter, files (desktop only) and the picture through `pasteboard`.
  factory ClipboardImageReader.platform() => ClipboardImageReader(
    readText: () async => (await Clipboard.getData(Clipboard.kTextPlain))?.text,
    // On Android the "files" are content uris of any clip item, not paths.
    readFiles: isDesktop ? Pasteboard.files : () async => const <String>[],
    readImage: () => Pasteboard.image,
  );

  /// The plain text on the clipboard.
  final Future<String?> Function() readText;

  /// The paths of files copied in the file manager.
  final Future<List<String>> Function() readFiles;

  /// The picture on the clipboard.
  final Future<Uint8List?> Function() readImage;

  static Future<T?> _safe<T>(Future<T> Function() read) async {
    try {
      return await read();
    } on Object {
      return null;
    }
  }

  /// The images to upload instead of pasting, null when the paste is the editor's (text, other files, nothing).
  Future<ClipboardImages?> read() async {
    final files = await _safe(readFiles) ?? const <String>[];
    if (files.isNotEmpty) {
      return files.every(isImageFilePath) ? ClipboardImagePaths(List.of(files)) : null;
    }
    final text = await _safe(readText);
    if (text != null && text.trim().isNotEmpty) return null;
    final bytes = await _safe(readImage);
    if (bytes == null || bytes.isEmpty) return null;
    return ClipboardImageBytes(bytes);
  }
}
