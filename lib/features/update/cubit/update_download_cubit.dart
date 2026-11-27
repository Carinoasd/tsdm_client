import 'dart:io' as io;

import 'package:bloc/bloc.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/features/update/models/update_channel.dart';
import 'package:tsdm_client/features/update/repository/release_update_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/git_info.dart';

export 'package:tsdm_client/features/update/repository/release_update_repository.dart'
    show UpdateDownloadFailure, UpdateTarget;

/// Downloading and installation are explicit separate user actions.
enum UpdateDownloadStatus {
  /// No download has been requested.
  idle,

  /// Looking up the exact official release asset.
  resolving,

  /// Writing APK bytes into a private partial file.
  downloading,

  /// Checking the published size and SHA-256 digest.
  verifying,

  /// A verified APK is available for an explicit installation request.
  ready,

  /// Android is validating the APK and opening the system installer.
  installing,

  /// The user must grant this app permission to request installation.
  permissionRequired,

  /// The system installer was opened; installation is not yet confirmed.
  installerOpened,

  /// The current operation failed and can be retried.
  failed,

  /// The user cancelled the active download.
  cancelled,
}

/// App-scoped download progress survives navigation to another page.
class UpdateDownloadState {
  /// Constructor.
  const UpdateDownloadState({
    this.status = UpdateDownloadStatus.idle,
    this.received = 0,
    this.total = 0,
    this.version,
    this.failure,
  });

  /// Current stage.
  final UpdateDownloadStatus status;

  /// Bytes safely written.
  final int received;

  /// Expected bytes from the release asset metadata.
  final int total;

  /// Version of this download, independent of subsequent update checks.
  final String? version;

  /// Localizable error category.
  final UpdateDownloadFailure? failure;

  /// Prevents starting overlapping operations.
  bool get isBusy => const {
    UpdateDownloadStatus.resolving,
    UpdateDownloadStatus.downloading,
    UpdateDownloadStatus.verifying,
    UpdateDownloadStatus.installing,
  }.contains(status);

  /// The completed download can be offered again after permission settings or a cancelled system installer.
  bool get canInstall =>
      const {
        UpdateDownloadStatus.ready,
        UpdateDownloadStatus.permissionRequired,
        UpdateDownloadStatus.installerOpened,
      }.contains(status) ||
      (status == UpdateDownloadStatus.failed && failure == UpdateDownloadFailure.install);
}

/// Holds one user-requested APK download; never starts installation automatically.
class UpdateDownloadCubit extends Cubit<UpdateDownloadState> {
  /// Dependencies are injectable for offline tests; construction does not call native Android APIs.
  UpdateDownloadCubit({ReleaseUpdateRepository? repository, bool? supported, int? currentVersionCode})
    : _repository = repository ?? ReleaseUpdateRepository(),
      supported = supported ?? (io.Platform.isAndroid || io.Platform.isWindows),
      _currentVersionCode = currentVersionCode ?? int.tryParse(appVersion.split('+').last) ?? 0,
      super(const UpdateDownloadState());

  final ReleaseUpdateRepository _repository;
  final int _currentVersionCode;

  /// Where the downloads started from now on take the update from.
  UpdateChannel get channel => _repository.channel;

  set channel(UpdateChannel value) => _repository.channel = value;

  /// The release asset this platform installs, decides the wording of the update page.
  UpdateTarget get target => _repository.installer.target;

  /// Android installs the APK through the system installer, Windows replaces the portable folder.
  final bool supported;
  CancelToken? _token;
  DownloadedUpdate? _downloaded;
  Future<void>? _cleanup;

  /// Completes when the cache cleanup started by [restore] is over (for tests; the cleanup runs in the background).
  @visibleForTesting
  Future<void> get cleanupDone async => _cleanup?.catchError((Object _) {});

  void _stage(UpdateDownloadStatus status, {int? received, int? total, UpdateDownloadFailure? failure}) {
    if (!isClosed) {
      emit(
        UpdateDownloadState(
          status: status,
          received: received ?? state.received,
          total: total ?? state.total,
          version: state.version,
          failure: failure,
        ),
      );
    }
  }

  /// Recheck a previously downloaded APK after process death, without downloading or opening the installer.
  ///
  /// Version discovery may call this on startup. In-flight and user-visible download states are never replaced;
  /// returning from permission settings still requires an explicit Install action, even after a successful restore.
  Future<void> restore(LatestVersionInfo info) async {
    if (isClosed || !supported || state.status != UpdateDownloadStatus.idle) {
      return;
    }
    // Nothing is running: drop unfinished downloads and the ones of other versions, also once the update is
    // installed and the current version is the latest. Restoring only reads complete files of this version, so it
    // does not wait; a download does, so its partial file is not removed.
    final newer = info.versionCode > _currentVersionCode;
    _cleanup ??= _repository
        .cleanup(keepVersionCode: newer ? info.versionCode : null)
        .whenComplete(() => _cleanup = null);
    if (!newer) {
      return;
    }
    final token = CancelToken();
    _token = token;
    emit(UpdateDownloadState(status: UpdateDownloadStatus.resolving, version: info.version));
    try {
      final update = await _repository.restore(
        info,
        cancelToken: token,
        onVerifying: () {
          if (_token == token && !token.isCancelled) _stage(UpdateDownloadStatus.verifying);
        },
      );
      if (isClosed || _token != token || token.isCancelled) return;
      if (update == null) {
        emit(const UpdateDownloadState());
        return;
      }
      _downloaded = update;
      _stage(UpdateDownloadStatus.ready);
    } on UpdateDownloadException catch (error) {
      _warn('update restore failed: ${error.failure}');
      if (_token == token && !token.isCancelled) _stage(UpdateDownloadStatus.failed, failure: error.failure);
    } on Exception catch (error) {
      _warn('update restore failed: $error');
      if (_token == token && !token.isCancelled) {
        _stage(UpdateDownloadStatus.failed, failure: UpdateDownloadFailure.network);
      }
    }
  }

