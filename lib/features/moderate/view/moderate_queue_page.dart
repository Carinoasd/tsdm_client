import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Open the moderation queue of forum [fid] ([title] its name).
Future<void> openModerateQueue(BuildContext context, {required int fid, String? title}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ModerateQueuePage(fid: fid, title: title),
  ),
);

/// The moderation queue of forum [fid]: the threads and the replies waiting for a moderator, each passed, ignored or
/// deleted one at a time, as the forum's moderation panel lists them.
class ModerateQueuePage extends StatefulWidget {
  /// Constructor.
  const ModerateQueuePage({required this.fid, this.title, this.repository, super.key});

  /// The forum.
  final int fid;

  /// The forum's name.
  final String? title;

  /// Where the lists come from and the operations go to; the app's client when null.
  final ModerateRepository? repository;

  @override
  State<ModerateQueuePage> createState() => _ModerateQueuePageState();
}

class _ModerateQueuePageState extends State<ModerateQueuePage> {
  late final ModerateRepository _repository = widget.repository ?? ModerateRepository.network();

  @override
  Widget build(BuildContext context) {
    final tr = context.t.moderate;
    return DefaultTabController(
      length: ModerateQueueKind.values.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.title == null ? tr.queue : '${tr.queue} · ${widget.title}'),
          bottom: TabBar(
            tabs: [
              for (final kind in ModerateQueueKind.values)
                Tab(text: kind == ModerateQueueKind.threads ? tr.queueThreads : tr.queueReplies),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            for (final kind in ModerateQueueKind.values)
              _QueueList(key: ValueKey(kind), kind: kind, fid: widget.fid, repository: _repository),
          ],
        ),
      ),
    );
  }
}

class _QueueList extends StatefulWidget {
  const _QueueList({required this.kind, required this.fid, required this.repository, super.key});

  final ModerateQueueKind kind;
  final int fid;
  final ModerateRepository repository;

  @override
  State<_QueueList> createState() => _QueueListState();
}

class _QueueListState extends State<_QueueList> with AutomaticKeepAliveClientMixin {
  bool _loading = true;

  /// The pages loaded, the first one first.
  final _pages = <ModerateQueueList>[];

  /// The panel's login form asks the password: its form hash.
  String? _loginFormHash;

  /// The forum's refusal, or why the list could not be had.
  String? _error;

  bool _loadingMore = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Load the first page again.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final answer = await widget.repository.fetchQueue(widget.kind, fid: widget.fid).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      _pages.clear();
      _loginFormHash = null;
      _apply(answer);
    });
  }

  Future<void> _loadMore() async {
    final last = _pages.lastOrNull;
    if (last == null || !last.hasNext || _loadingMore) {
      return;
    }
    setState(() => _loadingMore = true);
    final answer = await widget.repository.fetchQueue(widget.kind, fid: widget.fid, page: last.page + 1).run();
    if (!mounted) {
      return;
    }
    switch (answer) {
      case Right(value: ModerateQueueReady(:final page)):
        setState(() {
          _loadingMore = false;
          _pages.add(page);
        });
      case Right(value: ModerateQueueNeedsLogin()):
        // The panel asks the password again: the list from the start once given.
        setState(() => _loadingMore = false);
        await _load();
      default:
        // The pages loaded stay; the next one can be asked again.
        setState(() => _loadingMore = false);
        showSnackBar(
          context: context,
          message: switch (answer) {
            Right(value: ModerateQueueRefused(:final message)) when message.isNotEmpty => message,
            Left(value: IdentityChangedException()) => context.t.general.accountChangedRetry,
            _ => context.t.general.failedToLoad,
          },
        );
    }
  }

  void _apply(Either<AppException, ModerateQueueAnswer> answer) {
    switch (answer) {
      case Right(value: ModerateQueueReady(:final page)):
        _pages.add(page);
      case Right(value: ModerateQueueNeedsLogin(:final formHash)):
        _pages.clear();
        _loginFormHash = formHash;
      case Right(value: ModerateQueueRefused(:final message)):
        _error = message.isNotEmpty ? message : context.t.moderate.failed;
      case Left(:final value):
        _error = value is IdentityChangedException
            ? context.t.general.accountChangedRetry
            : context.t.general.failedToLoad;
    }
  }

  Future<void> _act(ModerateQueueList page, ModerateQueueItem item, ModerateQueueAction action) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _QueueActionDialog(page: page, item: item, action: action, repository: widget.repository),
    );
    // Done, or an answer the app could not read (the panel's session may have ended): the list as it is now.
    if (done != null && mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loginFormHash case final formHash?) {
      return _PanelLogin(fid: widget.fid, formHash: formHash, repository: widget.repository, onLoggedIn: _load);
    }
    if (_error case final error?) {
      return AppStateView(
        icon: Icons.error_outline,
        error: true,
        message: error,
        action: TextButton(onPressed: _load, child: Text(context.t.general.retry)),
      );
    }
    final items = [
      for (final page in _pages)
        for (final item in page.items) (page, item),
    ];
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: AppStateView(icon: Icons.task_alt_outlined, message: context.t.moderate.queueEmpty),
      );
    }
    final hasNext = _pages.lastOrNull?.hasNext ?? false;
    return RefreshIndicator(
      onRefresh: _load,
      child: AppCenteredList(
        builder: (context, padding, _) => ListView.separated(
          padding: padding.copyWith(top: 8, bottom: 8),
          itemCount: items.length + (hasNext ? 1 : 0),
          separatorBuilder: (_, _) => appListSeparator,
          itemBuilder: (context, index) {
            if (index == items.length) {
              return Center(
                child: _loadingMore
                    ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())
                    : TextButton(onPressed: _loadMore, child: Text(context.t.moderate.nextPage)),
              );
            }
            final (page, item) = items[index];
            return _QueueItemCard(item: item, onAction: (action) => _act(page, item, action));
          },
        ),
      ),
    );
  }
}

