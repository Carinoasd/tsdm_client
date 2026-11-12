import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/attachment_download/models/attachment_download.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_manager.dart';
import 'package:tsdm_client/features/attachment_download/utils/attachment_protocol.dart';
import 'package:tsdm_client/features/attachment_download/utils/download_location.dart';
import 'package:tsdm_client/features/audio_player/utils/audio_attachment.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/data_saver_mode.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/network_usage.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// From this size on, a download on a metered network with the data saver on asks first.
const int attachmentLargeDownloadBytes = 20 * 1024 * 1024;

/// The account downloads are kept for: the one the requests are sent as, 0 for a guest.
int currentDownloadUid() =>
    getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>().userLoginInfo.uid ?? 0 : 0;

/// Whether a download of [size] bytes asks first: the data saver on ([DataSaverMode]) and the network metered.
Future<bool> attachmentDownloadNeedsConfirm(int? size) async {
  if (size == null || size < attachmentLargeDownloadBytes || !getIt.isRegistered<SettingsRepository>()) {
    return false;
  }
  final mode = DataSaverMode.fromIndex(getIt.get<SettingsRepository>().currentSettings.dataSaverMode);
  if (mode == DataSaverMode.off) {
    return false;
  }
  return NetworkUsage.isMetered();
}

/// Download the attachment at [url] the user tapped in the app, as the post shows it ([filename], [sizeText]), and
/// show its progress. The thread is the one of the page when there is one.
///
/// Without a manager (tests of other pages) the link opens as before.
Future<void> downloadAttachment(BuildContext context, String url, {String? filename, String? sizeText}) async {
  final manager = AttachmentDownloadManager.app;
  final absolute = url.prependHost();
  if (manager == null) {
    await context.dispatchAsUrl(absolute);
    return;
  }
  final size = attachmentSizeOf(sizeText);
  final typed = (filename ?? '').trim();
  final name = typed.isNotEmpty ? typed : 'attachment-${aidOfAttachmentUrl(absolute) ?? 0}';
  if (await attachmentDownloadNeedsConfirm(size)) {
    if (!context.mounted) {
      return;
    }
    final tr = context.t.attachmentDownload;
    final ok = await showQuestionDialog(
      context: context,
      title: tr.largeTitle,
      message: tr.largeMessage(name: name, size: formatDownloadSize(size!)),
    );
    if (!(ok ?? false)) {
      return;
    }
  }
  if (!context.mounted) {
    return;
  }
  final thread = context.readOrNull<ThreadBloc>()?.state;
  final item = await manager.start(
    uid: currentDownloadUid(),
    url: absolute,
    filename: name,
    size: size,
    tid: thread?.tid,
    threadTitle: thread?.title,
  );
  if (!context.mounted) {
    return;
  }
  await showAttachmentDownloadSheet(context, item);
}

/// Show the download [item] as it goes, with what can be done with it.
Future<void> showAttachmentDownloadSheet(BuildContext context, AttachmentDownload item) async {
  final manager = AttachmentDownloadManager.app;
  if (manager == null) {
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ListenableBuilder(
        listenable: manager,
        builder: (context, _) {
          final current = manager.find(item.uid, item.id);
          if (current == null) {
            return const SizedBox.shrink();
          }
          return AttachmentDownloadView(current, inSheet: true);
        },
      ),
    ),
  );
}

/// The download [item]: its name, progress or result, and the actions it has. [inSheet] adds the way to the
/// downloads page.
class AttachmentDownloadView extends StatelessWidget {
  /// Constructor.
  const AttachmentDownloadView(this.item, {this.inSheet = false, super.key});

  /// The download.
  final AttachmentDownload item;

  /// Shown in the sheet opened from a post.
  final bool inSheet;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.attachmentDownload;
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final failed = item.status == AttachmentDownloadStatus.failed || item.status == AttachmentDownloadStatus.cancelled;
    final message = switch (item.status) {
      AttachmentDownloadStatus.failed => context.displayTextOr(item.message, tr.failedGeneric),
      AttachmentDownloadStatus.cancelled => tr.cancelled,
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.filename, style: textTheme.titleMedium, maxLines: 3, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          if (item.status.active) ...[
            LinearProgressIndicator(value: item.status == AttachmentDownloadStatus.queued ? null : item.progress),
            const SizedBox(height: 8),
            Text(attachmentDownloadSizeLine(context, item), style: textTheme.bodySmall),
          ] else if (item.status == AttachmentDownloadStatus.completed)
            Text(attachmentDownloadSizeLine(context, item), style: textTheme.bodySmall)
          else if (message != null)
            Text(
              message,
              key: const ValueKey('attachment-download-message'),
              style: textTheme.bodyMedium?.copyWith(color: failed ? colorScheme.error : null),
            ),
          if (item.notice != null) ...[
            const SizedBox(height: 8),
            Text(
              context.displayText(item.notice!),
              style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final action in attachmentDownloadActionsOf(item, inSheet: inSheet))
                action.primary
                    ? FilledButton.tonalIcon(
                        key: ValueKey('attachment-download-${action.kind.name}'),
                        icon: Icon(action.kind.icon),
                        label: Text(action.kind.label(context)),
                        onPressed: () async => runAttachmentDownloadAction(context, item, action.kind),
                      )
                    : OutlinedButton.icon(
                        key: ValueKey('attachment-download-${action.kind.name}'),
                        icon: Icon(action.kind.icon),
                        label: Text(action.kind.label(context)),
                        onPressed: () async => runAttachmentDownloadAction(context, item, action.kind),
                      ),
            ],
          ),
        ],
      ),
    );
  }
}

