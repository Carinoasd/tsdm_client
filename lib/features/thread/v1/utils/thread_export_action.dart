import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/image/utils/image_actions.dart' show canShareImageFiles;
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/post_export.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// What the export dialog asks.
@immutable
final class ThreadExportChoice {
  /// Constructor.
  const ThreadExportChoice({required this.format, required this.allPages, required this.share});

  /// Plain text or Markdown.
  final PostExportFormat format;

  /// Every page of the thread, not only the floors loaded.
  final bool allPages;

  /// Hand the file to the share sheet instead of saving it where the user picks.
  final bool share;
}

/// Ask what to export of the thread on [state] and write it out: saved where the user picks, or shared.
Future<void> exportThread(BuildContext context, ThreadState state) async {
  final tid = state.tid;
  if (tid == null) {
    return;
  }
  // Everything the work needs is taken before the first await: the page may be rebuilt meanwhile.
  final repository = RepositoryProvider.of<ThreadRepository>(context);
  final choice = await showDialog<ThreadExportChoice>(
    context: context,
    builder: (_) => _ExportDialog(canLoadAll: !state.isOffline),
  );
  if (choice == null || !context.mounted) {
    return;
  }
  final List<Post> posts;
  if (choice.allPages) {
    final loaded = await _loadAllPages(context, repository, state);
    if (loaded == null) {
      return;
    }
    posts = loaded;
  } else {
    posts = state.postList;
  }
  if (!context.mounted) {
    return;
  }
  final title = state.title ?? tid;
  final text = buildThreadExport(
    title: title,
    posts: posts,
    format: choice.format,
    url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
  );
  final fileName = threadExportFileName(title: title, tid: tid, format: choice.format);
  await writeExportFile(
    context,
    Uint8List.fromList(utf8.encode(text)),
    fileName: fileName,
    mimeType: choice.format.mimeType,
    share: choice.share,
  );
}

/// Every floor of the thread, page after page as the thread page asks them (same author filter and order), or null
/// when the user cancelled or a page could not be had (told then).
Future<List<Post>?> _loadAllPages(BuildContext context, ThreadRepository repository, ThreadState state) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final progress = ValueNotifier<({int page, int total})>((page: 1, total: 1));
  var cancelled = false;
  var dialogOpen = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder(
            valueListenable: progress,
            builder: (_, value, _) => Row(
              children: [
                const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
                const SizedBox(width: 16),
                Flexible(
                  child: Text(context.t.threadExport.progress(page: value.page, total: value.total)),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                dialogOpen = false;
                Navigator.of(dialogContext).pop();
              },
              child: Text(context.t.threadExport.cancel),
            ),
          ],
        ),
      ),
    ),
  );
  void closeDialog() {
    if (dialogOpen) {
      dialogOpen = false;
      navigator.pop();
    }
  }

  final posts = <Post>[];
  var total = 1;
  try {
    for (var page = 1; page <= total; page++) {
      if (cancelled) {
        return null;
      }
      progress.value = (page: page, total: total);
      final answer = await repository
          .fetchThreadPage(
            tid: state.tid,
            pageNumber: page,
            onlyVisibleUid: state.onlyVisibleUid,
            reverseOrder: state.reverseOrder,
            exactOrder: state.exactOrder,
          )
          .run();
      if (cancelled) {
        return null;
      }
      final info = answer.match((_) => null, (v) => v);
      if (info == null || !info.havePermission) {
        closeDialog();
        if (context.mounted) {
          showSnackBar(context: context, message: context.t.threadExport.failed);
        }
        return null;
      }
      posts.addAll(info.postList);
      total = info.totalPages < 1 ? 1 : info.totalPages;
    }
    return posts;
  } finally {
    closeDialog();
    progress.dispose();
  }
}

/// Write [data] as [fileName]: shared as a file ([share]), or saved where the user picks.
///
/// Tells the user where it went, or that it failed.
Future<void> writeExportFile(
  BuildContext context,
  Uint8List data, {
  required String fileName,
  required String mimeType,
  required bool share,
}) async {
  final tr = context.t.threadExport;
  try {
    if (share) {
      final folder = Directory(path.join((await getTemporaryDirectory()).path, 'shared_exports'));
      if (folder.existsSync()) {
        await folder.delete(recursive: true);
      }
      await folder.create(recursive: true);
      final file = await File(path.join(folder.path, fileName)).writeAsBytes(data, flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: mimeType, name: fileName)],
        ),
      );
      return;
    }
    final String? filePath;
    if (isDesktop) {
      // On desktop platforms, `saveFile` only returns the selected path.
      filePath = await FilePicker.platform.saveFile(dialogTitle: tr.save, fileName: fileName);
      if (filePath == null) {
        return;
      }
      await File(filePath).writeAsBytes(data, flush: true);
    } else {
      // Mobile in one step.
      filePath = await FilePicker.platform.saveFile(dialogTitle: tr.save, fileName: fileName, bytes: data);
      if (filePath == null) {
        return;
      }
    }
    if (context.mounted) {
      showSnackBar(
        context: context,
        message: tr.saved(filePath: filePath),
      );
    }
  } on Exception catch (e, st) {
    talker.handle(e, st, 'failed to export a thread');
    if (context.mounted) {
      showSnackBar(context: context, message: tr.failed);
    }
  }
}

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.canLoadAll});

  final bool canLoadAll;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  PostExportFormat _format = PostExportFormat.markdown;
  bool _allPages = false;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadExport;
    return AlertDialog(
      title: Text(tr.menu),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<PostExportFormat>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: PostExportFormat.plainText, label: Text(tr.plain)),
              ButtonSegment(value: PostExportFormat.markdown, label: Text(tr.markdown)),
            ],
            selected: {_format},
            onSelectionChanged: (v) => setState(() => _format = v.first),
          ),
          if (widget.canLoadAll) ...[
            const SizedBox(height: 16),
            SegmentedButton<bool>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: false, label: Text(tr.loaded)),
                ButtonSegment(value: true, label: Text(tr.all)),
              ],
              selected: {_allPages},
              onSelectionChanged: (v) => setState(() => _allPages = v.first),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr.cancel)),
        if (canShareImageFiles)
          TextButton(
            onPressed: () => Navigator.of(
              context,
            ).pop(ThreadExportChoice(format: _format, allPages: _allPages, share: true)),
            child: Text(tr.share),
          ),
        FilledButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(ThreadExportChoice(format: _format, allPages: _allPages, share: false)),
          child: Text(tr.save),
        ),
      ],
    );
  }
}
