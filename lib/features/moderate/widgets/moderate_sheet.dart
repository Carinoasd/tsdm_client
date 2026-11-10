import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/view/split_thread_page.dart';
import 'package:tsdm_client/features/thread_link_card/models/thread_link_card_info.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// What a management of the thread page changed.
enum ModerateDone {
  /// The thread is still there, changed (stuck, digested, closed, moved…): load it again.
  changed,

  /// The thread was deleted: leave it.
  deleted,
}

/// Icon of an operation.
IconData moderateOperationIcon(ModerateOperation operation) => switch (operation) {
  ModerateOperation.stick => Icons.vertical_align_top_outlined,
  ModerateOperation.digest => Icons.star_outline,
  ModerateOperation.highlight => Icons.format_color_text_outlined,
  ModerateOperation.recommend => Icons.recommend_outlined,
  ModerateOperation.stamp => Icons.approval_outlined,
  ModerateOperation.stamplist => Icons.label_outline,
  ModerateOperation.close => Icons.lock_outline,
  ModerateOperation.open => Icons.lock_open_outlined,
  ModerateOperation.move => Icons.drive_file_move_outline,
  ModerateOperation.type => Icons.category_outlined,
  ModerateOperation.copy => Icons.copy_all_outlined,
  ModerateOperation.merge => Icons.merge_type,
  ModerateOperation.split => Icons.call_split,
  ModerateOperation.repair => Icons.build_outlined,
  ModerateOperation.delete => Icons.delete_outline,
  ModerateOperation.bump => Icons.arrow_upward_outlined,
  ModerateOperation.down => Icons.arrow_downward_outlined,
};

/// Name of an operation.
String moderateOperationName(BuildContext context, ModerateOperation operation) {
  final tr = context.t.moderate;
  return switch (operation) {
    ModerateOperation.stick => tr.stick,
    ModerateOperation.digest => tr.digest,
    ModerateOperation.highlight => tr.highlight,
    ModerateOperation.recommend => tr.recommend,
    ModerateOperation.stamp => tr.stamp,
    ModerateOperation.stamplist => tr.stamplist,
    ModerateOperation.close => tr.close,
    ModerateOperation.open => tr.open,
    ModerateOperation.move => tr.move,
    ModerateOperation.type => tr.type,
    ModerateOperation.copy => tr.copy,
    ModerateOperation.merge => tr.merge,
    ModerateOperation.split => tr.split,
    ModerateOperation.repair => tr.repair,
    ModerateOperation.delete => tr.delete,
    ModerateOperation.bump => tr.bump,
    ModerateOperation.down => tr.down,
  };
}

/// The operations offered on a thread: stick, digest, highlight, recommend, stamp and icon, close or open (the one
/// that changes it: [closed] is the lock beside the title), bump and sink, category, move, copy, merge, split, repair,
/// and delete last.
List<ModerateOperation> moderateOperationsFor({required bool closed}) => [
  ModerateOperation.stick,
  ModerateOperation.digest,
  ModerateOperation.highlight,
  ModerateOperation.recommend,
  ModerateOperation.stamp,
  ModerateOperation.stamplist,
  if (closed) ModerateOperation.open else ModerateOperation.close,
  ModerateOperation.bump,
  ModerateOperation.down,
  ModerateOperation.type,
  ModerateOperation.move,
  ModerateOperation.copy,
  ModerateOperation.merge,
  ModerateOperation.split,
  ModerateOperation.repair,
  ModerateOperation.delete,
];

/// The operations offered on several threads at once: both close and open (the threads may be either), bump and sink,
/// category, and delete last. The stamp, the icon, copy, merge, split and repair act on one thread only.
const List<ModerateOperation> moderateBatchOperations = [
  ModerateOperation.stick,
  ModerateOperation.digest,
  ModerateOperation.highlight,
  ModerateOperation.close,
  ModerateOperation.open,
  ModerateOperation.bump,
  ModerateOperation.down,
  ModerateOperation.type,
  ModerateOperation.move,
  ModerateOperation.delete,
];

