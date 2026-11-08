import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Why a font file was refused by [CustomFontStore.import].
enum FontImportError {
  /// Not a .ttf / .otf file, or the engine can not load it.
  unusable,

  /// The file name is a generic family name.
  reservedName,

  /// A font with this name is already registered in this session; the engine can not replace it before a restart.
  nameInUse,
}

/// A font file refused by [CustomFontStore.import].
class FontImportException implements Exception {
  /// Constructor.
  const FontImportException(this.error, this.path);

  /// Reason.
  final FontImportError error;

  /// The refused file.
  final String path;

  @override
  String toString() => 'FontImportException($error, $path)';
}

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

  /// Families registered with the engine in this session. The engine can not unload or replace a family, so a family
  /// is registered once and a replaced font file only shows after the app restarts.
  static final Set<String> _registeredFamilies = {};

  /// Family names the app or the engine already uses for generic fonts; importing a file with such a name is refused.
  static const reservedFamilies = {'serif', 'sans-serif', 'monospace', 'cursive', 'fantasy', 'system-ui', 'roboto'};

  /// Forget which families were registered (tests only; the engine itself keeps them).
  @visibleForTesting
  static void resetRegisteredFamilies() => _registeredFamilies.clear();

  Future<void> _register(String family, Uint8List bytes) async {
    if (_registeredFamilies.contains(family)) {
      return;
    }
    await _registerFont(family, bytes);
    _registeredFamilies.add(family);
  }

  static Future<void> _loadWithFontLoader(String family, Uint8List bytes) async {
    final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(bytes)));
    await loader.load();
  }

  /// Whether [path] looks like a font file that can be imported.
  static bool isSupported(String path) =>
      supportedExtensions.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

  /// The family name for the font file at [path].
  static String familyOf(String path) => p.basenameWithoutExtension(path).trim();

  /// Families of the imported fonts, sorted.
  Future<List<String>> list() async {
    if (!directory.existsSync()) {
      return const [];
    }
    final families = <String>{};
    try {
      await for (final entity in directory.list()) {
        if (entity is File && isSupported(entity.path)) {
          families.add(familyOf(entity.path));
        }
      }
    } on FileSystemException {
      return const [];
    }
    return families.toList()..sort();
  }

  /// Copy the font file [source] into the store, register it and return its family name.
  ///
  /// A font with the same name is replaced only if that family is not registered yet in this session (a font that was
  /// loaded at startup or by [loadAll] must be deleted and the app restarted first). Throws [FontImportException] when the file is refused; nothing is kept then.
  Future<String> import(File source) async {
    if (!isSupported(source.path)) {
      throw FontImportException(FontImportError.unusable, source.path);
    }
    final family = familyOf(source.path);
    if (family.isEmpty || reservedFamilies.contains(family.toLowerCase())) {
      throw FontImportException(FontImportError.reservedName, source.path);
    }
    // The registration below is skipped for a known family, so a same-name file could not be validated.
    if (_registeredFamilies.contains(family)) {
      throw FontImportException(FontImportError.nameInUse, source.path);
    }
    final bytes = await source.readAsBytes();
    // Register first so a broken file is never kept.
    try {
      await _register(family, bytes);
    } on Object {
      throw FontImportException(FontImportError.unusable, source.path);
    }
    await directory.create(recursive: true);
    // Write aside first so a failed write does not lose the font that is there; if it fails the font works for this
    // session only.
    final target = _fileOf(family, p.extension(source.path).toLowerCase());
    final temp = File('${target.path}.tmp');
    try {
      await temp.writeAsBytes(bytes, flush: true);
      // Same name with the other extension is replaced, not kept beside it.
      await delete(family);
      await temp.rename(target.path);
    } on Object {
      if (temp.existsSync()) {
        await temp.delete();
      }
      rethrow;
    }
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

  /// Register the imported font [family] with the engine; false when there is no such font or it fails to load.
  Future<bool> load(String family) async {
    if (p.basename(family) != family) {
      return false;
    }
    for (final ext in supportedExtensions) {
      final file = _fileOf(family, '.$ext');
      if (!file.existsSync()) {
        continue;
      }
      try {
        await _register(family, await file.readAsBytes());
        return true;
      } on Object {
        return false;
      }
    }
    return false;
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
          await _register(family, await entity.readAsBytes());
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
