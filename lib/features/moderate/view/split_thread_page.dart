import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:universal_html/parsing.dart';

/// The thread a split made: its title, and its first floor (the earliest of the floors split off), by which it is
/// opened (the forum's answer names no thread, its floors keep their ids). `unconfirmed`: the request left and no
/// verdict came back (a server error, a dropped connection), the thread may or may not have been made.
typedef ModerateSplitDone = ({String subject, String pid, String message, bool unconfirmed});

/// Open the split of thread [tid] in forum [fid]: pick the floors, give the new thread a title, send the forum's window.
/// Null when nothing was split.
Future<ModerateSplitDone?> openSplitThreadPage(
  BuildContext context, {
  required String tid,
  required int fid,
  required ModerateRepository repository,
}) => Navigator.of(context).push(
  MaterialPageRoute<ModerateSplitDone>(
    builder: (_) => SplitThreadPage(tid: tid, fid: fid, repository: repository),
  ),
);

/// The text of a floor shown in the list: its content without markup, on one line.
String splitFloorExcerpt(Post post) {
  final bbcode = post.messageBbcode;
  final text = bbcode != null
      ? bbcode
            // Somebody else's words, a picture's url: none of the floor's own text.
            .replaceAll(RegExp(r'\[(quote|img)(=[^\]]*)?\][\s\S]*?\[/\1\]', caseSensitive: false), ' ')
            .replaceAll(RegExp(r'\[/?[a-zA-Z*][^\[\]]*\]'), ' ')
      : parseHtmlDocument('<div>${post.data}</div>').body?.text ?? '';
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// The split of thread [tid] in forum [fid]: the forum's window of it is asked first (a group that may not split, a
/// thread without replies is refused there), then the floors are listed page by page, oldest first, to be picked by
/// their numbers.
class SplitThreadPage extends StatefulWidget {
  /// Constructor.
  const SplitThreadPage({required this.tid, required this.fid, required this.repository, super.key});

  /// The thread.
  final String tid;

  /// The forum of the thread.
  final int fid;

  /// Where the window and the floors come from and the split goes to.
  final ModerateRepository repository;

  @override
  State<SplitThreadPage> createState() => _SplitThreadPageState();
}

class _SplitThreadPageState extends State<SplitThreadPage> {
  ModerateForm? _form;
  bool _windowLoading = true;
  String? _windowError;
  bool _unavailable = false;

  /// The numbered floors loaded, in order, each once.
  final _floors = <Post>[];

  /// The pages loaded and the pages the thread has.
  int _page = 0;
  int _totalPages = 1;
  bool _pageLoading = false;
  String? _pageError;

  /// A floor loaded had no number (the web page's first floor may print 楼主): it is not listed, and stays.
  bool _unnumbered = false;

  /// The floors picked, by number.
  final _picked = <int>{};

  @override
  void initState() {
    super.initState();
    unawaited(_loadWindow());
  }

  Future<void> _loadWindow() async {
    setState(() {
      _windowLoading = true;
      _windowError = null;
      _unavailable = false;
    });
    final answer = await widget.repository.fetchWindow(ModerateOperation.split, tid: widget.tid, fid: widget.fid).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _windowLoading = false;
      switch (answer) {
        case Right(value: ModerateWindowReady(:final form)):
          _form = form;
        case Right(value: ModerateWindowRefused(:final message, :final unavailable)):
          _unavailable = unavailable;
          _windowError = message.isNotEmpty
              ? context.displayText(message)
              : unavailable
              ? context.t.moderate.unavailable
              : context.t.moderate.failed;
        case Left(:final value):
          _windowError = _failure(value);
      }
    });
    if (_form != null) {
      await _loadPage();
    }
  }

  String _failure(AppException e) =>
      e is IdentityChangedException ? context.t.general.accountChangedRetry : context.t.general.failedToLoad;

  bool get _hasMore => _page < _totalPages;

  /// Load the page after the last one loaded.
  Future<void> _loadPage() async {
    if (_pageLoading || !_hasMore) {
      return;
    }
    final page = _page + 1;
    setState(() {
      _pageLoading = true;
      _pageError = null;
    });
    final answer = await widget.repository.fetchThreadPage(widget.tid, page: page).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _pageLoading = false;
      switch (answer) {
        case Right(value: final info) when info.havePermission && !info.needLogin:
          _page = page;
          _totalPages = info.totalPages < page ? page : info.totalPages;
          for (final post in info.postList) {
            // A floor without a number can not be named to the forum; a floor seen on an earlier page (replies
            // posted meanwhile push floors onward) is listed once.
            if ((post.postFloor ?? 0) <= 0) {
              _unnumbered = true;
            } else if (!_floors.any((e) => e.postID == post.postID)) {
              _floors.add(post);
            }
          }
        case Right(value: final info):
          final message = info.permissionDeniedMessage?.text?.trim() ?? '';
          _pageError = message.isNotEmpty ? context.displayText(message) : context.t.general.failedToLoad;
        case Left(:final value):
          _pageError = _failure(value);
      }
    });
  }

  /// Every floor of the thread would be split off: the forum takes it and leaves the thread without a floor.
  bool get _takesEveryFloor => !_hasMore && !_unnumbered && _floors.every((e) => _picked.contains(e.postFloor));

  bool get _canSplit => _form != null && _picked.isNotEmpty && !_takesEveryFloor;

  Future<void> _next() async {
    final form = _form;
    if (form == null || !_canSplit) {
      return;
    }
    final floors = _picked.toList()..sort();
    final first = _floors.firstWhere((e) => e.postFloor == floors.first);
    final done = await showDialog<({String subject, String message, bool unconfirmed})>(
      context: context,
      builder: (_) => _SplitDialog(form: form, floors: floors, repository: widget.repository),
    );
    if (done != null && mounted) {
      Navigator.of(context).pop<ModerateSplitDone>((
        subject: done.subject,
        pid: first.postID,
        message: done.message,
        unconfirmed: done.unconfirmed,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.moderate;
    return Scaffold(
      appBar: AppBar(
        title: Text(_picked.isEmpty ? tr.split : '${tr.split} (${_picked.length})'),
        actions: [
          TextButton(onPressed: _canSplit ? _next : null, child: Text(context.t.general.ok)),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_windowLoading || (_form != null && _floors.isEmpty && _pageLoading)) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _windowError ?? (_floors.isEmpty ? _pageError : null);
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SelectableText(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              if (!_unavailable)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TextButton(
                    onPressed: _windowError != null ? _loadWindow : _loadPage,
                    child: Text(context.t.general.retry),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return SafeArea(
      child: ListView.builder(
        itemCount: _floors.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index == _floors.length) {
            if (_pageError != null) {
              return ListTile(
                title: Text(_pageError!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                trailing: IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: context.t.general.retry,
                  onPressed: _loadPage,
                ),
              );
            }
            if (!_pageLoading) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  unawaited(_loadPage());
                }
              });
            }
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final post = _floors[index];
          final floor = post.postFloor!;
          return CheckboxListTile(
            controlAffinity: ListTileControlAffinity.leading,
            value: _picked.contains(floor),
            onChanged: (v) => setState(() => (v ?? false) ? _picked.add(floor) : _picked.remove(floor)),
            title: Row(
              children: [
                Expanded(child: Text(post.author.name, maxLines: 1, overflow: TextOverflow.ellipsis)),
                Text('#$floor', style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
            subtitle: Text(context.displayText(splitFloorExcerpt(post)), maxLines: 2, overflow: TextOverflow.ellipsis),
          );
        },
      ),
    );
  }
}

/// The title of the new thread, the reason and the notice of a split of [floors], sent once. Pops the title and the
/// forum's words once the forum split them.
class _SplitDialog extends StatefulWidget {
  const _SplitDialog({required this.form, required this.floors, required this.repository});

  final ModerateForm form;
  final List<int> floors;
  final ModerateRepository repository;

  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  final _subject = TextEditingController();
  final _reason = TextEditingController();
  late bool _notify = widget.form.notifyForced;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _subject.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final subject = _subject.text.trim();
    setState(() {
      _sending = true;
      _error = null;
    });
    final outcome = await widget.repository
        .submit(
          widget.form,
          ModerateRequest(
            operation: ModerateOperation.split,
            subject: subject,
            floors: widget.floors,
            reason: _reason.text,
            notify: _notify,
          ),
        )
        .run();
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case Right(value: ModerateSucceeded(:final message)):
        Navigator.of(context).pop((subject: subject, message: message, unconfirmed: false));
      case Right(value: ModerateRefused(:final message)):
        setState(() {
          _sending = false;
          _error = message.isNotEmpty ? context.displayText(message) : context.t.moderate.failed;
        });
      case Left(:final value) when ModerateOperation.split.resultUnknownOn(value):
        // The thread may be made all the same: told by the caller, nothing offered to send twice.
        Navigator.of(context).pop((subject: subject, message: '', unconfirmed: true));
      case Left(:final value):
        setState(() {
          _sending = false;
          _error = value is IdentityChangedException
              ? context.t.general.accountChangedRetry
              : context.t.moderate.failed;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.moderate;
    final form = widget.form;
    final dialog = CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.call_split, title: tr.split),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.floors.map((e) => '#$e').join('  '), style: Theme.of(context).textTheme.labelLarge),
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextField(
                controller: _subject,
                enabled: !_sending,
                autofocus: true,
                // The forum's limit of a thread's title.
                maxLength: 80,
                decoration: InputDecoration(labelText: tr.splitSubject),
                onChanged: (_) => setState(() {}),
              ),
            ),
            TextField(
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
                        itemBuilder: (_) => [
                          for (final r in form.reasons) PopupMenuItem(value: r, child: Text(context.displayText(r))),
                        ],
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
          onPressed: _sending ? null : () => Navigator.of(context).pop(),
          child: Text(context.t.general.cancel),
        ),
        TextButton(
          onPressed: _sending || _subject.text.trim().isEmpty ? null : _send,
          child: _sending
              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(context.t.general.ok),
        ),
      ],
    );
    // Sent once: not left while the forum answers.
    return PopScope(canPop: !_sending, child: dialog);
  }
}