/// Let the moderator pick one of [operations], delete last and apart.
Future<ModerateOperation?> _pickOperation(BuildContext context, List<ModerateOperation> operations) =>
    showModalBottomSheet<ModerateOperation>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final op in operations) ...[
                if (op == ModerateOperation.delete) const Divider(height: 1),
                ListTile(
                  leading: Icon(
                    moderateOperationIcon(op),
                    color: op == ModerateOperation.delete ? Theme.of(context).colorScheme.error : null,
                  ),
                  title: Text(
                    moderateOperationName(context, op),
                    style: op == ModerateOperation.delete
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                  ),
                  onTap: () => Navigator.of(context).pop(op),
                ),
              ],
            ],
          ),
        ),
      ),
    );

/// Offer the management of threads [threads] (tid and title, in the list's order) of forum [fid] to a moderator: pick
/// an operation, fill in the forum's window of it once, send it for every thread; the threads not done are listed
/// with why. Null when nothing was sent.
Future<ModerateBatchReport?> showBatchModerateSheet(
  BuildContext context, {
  required List<(String, String)> threads,
  required int fid,
  ModerateRepository? repository,
}) async {
  final operation = await _pickOperation(context, moderateBatchOperations);
  if (operation == null || !context.mounted) {
    return null;
  }
  final report = await showDialog<ModerateBatchReport>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ModerateDialog.batch(
      operation: operation,
      tids: [for (final (tid, _) in threads) tid],
      fid: fid,
      repository: repository ?? ModerateRepository.network(),
    ),
  );
  if (report == null || !context.mounted) {
    return report;
  }
  final failed = report.failed;
  if (failed.isEmpty) {
    showSnackBar(
      context: context,
      message: context.t.moderate.batch.done(count: report.doneCount),
    );
    return report;
  }
  final titles = {for (final (tid, title) in threads) tid: title};
  await showDialog<void>(
    context: context,
    builder: (context) => CustomAlertDialog.sync(
      title: AppDialogTitle(
        icon: moderateOperationIcon(operation),
        title: context.t.moderate.batch.failed(count: failed.length),
        error: true,
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (tid, failure) in failed)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(titles[tid] ?? tid, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: SelectableText(switch (failure.kind) {
                  ModerateBatchFailure.refused when failure.message.isNotEmpty => failure.message,
                  ModerateBatchFailure.accountChanged => context.t.general.accountChangedRetry,
                  ModerateBatchFailure.unknown => context.t.moderate.batch.unknown,
                  _ => context.t.moderate.failed,
                }),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.ok))],
    ),
  );
  return report;
}

/// Offer the management of thread [tid] in forum [fid] to a moderator: pick an operation, fill in the forum's window
/// of it, send it. Null when nothing was done.
///
/// A split picks its floors on a page of its own ([openSplitThreadPage]); once done, the new thread is offered to open.
Future<ModerateDone?> showThreadModerateSheet(
  BuildContext context, {
  required String tid,
  required int fid,
  required bool closed,
  ModerateRepository? repository,
}) async {
  final operation = await _pickOperation(context, moderateOperationsFor(closed: closed));
  if (operation == null || !context.mounted) {
    return null;
  }
  if (operation == ModerateOperation.split) {
    final split = await openSplitThreadPage(
      context,
      tid: tid,
      fid: fid,
      repository: repository ?? ModerateRepository.network(),
    );
    if (split == null) {
      return null;
    }
    if (context.mounted) {
      showSnackBar(
        context: context,
        message: split.message.isNotEmpty ? split.message : context.t.moderate.done,
        action: SnackBarAction(
          label: context.t.moderate.openNewThread,
          onPressed: () {
            if (context.mounted) {
              unawaited(
                context.pushNamed(
                  ScreenPaths.threadV1,
                  queryParameters: {'pid': split.pid, 'appBarTitle': split.subject},
                ),
              );
            }
          },
        ),
      );
    }
    return ModerateDone.changed;
  }
  final done = await showDialog<bool>(
    context: context,
    builder: (_) => ModerateDialog(
      operation: operation,
      tid: tid,
      fid: fid,
      repository: repository ?? ModerateRepository.network(),
    ),
  );
  if (done != true) {
    return null;
  }
  return operation == ModerateOperation.delete ? ModerateDone.deleted : ModerateDone.changed;
}

