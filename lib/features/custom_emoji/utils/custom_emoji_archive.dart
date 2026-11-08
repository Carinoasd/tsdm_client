import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:tsdm_client/features/custom_emoji/models/custom_emoji.dart';
import 'package:tsdm_client/features/custom_emoji/utils/custom_emoji_image.dart';

/// What the `manifest.json` of an exported archive says it is.
const customEmojiArchiveFormat = 'tsdm_client.emoji_packs';

/// Version of the archive.
const customEmojiArchiveVersion = 1;

/// The largest image read from an archive, in bytes.
const int customEmojiArchiveMaxImageBytes = 8 * 1024 * 1024;

/// The largest archive read, in bytes.
const int customEmojiArchiveMaxBytes = 200 * 1024 * 1024;

/// The largest `manifest.json` read, in bytes.
const int _maxManifestBytes = 4 * 1024 * 1024;

/// The most bytes of images read from an archive, all together (decompressed).
const int customEmojiArchiveMaxTotalBytes = 256 * 1024 * 1024;

/// At most this many images are read from an archive.
const customEmojiArchiveMaxImages = 5000;

final RegExp _imageNameRe = RegExp(r'^[0-9a-f]{64}\.(png|jpg|gif)$');

/// Thrown by [_LimitedOutput] past its limit.
final class _TooLarge implements Exception {
  const _TooLarge();
}

/// Decompressed bytes up to [limit]: the sizes an archive declares are not trusted.
final class _LimitedOutput extends OutputMemoryStream {
  _LimitedOutput(this.limit);

  final int limit;

  void _check(int n) {
    if (length + n > limit) throw const _TooLarge();
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }
}

/// The content of [file], null when it is (or decompresses to) more than [limit] bytes or cannot be read.
Uint8List? _readLimited(ArchiveFile file, int limit) {
  if (file.size > limit) return null;
  try {
    final output = _LimitedOutput(limit);
    file.writeContent(output);
    return output.getBytes();
  } on Object {
    return null;
  }
}

/// A pack read from an archive: its name and its images with their bytes, in order.
final class ArchivedCustomEmojiPack {
  /// Constructor.
  const ArchivedCustomEmojiPack({required this.name, required this.emojis});

  /// The name.
  final String name;

  /// The images and their bytes.
  final List<(CustomEmoji, Uint8List)> emojis;
}

/// A zip of [packs]: `manifest.json` (the packs' names and their images, in order) and every image once, as
/// `images/<sha256>.<ext>`. [bytesOf] reads the saved bytes of an image, null when they are gone (that one is left
/// out).
Uint8List encodeCustomEmojiArchive(List<CustomEmojiPack> packs, Uint8List? Function(CustomEmoji emoji) bytesOf) {
  final archive = Archive();
  final written = <String>{};
  final manifestPacks = <Map<String, Object>>[];
  for (final pack in packs) {
    final names = <String>[];
    for (final emoji in pack.emojis) {
      if (!written.contains(emoji.fileName)) {
        final bytes = bytesOf(emoji);
        if (bytes == null) {
          continue;
        }
        archive.addFile(ArchiveFile.bytes('images/${emoji.fileName}', bytes));
        written.add(emoji.fileName);
      }
      names.add(emoji.fileName);
    }
    manifestPacks.add({'name': pack.name, 'emojis': names});
  }
  final manifest = {'format': customEmojiArchiveFormat, 'v': customEmojiArchiveVersion, 'packs': manifestPacks};
  archive.addFile(ArchiveFile.bytes('manifest.json', utf8.encode(jsonEncode(manifest))));
  return ZipEncoder().encodeBytes(archive);
}

/// The packs of an archive [encodeCustomEmojiArchive] wrote, null when [bytes] is no such archive.
///
/// Nothing in it is trusted: only `manifest.json` and the entries named exactly `images/<sha256>.<ext>` are read; an
/// image larger than [customEmojiArchiveMaxImageBytes] (decompressed, whatever the archive declares), past
/// [customEmojiArchiveMaxTotalBytes] of images, whose bytes are not of its name (hash, format) or past the
/// first [customEmojiArchiveMaxImages] is left out, as is a name of the manifest no entry has.
List<ArchivedCustomEmojiPack>? decodeCustomEmojiArchive(Uint8List bytes) {
  if (bytes.length > customEmojiArchiveMaxBytes) return null;
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } on Object {
    return null;
  }
  final entries = <String, ArchiveFile>{};
  for (final file in archive.files) {
    if (file.isFile) {
      entries[file.name] = file;
    }
  }
  final Object? manifest;
  try {
    final file = entries['manifest.json'];
    final data = file == null ? null : _readLimited(file, _maxManifestBytes);
    if (data == null) {
      return null;
    }
    manifest = jsonDecode(utf8.decode(data));
  } on Object {
    return null;
  }
  if (manifest is! Map || manifest['format'] != customEmojiArchiveFormat || manifest['packs'] is! List) {
    return null;
  }
  final v = manifest['v'];
  if (v is! int || v > customEmojiArchiveVersion) {
    return null;
  }
  // Each image checked once, however many packs list it.
  final checked = <String, Uint8List?>{};
  var total = 0;
  Uint8List? imageOf(String name) => checked.putIfAbsent(name, () {
    if (!_imageNameRe.hasMatch(name) || checked.length >= customEmojiArchiveMaxImages) {
      return null;
    }
    final file = entries['images/$name'];
    final left = customEmojiArchiveMaxTotalBytes - total;
    final data = file == null || left <= 0
        ? null
        : _readLimited(file, left < customEmojiArchiveMaxImageBytes ? left : customEmojiArchiveMaxImageBytes);
    if (data == null) {
      return null;
    }
    final dot = name.indexOf('.');
    if (customEmojiFormatOf(data) != name.substring(dot + 1) || sha256Hex(data) != name.substring(0, dot)) {
      return null;
    }
    total += data.length;
    return data;
  });

  final packs = <ArchivedCustomEmojiPack>[];
  for (final pack in manifest['packs'] as List) {
    if (pack is! Map || pack['name'] is! String || pack['emojis'] is! List) {
      continue;
    }
    final emojis = <(CustomEmoji, Uint8List)>[];
    for (final name in pack['emojis'] as List) {
      if (name is! String || emojis.any((e) => e.$1.fileName == name)) {
        continue;
      }
      final data = imageOf(name);
      if (data == null) {
        continue;
      }
      final dot = name.indexOf('.');
      emojis.add((CustomEmoji(sha256: name.substring(0, dot), ext: name.substring(dot + 1)), data));
    }
    packs.add(ArchivedCustomEmojiPack(name: (pack['name'] as String).trim(), emojis: emojis));
  }
  return packs;
}
