import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_panel_login.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The moderation panel's log (管理日志), read only: newest first, filtered by a keyword as the panel does.
class ModeratorLogPage extends StatefulWidget {
  /// Constructor.
  const ModeratorLogPage({required this.repository, super.key});

  /// The panel.
  final ModcpRepository repository;

  @override
  State<ModeratorLogPage> createState() => _ModeratorLogPageState();
}

class _ModeratorLogPageState extends State<ModeratorLogPage> {
  final _keyword = TextEditingController();
  bool _loading = true;
  bool _loadingMore = false;

  /// The keyword of the pages loaded.
  String _shownKeyword = '';

  final _pages = <ModcpLogPage>[];
  String? _loginFormHash;
  Either<AppException, ModcpAnswer<Object?>>? _failure;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  /// The log asked last: an answer to an earlier one is dropped.
  int _generation = 0;

  Future<void> _load() async {
    final generation = ++_generation;
    final keyword = _keyword.text.trim();
    setState(() {
      _loading = true;
      _failure = null;
    });
    final answer = await widget.repository.fetchLog(keyword: keyword).run();
    if (!mounted || generation != _generation) {
      return;
    }
    setState(() {
      _loading = false;
      _shownKeyword = keyword;
      _pages.clear();
      _loginFormHash = null;
      switch (answer) {
        case Right(value: ModcpReady(:final value)):
          _pages.add(value);
        case Right(value: ModcpNeedsLogin(:final formHash)):
          _loginFormHash = formHash;
        default:
          _failure = answer;
      }
    });
  }

  Future<void> _loadMore() async {
    final last = _pages.lastOrNull;
    if (last == null || !last.hasNext || _loadingMore) {
      return;
    }
    final generation = _generation;
    setState(() => _loadingMore = true);
    final answer = await widget.repository.fetchLog(keyword: _shownKeyword, page: last.page + 1).run();
    if (!mounted) {
      return;
    }
    if (generation != _generation) {
      // The log was asked again meanwhile.
      setState(() => _loadingMore = false);
      return;
    }
    switch (answer) {
      case Right(value: ModcpReady(:final value)):
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

  Widget _body(BuildContext context) {
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
    final entries = [for (final page in _pages) ...page.entries];
    if (entries.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: AppScrollableStateView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: AppStateView(icon: Icons.history_outlined, message: context.t.modcp.logEmpty, scrollable: false),
        ),
      );
    }
    final hasNext = _pages.lastOrNull?.hasNext ?? false;
    return RefreshIndicator(
      onRefresh: _load,
      child: AppCenteredList(
        builder: (context, padding, _) => ListView.separated(
          padding: padding.copyWith(top: 8, bottom: 8),
          itemCount: entries.length + (hasNext ? 1 : 0),
          separatorBuilder: (_, _) => appListSeparator,
          itemBuilder: (context, index) {
            if (index == entries.length) {
              return Center(
                child: _loadingMore
                    ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator())
                    : TextButton(onPressed: _loadMore, child: Text(context.t.moderate.nextPage)),
              );
            }
            return _LogEntryCard(entries[index]);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.t.modcp.log),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(64),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            key: const ValueKey('modcp-log-keyword'),
            controller: _keyword,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _load(),
            decoration: InputDecoration(
              isDense: true,
              hintText: context.t.modcp.keyword,
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
      ),
    ),
    body: _body(context),
  );
}

class _LogEntryCard extends StatelessWidget {
  const _LogEntryCard(this.entry);

  final ModcpLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    String line(List<String> parts) => parts.where((e) => e.isNotEmpty).join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      shape: appSurfaceShape(context),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              line([
                context.displayText(entry.action),
                context.displayText(entry.op),
                context.displayText(entry.forum),
              ]),
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 4),
            Text(line([entry.operator, context.displayText(entry.group), entry.time, entry.ip]), style: muted),
            if (entry.other.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SelectableText(entry.other, style: theme.textTheme.bodySmall),
              ),
          ],
        ),
      ),
    );
  }
}
