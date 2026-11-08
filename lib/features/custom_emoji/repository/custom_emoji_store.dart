import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tsdm_client/features/custom_emoji/models/custom_emoji.dart';
import 'package:tsdm_client/features/custom_emoji/utils/custom_emoji_archive.dart';
import 'package:tsdm_client/features/custom_emoji/utils/custom_emoji_image.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:uuid/uuid.dart';

/// The user's custom emoji packs, kept on this device for every account in `emoji_packs` of the app's documents
/// directory: `packs.json` (the packs and the order of their images), the images as `images/<sha256>.<ext>`, and
/// `uploads.json`, the attachment each account last uploaded of an image (by SHA-256, [uploadedAid]).
///
/// Read once, the first time [packs] is asked for; every change is written in the background, into a temporary file
/// renamed over the old one.
final class CustomEmojiStore with LoggerMixin {
  /// Constructor.
  ///
  /// The files live in [directory] (`emoji_packs` in the app's documents directory by default); [prepare] reads an
  /// added image ([prepareCustomEmoji] in an isolate by default).
  CustomEmojiStore({
    Future<Directory> Function()? directory,
    Future<PreparedCustomEmoji?> Function(Uint8List bytes)? prepare,
  }) : _directory = directory ?? _defaultDirectory,
       _prepare = prepare ?? _prepareInIsolate;

  /// The app's store, null when none is registered (tests of other features).
  static CustomEmojiStore? get app => getIt.isRegistered<CustomEmojiStore>() ? getIt.get<CustomEmojiStore>() : null;

  static Future<Directory> _defaultDirectory() async {
    final sep = Platform.pathSeparator;
    return Directory('${(await getApplicationDocumentsDirectory()).path}${sep}emoji_packs');
  }

  static Future<PreparedCustomEmoji?> _prepareInIsolate(Uint8List bytes) => compute(prepareCustomEmoji, bytes);

  /// Version of the files.
  static const formatVersion = 1;

  final Future<Directory> Function() _directory;
  final Future<PreparedCustomEmoji?> Function(Uint8List bytes) _prepare;

  final _packs = ValueNotifier<List<CustomEmojiPack>>(const []);

  /// uid → SHA-256 → aid.
  final _uploads = <String, Map<String, int>>{};

  Directory? _dir;
  Future<void>? _loading;
  Future<void> _writes = Future<void>.value();

  /// The packs, in their order; empty until read ([load]).
  ValueListenable<List<CustomEmojiPack>> get packs {
    unawaited(load());
    return _packs;
  }

  /// Completes once every write asked so far is done.
  @visibleForTesting
  Future<void> get pendingWrites => _writes;

  String get _sep => Platform.pathSeparator;

  /// The saved file of [emoji], null before the store is read.
  File? fileOf(CustomEmoji emoji) {
    final dir = _dir;
    return dir == null ? null : File('${dir.path}${_sep}images$_sep${emoji.fileName}');
  }

  /// Read the files, once.
  Future<void> load() => _loading ??= () async {
    try {
      final dir = await _directory();
      _dir = dir;
      final packsFile = File('${dir.path}${_sep}packs.json');
      if (packsFile.existsSync()) {
        final saved = jsonDecode(await packsFile.readAsString());
        if (saved is Map && saved['v'] == formatVersion && saved['packs'] is List) {
          _packs.value = (saved['packs'] as List).map(CustomEmojiPack.fromJson).nonNulls.toList();
        }
      }
      final uploadsFile = File('${dir.path}${_sep}uploads.json');
      if (uploadsFile.existsSync()) {
        final saved = jsonDecode(await uploadsFile.readAsString());
        if (saved is Map && saved['v'] == formatVersion && saved['accounts'] is Map) {
          for (final MapEntry(:key, :value) in (saved['accounts'] as Map).entries) {
            if (key is! String || value is! Map) continue;
            final map = <String, int>{};
            for (final MapEntry(key: sha, value: aid) in value.entries) {
              if (sha is String && isSha256(sha) && aid is int && aid > 0) {
                map[sha] = aid;
              }
            }
            _uploads[key] = map;
          }
        }
      }
    } on Object catch (e) {
      warning('custom emoji packs: files unreadable: $e');
    }
  }();

  /// A new empty pack named [name], last.
  Future<CustomEmojiPack> createPack(String name) async {
    await load();
    final pack = CustomEmojiPack(id: const Uuid().v4(), name: name.trim());
    _setPacks([..._packs.value, pack]);
    return pack;
  }

  /// Rename the pack [id].
  Future<void> renamePack(String id, String name) async {
    await load();
    _setPacks([for (final p in _packs.value) p.id == id ? p.copyWith(name: name.trim()) : p]);
  }

  /// Delete the pack [id] and the images no other pack has.
  Future<void> deletePack(String id) async {
    await load();
    final removed = _packs.value.where((e) => e.id == id).expand((e) => e.emojis).toList();
    _setPacks(_packs.value.where((e) => e.id != id).toList());
    _deleteOrphans(removed);
  }

  /// Move the pack at [from] to [to] (indexes of [packs], [to] counted before the move as a reorderable list tells it).
  Future<void> movePack(int from, int to) async {
    await load();
    _setPacks(_moved(_packs.value, from, to));
  }

  /// Move the image at [from] of the pack [id] to [to], counted as [movePack] does.
  Future<void> moveEmoji(String id, int from, int to) async {
    await load();
    _setPacks([for (final p in _packs.value) p.id == id ? p.copyWith(emojis: _moved(p.emojis, from, to)) : p]);
  }

