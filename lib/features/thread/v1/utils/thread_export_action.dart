import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/image/utils/image_actions.dart' show canShareImageFiles;
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/post_export.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_pdf_export_action.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/export_file.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// Floors under which the export is built on the UI isolate: starting an isolate costs more than it saves.
const _inlineFloors = 40;

/// The wait between two pages of an export of every page: a thread of hundreds of pages in a burst could be taken for
/// flooding by the forum.
const _pageInterval = Duration(milliseconds: 300);

/// The marks of the exported text in the language of the app.
PostExportLabels exportLabelsOf(BuildContext context) {
  final tr = context.t.threadExport;
  return PostExportLabels(
    fold: tr.labelFold,
    hidden: tr.labelHidden,
    image: tr.labelImage,
    media: tr.labelMedia,
    smiley: tr.labelSmiley,
  );
}

/// Copy the content of [post] to the clipboard as [format]; nothing when it has no text.
Future<void> copyPostAsText(BuildContext context, Post post, PostExportFormat format) async {
  final text = postHtmlToText(post.data, format: format, labels: exportLabelsOf(context));
  if (text.isEmpty) {
    return;
  }
  await copyToClipboard(context, text);
}

@immutable
final class _ExportJob {
  const _ExportJob({
    required this.title,
    required this.floors,
    required this.format,
    required this.url,
    required this.labels,
  });

  final String title;
  final List<ExportFloor> floors;
  final PostExportFormat format;
  final String url;
  final PostExportLabels labels;
}

String _runExport(_ExportJob job) => buildThreadExportOfFloors(
  title: job.title,
  floors: job.floors,
  format: job.format,
  url: job.url,
  labels: job.labels,
);

/// What the export dialog asks.
@immutable
final class ThreadExportChoice {
  /// Constructor.
  const ThreadExportChoice({required this.kind, required this.allPages, required this.share});

  /// What is written.
  final ThreadExportKind kind;

  /// The format of the text, null for a PDF.
  PostExportFormat? get format => switch (kind) {
    ThreadExportKind.plainText => PostExportFormat.plainText,
    ThreadExportKind.markdown => PostExportFormat.markdown,
    ThreadExportKind.pdf => null,
  };

  /// Whether a PDF is written.
  bool get pdf => kind == ThreadExportKind.pdf;

  /// Every page of the thread, not only the floors loaded.
  final bool allPages;

  /// Hand the file to the share sheet instead of saving it where the user picks.
  final bool share;
}

/// What the export writes.
enum ThreadExportKind {
  /// Plain text.
  plainText,

  /// Markdown.
  markdown,

  /// A PDF.
  pdf,
}

/// Whether an export is on its way: a second one would only make a second file.
bool _exporting = false;

/// Ask what to export of the thread on [state] and write it out: saved where the user picks, or shared.
Future<void> exportThread(BuildContext context, ThreadState state) async {
  final tid = state.tid;
  if (tid == null || _exporting) {
    return;
  }
  _exporting = true;
  try {
    await _exportThread(context, state, tid);
  } finally {
    _exporting = false;
  }
}

Future<void> _exportThread(BuildContext context, ThreadState state, String tid) async {
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
    final progress = ExportProgressDialog()..open(context);
    List<Post>? loaded;
    try {
      loaded = await loadAllThreadPages(context, repository, state, progress);
    } finally {
      // The PDF goes on in the same dialog.
      if (!choice.pdf || loaded == null || !context.mounted) {
        progress.close();
      }
    }
    if (loaded == null || !context.mounted) {
      return;
    }
    if (choice.pdf) {
      await exportThreadPdf(
        context,
        title: state.title ?? tid,
        tid: tid,
        posts: loaded,
        share: choice.share,
        progress: progress,
      );
      return;
    }
    posts = loaded;
  } else {
    posts = state.postList;
  }
  if (!context.mounted) {
    return;
  }
  final format = choice.format;
  if (format == null) {
    await exportThreadPdf(context, title: state.title ?? tid, tid: tid, posts: posts, share: choice.share);
    return;
  }
  final title = state.title ?? tid;
  // Thousands of floors are parsed one by one: off the UI isolate.
  final job = _ExportJob(
    title: title,
    floors: posts.map(exportFloorOf).toList(),
    format: format,
    url: '$baseUrl/forum.php?mod=viewthread&tid=$tid',
    labels: exportLabelsOf(context),
  );
  final String text;
  try {
    text = posts.length < _inlineFloors ? _runExport(job) : await compute(_runExport, job);
  } on Object catch (e, st) {
    talker.handle(e, st, 'failed to build the export of a thread');
    if (context.mounted) {
      showSnackBar(context: context, message: context.t.threadExport.failed);
    }
    return;
  }
  if (!context.mounted) {
    return;
  }
  final fileName = threadExportFileName(title: title, tid: tid, format: format);
  await writeExportFile(
    context,
    Uint8List.fromList(utf8.encode(text)),
    fileName: fileName,
    mimeType: format.mimeType,
    share: choice.share,
  );
}

