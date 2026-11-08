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

/// At most this many images are read from an archive.
const customEmojiArchiveMaxImages = 5000;

final RegExp _imageNameRe = RegExp(r'^[0-9a-f]{64}\.(png|jpg|gif)$');

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
/// image larger than [customEmojiArchiveMaxImageBytes], whose bytes are not of its name (hash, format) or past the
/// first [customEmojiArchiveMaxImages] is left out, as is a name of the manifest no entry has.
List<ArchivedCustomEmojiPack>? decodeCustomEmojiArchive(Uint8List bytes) {
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
    if (file == null || file.size > 4 * 1024 * 1024) {
      return null;
    }
    manifest = jsonDecode(utf8.decode(file.content));
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
  Uint8List? imageOf(String name) => checked.putIfAbsent(name, () {
    if (!_imageNameRe.hasMatch(name) || checked.length >= customEmojiArchiveMaxImages) {
      return null;
    }
    final file = entries['images/$name'];
    if (file == null || file.size > customEmojiArchiveMaxImageBytes) {
      return null;
    }
    final Uint8List data;
    try {
      data = file.content;
    } on Object {
      return null;
    }
    final dot = name.indexOf('.');
    if (data.length > customEmojiArchiveMaxImageBytes ||
        customEmojiFormatOf(data) != name.substring(dot + 1) ||
        sha256Hex(data) != name.substring(0, dot)) {
      return null;
    }
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