class _QueueItemCard extends StatelessWidget {
  const _QueueItemCard({required this.item, required this.onAction});

  final ModerateQueueItem item;
  final void Function(ModerateQueueAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tr = context.t.moderate;
    return Card(
      margin: EdgeInsets.zero,
      shape: appSurfaceShape(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(item.subject, style: theme.textTheme.titleSmall),
            ),
            const SizedBox(height: 4),
            Text(
              [item.author, item.time].where((e) => e.isNotEmpty).join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (item.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: SelectableText(item.message),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => onAction(ModerateQueueAction.delete),
                  style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                  child: Text(tr.queueDelete),
                ),
                TextButton(onPressed: () => onAction(ModerateQueueAction.ignore), child: Text(tr.ignore)),
                FilledButton.tonal(onPressed: () => onAction(ModerateQueueAction.validate), child: Text(tr.validate)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _actionName(BuildContext context, ModerateQueueAction action) {
  final tr = context.t.moderate;
  return switch (action) {
    ModerateQueueAction.validate => tr.validate,
    ModerateQueueAction.ignore => tr.ignore,
    ModerateQueueAction.delete => tr.queueDelete,
  };
}

IconData _actionIcon(ModerateQueueAction action) => switch (action) {
  ModerateQueueAction.validate => Icons.check_circle_outline,
  ModerateQueueAction.ignore => Icons.do_not_disturb_on_outlined,
  ModerateQueueAction.delete => Icons.delete_outline,
};

/// Confirm [action] on [item] with an optional reason and send it once. Pops true once done, false when the answer
/// could not be read (the list is loaded again), nothing when cancelled; a refusal in the forum's words stays.
class _QueueActionDialog extends StatefulWidget {
  const _QueueActionDialog({required this.page, required this.item, required this.action, required this.repository});

  final ModerateQueueList page;
  final ModerateQueueItem item;
  final ModerateQueueAction action;
  final ModerateRepository repository;

  @override
  State<_QueueActionDialog> createState() => _QueueActionDialogState();
}

class _QueueActionDialogState extends State<_QueueActionDialog> {
  final _reason = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final outcome = await widget.repository
        .submitQueue(widget.page, widget.action, widget.item, reason: _reason.text)
        .run();
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case Right(value: ModerateSucceeded(:final message)):
        showSnackBar(context: context, message: message.isNotEmpty ? message : context.t.moderate.done);
        Navigator.of(context).pop(true);
      case Right(value: ModerateRefused(:final message)) when message.isNotEmpty:
        setState(() {
          _sending = false;
          _error = message;
        });
      case Right(value: ModerateRefused()):
        showSnackBar(context: context, message: context.t.moderate.failed);
        Navigator.of(context).pop(false);
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
    final danger = widget.action == ModerateQueueAction.delete;
    // Once sent the forum carries it out whatever the dialog does: it stays until the answer.
    return PopScope(
      canPop: !_sending,
      child: CustomAlertDialog.sync(
        title: AppDialogTitle(
          icon: _actionIcon(widget.action),
          title: _actionName(context, widget.action),
          error: danger,
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.item.subject, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 12),
              TextField(
                controller: _reason,
                enabled: !_sending,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(labelText: context.t.moderate.reason),
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
            onPressed: _sending ? null : _send,
            child: _sending
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(
                    context.t.general.ok,
                    style: danger ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
                  ),
          ),
        ],
      ),
    );
  }
}

/// The panel's password, asked when the forum asks it again; sent once per tap and kept nowhere.
class _PanelLogin extends StatefulWidget {
  const _PanelLogin({required this.fid, required this.formHash, required this.repository, required this.onLoggedIn});

  final int fid;
  final String formHash;
  final ModerateRepository repository;
  final Future<void> Function() onLoggedIn;

  @override
  State<_PanelLogin> createState() => _PanelLoginState();
}

class _PanelLoginState extends State<_PanelLogin> {
  final _password = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final password = _password.text;
    if (password.isEmpty || _sending) {
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final answer = await widget.repository
        .loginPanel(formHash: widget.formHash, fid: widget.fid, password: password)
        .run();
    if (!mounted) {
      return;
    }
    switch (answer) {
      case Right(value: ModeratePanelWrongPassword()):
        _password.clear();
        setState(() {
          _sending = false;
          _error = context.t.moderate.wrongPassword;
        });
      case Right(value: ModeratePanelRefused(:final message)):
        _password.clear();
        setState(() {
          _sending = false;
          _error = message.isNotEmpty ? message : context.t.moderate.failed;
        });
      case Left(value: IdentityChangedException()):
        setState(() {
          _sending = false;
          _error = context.t.general.accountChangedRetry;
        });
      case Right(value: ModeratePanelLoggedIn()) || Left():
        // Logged in, or the answer could not be read: the list tells (it asks again when the password was wrong).
        _password.clear();
        await widget.onLoggedIn();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.moderate;
    return AppCenteredList(
      maxWidth: 420,
      builder: (context, padding, _) => ListView(
        padding: padding.copyWith(top: 32, bottom: 32),
        children: [
          Icon(Icons.admin_panel_settings_outlined, size: 48, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(tr.panelLogin, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 24),
          TextField(
            controller: _password,
            enabled: !_sending,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _login(),
            decoration: InputDecoration(labelText: tr.password, errorText: _error),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _sending ? null : _login,
            child: _sending
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(context.t.general.ok),
          ),
        ],
      ),
    );
  }
}
