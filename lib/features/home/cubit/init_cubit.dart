import 'dart:async';
import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_trim.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';

part 'init_cubit.mapper.dart';
part 'init_state.dart';

/// Cubit to do some initializing work during app start.
final class InitCubit extends Cubit<InitState> with LoggerMixin {
  /// Constructor.
  InitCubit() : super(const InitState());

  /// Delete legacy data used in version v0.x.
  Future<void> deleteV0LegacyData() async {
    final v0IsarDb = File('${(await getApplicationSupportDirectory()).path}/db/main.isar');
    if (!v0IsarDb.existsSync()) {
      return;
    }
    await v0IsarDb.delete();

    final v0IsarDbLock = File('${v0IsarDb.path}-lck');
    if (v0IsarDbLock.existsSync()) {
      await v0IsarDbLock.delete();
    }

    final v0ImageCacheDir = Directory('${(await getApplicationCacheDirectory()).path}/images');
    if (v0ImageCacheDir.existsSync()) {
      await v0ImageCacheDir.list(recursive: true).forEach((e) => e.delete());
    }

    emit(state.copyWith(v0LegacyDataDeleted: true));
  }

  /// How long after the first frame [scheduleImageCacheTrim] cleans up the image cache by default: past the homepage
  /// and its first pictures, which the clean up must not compete with.
  static const imageCacheTrimDelay = Duration(seconds: 20);

  Timer? _imageCacheTrimTimer;

  /// Clean up the image cache in the background, [delay] after the first frame: the images not shown within the age
  /// of [limits] and the least recently shown ones beyond its count and size go (`ImageCacheProvider.trimCache`).
  ///
  /// Never before the first frame and never waited for: the homepage used to show a spinner instead of its content
  /// until the outdated images were deleted and the whole table read again, which took long with a large cache.
  ///
  /// [trim] is the clean up, `ImageCacheProvider.trimCache` of the app by default.
  void scheduleImageCacheTrim(
    ImageCacheLimits limits, {
    Duration delay = imageCacheTrimDelay,
    @visibleForTesting Future<Object?> Function(ImageCacheLimits limits)? trim,
  }) {
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (isClosed) {
        return;
      }
      _imageCacheTrimTimer?.cancel();
      _imageCacheTrimTimer = Timer(delay, () async {
        _imageCacheTrimTimer = null;
        if (isClosed) {
          return;
        }
        debug('trim image cache');
        await (trim ?? getIt.get<ImageCacheProvider>().trimCache)(limits);
      });
    });
  }

  /// Clear temporary cache file created by file picker.
  ///
  /// Only needed and can be call on Android an iOS.
  Future<void> autoClearFilePickerCache() async {
    if (isMobile) {
      await FilePicker.platform.clearTemporaryFiles();
    }
  }

  @override
  Future<void> close() async {
    _imageCacheTrimTimer?.cancel();
    _imageCacheTrimTimer = null;
    await super.close();
  }
}