  /// Start one download of a newer version; duplicate clicks are ignored.
  Future<void> download(LatestVersionInfo info) async {
    if (isClosed || state.isBusy) return;
    if (!supported || info.versionCode <= _currentVersionCode) {
      _stage(UpdateDownloadStatus.failed, failure: UpdateDownloadFailure.unsupported);
      return;
    }
    final token = CancelToken();
    _token = token;
    emit(UpdateDownloadState(status: UpdateDownloadStatus.resolving, version: info.version));
    try {
      // A run that can never install (e.g. not the portable Windows folder) learns it before the download.
      final blocked = await _repository.installer.preflight();
      if (isClosed || _token != token || token.isCancelled) return;
      if (blocked != null) {
        _stage(UpdateDownloadStatus.failed, failure: blocked);
        return;
      }
      final old = _downloaded;
      _downloaded = null;
      await _repository.discard(old);
      // Never throws; awaited only so the cleanup does not remove the new partial file.
      await _cleanup?.catchError((Object _) {});
      if (isClosed || _token != token || token.isCancelled) return;
      final update = await _repository.download(
        info,
        cancelToken: token,
        onProgress: (received, total) {
          if (_token == token && !token.isCancelled) {
            _stage(UpdateDownloadStatus.downloading, received: received, total: total);
          }
        },
        onVerifying: () {
          if (_token == token && !token.isCancelled) _stage(UpdateDownloadStatus.verifying);
        },
      );
      if (isClosed || _token != token || token.isCancelled) {
        await _repository.discard(update);
        return;
      }
      _downloaded = update;
      _stage(UpdateDownloadStatus.ready);
    } on UpdateDownloadException catch (error) {
      _warn('update download failed: ${error.failure}');
      if (_token == token && !token.isCancelled) _stage(UpdateDownloadStatus.failed, failure: error.failure);
    } on Exception catch (error) {
      _warn('update download failed: $error');
      if (_token == token && !token.isCancelled) {
        _stage(UpdateDownloadStatus.failed, failure: UpdateDownloadFailure.network);
      }
    }
  }

  /// Cancels a fetch or verification, keeping stale completion callbacks out of a newer download.
  void cancel() {
    if (isClosed || !state.isBusy || state.status == UpdateDownloadStatus.installing) return;
    _token?.cancel();
    _stage(UpdateDownloadStatus.cancelled);
  }

  /// Ask the system to install only after the user presses Install.
  Future<void> install() async {
    final update = _downloaded;
    if (isClosed || !supported || !state.canInstall || update == null) return;
    _stage(UpdateDownloadStatus.installing);
    try {
      if (!await _repository.installer.canInstall()) {
        _stage(UpdateDownloadStatus.permissionRequired);
        return;
      }
      if (!await _repository.installer.install(update)) {
        _stage(UpdateDownloadStatus.failed, failure: UpdateDownloadFailure.install);
        return;
      }
      _stage(UpdateDownloadStatus.installerOpened);
    } on UpdateDownloadException catch (error) {
      _warn('update install failed: ${error.failure}');
      _stage(UpdateDownloadStatus.failed, failure: error.failure);
    } on PlatformException catch (error) {
      _warn('update install failed: $error');
      if (error.code == 'install_permission_required') {
        _stage(UpdateDownloadStatus.permissionRequired);
      } else {
        _stage(UpdateDownloadStatus.failed, failure: UpdateDownloadFailure.install);
      }
    } on Exception catch (error) {
      _warn('update install failed: $error');
      _stage(UpdateDownloadStatus.failed, failure: UpdateDownloadFailure.install);
    }
  }

  /// Returning from settings does not launch the installer; the user can retry Install explicitly.
  Future<void> openPermissionSettings() async {
    if (isClosed || !supported || !state.canInstall) return;
    try {
      if (!await _repository.installer.openPermissionSettings()) {
        _stage(UpdateDownloadStatus.failed, failure: UpdateDownloadFailure.install);
      }
    } on Exception {
      _stage(UpdateDownloadStatus.failed, failure: UpdateDownloadFailure.install);
    }
  }

  /// Failures are logged for reports (GitHub #172); logging must not throw where no logger was set up (tests).
  static void _warn(String message) {
    try {
      talker.warning(message);
      // The logger is a late global: reading it before initLogger throws a LateInitializationError.
      // ignore: avoid_catching_errors
    } on Error {
      // Nothing to log to.
    }
  }

  @override
  Future<void> close() async {
    _token?.cancel();
    _repository.dispose();
    // The verified APK may still be read by the external installer after the Dart tree is disposed.
    await super.close();
  }
}
