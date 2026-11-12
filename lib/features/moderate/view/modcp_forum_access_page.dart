import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/features/moderate/models/modcp_json_pages.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_pages_widgets.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The members' permissions in a forum (`modcp_forumaccess`): the members whose permissions in the forum (chosen first)
/// are set apart from their user group's, looked up by name; a moderator of the forum denies a member some of them, or
/// gives them back the user group's.
///
/// The panel's own rules decide (a member of the staff, a permission the admin centre allowed); it tells which, the app
/// words it.
class ModcpForumAccessPage extends StatefulWidget {
  /// Constructor.
  const ModcpForumAccessPage({required this.repository, super.key});

  /// The panel's pages.
  final ModcpPagesRepository repository;

  @override
  State<ModcpForumAccessPage> createState() => _ModcpForumAccessPageState();
}

class _ModcpForumAccessPageState extends State<ModcpForumAccessPage> {
  bool _loading = true;
  bool _busy = false;
  Either<AppException, ModcpAnswer<ModcpAccessPage>>? _answer;
  int _fid = 0;
  int _page = 1;
  List<ModcpForum> _forums = const [];
  bool _picking = false;
  int _generation = 0;

  /// The page read last: its search is what is asked again once the panel's password was given.
  ModcpAccessPage? _last;

  @override
  void initState() {
    super.initState();
    unawaited(_open(0));
  }

  ModcpAccessPage? get _shown => switch (_answer) {
    Right(value: ModcpReady(:final value)) => value,
    _ => null,
  };

  /// The member looked up when the panel asked its password: looked up again once logged in.
  String? _searching;

  /// Ask [request] and show its answer; [searching] is the member looked up, [opening] the forum and page asked: what
  /// is asked again when the panel asks its password first.
  Future<void> _ask(
    Future<Either<AppException, ModcpAnswer<ModcpAccessPage>>> Function() request, {
    String? searching,
    ({int fid, int page})? opening,
  }) async {
    final generation = ++_generation;
    setState(() => _loading = true);
    final answer = await request();
    if (!mounted || generation != _generation) {
      return;
    }
    final isPage = switch (answer) {
      Right(value: ModcpReady() || ModcpNeedsLogin()) => true,
      _ => false,
    };
    if (!isPage && _shown != null) {
      setState(() => _loading = false);
      showModcpLoadFailure(context, answer);
      return;
    }
    if (answer case Right(value: ModcpNeedsLogin())) {
      // The whole list asked (a forum, a page, the search cleared): none looked up again.
      _searching = searching ?? (opening != null ? '' : null);
      if (opening != null) {
        _fid = opening.fid;
        _page = opening.page;
      }
    } else {
      _searching = null;
    }
    _show(answer);
    if (answer case Right(
      value: ModcpReady(value: ModcpAccessPage(needForum: true, :final forums)),
    ) when forums.length == 1 && !_picking) {
      await _open(forums.single.fid);
    }
  }

  void _show(Either<AppException, ModcpAnswer<ModcpAccessPage>> answer) => setState(() {
    _loading = false;
    _answer = answer;
    if (answer case Right(value: ModcpReady(:final value))) {
      _last = value;
      if (value.forums.isNotEmpty) _forums = value.forums;
      _fid = value.fid;
      _page = value.page;
    }
  });

  Future<void> _open(int fid, {int page = 1}) => _ask(
    () => widget.repository.fetchAccess(fid: fid, page: page).run(),
    opening: (fid: fid, page: page),
  );

  /// What was shown last, asked again: the member looked up looked up again.
  Future<void> _reload() {
    final last = _last;
    final keyword = _searching ?? last?.keyword ?? '';
    if (last != null && keyword.isNotEmpty && !last.needForum) {
      return _ask(() => widget.repository.searchAccess(last, keyword).run(), searching: keyword);
    }
    return _open(_fid, page: _page);
  }

  Future<void> _switchForum(ModcpAccessPage shown) async {
    final picked = await showModcpForumSwitch(context, _forums, shown.fid);
    if (picked != null && mounted && picked.fid != shown.fid) {
      await _open(picked.fid);
    }
  }