/// The window of [operation] on thread [tid] in forum [fid]: loads the forum's window, lets the moderator choose and
/// sends it. Pops true once the forum carried it out.
class ModerateDialog extends StatefulWidget {
  /// Constructor.
  const ModerateDialog({
    required this.operation,
    required this.tid,
    required this.fid,
    required this.repository,
    this.imageBuilder,
    super.key,
  }) : tids = null;

  /// The window of [operation] on threads [tids] of forum [fid]: the forum's window of them, sent for every thread
  /// ([ModerateRepository.runBatch]). Pops the [ModerateBatchReport] once sent.
  ModerateDialog.batch({
    required this.operation,
    required List<String> this.tids,
    required this.fid,
    required this.repository,
    this.imageBuilder,
    super.key,
  }) : assert(tids.isNotEmpty, 'no thread to manage'),
       tid = tids.first;

  /// The operation.
  final ModerateOperation operation;

  /// The thread, the first of [tids] for several.
  final String tid;

  /// The threads of a management of several threads; null for one thread.
  final List<String>? tids;

  /// The forum of the thread.
  final int fid;

  /// Where the window comes from and goes to.
  final ModerateRepository repository;

  /// Builds the picture of a stamp or an icon at its url; the app's cached image when null.
  final Widget Function(String url)? imageBuilder;

  @override
  State<ModerateDialog> createState() => _ModerateDialogState();
}

class _ModerateDialogState extends State<ModerateDialog> {
  ModerateForm? _form;

  /// The window of the threads, for several.
  ModerateBatchForm? _batch;
  bool _loading = true;
  bool _sending = false;

  /// The forum's refusal, or why the window could not be had.
  String? _error;

  /// The window came without the operation: asking again changes nothing.
  bool _unavailable = false;

  String? _level;
  DateTime? _expiration;
  String? _moveTo;
  bool _redirect = false;
  bool _notify = false;
  ModerateHighlight _highlight = const ModerateHighlight();
  bool _recommend = true;

  /// The stamp, icon or category chosen.
  String? _choice;

  /// The categories of the forum to copy to, once loaded.
  List<ModerateChoice>? _threadTypes;
  String? _threadType;
  bool _typesLoading = false;
  bool _typesFailed = false;

  /// The categories asked last: an earlier answer is dropped.
  int _typesAsked = 0;
  final _reason = TextEditingController();
  final _recommendTitle = TextEditingController();

  /// The thread to merge, as typed; the thread it names ([moderateMergeTidOf]), and that thread as the forum served
  /// it, or why not.
  final _mergeInput = TextEditingController();
  String? _mergeTid;
  ThreadLinkCardInfo? _mergeThread;
  bool _mergeLoading = false;
  String? _mergeError;
  Timer? _mergeTimer;

