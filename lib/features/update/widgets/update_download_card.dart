import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/update/cubit/update_download_cubit.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The app-wide download survives page navigation and independent version checks.
class UpdateDownloadCard extends StatelessWidget {
  /// Constructor. [latest] is present only when a newer release is available.
  const UpdateDownloadCard({required this.cubit, required this.latest, super.key});

  /// The downloader owned by the app's update cubit.
  final UpdateDownloadCubit cubit;

  /// A newer release, if the last successful version check found one.
  final LatestVersionInfo? latest;

  @override
  Widget build(BuildContext context) {
    if (!cubit.supported) {
      return const SizedBox.shrink();
    }
    return BlocBuilder<UpdateDownloadCubit, UpdateDownloadState>(
      bloc: cubit,
      builder: (context, state) {
        if (state.status == UpdateDownloadStatus.idle && latest == null) {
          return const SizedBox.shrink();
        }
        final tr = context.t.updatePage.download;
        final version = state.version ?? latest?.version;
        final progress = state.total > 0 ? (state.received / state.total).clamp(0.0, 1.0) : null;
        final failed = state.status == UpdateDownloadStatus.failed;
        final mayDownload =
            latest != null &&
            (state.status == UpdateDownloadStatus.idle ||
                state.status == UpdateDownloadStatus.cancelled ||
                (failed && !state.canInstall));
        final mayCancel =
            state.status == UpdateDownloadStatus.resolving ||
            state.status == UpdateDownloadStatus.downloading ||
            state.status == UpdateDownloadStatus.verifying;
        final message = switch (state.status) {
          UpdateDownloadStatus.idle => null,
          UpdateDownloadStatus.resolving => tr.resolving,
          UpdateDownloadStatus.downloading => tr.downloading,
          UpdateDownloadStatus.verifying => tr.verifying,
          UpdateDownloadStatus.ready => tr.ready,
          UpdateDownloadStatus.installing => tr.installing,
          UpdateDownloadStatus.permissionRequired => tr.permissionRequired,
          UpdateDownloadStatus.installerOpened => tr.installerOpened,
          UpdateDownloadStatus.cancelled => tr.cancelled,
          UpdateDownloadStatus.failed => switch (state.failure) {
            UpdateDownloadFailure.network => tr.networkError,
            UpdateDownloadFailure.releaseUnavailable => tr.releaseUnavailableError,
            UpdateDownloadFailure.invalidRelease => tr.invalidReleaseError,
            UpdateDownloadFailure.integrity => tr.integrityError,
            UpdateDownloadFailure.storage => tr.storageError,
            UpdateDownloadFailure.install => tr.installError,
            UpdateDownloadFailure.unsupported => tr.unsupportedError,
            null => tr.networkError,
          },
        };
        return Padding(
          padding: const EdgeInsets.only(top: appSurfaceGap),
          child: AppSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (version != null) ...[
                  Text(
                    tr.title(version: version),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  sizedBoxW8H8,
                ],
                Text(tr.universalApk),
                if (message != null) ...[
                  sizedBoxW12H12,
                  if (failed) AppNoticeBanner(message: message, tone: AppNoticeTone.error) else Text(message),
                ],
                if (state.isBusy) ...[
                  sizedBoxW12H12,
                  LinearProgressIndicator(
                    value: state.status == UpdateDownloadStatus.downloading ? progress : null,
                    semanticsLabel: message,
                  ),
                ],
                if (state.status == UpdateDownloadStatus.downloading) ...[
                  sizedBoxW8H8,
                  Text(
                    progress == null
                        ? tr.received(bytes: tr.bytes(count: state.received.toString()))
                        : tr.progress(
                            received: tr.bytes(count: state.received.toString()),
                            total: tr.bytes(count: state.total.toString()),
                            percent: (progress * 100).toStringAsFixed(0),
                          ),
                  ),
                ],
                if ((failed || state.status == UpdateDownloadStatus.cancelled) &&
                    !state.canInstall &&
                    latest == null) ...[
                  sizedBoxW8H8,
                  Text(tr.checkToRetry),
                ],
                if (mayDownload || mayCancel || state.canInstall) ...[
                  sizedBoxW12H12,
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (mayDownload)
                        FilledButton.icon(
                          icon: const Icon(Icons.download_outlined),
                          label: Text(
                            state.status == UpdateDownloadStatus.idle
                                ? tr.downloadApk(version: latest!.version)
                                : tr.retryDownload(version: latest!.version),
                            textAlign: TextAlign.center,
                          ),
                          onPressed: () async => cubit.download(latest!),
                        ),
                      if (mayCancel)
                        OutlinedButton.icon(
                          icon: const Icon(Icons.close),
                          label: Text(context.t.general.cancel, textAlign: TextAlign.center),
                          onPressed: cubit.cancel,
                        ),
                      if (state.status == UpdateDownloadStatus.permissionRequired)
                        FilledButton.icon(
                          icon: const Icon(Icons.settings_outlined),
                          label: Text(tr.openPermissionSettings, textAlign: TextAlign.center),
                          onPressed: cubit.openPermissionSettings,
                        ),
                      if (state.canInstall)
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.system_update_outlined),
                          label: Text(
                            state.status == UpdateDownloadStatus.ready ? tr.install : tr.retryInstall,
                            textAlign: TextAlign.center,
                          ),
                          onPressed: cubit.install,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
