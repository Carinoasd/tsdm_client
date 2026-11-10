import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Left, Right, right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_panel_login.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// The recycle bins of the moderation panel: deleted threads and deleted replies of one forum, picked several at a
/// time and restored, or deleted for good when the panel offers it.
///
/// The forum is one of those the panel offers a bin of, chosen first (the only one right away), switched in the app
/// bar.
class RecycleBinPage extends StatefulWidget {
  /// Constructor.
  const RecycleBinPage({required this.repository, super.key});

  /// The panel.
  final ModcpRepository repository;

  @override
  State<RecycleBinPage> createState() => _RecycleBinPageState();
}

class _RecycleBinPageState extends State<RecycleBinPage> {
  ModcpForum? _forum;

  /// The forum chosen was not one the panel lists a bin of: ask, even when only one is offered.
  bool _askForum = false;

  /// The forums the panel offered, last read.
  List<ModcpForum> _forums = const [];

  Future<Either<AppException, ModcpAnswer<List<ModcpForum>>>> _loadForums() async {
    final answer = await widget.repository.fetchRecycleBin(RecycleBinKind.threads).run();
    return switch (answer) {
      Right(value: ModcpReady(:final value)) => right(ModcpReady(_forums = value.forums)),
      Right(value: ModcpNeedsLogin(:final formHash)) => right(ModcpNeedsLogin(formHash: formHash)),
      Right(value: ModcpRefused(:final message)) => right(ModcpRefused(message)),
      Left(:final value) => Left(value),
    };
  }

  Future<void> _switchForum() async {
    final picked = await showModalBottomSheet<ModcpForum>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final forum in _forums)
              ListTile(
                key: ValueKey('modcp-switch-forum-${forum.fid}'),
                title: Text(context.displayText(forum.name)),
                selected: forum.fid == _forum?.fid,
                trailing: forum.fid == _forum?.fid ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(forum),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted && picked.fid != _forum?.fid) {
      setState(() => _forum = picked);
    }
  }

  void _onForums(List<ModcpForum> forums) {
    if (forums.isNotEmpty) {
      _forums = forums;
    }
  }

  /// Back to the forums to choose from, none chosen without asking this time.
  void _onForumGone(List<ModcpForum> forums) {
    if (!mounted || _forum == null) {
      return;
    }
    setState(() {
      _forums = forums;
      _forum = null;
      _askForum = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcp;
    final forum = _forum;
    if (forum == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.recycleBin)),
        body: ModcpForumChooser(
          repository: widget.repository,
          load: _loadForums,
          pickSingle: !_askForum,
          onPick: (forum) => setState(() => _forum = forum),
        ),
      );
    }
    return DefaultTabController(
      length: RecycleBinKind.values.length,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${tr.recycleBin} · ${forum.name}'),
          actions: [
            if (_forums.length > 1)
              IconButton(
                key: const ValueKey('modcp-switch-forum'),
                tooltip: tr.switchForum,
                icon: const Icon(Icons.swap_horiz),
                onPressed: _switchForum,
              ),
          ],
          bottom: TabBar(
            tabs: [
              for (final kind in RecycleBinKind.values)
                Tab(text: kind == RecycleBinKind.threads ? tr.threads : tr.posts),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            for (final kind in RecycleBinKind.values)
              _BinList(
                key: ValueKey('${kind.name}-${forum.fid}'),
                kind: kind,
                fid: forum.fid,
                repository: widget.repository,
                onForums: _onForums,
                onForumGone: _onForumGone,
              ),
          ],
        ),
      ),
    );
  }
}

class _BinList extends StatefulWidget {
  const _BinList({
    required this.kind,
    required this.fid,
    required this.repository,
    required this.onForums,
    required this.onForumGone,
    super.key,
  });

  final RecycleBinKind kind;
  final int fid;
  final ModcpRepository repository;
  final void Function(List<ModcpForum> forums) onForums;

  /// The panel lists no bin of the forum: the forums it offers.
  final void Function(List<ModcpForum> forums) onForumGone;