/// Every floor of the thread, page after page as the thread page asks them (same author filter and order), or null
/// when the user cancelled through [progress] or a page could not be had (told then, [progress] closed).
Future<List<Post>?> loadAllThreadPages(
  BuildContext context,
  ThreadRepository repository,
  ThreadState state,
  ExportProgressDialog progress,
) async {
  final tr = context.t.threadExport;
  final posts = <Post>[];
  var total = 1;
  for (var page = 1; page <= total; page++) {
    if (progress.cancelled) {
      return null;
    }
    progress.update(
      tr.progress(page: page, total: total),
      value: total > 1 ? (page - 1) / total : null,
    );
    if (page > 1) {
      await Future<void>.delayed(_pageInterval);
      if (progress.cancelled) {
        return null;
      }
    }
    final answer = await repository
        .fetchThreadPage(
          tid: state.tid,
          pageNumber: page,
          onlyVisibleUid: state.onlyVisibleUid,
          reverseOrder: state.reverseOrder,
          exactOrder: state.exactOrder,
        )
        .run();
    if (progress.cancelled) {
      return null;
    }
    final info = answer.match((_) => null, (v) => v);
    if (info == null || !info.havePermission) {
      progress.close();
      if (context.mounted) {
        showSnackBar(context: context, message: tr.failed);
      }
      return null;
    }
    posts.addAll(info.postList);
    total = info.totalPages < 1 ? 1 : info.totalPages;
  }
  return posts;
}

/// The dialog telling how far an export is, with a button cancelling it.
final class ExportProgressDialog {
  final _state = ValueNotifier<({String text, double? value})>((text: '', value: null));
  NavigatorState? _navigator;
  bool _open = false;
  bool _disposed = false;

  /// Whether the user cancelled.
  bool get cancelled => _cancelled;
  bool _cancelled = false;

  /// Called when the user cancels.
  VoidCallback? onCancel;

  /// Shows the dialog over [context].
  void open(BuildContext context) {
    _navigator = Navigator.of(context, rootNavigator: true);
    _open = true;
    final cancel = context.t.threadExport.cancel;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: ValueListenableBuilder(
              valueListenable: _state,
              builder: (_, state, _) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(state.text),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(value: state.value),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  _cancelled = true;
                  _open = false;
                  Navigator.of(dialogContext).pop();
                  onCancel?.call();
                },
                child: Text(cancel),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Shows [text] and how much is done ([value] 0 to 1, null when unknown).
  void update(String text, {double? value}) {
    if (!_disposed) {
      _state.value = (text: text, value: value);
    }
  }

  /// Closes the dialog, when the user did not.
  void close() {
    if (_open) {
      _open = false;
      _navigator?.pop();
    }
    if (!_disposed) {
      _disposed = true;
      // After the dialog is gone: its builder listens until then.
      WidgetsBinding.instance.addPostFrameCallback((_) => _state.dispose());
    }
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
    final filePath = await shareOrSaveFile(
      data,
      fileName: fileName,
      mimeType: mimeType,
      share: share,
      dialogTitle: tr.save,
    );
    if (filePath == null) {
      return;
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
  ThreadExportKind _kind = ThreadExportKind.markdown;
  bool _allPages = false;

  ThreadExportChoice _choice({required bool share}) =>
      ThreadExportChoice(kind: _kind, allPages: _allPages, share: share);

  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadExport;
    return AlertDialog(
      title: Text(tr.menu),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<ThreadExportKind>(
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: ThreadExportKind.plainText, label: Text(tr.plain)),
              ButtonSegment(value: ThreadExportKind.markdown, label: Text(tr.markdown)),
              ButtonSegment(value: ThreadExportKind.pdf, label: Text(tr.pdf)),
            ],
            selected: {_kind},
            onSelectionChanged: (v) => setState(() => _kind = v.first),
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
            onPressed: () => Navigator.of(context).pop(_choice(share: true)),
            child: Text(tr.share),
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_choice(share: false)),
          child: Text(tr.save),
        ),
      ],
    );
  }
}