  /// The thread to merge asked last: an earlier answer is dropped.
  int _mergeAsked = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _reason.dispose();
    _recommendTitle.dispose();
    _mergeInput.dispose();
    _mergeTimer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _unavailable = false;
    });
    if (widget.tids case final tids?) {
      final answer = await widget.repository.fetchBatchWindow(widget.operation, tids: tids, fid: widget.fid).run();
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        switch (answer) {
          case Right(value: ModerateBatchWindowReady(:final form)):
            _batch = form;
            _took(form.window);
          case Right(value: ModerateBatchWindowRefused(:final message, :final unavailable)):
            _unavailable = unavailable;
            _error = message.isNotEmpty
                ? message
                : unavailable
                ? context.t.moderate.unavailable
                : context.t.moderate.failed;
          case Left(:final value):
            _error = _failure(value);
        }
      });
      return;
    }
    final answer = await widget.repository.fetchWindow(widget.operation, tid: widget.tid, fid: widget.fid).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      switch (answer) {
        case Right(value: ModerateWindowReady(:final form)):
          _took(form);
        case Right(value: ModerateWindowRefused(:final message, :final unavailable)):
          _unavailable = unavailable;
          _error = message.isNotEmpty
              ? message
              : unavailable
              ? context.t.moderate.unavailable
              : context.t.moderate.failed;
        case Left(:final value):
          _error = _failure(value);
      }
    });
  }

  /// Fill the choices in as window [form] serves them.
  void _took(ModerateForm form) {
    _form = form;
    _level = form.currentLevel?.value;
    _notify = form.notifyForced;
    _expiration = form.expiration;
    _highlight = form.highlight ?? const ModerateHighlight();
    _recommendTitle.text = form.recommendTitle ?? '';
    // As the website's select: the thread's own, or the first (none) of a stamp or an icon; a category is picked.
    _choice =
        form.currentChoice?.value ??
        (form.operation == ModerateOperation.stamp || form.operation == ModerateOperation.stamplist
            ? form.choices.firstOrNull?.value
            : null);
  }

  /// Copy to forum [fid]: its categories are loaded, the first chosen as the website's select does.
  Future<void> _pickCopyTarget(String fid) async {
    final asked = ++_typesAsked;
    setState(() {
      _moveTo = fid;
      _threadTypes = null;
      _threadType = null;
      _typesLoading = true;
      _typesFailed = false;
    });
    final answer = await widget.repository.fetchThreadTypes(int.parse(fid)).run();
    // Another forum picked meanwhile: its own answer counts.
    if (!mounted || asked != _typesAsked) {
      return;
    }
    setState(() {
      _typesLoading = false;
      switch (answer) {
        case Right(:final value):
          _threadTypes = value;
          _threadType = value.first.value;
        case Left():
          _typesFailed = true;
      }
    });
  }

  /// The thread to merge typed as [input]: looked up once the typing paused.
  void _typedMergeThread(String input) {
    final tid = moderateMergeTidOf(input);
    if (tid == _mergeTid) {
      return;
    }
    _mergeTimer?.cancel();
    // Whatever is on its way is for another thread.
    _mergeAsked++;
    // The forum merges another thread only: this one is not asked.
    final self = tid == widget.tid;
    setState(() {
      _mergeTid = tid;
      _mergeThread = null;
      _mergeError = self ? context.t.moderate.mergeSelf : null;
      _mergeLoading = tid != null && !self;
    });
    if (tid != null && !self) {
      _mergeTimer = Timer(const Duration(milliseconds: 400), () => _lookUpMergeThread(tid));
    }
  }

  /// Ask the forum for the first page of thread [tid], to show its title.
  Future<void> _lookUpMergeThread(String tid) async {
    final asked = ++_mergeAsked;
    setState(() {
      _mergeLoading = true;
      _mergeError = null;
    });
    final answer = await widget.repository.fetchThreadPage(tid).run();
    if (!mounted || asked != _mergeAsked) {
      return;
    }
    setState(() {
      _mergeLoading = false;
      switch (answer) {
        case Right(value: final page):
          _mergeThread = ThreadLinkCardInfo.ofPage(int.parse(tid), page);
          if (_mergeThread == null) {
            // The forum's words: no such thread, no permission.
            final message = page.permissionDeniedMessage?.text?.trim() ?? '';
            _mergeError = message.isNotEmpty ? message : context.t.general.failedToLoad;
          }
        case Left(:final value):
          _mergeError = _failure(value);
      }
    });
  }

  String _failure(AppException e) =>
      e is IdentityChangedException ? context.t.general.accountChangedRetry : context.t.general.failedToLoad;

  ModerateRequest _request() => ModerateRequest(
    operation: _operation,
    level: _level,
    expiration: _expiration,
    moveTo: _moveTo,
    redirect: _redirect,
    reason: _reason.text,
    notify: _notify,
    highlight: _highlight,
    recommend: _recommend,
    recommendTitle: _form?.recommendTitle == null ? null : _recommendTitle.text,
    choice: _choice,
    threadType: _threadType,
    otherTid: _mergeTid,
  );

  /// Several threads are managed together.
  bool get _isBatch => widget.tids != null;

  /// The operation done: the one picked, or the one the window checks (close and open of one thread).
  ModerateOperation get _operation => _isBatch ? widget.operation : _form?.operation ?? widget.operation;

  bool get _canSend =>
      _form != null &&
      !_sending &&
      (_form!.levels.isEmpty || _level != null) &&
      (_form!.choices.isEmpty || _choice != null) &&
      (_operation != ModerateOperation.move || (_moveTo ?? '').isNotEmpty) &&
      (_operation != ModerateOperation.copy || ((_moveTo ?? '').isNotEmpty && _threadType != null && !_typesLoading)) &&
      (_operation != ModerateOperation.merge || (_mergeThread != null && !_mergeLoading));

  Future<void> _send() async {
    final form = _form;
    if (form == null) {
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    if (_batch case final batch?) {
      final report = await widget.repository.runBatch(batch, _request(), tids: widget.tids!, fid: widget.fid);
      if (mounted) {
        Navigator.of(context).pop(report);
      }
      return;
    }
    final outcome = await widget.repository.submit(form, _request()).run();
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case Right(value: ModerateSucceeded(:final message)):
        showSnackBar(context: context, message: message.isNotEmpty ? message : context.t.moderate.done);
        Navigator.of(context).pop(true);
      case Right(value: ModerateRefused(:final message)):
        setState(() {
          _sending = false;
          _error = message.isNotEmpty ? message : context.t.moderate.failed;
        });
      case Left(:final value):
        setState(() {
          _sending = false;
          _error = value is IdentityChangedException
              ? context.t.general.accountChangedRetry
              : context.t.moderate.failed;
        });
    }
  }

  Future<void> _pickExpiration() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    // The forum takes a day after today and at most 180 days ahead (`checkexpiration`).
    final first = today.add(const Duration(days: 1));
    final picked = await showDatePicker(
      context: context,
      firstDate: first,
      lastDate: today.add(const Duration(days: 180)),
      initialDate: _expiration ?? first,
    );
    if (picked != null && mounted) {
      setState(() => _expiration = picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final danger = _operation == ModerateOperation.delete;
    final form = _form;
    final dialog = CustomAlertDialog.sync(
      title: AppDialogTitle(
        icon: moderateOperationIcon(_operation),
        title: !_isBatch
            ? moderateOperationName(context, _operation)
            : context.t.moderate.batch.title(
                operation: moderateOperationName(context, _operation),
                count: widget.tids!.length,
              ),
        error: danger,
      ),
      content: _loading
          ? const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (form != null) ..._fields(context, form),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: SelectableText(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                    ),
                ],
              ),
            ),
      actions: [
        TextButton(
          // Several threads are sent one window after another: not left half way.
          onPressed: _sending && _isBatch ? null : () => Navigator.of(context).pop(_isBatch ? null : false),
          child: Text(context.t.general.cancel),
        ),
        if (form == null && !_loading && !_unavailable)
          TextButton(onPressed: _load, child: Text(context.t.general.retry))
        else if (form != null || _loading)
          TextButton(
            onPressed: _canSend ? _send : null,
            child: _sending
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(
                    context.t.general.ok,
                    style: danger && _canSend ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
                  ),
          ),
      ],
    );
    return !_isBatch ? dialog : PopScope(canPop: !_sending, child: dialog);
  }

  /// The chosen operation has an end day: a level other than none, a highlight the forum counts, a recommendation.
  bool _hasExpiration(ModerateForm form) => switch (_operation) {
    ModerateOperation.stick ||
    ModerateOperation.digest => form.levels.isNotEmpty && (int.tryParse(_level ?? '') ?? 0) > 0,
    ModerateOperation.highlight => _highlight.marksTitle,
    ModerateOperation.recommend => _recommend,
    _ => false,
  };

  List<Widget> _fields(BuildContext context, ModerateForm form) {
    final tr = context.t.moderate;
    // The forum takes nothing with a repair: no reason, no notice.
    if (_operation == ModerateOperation.repair) {
      return const [];
    }
    return [
      if (form.levels.isNotEmpty)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final level in form.levels)
              ChoiceChip(
                label: Text(level.label),
                selected: _level == level.value,
                onSelected: _sending ? null : (_) => setState(() => _level = level.value),
              ),
          ],
        ),
      if (form.choices.isNotEmpty)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final choice in form.choices)
              ChoiceChip(
                label: _choiceLabel(context, choice),
                selected: _choice == choice.value,
                onSelected: _sending ? null : (_) => setState(() => _choice = choice.value),
              ),
          ],
        ),
      if (_operation == ModerateOperation.highlight)
        _HighlightFields(
          value: _highlight,
          enabled: !_sending,
          onChanged: (v) => setState(() => _highlight = v),
        ),
      if (_operation == ModerateOperation.recommend) ...[
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: true, label: Text(tr.recommend)),
            ButtonSegment(value: false, label: Text(tr.unrecommend)),
          ],
          selected: {_recommend},
          onSelectionChanged: _sending ? null : (v) => setState(() => _recommend = v.first),
        ),
        if (_recommend && form.recommendTitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextField(
              controller: _recommendTitle,
              enabled: !_sending,
              // The forum's limit of a thread's title.
              maxLength: 80,
              decoration: InputDecoration(labelText: tr.recommendTitle),
            ),
          ),
      ],
      if (_hasExpiration(form))
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.event_outlined),
          title: Text(tr.expiration),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _expiration == null
                    ? tr.noExpiration
                    : MaterialLocalizations.of(context).formatCompactDate(_expiration!),
              ),
              if (_expiration != null)
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _sending ? null : () => setState(() => _expiration = null),
                ),
            ],
          ),
          onTap: _sending ? null : _pickExpiration,
        ),
      if (_operation == ModerateOperation.copy) ...[
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: _moveTo,
          decoration: InputDecoration(labelText: tr.copyTo),
          items: _forumItems(context, form.forums),
          onChanged: _sending ? null : (v) => v == null ? null : _pickCopyTarget(v),
        ),
        ..._copyTypeFields(context),
      ],
      if (_operation == ModerateOperation.merge) ..._mergeFields(context),
      if (_operation == ModerateOperation.move) ...[
        DropdownButtonFormField<String>(
          isExpanded: true,
          initialValue: _moveTo,
          decoration: InputDecoration(labelText: tr.moveTo),
          items: _forumItems(context, form.forums),
          onChanged: _sending ? null : (v) => setState(() => _moveTo = v),
        ),
        if (form.canRedirect)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text(tr.moveNormal)),
                ButtonSegment(value: true, label: Text(tr.moveRedirect)),
              ],
              selected: {_redirect},
              onSelectionChanged: _sending ? null : (v) => setState(() => _redirect = v.first),
            ),
          ),
      ],
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: TextField(
          controller: _reason,
          enabled: !_sending,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: tr.reason,
            suffixIcon: form.reasons.isEmpty
                ? null
                : PopupMenuButton<String>(
                    icon: const Icon(Icons.arrow_drop_down),
                    enabled: !_sending,
                    onSelected: (v) => _reason.text = v,
                    itemBuilder: (_) => [for (final r in form.reasons) PopupMenuItem(value: r, child: Text(r))],
                  ),
          ),
        ),
      ),
      if (form.canNotify)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(tr.notifyAuthor),
          value: _notify || form.notifyForced,
          onChanged: form.notifyForced || _sending ? null : (v) => setState(() => _notify = v ?? false),
        ),
    ];
  }

  /// The thread to merge into this one: its id or link, and the thread found.
  List<Widget> _mergeFields(BuildContext context) {
    final thread = _mergeThread;
    return [
      TextField(
        controller: _mergeInput,
        enabled: !_sending,
        autofocus: true,
        decoration: InputDecoration(labelText: context.t.moderate.mergeThread),
        onChanged: _typedMergeThread,
      ),
      if (_mergeLoading)
        const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator())
      else if (thread != null)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.article_outlined),
          title: Text(thread.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: thread.author == null && thread.forumName == null
              ? null
              : Text([?thread.author, ?thread.forumName].join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis),
        )
      else if (_mergeError != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(_mergeError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
              if (_mergeTid != widget.tid)
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: context.t.general.retry,
                  onPressed: _sending || _mergeTid == null ? null : () => _lookUpMergeThread(_mergeTid!),
                ),
            ],
          ),
        ),
    ];
  }

  /// A stamp, icon or category: its picture when it has one, and its name (none for the empty category).
  Widget _choiceLabel(BuildContext context, ModerateChoice choice) {
    final label = Text(choice.label.isEmpty ? context.t.moderate.noType : choice.label);
    final image = choice.image;
    if (image == null) {
      return label;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: SizedBox(
            width: 48,
            height: 24,
            child: widget.imageBuilder?.call(image) ?? CachedImage(image, width: 48, height: 24, fit: BoxFit.contain),
          ),
        ),
        label,
      ],
    );
  }

  /// The category of the copy in the forum copied to: offered when that forum has categories, none among them
  /// unless it requires one.
  List<Widget> _copyTypeFields(BuildContext context) {
    final types = _threadTypes;
    if (_typesLoading) {
      return const [Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator())];
    }
    if (_typesFailed) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  context.t.general.failedToLoad,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: context.t.general.retry,
                onPressed: _sending || _moveTo == null ? null : () => _pickCopyTarget(_moveTo!),
              ),
            ],
          ),
        ),
      ];
    }
    if (types == null || types.every((e) => e.value == '0')) {
      return const [];
    }
    return [
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: DropdownButtonFormField<String>(
          // A new list for each forum picked.
          key: ValueKey(_moveTo),
          isExpanded: true,
          initialValue: _threadType,
          decoration: InputDecoration(labelText: context.t.moderate.threadType),
          items: [
            for (final type in types)
              DropdownMenuItem(
                value: type.value,
                child: Text(
                  type.label.isEmpty ? context.t.moderate.noType : type.label,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: _sending ? null : (v) => setState(() => _threadType = v),
        ),
      ),
    ];
  }

  /// The forums to move to, each category a header that can not be picked.
  List<DropdownMenuItem<String>> _forumItems(BuildContext context, List<ModerateChoice> forums) {
    final items = <DropdownMenuItem<String>>[];
    String? group;
    for (final forum in forums) {
      if (forum.group != null && forum.group != group) {
        group = forum.group;
        items.add(
          DropdownMenuItem(
            enabled: false,
            child: Text(group!, style: Theme.of(context).textTheme.labelMedium),
          ),
        );
      }
      items.add(
        DropdownMenuItem(
          value: forum.value,
          child: Padding(
            padding: EdgeInsets.only(left: 12.0 + forum.depth * 12),
            child: Text(forum.label, overflow: TextOverflow.ellipsis),
          ),
        ),
      );
    }
    return items;
  }
}

