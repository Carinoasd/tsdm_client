import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Manages the font files the user imported (.ttf / .otf) into the app's own directory.
///
/// A font's family name is its file name without the extension.
class CustomFontStore {
  /// Constructor.
  ///
  /// [directory] is where the fonts are kept; [registerFont] registers the bytes of a font under a family name with the
  /// engine (the real one uses a [FontLoader]).
  CustomFontStore(this.directory, {Future<void> Function(String family, Uint8List bytes)? registerFont})
    : _registerFont = registerFont ?? _loadWithFontLoader;

  /// File extensions that can be imported, lower case, without the dot.
  static const supportedExtensions = ['ttf', 'otf'];

  /// The store in the app's support directory.
  static Future<CustomFontStore> open() async => CustomFontStore(
    Directory(p.join((await getApplicationSupportDirectory()).path, 'fonts')),
  );

  /// Directory the imported fonts are kept in.
  final Directory directory;

  final Future<void> Function(String family, Uint8List bytes) _registerFont;

  static Future<void> _loadWithFontLoader(String family, Uint8List bytes) async {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  /// Whether [path] looks like a font file that can be imported.
  static bool isSupported(String path) =>
      supportedExtensions.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

  /// The family name for the font file at [path].
  static String familyOf(String path) => p.basenameWithoutExtension(path);

  /// Families of the imported fonts, sorted.
  Future<List<String>> list() async {
    if (!directory.existsSync()) {
      return const [];
    }
    final families = <String>[];
    try {
      await for (final entity in directory.list()) {
        if (entity is File && isSupported(entity.path)) {
          families.add(familyOf(entity.path));
        }
      }
    } on FileSystemException {
      return const [];
    }
    return families..sort();
  }

  /// Copy the font file [source] into the store, register it and return its family name.
  ///
  /// A font with the same name is replaced. Throws [FormatException] when [source] is not a font file the engine can
  /// load; nothing is kept then.
  Future<String> import(File source) async {
    if (!isSupported(source.path)) {
      throw FormatException('unsupported font file', source.path);
    }
    final family = familyOf(source.path);
    final bytes = await source.readAsBytes();
    // Register first so a broken file is never kept.
    try {
      await _registerFont(family, bytes);
    } on Object catch (e) {
      throw FormatException('font file can not be loaded: $e', source.path);
    }
    await directory.create(recursive: true);
    await _fileOf(family, p.extension(source.path).toLowerCase()).writeAsBytes(bytes, flush: true);
    return family;
  }

  /// Delete the imported font [family]. The engine keeps it until the app restarts.
  Future<void> delete(String family) async {
    for (final ext in supportedExtensions) {
      final file = _fileOf(family, '.$ext');
      if (file.existsSync()) {
        await file.delete();
      }
    }
  }

  /// Register all imported fonts with the engine, returning the families that loaded.
  ///
  /// A font that fails to load is skipped so the app falls back to the default font.
  Future<List<String>> loadAll() async {
    final loaded = <String>[];
    if (!directory.existsSync()) {
      return loaded;
    }
    try {
      await for (final entity in directory.list()) {
        if (entity is! File || !isSupported(entity.path)) {
          continue;
        }
        final family = familyOf(entity.path);
        try {
          await _registerFont(family, await entity.readAsBytes());
          loaded.add(family);
        } on Object {
          // Broken file: skip, the default font stays.
        }
      }
    } on FileSystemException {
      // Directory vanished or unreadable: nothing to load.
    }
    return loaded..sort();
  }

  File _fileOf(String family, String ext) => File(p.join(directory.path, '$family$ext'));
}
