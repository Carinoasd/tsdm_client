import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Left, Right;
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/features/report_handling/models/report_handling.dart';
import 'package:tsdm_client/features/report_handling/repository/report_source.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Handling reports (舉報處理) of a [source]: choose the part (the panel's forum), list the reports (each opens what
/// was reported), pick some with the reporter's reward and a message when the forum sets a reward, handle them.
///
/// The source decides everything: what is listed, the login it asks, what was done.
class ReportHandlingPage extends StatefulWidget {
  /// Constructor.
  const ReportHandlingPage({required this.source, super.key});

  /// Where the reports come from.
  final ReportSource source;

  @override
  State<ReportHandlingPage> createState() => _ReportHandlingPageState();
}

class _ReportHandlingPageState extends State<ReportHandlingPage> {
  bool _loading = true;
  bool _busy = false;
  Either<AppException, ReportAnswer>? _answer;
  String _scope = '';
  int _generation = 0;

  /// The page of the part listed last: kept through a login asked meanwhile.
  int _page = 1;

  final _selected = <int>{};
  final _credits = <int, int>{};
  final _messages = <int, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final c in _messages.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// Forget the choices; the message fields still on screen this frame keep their controllers until it is drawn.
  void _clearChoices() {
    _selected.clear();
    _credits.clear();
    final old = _messages.values.toList();
    _messages.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in old) {
        c.dispose();
      }
    });
  }

  Future<void> _load({String? scope, int page = 1}) async {
    final generation = ++_generation;
    final next = scope ?? _scope;
    setState(() {
      _loading = true;
      if (next != _scope) _clearChoices();
      _scope = next;
      _page = page;
    });
    final answer = await widget.source.load(scope: next, page: page);
    if (!mounted || generation != _generation) {
      return;
    }
    setState(() {
      _loading = false;
      _answer = answer;
      if (answer case Right(value: ReportReady(:final list))) {
        _page = list.page;
        final listed = {for (final i in list.items) i.id};
        _selected.retainWhere(listed.contains);
      }
    });
    // The only part offered is chosen right away.
    if (answer case Right(value: ReportReady(list: ReportList(needScope: true, scopes: [final only])))) {
      await _load(scope: only.key);
    }
  }

  Future<void> _reload() => _load(page: _page);

  Future<void> _open(ReportItem item) async {
    if (item.pid > 0) {
      await context.pushNamed(
        ScreenPaths.threadV1,
        queryParameters: {'pid': '${item.pid}', 'overrideReverseOrder': 'false'},
      );
    } else if (item.tid > 0) {
      await context.pushNamed(ScreenPaths.threadV1, queryParameters: {'tid': '${item.tid}'});
    } else if (item.absoluteUrl case final url?) {
      await context.dispatchAsUrl(url);
    }
  }

  String _credit(ReportReward reward, int value) =>
      '${value > 0 ? '+' : ''}$value${reward.unit.isEmpty ? '' : ' ${context.displayText(reward.unit)}'}';

  Future<void> _resolve(ReportList list) async {
    final tr = context.t.reportHandling;
    final reward = list.reward;
    final decisions = <ReportDecision>[
      for (final item in list.items)
        if (_selected.contains(item.id))
          (
            item: item,
            credit: reward == null ? 0 : (_credits[item.id] ?? 0),
            message: reward == null ? '' : (_messages[item.id]?.text ?? ''),
          ),
    ];
    if (decisions.isEmpty) {
      return;
    }
    final ok = await showToolsConfirm(
      context,
      title: tr.title,
      confirm: tr.resolve(n: decisions.length),
      destructive: decisions.any((d) => d.credit < 0),
      content: [
        for (final d in decisions)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              [
                if (d.item.username.isEmpty) 'UID ${d.item.uid}' else d.item.username,
                if (reward != null && d.credit != 0)
                  '${context.displayText(reward.creditTitle)} ${_credit(reward, d.credit)}',
              ].join(' · '),
            ),
          ),
      ],
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _busy = true);
    final outcome = await widget.source.resolve(list, decisions);
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    final message = switch (outcome) {
      Right(value: ReportDone(:final message)) => message.isEmpty ? tr.done : message,
      Right(value: ReportNotDone(:final message)) => message.isEmpty ? context.t.moderate.failed : message,
      Right(value: ReportSessionEnded()) => null,
      Right(value: ReportUnknown()) => context.t.medalTitleTools.unconfirmed,
      Left(value: IdentityChangedException()) => context.t.general.accountChangedRetry,
      Left() => context.t.medalTitleTools.unconfirmed,
    };
    if (message != null) {
      showSnackBar(context: context, message: context.displayText(message), showCloseIcon: true);
    }
    if (outcome case Right(value: ReportDone())) {
      setState(_clearChoices);
    }
    if (outcome case Left(value: IdentityChangedException())) {
      return;
    }
    await _reload();
  }

  Widget _scopes(ReportList list) {
    if (list.scopes.isEmpty) {
      return AppStateView(icon: Icons.forum_outlined, message: context.t.modcp.noForums);
    }
    return AppCenteredList(
      builder: (context, padding, _) => ListView(
        padding: padding.copyWith(top: 8, bottom: 8),
        children: [
          AppSurface(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (final s in list.scopes)
                  ListTile(
                    key: ValueKey('report-scope-${s.key}'),
                    leading: const Icon(Icons.forum_outlined),
                    title: Text(context.displayText(s.label)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _load(scope: s.key),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _item(ReportList list, ReportItem item) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final selected = _selected.contains(item.id);
    final reward = list.reward;
    final canOpen = item.pid > 0 || item.tid > 0 || item.absoluteUrl != null;
    return Card(
      key: ValueKey('report-${item.id}'),
      margin: EdgeInsets.zero,
      shape: appSurfaceShape(context),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: canOpen ? () => _open(item) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 12, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    key: ValueKey('report-pick-${item.id}'),
                    value: selected,
                    onChanged: _busy || !list.canResolve
                        ? null
                        : (v) => setState(() => (v ?? false) ? _selected.add(item.id) : _selected.remove(item.id)),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final line in item.lines) Text(line, style: theme.textTheme.bodyMedium),
                          if (item.excerpt.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(item.excerpt, style: theme.textTheme.bodySmall),
                            ),
                          const SizedBox(height: 6),
                          Text(
                            [
                              if (item.forum.isNotEmpty && item.forum != list.scopeLabel)
                                context.displayText(item.forum),
                              toolsDateTime(item.dateline),
                              if (item.count > 1) '×${item.count}',
                            ].join(' · '),
                            style: muted,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (canOpen)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Icon(Icons.chevron_right, color: theme.colorScheme.outline),
                    ),
                ],
              ),
              if (selected && reward != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12, top: 4),
                  child: Row(
                    children: [
                      DropdownButton<int>(
                        key: ValueKey('report-credit-${item.id}'),
                        value: _credits[item.id] ?? 0,
                        onChanged: _busy ? null : (v) => setState(() => _credits[item.id] = v ?? 0),
                        items: [
                          for (final v in reward.options)
                            DropdownMenuItem(
                              value: v,
                              child: Text(
                                v == 0
                                    ? context.t.reportHandling.noReward
                                    : '${context.displayText(reward.creditTitle)} ${_credit(reward, v)}',
                              ),
                            ),
                        ],
                      ),
                      sizedBoxW12H12,
                      Expanded(
                        child: TextField(
                          key: ValueKey('report-message-${item.id}'),
                          controller: _messages.putIfAbsent(item.id, TextEditingController.new),
                          enabled: !_busy,
                          decoration: InputDecoration(
                            isDense: true,
                            labelText: context.t.reportHandling.message,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _list(ReportList list) {
    final tr = context.t.reportHandling;
    if (list.items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _reload,
        child: AppScrollableStateView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: AppStateView(icon: Icons.flag_outlined, message: tr.empty, scrollable: false),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: AppCenteredList(
        builder: (context, padding, _) => ListView.separated(
          padding: padding.copyWith(top: 8, bottom: 8),
          itemCount: list.items.length + 1,
          separatorBuilder: (_, _) => appListSeparator,
          itemBuilder: (context, index) => index == list.items.length
              ? ToolsPager(
                  paging: (page: list.page, pages: list.pages, total: list.count),
                  enabled: !_busy && !_loading,
                  onPage: (page) => _load(page: page),
                )
              : _item(list, list.items[index]),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading && _answer == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return switch (_answer) {
      Right(value: final ReportNeedsLogin need) => widget.source.loginView(need, _reload),
      Right(value: ReportReady(:final list)) when list.needScope => _scopes(list),
      Right(value: ReportReady(:final list)) => _list(list),
      Right(value: ReportRefused(:final message)) => AppStateView(
        icon: Icons.error_outline,
        error: true,
        message: message.isEmpty ? context.t.moderate.failed : context.displayText(message),
        action: TextButton(onPressed: _reload, child: Text(context.t.general.retry)),
      ),
      Left(value: IdentityChangedException()) => AppStateView(
        icon: Icons.error_outline,
        error: true,
        message: context.t.general.accountChangedRetry,
      ),
      _ => AppStateView(
        icon: Icons.error_outline,
        error: true,
        message: context.t.general.failedToLoad,
        action: TextButton(onPressed: _reload, child: Text(context.t.general.retry)),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.reportHandling;
    final list = switch (_answer) {
      Right(value: ReportReady(:final list)) => list,
      _ => null,
    };
    final shown = list != null && !list.needScope ? list : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(shown == null || shown.scopeLabel.isEmpty ? tr.title : context.displayText(shown.scopeLabel)),
        bottom: _loading && _answer != null
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
        actions: [
          if (shown != null && shown.scopes.length > 1)
            PopupMenuButton<String>(
              key: const ValueKey('report-switch-scope'),
              tooltip: context.t.modcp.switchForum,
              icon: const Icon(Icons.swap_horiz),
              enabled: !_busy,
              onSelected: (key) => _load(scope: key),
              itemBuilder: (context) => [
                for (final s in shown.scopes)
                  CheckedPopupMenuItem(
                    value: s.key,
                    checked: s.key == shown.scope,
                    child: Text(context.displayText(s.label)),
                  ),
              ],
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SafeArea(top: false, bottom: _selected.isEmpty, child: _body()),
          ),
          if (shown != null && shown.canResolve && _selected.isNotEmpty)
            AppBottomActionBar(
              child: Row(
                children: [
                  TextButton(
                    key: const ValueKey('report-pick-all'),
                    onPressed: _busy
                        ? null
                        : () => setState(() {
                            final all = shown.items.every((i) => _selected.contains(i.id));
                            all ? _selected.clear() : _selected.addAll(shown.items.map((i) => i.id));
                          }),
                    child: Text(context.t.modcp.selected(count: _selected.length)),
                  ),
                  const Spacer(),
                  FilledButton(
                    key: const ValueKey('report-resolve'),
                    onPressed: _busy ? null : () => _resolve(shown),
                    child: Text(tr.resolve(n: _selected.length)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