/// The background colors offered for a highlight, light enough for the title's text to stay readable.
const List<String> moderateHighlightBackgrounds = ['#FFF3B0', '#FFE0CC', '#FFD6E0', '#D6F5D6', '#D6EBFF', '#E8DCFF'];

/// The color of a `highlight_bgcolor` value (`#RGB` or `#RRGGBB`); null for any other.
Color? _cssColor(String value) {
  var hex = value.startsWith('#') ? value.substring(1) : '';
  if (hex.length == 3) {
    hex = hex.split('').map((e) => '$e$e').join();
  }
  final rgb = hex.length == 6 ? int.tryParse(hex, radix: 16) : null;
  return rgb == null ? null : Color(0xFF000000 | rgb);
}

/// The choices of a highlight: the text color, bold, italic and underline, the background color.
class _HighlightFields extends StatelessWidget {
  const _HighlightFields({required this.value, required this.enabled, required this.onChanged});

  final ModerateHighlight value;
  final bool enabled;
  final ValueChanged<ModerateHighlight> onChanged;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.moderate;
    final scheme = Theme.of(context).colorScheme;
    // A color served that the app does not offer stays picked, and is offered.
    final backgrounds = [
      ...moderateHighlightBackgrounds,
      if (value.background.isNotEmpty && !moderateHighlightBackgrounds.contains(value.background.toUpperCase()))
        value.background,
    ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(
          context,
          icon: Icons.format_color_text_outlined,
          label: tr.textColor,
          children: [
            for (final (i, argb) in moderateHighlightColors.indexed)
              _Swatch(
                color: i == 0 ? scheme.onSurface : Color(argb),
                label: i == 0 ? tr.defaultColor : '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
                selected: value.color == i,
                onTap: enabled ? () => onChanged(value.copyWith(color: i)) : null,
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: SegmentedButton<int>(
            multiSelectionEnabled: true,
            emptySelectionAllowed: true,
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: 1, icon: const Icon(Icons.format_bold), tooltip: tr.bold),
              ButtonSegment(value: 2, icon: const Icon(Icons.format_italic), tooltip: tr.italic),
              ButtonSegment(value: 3, icon: const Icon(Icons.format_underlined), tooltip: tr.underline),
            ],
            selected: {if (value.bold) 1, if (value.italic) 2, if (value.underline) 3},
            onSelectionChanged: enabled
                ? (v) => onChanged(value.copyWith(bold: v.contains(1), italic: v.contains(2), underline: v.contains(3)))
                : null,
          ),
        ),
        _row(
          context,
          icon: Icons.format_color_fill_outlined,
          label: tr.backgroundColor,
          children: [
            _Swatch(
              color: scheme.surface,
              label: tr.noColor,
              selected: value.background.isEmpty,
              onTap: enabled ? () => onChanged(value.copyWith(background: '')) : null,
              child: Icon(Icons.format_color_reset_outlined, size: 18, color: scheme.onSurfaceVariant),
            ),
            for (final bg in backgrounds)
              _Swatch(
                color: _cssColor(bg) ?? scheme.surfaceContainerHighest,
                label: bg,
                selected: value.background.toUpperCase() == bg.toUpperCase(),
                onTap: enabled ? () => onChanged(value.copyWith(background: bg)) : null,
              ),
          ],
        ),
      ],
    );
  }

  Widget _row(BuildContext context, {required IconData icon, required String label, required List<Widget> children}) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6, right: 12),
            child: Tooltip(
              message: label,
              child: Icon(icon, semanticLabel: label),
            ),
          ),
          Expanded(child: Wrap(spacing: 6, runSpacing: 6, children: children)),
        ],
      );
}

/// A color to pick, ringed when picked.
class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.label, required this.selected, this.onTap, this.child});

  final Color color;
  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: label,
      child: Semantics(
        selected: selected,
        button: true,
        child: InkResponse(
          onTap: onTap,
          radius: 20,
          child: Container(
            width: 32,
            height: 32,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: selected ? scheme.primary : Colors.transparent, width: 2),
            ),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Center(
                child:
                    child ??
                    (selected
                        ? Icon(
                            Icons.check,
                            size: 16,
                            color: ThemeData.estimateBrightnessForColor(color) == Brightness.dark
                                ? Colors.white
                                : Colors.black,
                          )
                        : null),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