  Future<void> _search(ModcpAccessPage shown) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(initial: shown.keyword),
    );
    if (name == null || !mounted) {
      return;
    }
    if (name.trim().isEmpty) {
      await _open(shown.fid);
      return;
    }
    await _ask(() => widget.repository.searchAccess(shown, name).run(), searching: name);
  }

  /// Set the permissions of [entry] (a new member when null).
  Future<void> _edit(ModcpAccessPage shown, ModcpAccessEntry? entry) async {
    final choice = await showDialog<_AccessChoice>(
      context: context,
      builder: (_) => _AccessDialog(entry: entry),
    );
    if (choice == null || !mounted) {
      return;
    }
    final tr = context.t.modcpPages;
    final restore = choice.denied.isEmpty;
    final ok = await showToolsConfirm(
      context,
      title: restore ? tr.restore : tr.setAccess,
      confirm: restore ? tr.restore : context.t.modcp.save,
      destructive: true,
      content: [
        Text('${choice.username} · ${context.displayText(shown.forumName)}'),
        if (!restore) ...[
          const SizedBox(height: 8),
          Text(
            '${tr.deny}: ${[for (final r in ModcpAccessRight.values)
              if (choice.denied.contains(r) || choice.denied.contains(ModcpAccessRight.view)) modcpAccessRightName(context, r)].join('、')}',
          ),
        ],
      ],
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _busy = true);
    final outcome = await widget.repository.setAccess(shown, choice.username, choice.denied).run();
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    final posted = outcome.toNullable();
    showSnackBar(
      context: context,
      message: modcpPagesOutcomeText(
        context,
        outcome.map((e) => e.outcome),
        done: restore ? tr.accessRestored : tr.accessDone,
        refused: switch (posted?.page?.result) {
          ModcpAccessResult.nouser => tr.accessNoUser,
          ModcpAccessResult.staff => tr.accessStaff,
          ModcpAccessResult.whitelist => tr.accessWhitelist,
          _ => null,
        },
      ),
    );
    if (posted?.page case final page? when page.fid == shown.fid) {
      _generation++;
      _show(Right(ModcpReady(page)));
    } else {
      await _reload();
    }
  }

  Widget _entry(ModcpAccessPage shown, ModcpAccessEntry entry) {
    final theme = Theme.of(context);
    final denied = entry.denied;
    final allowed = entry.allowed;
    return Card(
      key: ValueKey('modcp-access-${entry.uid}'),
      margin: EdgeInsets.zero,
      shape: appSurfaceShape(context),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: shown.canSet && !_busy ? () => _edit(shown, entry) : null,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(entry.username.isEmpty ? 'UID ${entry.uid}' : entry.username, style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final r in ModcpAccessRight.values)
                    if (denied.contains(r) || allowed.contains(r))
                      Chip(
                        key: ValueKey('modcp-access-${entry.uid}-${r.name}'),
                        visualDensity: VisualDensity.compact,
                        avatar: Icon(
                          denied.contains(r) ? Icons.block : Icons.check,
                          size: 16,
                          color: denied.contains(r) ? theme.colorScheme.error : theme.colorScheme.primary,
                        ),
                        label: Text(modcpAccessRightName(context, r)),
                      ),
                ],
              ),
              const SizedBox(height: 6),
              modcpMutedLine(context, [entry.admin, if (entry.dateline > 0) toolsDateTime(entry.dateline)]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list(ModcpAccessPage shown) {
    if (shown.needForum) {
      return ModcpForumList(
        forums: shown.forums,
        onPick: (forum) {
          _picking = true;
          unawaited(_open(forum.fid));
        },
      );
    }
    final list = shown.entries.isEmpty
        ? RefreshIndicator(
            onRefresh: _reload,
            child: AppScrollableStateView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: AppStateView(
                icon: Icons.admin_panel_settings_outlined,
                message: context.t.modcpPages.accessEmpty,
                scrollable: false,
              ),
            ),
          )
        : RefreshIndicator(
            onRefresh: _reload,
            child: AppCenteredList(
              builder: (context, padding, _) => ListView.separated(
                padding: padding.copyWith(top: 8, bottom: 88),
                // A member looked up is listed on one page: the pages are the whole list's.
                itemCount: shown.entries.length + (shown.keyword.isEmpty ? 1 : 0),
                separatorBuilder: (_, _) => appListSeparator,
                itemBuilder: (context, index) => index == shown.entries.length
                    ? ToolsPager(
                        paging: (page: shown.page, pages: shown.pages, total: shown.count),
                        enabled: !_loading && !_busy,
                        onPage: (page) => unawaited(_open(shown.fid, page: page)),
                      )
                    : _entry(shown, shown.entries[index]),
              ),
            ),
          );
    return Column(
      children: [
        if (_loading || _busy) const LinearProgressIndicator(),
        Expanded(child: list),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcpPages;
    final shown = _shown;
    final forumShown = shown != null && !shown.needForum;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          forumShown && shown.forumName.isNotEmpty
              ? '${tr.access} · ${context.displayText(shown.forumName)}'
              : tr.access,
        ),
        actions: [
          if (forumShown && shown.keyword.isNotEmpty)
            IconButton(
              key: const ValueKey('modcp-access-clear-search'),
              tooltip: context.t.general.cancel,
              icon: const Icon(Icons.filter_alt_off_outlined),
              onPressed: _loading ? null : () => _open(shown.fid),
            ),
          if (forumShown && shown.searchForm != null)
            IconButton(
              key: const ValueKey('modcp-access-search'),
              tooltip: context.t.modcp.search,
              icon: const Icon(Icons.search),
              onPressed: _loading ? null : () => _search(shown),
            ),
          if (forumShown && _forums.length > 1)
            IconButton(
              key: const ValueKey('modcp-switch-forum'),
              tooltip: context.t.modcp.switchForum,
              icon: const Icon(Icons.swap_horiz),
              onPressed: _loading ? null : () => _switchForum(shown),
            ),
        ],
      ),
      floatingActionButton: forumShown && shown.canSet
          ? FloatingActionButton(
              key: const ValueKey('modcp-access-add'),
              tooltip: tr.setAccess,
              onPressed: _busy ? null : () => _edit(shown, null),
              child: const Icon(Icons.person_add_alt_outlined),
            )
          : null,
      body: ModcpAnswerView<ModcpAccessPage>(
        repository: widget.repository.panel,
        loading: _loading && shown == null,
        answer: _answer,
        onReload: _reload,
        builder: (context, page) => _list(page),
      ),
    );
  }
}

