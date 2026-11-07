import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/offline_thread/batch/offline_batch_cubit.dart';
import 'package:tsdm_client/features/offline_thread/batch/offline_batch_source.dart';
import 'package:tsdm_client/features/offline_thread/repository/offline_thread_repository.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Run a batch of [mode] over the threads [jobs] lists for the account in use, in a dialog that shows the progress and
/// the cancel button, then the outcome. Does nothing without a logged in account or with the setting off.
///
/// Completes once the dialog is closed.
Future<void> showOfflineBatchDialog({
  required BuildContext context,
  required OfflineBatchMode mode,
  required Future<OfflineBatchList> Function(Future<bool> Function() next) jobs,
}) async {
  final uid = appOfflineThreads.currentUid();
  if (uid == null || !appOfflineThreads.enabled) {
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => RootPage(
      DialogPaths.offlineBatch,
      BlocProvider(
        create: (_) {
          final cubit = OfflineBatchCubit(
            mode: mode,
            source: AppOfflineBatchSource(uid: uid),
          );
          unawaited(cubit.start(jobs));
          return cubit;
        },
        child: const _OfflineBatchDialog(),
      ),
    ),
  );
}

class _OfflineBatchDialog extends StatelessWidget {
  const _OfflineBatchDialog();

  @override
  Widget build(BuildContext context) {
    final tr = context.t.offlineBatch;
    return BlocBuilder<OfflineBatchCubit, OfflineBatchState>(
      builder: (context, state) {
        final theme = Theme.of(context);
        final finished = state.finished;
        final value = state.status == OfflineBatchStatus.collecting || state.total == 0
            ? null
            : state.processed / state.total;
        return PopScope(
          canPop: finished,
          child: CustomAlertDialog.sync(
            title: AppDialogTitle(
              icon: state.mode == OfflineBatchMode.download ? Icons.download_for_offline_outlined : Icons.sync,
              title: state.mode == OfflineBatchMode.download ? tr.downloadTitle : tr.updateTitle,
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!finished) ...[
                  LinearProgressIndicator(value: value),
                  sizedBoxW8H8,
                  Row(
                    children: [
                      Expanded(
                        child: Text(state.current ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      sizedBoxW8H8,
                      Text(tr.progress(done: state.processed, total: state.total)),
                    ],
                  ),
                ] else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      AppInfoPill(icon: Icons.cloud_done_outlined, label: '${state.saved}', tooltip: tr.savedCount),
                      AppInfoPill(icon: Icons.skip_next_outlined, label: '${state.skipped}', tooltip: tr.skippedCount),
                      if (state.overLimit > 0)
                        AppInfoPill(
                          icon: Icons.inventory_2_outlined,
                          label: '${state.overLimit}',
                          tooltip: tr.overLimitCount,
                        ),
                      AppInfoPill(
                        icon: Icons.error_outline,
                        label: '${state.failures.length}',
                        tooltip: tr.failedCount,
                      ),
                    ],
                  ),
                  if (state.failures.isNotEmpty) ...[
                    sizedBoxW8H8,
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 240),
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final failure in state.failures)
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text(
                                failure.title.isEmpty ? failure.reason : failure.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: failure.title.isEmpty
                                  ? null
                                  : Text(
                                      failure.reason,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(color: theme.colorScheme.error),
                                    ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
            actions: [
              if (finished)
                TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t.general.close))
              else
                TextButton(
                  onPressed: context.read<OfflineBatchCubit>().cancel,
                  child: Text(context.t.general.cancel),
                ),
            ],
          ),
        );
      },
    );
  }
}