/// `1.2 MB / 5.0 MB` while it runs, the size once done.
String attachmentDownloadSizeLine(BuildContext context, AttachmentDownload item) {
  final tr = context.t.attachmentDownload;
  final size = item.shownSize;
  return switch (item.status) {
    AttachmentDownloadStatus.queued => tr.queued,
    AttachmentDownloadStatus.running =>
      size == null
          ? formatDownloadSize(item.received)
          : '${formatDownloadSize(item.received)} / ${formatDownloadSize(size)}',
    _ => size == null ? '' : formatDownloadSize(size),
  };
}

/// What can be done with a download.
enum AttachmentDownloadActionKind {
  /// Stop it.
  cancel(Icons.close),

  /// Start it again.
  retry(Icons.refresh),

  /// Buy the attachment first (the forum's purchase).
  purchase(Icons.shopping_cart_outlined),

  /// Hand the file to the system.
  open(Icons.open_in_new),

  /// Share the file.
  share(Icons.share_outlined),

  /// Save a copy where the user picks.
  saveAs(Icons.save_alt_outlined),

  /// Show the folder of the file.
  showInFolder(Icons.folder_open_outlined),

  /// Open the thread it came from.
  thread(Icons.article_outlined),

  /// Open the downloads page.
  manager(Icons.download_outlined),

  /// Remove it (and its file).
  delete(Icons.delete_outline)
  ;

  const AttachmentDownloadActionKind(this.icon);

  /// Icon.
  final IconData icon;

  /// Label.
  String label(BuildContext context) {
    final tr = context.t.attachmentDownload;
    return switch (this) {
      cancel => tr.cancel,
      retry => tr.retry,
      purchase => tr.purchase,
      open => tr.open,
      share => tr.share,
      saveAs => tr.saveAs,
      showInFolder => tr.showInFolder,
      thread => tr.thread,
      manager => tr.title,
      delete => tr.delete,
    };
  }
}

/// The actions of [item], the main one first (`primary`); [inSheet] adds the downloads page.
List<({AttachmentDownloadActionKind kind, bool primary})> attachmentDownloadActionsOf(
  AttachmentDownload item, {
  bool inSheet = false,
}) {
  final kinds = <AttachmentDownloadActionKind>[
    if (item.status.active) AttachmentDownloadActionKind.cancel,
    if (item.status == AttachmentDownloadStatus.failed && item.purchaseUrl != null)
      AttachmentDownloadActionKind.purchase,
    if (item.status == AttachmentDownloadStatus.failed || item.status == AttachmentDownloadStatus.cancelled)
      AttachmentDownloadActionKind.retry,
    if (item.status == AttachmentDownloadStatus.completed && item.path != null) ...[
      AttachmentDownloadActionKind.open,
      if (canShareDownloadedFile) AttachmentDownloadActionKind.share,
      if (isMobile) AttachmentDownloadActionKind.saveAs,
      if (isDesktop) AttachmentDownloadActionKind.showInFolder,
    ],
    if (!inSheet && item.tid != null) AttachmentDownloadActionKind.thread,
    if (inSheet) AttachmentDownloadActionKind.manager,
    if (!inSheet) AttachmentDownloadActionKind.delete,
  ];
  return [for (final (i, kind) in kinds.indexed) (kind: kind, primary: i == 0)];
}

/// Do [kind] with [item].
Future<void> runAttachmentDownloadAction(
  BuildContext context,
  AttachmentDownload item,
  AttachmentDownloadActionKind kind,
) async {
  final manager = AttachmentDownloadManager.app;
  final tr = context.t.attachmentDownload;
  final path = item.path;
  switch (kind) {
    case AttachmentDownloadActionKind.cancel:
      await manager?.cancel(item.uid, item.id);
    case AttachmentDownloadActionKind.retry:
      await manager?.retry(item.uid, item.id);
    case AttachmentDownloadActionKind.purchase:
      // The forum's purchase, as the link of the post goes.
      await context.dispatchAsUrl(item.purchaseUrl!);
    case AttachmentDownloadActionKind.open:
      final origin = _originOf(context);
      final opened = path != null && await openDownloadedFile(path, origin: origin);
      if (!opened && context.mounted) {
        showSnackBar(context: context, message: tr.openFailed);
      }
    case AttachmentDownloadActionKind.share:
      if (path != null) {
        await shareDownloadedFile(path, origin: _originOf(context));
      }
    case AttachmentDownloadActionKind.saveAs:
      if (path == null) {
        return;
      }
      final saved = await saveDownloadedFileAs(path, item.filename);
      if (saved != null && context.mounted) {
        showSnackBar(
          context: context,
          message: tr.saved(path: saved),
        );
      }
    case AttachmentDownloadActionKind.showInFolder:
      if (path != null) {
        await showDownloadedFileFolder(path);
      }
    case AttachmentDownloadActionKind.thread:
      await context.pushNamed(ScreenPaths.threadV1, queryParameters: {'tid': item.tid});
    case AttachmentDownloadActionKind.manager:
      final router = GoRouter.of(context);
      Navigator.of(context).pop();
      unawaited(router.pushNamed(ScreenPaths.attachmentDownloads));
    case AttachmentDownloadActionKind.delete:
      final ok = await showQuestionDialog(
        context: context,
        title: tr.deleteTitle,
        message: tr.deleteMessage(name: item.filename),
        dangerous: true,
      );
      if (ok ?? false) {
        await manager?.remove(item.uid, item.id);
      }
  }
}

Rect? _originOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) {
    return null;
  }
  return box.localToGlobal(Offset.zero) & box.size;
}
