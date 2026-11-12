import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/attachment_download/models/attachment_download.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_manager.dart';
import 'package:tsdm_client/features/attachment_download/widgets/attachment_download_actions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The attachment downloads of the account in use: running, unfinished (failed, cancelled) and completed, the newest
/// first in each.
class AttachmentDownloadsPage extends StatefulWidget {
  /// Constructor.
  const AttachmentDownloadsPage({super.key});

  @override
  State<AttachmentDownloadsPage> createState() => _AttachmentDownloadsPageState();
}

class _AttachmentDownloadsPageState extends State<AttachmentDownloadsPage> {
  late int _uid;
  bool _loaded = false;
  StreamSubscription<AuthStatus>? _auth;

  AttachmentDownloadManager? get _manager => AttachmentDownloadManager.app;

  @override
  void initState() {
    super.initState();
    final auth = context.readOrNull<AuthenticationRepository>();
    _uid = auth?.effectiveCurrentUid ?? currentDownloadUid();
    // Another account in use: its downloads, never the previous one's.
    _auth = auth?.status.listen((_) {
      final uid = auth.effectiveCurrentUid ?? 0;
      if (uid != _uid && mounted) {
        setState(() {
          _uid = uid;
          _loaded = false;
        });
        unawaited(_load());
      }
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_auth?.cancel());
    super.dispose();
  }

  Future<void> _load() async {
    final uid = _uid;
    await _manager?.load(uid);
    if (mounted && uid == _uid) {
      setState(() => _loaded = true);
    }
  }

  Widget _buildItem(BuildContext context, AttachmentDownload item) {
    final tr = context.t.attachmentDownload;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final (icon, color) = switch (item.status) {
      AttachmentDownloadStatus.queued || AttachmentDownloadStatus.running => (Icons.downloading, colorScheme.primary),
      AttachmentDownloadStatus.completed => (Icons.insert_drive_file_outlined, colorScheme.primary),
      AttachmentDownloadStatus.failed || AttachmentDownloadStatus.cancelled => (Icons.error_outline, colorScheme.error),
    };
    final thread = item.threadTitle != null
        ? context.displayText(item.threadTitle!)
        : (item.tid == null ? null : tr.threadFallback(tid: item.tid!));
    final info = [
      attachmentDownloadSizeLine(context, item),
      ?thread,
      (item.finishedAt ?? item.createdAt).yyyyMMDDHHMM(),
    ].where((e) => e.isNotEmpty).join(' · ');
    final failure = switch (item.status) {
      AttachmentDownloadStatus.failed => context.displayTextOr(item.message, tr.failedGeneric),
      AttachmentDownloadStatus.cancelled => tr.cancelled,
      _ => null,
    };
    final actions = attachmentDownloadActionsOf(item);
    final primary = actions.firstOrNull;
    final rest = actions.skip(1).toList();
    return AppSurface(
      key: ValueKey('attachment-download-${item.id}'),
      padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
      onTap: () async => showAttachmentDownloadSheet(context, item),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(icon, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.filename, maxLines: 2, overflow: TextOverflow.ellipsis, style: textTheme.titleSmall),
                if (item.status.active) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(value: item.status == AttachmentDownloadStatus.queued ? null : item.progress),
                ],
                const SizedBox(height: 4),
                Text(info, maxLines: 2, overflow: TextOverflow.ellipsis, style: textTheme.labelSmall),
                if (failure != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    failure,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
                  ),
                ],
              ],
            ),
          ),
          if (primary != null)
            IconButton(
              key: ValueKey('attachment-download-${primary.kind.name}-${item.id}'),
              tooltip: primary.kind.label(context),
              icon: Icon(primary.kind.icon),
              onPressed: () async => runAttachmentDownloadAction(context, item, primary.kind),
            ),
          if (rest.isNotEmpty)
            PopupMenuButton<AttachmentDownloadActionKind>(
              key: ValueKey('attachment-download-menu-${item.id}'),
              onSelected: (kind) async => runAttachmentDownloadAction(context, item, kind),
              itemBuilder: (context) => [
                for (final action in rest)
                  PopupMenuItem(
                    value: action.kind,
                    child: Row(
                      children: [
                        Icon(
                          action.kind.icon,
                          color: action.kind == AttachmentDownloadActionKind.delete ? colorScheme.error : null,
                        ),
                        const SizedBox(width: 12),
                        Text(action.kind.label(context)),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.attachmentDownload;
    final manager = _manager;
    return Scaffold(
      appBar: AppBar(title: Text(tr.title)),
      body: SafeArea(
        bottom: false,
        child: manager == null || !_loaded
            ? const CenteredCircularIndicator()
            : ListenableBuilder(
                listenable: manager,
                builder: (context, _) {
                  final items = manager.itemsOf(_uid);
                  if (items.isEmpty) {
                    return AppStateView(icon: Icons.download_outlined, message: tr.empty);
                  }
                  final groups = [
                    (
                      'active',
                      tr.active,
                      Icons.downloading,
                      items.where((e) => e.status.active).toList(),
                    ),
                    (
                      'failed',
                      tr.failed,
                      Icons.error_outline,
                      items
                          .where(
                            (e) =>
                                e.status == AttachmentDownloadStatus.failed ||
                                e.status == AttachmentDownloadStatus.cancelled,
                          )
                          .toList(),
                    ),
                    (
                      'completed',
                      tr.completed,
                      Icons.download_done,
                      items.where((e) => e.status == AttachmentDownloadStatus.completed).toList(),
                    ),
                  ].where((e) => e.$4.isNotEmpty);
                  return AppCenteredList(
                    builder: (context, side, _) => ListView(
                      padding: side.copyWith(top: 12, bottom: 24),
                      children: [
                        for (final (key, title, icon, list) in groups) ...[
                          Padding(
                            key: ValueKey('attachment-downloads-$key'),
                            padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                            child: Row(
                              children: [
                                Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
                                const SizedBox(width: 8),
                                Text(title, style: Theme.of(context).textTheme.titleSmall),
                              ],
                            ),
                          ),
                          for (final item in list) ...[_buildItem(context, item), appListSeparator],
                        ],
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}
