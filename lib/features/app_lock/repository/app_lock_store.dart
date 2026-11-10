import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tsdm_client/features/app_lock/models/app_lock_config.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Where the app lock settings of this device live: `app_lock/app_lock.json` in the app's support directory.
///
/// Not in the settings table: a backup restored on another device, or the cross-device sync, must not bring a PIN.
class AppLockStore with LoggerMixin {
  /// Constructor; [file] is the default one in the app's support directory.
  AppLockStore({Future<File> Function()? file}) : _file = file ?? _defaultFile;

  /// A store keeping the settings in memory only (tests).
  @visibleForTesting
  AppLockStore.memory() : _file = null;

  static Future<File> _defaultFile() async {
    final sep = Platform.pathSeparator;
    return File('${(await getApplicationSupportDirectory()).path}${sep}app_lock${sep}app_lock.json');
  }

  final Future<File> Function()? _file;

  AppLockConfig _memory = const AppLockConfig();

  /// The saved settings; no lock when there is no file or it can not be read.
  Future<AppLockConfig> load() async {
    final source = _file;
    if (source == null) {
      return _memory;
    }
    try {
      final file = await source();
      if (!file.existsSync()) {
        return const AppLockConfig();
      }
      final json = jsonDecode(await file.readAsString());
      if (json is Map<String, Object?> && json['v'] == AppLockConfig.formatVersion) {
        return AppLockConfig.fromJson(json);
      }
      warning('app lock: unknown file format, no lock');
    } on Object catch (e) {
      warning('app lock: file unreadable, no lock: $e');
    }
    return const AppLockConfig();
  }

  /// Whether the lock is on, for what is done without unlocking (the reply typed in a notification): a file that
  /// exists but can not be read, or the directory that can not be found, counts as locked, unlike [load].
  Future<bool> lockedFailClosed() async {
    final source = _file;
    if (source == null) {
      return _memory.enabled;
    }
    try {
      final file = await source();
      if (!file.existsSync()) {
        return false;
      }
      final json = jsonDecode(await file.readAsString());
      if (json is Map<String, Object?> && json['v'] == AppLockConfig.formatVersion) {
        return AppLockConfig.fromJson(json).enabled;
      }
      warning('app lock: unknown file format, counted as locked');
    } on Object catch (e) {
      warning('app lock: file unreadable, counted as locked: $e');
    }
    return true;
  }

  /// Save [config], through a temporary file renamed over the old one.
  Future<void> save(AppLockConfig config) async {
    final source = _file;
    if (source == null) {
      _memory = config;
      return;
    }
    final file = await source();
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(config.toJson()), flush: true);
    await tmp.rename(file.path);
  }
}
