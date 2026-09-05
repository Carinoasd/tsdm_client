/// Path safety for cache files.
///
/// File names stored in the database (image cache, avatar cache) and ids coming from the forum (emoji) end up in file
/// paths under the cache directories. A restored backup or a crafted server answer could carry `../`, separators or
/// absolute paths; every such name goes through these checks before it is turned into a file.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// Emoji ids accepted in cache file names.
final _emojiIdRe = RegExp(r'^[A-Za-z0-9_-]{1,64}$');

/// Whether [name] is a plain file name: one path segment, no separators, not `.` or `..`, no NUL byte, at most 255
/// characters. The uuid v5 names this app writes qualify.
bool isSafeFileName(String name) =>
    name.isNotEmpty &&
    name.length <= 255 &&
    name != '.' &&
    name != '..' &&
    !name.contains('/') &&
    !name.contains(r'\') &&
    !name.codeUnits.contains(0);

/// Whether [id] may be used in an emoji cache file name.
bool isSafeEmojiId(String id) => _emojiIdRe.hasMatch(id);

/// The file called [name] inside [directory], or null when [name] is not a plain file name or would resolve outside
/// of [directory].
File? fileInside(Directory directory, String name) {
  if (!isSafeFileName(name)) {
    return null;
  }
  final root = p.normalize(directory.absolute.path);
  final file = File(p.join(root, name));
  if (!p.isWithin(root, p.normalize(file.absolute.path))) {
    return null;
  }
  return file;
}
