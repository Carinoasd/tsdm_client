import 'dart:io' as io;

import 'package:bloc/bloc.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/features/update/repository/android_update_repository.dart';
import 'package:tsdm_client/utils/git_info.dart';

export 'package:tsdm_client/features/update/repository/android_update_repository.dart' show UpdateDownloadFailure;

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
  UpdateDownloadCubit({AndroidUpdateRepository? repository, bool? supported, int? currentVersionCode})
    : _repository = repository ?? AndroidUpdateRepository(),
      supported = supported ?? io.Platform.isAndroid,
      _currentVersionCode = currentVersionCode ?? int.tryParse(appVersion.split('+').last) ?? 0,
      super(const UpdateDownloadState());

  final AndroidUpdateRepository _repository;
  final int _currentVersionCode;

  /// Only Android has the native APK installation flow.
  final bool supported;
  CancelToken? _token;
  DownloadedUpdate? _downloaded;

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
    final old = _downloaded;
    _downloaded = null;
    await _repository.discard(old);
    try {
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
      if (_token == token && !token.isCancelled) _stage(UpdateDownloadStatus.failed, failure: error.failure);
    } on Exception {
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
    } on PlatformException catch (error) {
      if (error.code == 'install_permission_required') {
        _stage(UpdateDownloadStatus.permissionRequired);
      } else {
        _stage(UpdateDownloadStatus.failed, failure: UpdateDownloadFailure.install);
      }
    } on Exception {
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

  @override
  Future<void> close() async {
    _token?.cancel();
    _repository.dispose();
    // The verified APK may still be read by the external installer after the Dart tree is disposed.
    await super.close();
  }
}
