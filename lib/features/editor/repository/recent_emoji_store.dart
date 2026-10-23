import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/logger.dart';

/// The emojis (`{:12_865:}`) and saved images (`[img]…[/img]`) last inserted from the emoji panel of the editors, the
/// most recent first: kept on this device for every account (`editor/recent_emoji.json` in the app's support
/// directory), at most [maxCount].
///
/// Read once, the first time [recent] is asked for; every use is written in the background, into a temporary file
/// renamed over the old one.
final class RecentEmojiStore with LoggerMixin {
  /// Constructor.
  ///
  /// The list lives in [file] (`editor/recent_emoji.json` in the app's support directory by default).
  RecentEmojiStore({Future<File> Function()? file, this.maxCount = defaultMaxCount}) : _file = file ?? _defaultFile;

  /// A store remembering in memory only (tests of the editors).
  @visibleForTesting
  RecentEmojiStore.memory({this.maxCount = defaultMaxCount}) : _file = null;

  /// The app's store, null when none is registered (tests of other features): nothing is remembered then.
  static RecentEmojiStore? get app => getIt.isRegistered<RecentEmojiStore>() ? getIt.get<RecentEmojiStore>() : null;

  static Future<File> _defaultFile() async {
    final sep = Platform.pathSeparator;
    return File('${(await getApplicationSupportDirectory()).path}${sep}editor${sep}recent_emoji.json');
  }

  /// How many are kept by default.
  static const defaultMaxCount = 32;

  /// Version of the file.
  static const formatVersion = 1;

  /// How many are kept.
  final int maxCount;

  final Future<File> Function()? _file;

  final _recent = ValueNotifier<List<String>>(const []);
  Future<void>? _loading;
  Future<void> _writes = Future<void>.value();

  /// The most recent first; empty until read ([load]).
  ValueListenable<List<String>> get recent {
    unawaited(load());
    return _recent;
  }

  /// Completes once every write asked so far is done.
  @visibleForTesting
  Future<void> get pendingWrites => _writes;

  /// Read the file, once.
  Future<void> load() => _loading ??= () async {
    final source = _file;
    if (source == null) {
      return;
    }
    try {
      final file = await source();
      if (!file.existsSync()) {
        return;
      }
      final saved = jsonDecode(await file.readAsString());
      if (saved is Map<String, dynamic> && saved['v'] == formatVersion && saved['codes'] is List) {
        final codes = (saved['codes'] as List).whereType<String>().where((e) => e.isNotEmpty).take(maxCount).toList();
        // A use while reading comes first.
        _recent.value = [..._recent.value, ...codes.where((e) => !_recent.value.contains(e))].take(maxCount).toList();
      }
    } on Object catch (e) {
      warning('recent emojis: file unreadable: $e');
    }
  }();

  /// [code] was inserted: it becomes the most recent.
  void use(String code) {
    if (code.isEmpty) {
      return;
    }
    final codes = [code, ..._recent.value.where((e) => e != code)].take(maxCount).toList();
    _recent.value = codes;
    final source = _file;
    if (source == null) {
      return;
    }
    _writes = _writes.then((_) async {
      try {
        await load();
        final file = await source();
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(jsonEncode({'v': formatVersion, 'codes': _recent.value}), flush: true);
        await temp.rename(file.path);
      } on Object catch (e, st) {
        warning('recent emojis: failed to save: $e');
        handleRaw(e, st);
      }
    });
  }
}
