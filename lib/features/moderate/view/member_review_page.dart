import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The new members waiting for approval (the panel's 审核 › 用户, when the forum approves new accounts by hand):
/// picked several at a time and let in, turned down, or deleted.
class MemberReviewPage extends StatefulWidget {
  /// Constructor.
  const MemberReviewPage({required this.repository, super.key});

  /// The panel.
  final ModcpRepository repository;

  @override
  State<MemberReviewPage> createState() => _MemberReviewPageState();
}

class _MemberReviewPageState extends State<MemberReviewPage> {
  bool _loading = true;
  bool _loadingMore = false;
  bool _sending = false;

  /// The first page as answered (its login, its refusal).
  Either<AppException, ModcpAnswer<MemberReviewList>>? _answer;

  /// The pages loaded, the first one first.
  final _pages = <MemberReviewList>[];

  final _picked = <String>{};

  /// The list asked last: an answer to an earlier one is dropped.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() => _loading = true);
    final answer = await widget.repository.fetchMemberReview().run();
    if (!mounted || generation != _generation) {
      return;
    }
    setState(() {
      _loading = false;
      _answer = answer;
      _pages.clear();
      _picked.clear();
      if (answer case Right(value: ModcpReady(:final value))) {
        _pages.add(value);
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
    final answer = await widget.repository.fetchMemberReview(page: last.page + 1).run();
    if (!mounted) {
      return;
    }
    setState(() => _loadingMore = false);
    if (generation != _generation) {
      return;
    }
    switch (answer) {
      case Right(value: ModcpReady(:final value)):
        setState(() => _pages.add(value));
      case Right(value: ModcpNeedsLogin()):
        await _load();
      default:
        showSnackBar(context: context, message: context.t.general.failedToLoad);
    }
  }

  /// The members of the pages loaded, each once, with the page each is on.
  List<(int, MemberReviewItem)> get _items {
    final seen = <String>{};
    return [
      for (final page in _pages)
        for (final item in page.items)
          if (seen.add(item.id)) (page.page, item),
    ];
  }

  Future<void> _act(MemberReviewAction action) async {
    final first = _pages.firstOrNull;
    if (first == null || _picked.isEmpty || _sending) {
      return;
    }
    final items = _items.where((e) => _picked.contains(e.$2.id)).toList();
    final ids = [for (final (_, item) in items) item.id];
    final tr = context.t;
    final reason = await showModcpReasonDialog(
      context,
      title: switch (action) {
        MemberReviewAction.validate => tr.moderate.validate,
        MemberReviewAction.ignore => tr.modcp.reject,
        MemberReviewAction.delete => tr.modcp.delete,
      },
      icon: switch (action) {
        MemberReviewAction.validate => Icons.how_to_reg_outlined,
        MemberReviewAction.ignore => Icons.person_remove_outlined,
        MemberReviewAction.delete => Icons.delete_outline,
      },
      count: ids.length,
      destructive: action == MemberReviewAction.delete,
    );
    if (reason == null || !mounted) {
      return;
    }
    setState(() => _sending = true);
    final lastPage = items.map((e) => e.$1).fold(1, (a, b) => a > b ? a : b);
    final outcome = await widget.repository
        .submitMemberReview(first, action, ids, reason: reason, lastPage: lastPage)
        .run();
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    showSnackBar(context: context, message: modcpOutcomeText(context, outcome));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcp;
    return Scaffold(
      appBar: AppBar(title: Text(tr.memberReview)),
      body: ModcpAnswerView<MemberReviewList>(
        repository: widget.repository,
        loading: _loading,
        answer: _answer,
        onReload: _load,
        builder: (context, _) => _list(context),
      ),
    );
  }

  Widget _list(BuildContext context) {
    final tr = context.t.modcp;
    final items = _items;
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: AppScrollableStateView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: AppStateView(icon: Icons.how_to_reg_outlined, message: tr.reviewEmpty, scrollable: false),
        ),
      );
    }
    final hasNext = _pages.lastOrNull?.hasNext ?? false;
    final allPicked = items.every((e) => _picked.contains(e.$2.id));
    final picked = items.where((e) => _picked.contains(e.$2.id)).map((e) => e.$2).toList();
    final canDelete = picked.isNotEmpty && picked.every((e) => e.canDelete);
    final theme = Theme.of(context);
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
                  return ModcpPickCard(
                    key: ValueKey('modcp-review-${item.id}'),
                    picked: _picked.contains(item.id),
                    onChanged: _sending
                        ? null
                        : (v) => setState(() => v ? _picked.add(item.id) : _picked.remove(item.id)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.username, style: theme.textTheme.titleSmall),
                        const SizedBox(height: 4),
                        modcpMutedLine(context, [item.regDate, item.regIp]),
                        if (item.reason.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(context.displayText(item.reason), style: theme.textTheme.bodyMedium),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        ModcpPickBar(
          picked: _picked.length,
          allPicked: allPicked,
          sending: _sending,
          onPickAll: _sending
              ? null
              : () => setState(() => allPicked ? _picked.clear() : _picked.addAll(items.map((e) => e.$2.id))),
          actions: [
            TextButton(
              key: const ValueKey('modcp-review-delete'),
              onPressed: !canDelete || _sending ? null : () => _act(MemberReviewAction.delete),
              style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
              child: Text(tr.delete),
            ),
            TextButton(
              key: const ValueKey('modcp-review-ignore'),
              onPressed: _picked.isEmpty || _sending ? null : () => _act(MemberReviewAction.ignore),
              child: Text(tr.reject),
            ),
            FilledButton.tonal(
              key: const ValueKey('modcp-review-validate'),
              onPressed: _picked.isEmpty || _sending ? null : () => _act(MemberReviewAction.validate),
              child: Text(context.t.moderate.validate),
            ),
          ],
        ),
      ],
    );
  }
}