  /// Remove [emoji] from the pack [id] (its file too when no other pack has it).
  Future<void> removeEmoji(String id, CustomEmoji emoji) async {
    await load();
    _setPacks([
      for (final p in _packs.value) p.id == id ? p.copyWith(emojis: p.emojis.where((e) => e != emoji).toList()) : p,
    ]);
    _deleteOrphans([emoji]);
  }

  /// Add the images [images] (their bytes) to the end of the pack [id], each scaled down and saved
  /// ([prepareCustomEmoji]): how many were added. One that is no readable image, or already in the pack, is not.
  Future<int> addImages(String id, Iterable<Future<Uint8List?> Function()> images) async {
    await load();
    var added = 0;
    for (final read in images) {
      if (!_packs.value.any((e) => e.id == id)) break;
      final Uint8List? bytes;
      try {
        bytes = await read();
      } on Object catch (e) {
        warning('custom emoji packs: image unreadable: $e');
        continue;
      }
      if (bytes == null) continue;
      final prepared = await _prepare(bytes);
      if (prepared == null) continue;
      if (await _addPrepared(id, prepared.emoji, prepared.bytes)) added++;
    }
    return added;
  }

  Future<bool> _addPrepared(String id, CustomEmoji emoji, Uint8List bytes) async {
    final pack = _packs.value.where((e) => e.id == id).firstOrNull;
    if (pack == null || pack.emojis.any((e) => e.sha256 == emoji.sha256)) {
      return false;
    }
    final file = fileOf(emoji);
    if (file == null) return false;
    // Written in turn with the deletions asked before, so none of them takes this file away.
    var saved = true;
    final job = _writes.then((_) async {
      try {
        if (!file.existsSync() || file.lengthSync() != bytes.length) {
          await file.parent.create(recursive: true);
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsBytes(bytes, flush: true);
          await tmp.rename(file.path);
        }
      } on Object catch (e) {
        warning('custom emoji packs: image not saved: $e');
        saved = false;
      }
    });
    _writes = job;
    await job;
    final now = _packs.value.where((e) => e.id == id).firstOrNull;
    if (!saved || now == null || now.emojis.any((e) => e.sha256 == emoji.sha256)) {
      return false;
    }
    _setPacks([
      for (final p in _packs.value) p.id == id ? p.copyWith(emojis: [...p.emojis, emoji]) : p,
    ]);
    return true;
  }

  /// A zip of the packs [ids] (all when null), [encodeCustomEmojiArchive].
  Future<Uint8List> exportArchive([Set<String>? ids]) async {
    await load();
    final packs = _packs.value.where((e) => ids == null || ids.contains(e.id)).toList();
    return encodeCustomEmojiArchive(packs, (emoji) {
      try {
        return fileOf(emoji)?.readAsBytesSync();
      } on Object {
        return null;
      }
    });
  }

  /// Add the packs of the archive [bytes] ([decodeCustomEmojiArchive]): a pack of the same name as one here gets the
  /// images it lacks, any other is added last. How many images were added; null when [bytes] is no such archive.
  Future<int?> importArchive(Uint8List bytes) async {
    await load();
    final archived = await compute(decodeCustomEmojiArchive, bytes);
    if (archived == null) return null;
    var added = 0;
    for (final pack in archived) {
      final name = pack.name.isEmpty ? 'emoji' : pack.name;
      final id = _packs.value.where((e) => e.name == name).firstOrNull?.id ?? (await createPack(name)).id;
      for (final (emoji, data) in pack.emojis) {
        if (await _addPrepared(id, emoji, data)) added++;
      }
    }
    return added;
  }

  /// The attachment the account [uid] last uploaded of the image [sha256], null when none is remembered.
  int? uploadedAid(int uid, String sha256) => _uploads['$uid']?[sha256];

  /// Remember the upload [aid] of the image [sha256] by the account [uid].
  void rememberUpload(int uid, String sha256, int aid) {
    (_uploads['$uid'] ??= {})[sha256] = aid;
    _writeUploads();
  }

  /// Forget the upload of the image [sha256] by the account [uid].
  void forgetUpload(int uid, String sha256) {
    if (_uploads['$uid']?.remove(sha256) != null) {
      _writeUploads();
    }
  }

  static List<T> _moved<T>(List<T> list, int from, int to) {
    if (from < 0 || from >= list.length) return list;
    final copy = [...list];
    final item = copy.removeAt(from);
    copy.insert((to > from ? to - 1 : to).clamp(0, copy.length), item);
    return copy;
  }

  void _setPacks(List<CustomEmojiPack> packs) {
    _packs.value = List.unmodifiable(packs);
    final data = jsonEncode({'v': formatVersion, 'packs': packs.map((e) => e.toJson()).toList()});
    _write('packs.json', data);
  }

  void _writeUploads() => _write('uploads.json', jsonEncode({'v': formatVersion, 'accounts': _uploads}));

  void _deleteOrphans(List<CustomEmoji> emojis) {
    for (final emoji in emojis) {
      final file = fileOf(emoji);
      _writes = _writes.then((_) async {
        // Still unused when it is its turn: not added back meanwhile.
        if (_packs.value.any((p) => p.emojis.any((e) => e.fileName == emoji.fileName))) return;
        try {
          if (file != null && file.existsSync()) await file.delete();
        } on Object catch (e) {
          warning('custom emoji packs: image not deleted: $e');
        }
      });
    }
  }

  void _write(String name, String data) {
    final dir = _dir;
    if (dir == null) return;
    _writes = _writes.then((_) async {
      try {
        await dir.create(recursive: true);
        final file = File('${dir.path}$_sep$name');
        final tmp = File('${file.path}.tmp');
        await tmp.writeAsString(data, flush: true);
        await tmp.rename(file.path);
      } on Object catch (e) {
        warning('custom emoji packs: $name not written: $e');
      }
    });
  }
}