  @override
  State<_BinList> createState() => _BinListState();
}

class _BinListState extends State<_BinList> with AutomaticKeepAliveClientMixin {
  bool _loading = true;
  bool _loadingMore = false;
  bool _sending = false;

  /// The pages loaded, the first one first.
  final _pages = <RecycleBinList>[];

  /// The items picked.
  final _picked = <String>{};

  /// The panel asks the password: the form hash of its login form.
  String? _loginFormHash;

  /// The forum's refusal, or why the list could not be had.
  Either<AppException, ModcpAnswer<Object?>>? _failure;

  /// The list asked last: an answer to an earlier one is dropped.
  int _generation = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  /// Load the first page again.
  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _failure = null;
    });
    final answer = await widget.repository.fetchRecycleBin(widget.kind, fid: widget.fid).run();
    if (!mounted || generation != _generation) {
      return;
    }
    setState(() {
      _loading = false;
      _pages.clear();
      _picked.clear();
      _loginFormHash = null;
      switch (answer) {
        case Right(value: ModcpReady(:final value)) when value.fid == widget.fid:
          _pages.add(value);
          widget.onForums(value.forums);
        case Right(value: ModcpReady()):
          // Handed back below.
          break;
        case Right(value: ModcpNeedsLogin(:final formHash)):
          _loginFormHash = formHash;
        default:
          _failure = answer;
      }
    });
    if (answer case Right(value: ModcpReady(:final value)) when value.fid != widget.fid) {
      // The forum keeps no bin (any more), or is not the account's: the forums the panel offers instead.
      widget.onForumGone(value.forums);
    }
  }

  Future<void> _loadMore() async {
    final last = _pages.lastOrNull;
    if (last == null || !last.hasNext || _loadingMore) {
      return;
    }
    final generation = _generation;
    setState(() => _loadingMore = true);
    final answer = await widget.repository.fetchRecycleBin(widget.kind, fid: widget.fid, page: last.page + 1).run();
    if (!mounted) {
      return;
    }
    if (generation != _generation) {
      // The list was loaded again meanwhile.
      setState(() => _loadingMore = false);
      return;
    }
    switch (answer) {
      case Right(value: ModcpReady(:final value)) when value.fid == widget.fid:
        setState(() {
          _loadingMore = false;
          _pages.add(value);
        });
      case Right(value: ModcpNeedsLogin()):
        setState(() => _loadingMore = false);
        await _load();
      default:
        setState(() => _loadingMore = false);
        showSnackBar(
          context: context,
          message: switch (answer) {
            Right(value: ModcpRefused(:final message)) when message.isNotEmpty => message,
            Left(value: IdentityChangedException()) => context.t.general.accountChangedRetry,
            _ => context.t.general.failedToLoad,
          },
        );
    }
  }

  /// The items of the pages loaded, each once: a page read after the bin changed may list one of the page before.
  List<(int, RecycleBinItem)> get _items {
    final seen = <String>{};
    return [
      for (final page in _pages)
        for (final item in page.items)
          if (seen.add(item.id)) (page.page, item),
    ];
  }

  Future<void> _act(RecycleBinAction action) async {
    final first = _pages.firstOrNull;
    if (first == null || _picked.isEmpty || _sending) {
      return;
    }
    final items = _items.where((e) => _picked.contains(e.$2.id)).toList();
    final ids = [for (final (_, item) in items) item.id];
    final lastPage = items.map((e) => e.$1).fold(1, (a, b) => a > b ? a : b);
    if (action == RecycleBinAction.delete) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => CustomAlertDialog.sync(
          title: AppDialogTitle(
            icon: Icons.delete_forever_outlined,
            title: context.t.modcp.deleteForever,
            error: true,
          ),
          content: Text(context.t.modcp.selected(count: ids.length)),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.general.cancel)),
            TextButton(
              key: const ValueKey('modcp-delete-confirm'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(context.t.general.ok, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) {
        return;
      }
    }
    setState(() => _sending = true);
    final outcome = await widget.repository.submitRecycleBin(first, action, ids, lastPage: lastPage).run();
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    final tr = context.t.modcp;
    showSnackBar(
      context: context,
      message: switch (outcome) {
        Right(value: RecycleBinDone(:final count)) => tr.done(count: count),
        Right(value: RecycleBinNotDone(:final remaining)) => tr.notDone(count: remaining.length),
        Right(value: RecycleBinRefused(:final message)) when message.isNotEmpty => message,
        Right(value: RecycleBinUnknown()) => context.t.moderate.batch.unknown,
        Left(value: IdentityChangedException()) => context.t.general.accountChangedRetry,
        _ => context.t.moderate.failed,
      },
    );
    // What the bin holds now (or the panel's login when its session ended).
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loginFormHash case final formHash?) {
      return ModeratePanelLoginView(
        login: (password) => widget.repository.loginPanel(formHash: formHash, password: password),
        onLoggedIn: _load,
      );
    }
    if (_failure case final failure?) {
      return modcpErrorView(context, failure, onRetry: _load);
    }
    final items = _items;
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: AppScrollableStateView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: AppStateView(icon: Icons.delete_outline, message: context.t.modcp.binEmpty, scrollable: false),
        ),
      );
    }
    final hasNext = _pages.lastOrNull?.hasNext ?? false;
    final canDelete = _pages.firstOrNull?.canDelete ?? false;
    final tr = context.t.modcp;
    final colorScheme = Theme.of(context).colorScheme;
    final allPicked = items.every((e) => _picked.contains(e.$2.id));
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
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
                  final (_, item) = items[index];
                  return _BinItemCard(
                    key: ValueKey('modcp-bin-item-${item.id}'),
                    item: item,
                    picked: _picked.contains(item.id),
                    onChanged: _sending
                        ? null
                        : (picked) => setState(() => picked ? _picked.add(item.id) : _picked.remove(item.id)),
                  );
                },
              ),
            ),
          ),
        ),
        Material(
          color: colorScheme.surfaceContainer,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 12, 4),
              child: Row(
                children: [
                  Checkbox(
                    key: const ValueKey('modcp-bin-pick-all'),
                    value: allPicked,
                    onChanged: _sending
                        ? null
                        : (_) => setState(() {
                            if (allPicked) {
                              _picked.clear();
                            } else {
                              _picked.addAll(items.map((e) => e.$2.id));
                            }
                          }),
                  ),
                  Expanded(child: Text(tr.selected(count: _picked.length))),
                  if (_sending)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  if (canDelete)
                    TextButton(
                      key: const ValueKey('modcp-bin-delete'),
                      onPressed: _picked.isEmpty || _sending ? null : () => _act(RecycleBinAction.delete),
                      style: TextButton.styleFrom(foregroundColor: colorScheme.error),
                      child: Text(tr.deleteForever),
                    ),
                  const SizedBox(width: 4),
                  FilledButton.tonal(
                    key: const ValueKey('modcp-bin-restore'),
                    onPressed: _picked.isEmpty || _sending ? null : () => _act(RecycleBinAction.restore),
                    child: Text(tr.restore),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BinItemCard extends StatelessWidget {
  const _BinItemCard({required this.item, required this.picked, required this.onChanged, super.key});

  final RecycleBinItem item;
  final bool picked;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final counts = item.replies.isEmpty && item.views.isEmpty ? '' : '${item.replies}/${item.views}';
    return Card(
      margin: EdgeInsets.zero,
      shape: appSurfaceShape(context),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onChanged == null ? null : () => onChanged!(!picked),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(value: picked, onChanged: onChanged == null ? null : (v) => onChanged!(v ?? false)),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.displayText(item.title),
                        style: theme.textTheme.titleSmall,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text([item.author, item.time, counts].where((e) => e.isNotEmpty).join(' · '), style: muted),
                      if (item.reason.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(context.displayText(item.reason), style: theme.textTheme.bodySmall),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