/// A member's name, to look up.
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initial});

  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(context.t.modcp.search),
    content: TextField(
      key: const ValueKey('modcp-access-search-name'),
      controller: _name,
      autofocus: true,
      decoration: InputDecoration(labelText: context.t.modcp.byName),
      onSubmitted: (v) => Navigator.of(context).pop(v),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
      FilledButton(
        key: const ValueKey('modcp-access-search-submit'),
        onPressed: () => Navigator.of(context).pop(_name.text),
        child: Text(context.t.modcp.search),
      ),
    ],
  );
}

/// What the moderator chose for a member: the permissions denied, none to give back the user group's.
typedef _AccessChoice = ({String username, Set<ModcpAccessRight> denied});

/// The permissions of [entry] (a new member, named here, when null): those denied ticked; those the admin centre
/// allowed can not be changed.
class _AccessDialog extends StatefulWidget {
  const _AccessDialog({required this.entry});

  final ModcpAccessEntry? entry;

  @override
  State<_AccessDialog> createState() => _AccessDialogState();
}

class _AccessDialogState extends State<_AccessDialog> {
  late final _name = TextEditingController(text: widget.entry?.username ?? '');
  late final Set<ModcpAccessRight> _denied = {...?widget.entry?.denied};
  late final Set<ModcpAccessRight> _allowed = {...?widget.entry?.allowed};

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcpPages;
    final entry = widget.entry;
    final viewDenied = _denied.contains(ModcpAccessRight.view);
    final name = _name.text.trim();
    return AlertDialog(
      scrollable: true,
      title: Text(tr.setAccess),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (entry == null)
            TextField(
              key: const ValueKey('modcp-access-name'),
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(labelText: context.t.modcp.byName),
              onChanged: (_) => setState(() {}),
            )
          else
            Text(entry.username.isEmpty ? 'UID ${entry.uid}' : entry.username),
          const SizedBox(height: 8),
          Text(tr.deny, style: Theme.of(context).textTheme.labelLarge),
          for (final r in ModcpAccessRight.values)
            CheckboxListTile(
              key: ValueKey('modcp-access-deny-${r.name}'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: _denied.contains(r) || (viewDenied && r != ModcpAccessRight.view),
              title: Text(modcpAccessRightName(context, r)),
              secondary: _allowed.contains(r)
                  ? Icon(Icons.verified_user_outlined, color: Theme.of(context).colorScheme.primary)
                  : null,
              onChanged: _allowed.contains(r) || (viewDenied && r != ModcpAccessRight.view)
                  ? null
                  : (v) => setState(() => (v ?? false) ? _denied.add(r) : _denied.remove(r)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        if (entry != null)
          TextButton(
            key: const ValueKey('modcp-access-restore'),
            onPressed: () => Navigator.of(context).pop((username: entry.username, denied: <ModcpAccessRight>{})),
            child: Text(tr.restore),
          ),
        FilledButton(
          key: const ValueKey('modcp-access-save'),
          onPressed: name.isEmpty || _denied.isEmpty
              ? null
              : () => Navigator.of(context).pop((username: name, denied: {..._denied})),
          child: Text(context.t.modcp.save),
        ),
      ],
    );
  }
}
