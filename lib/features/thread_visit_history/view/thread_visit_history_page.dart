import 'package:easy_refresh/easy_refresh.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/widgets/thread_visit_history_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/tips.dart';

/// Page of thread visit history.
class ThreadVisitHistoryPage extends StatefulWidget {
  /// Constructor.
  const ThreadVisitHistoryPage({super.key});

  @override
  State<ThreadVisitHistoryPage> createState() => _ThreadVisitHistoryPageState();
}

class _ThreadVisitHistoryPageState extends State<ThreadVisitHistoryPage> {
  /// Menu value of "all accounts": a `null` value never reaches `onSelected`.
  static const _allAccounts = -1;

  final _menuKey = GlobalKey<PopupMenuButtonState<int>>();

  /// Account the list is filtered to, `null` for all accounts (GitHub #19).
  ///
  /// Filtering happens on the loaded records, so a refresh keeps the choice and the accounts come from the stored
  /// history itself: records of an account that was removed from the app stay reachable.
  int? _selectedUid;

  /// Name of [_selectedUid], kept so the chip keeps its label after the last record of that account is gone.
  String _selectedUsername = '';

  void _select(int? uid, Map<int, String> accounts) => setState(() {
    _selectedUid = uid;
    _selectedUsername = uid == null ? '' : accounts[uid] ?? _selectedUsername;
  });

  Widget _buildFilter(BuildContext context, Map<int, String> accounts) {
    final tr = context.t.threadVisitHistoryPage;
    final theme = Theme.of(context);
    // Names shared by more than one account only tell them apart with the uid.
    final seen = <String>{};
    final duplicated = <String>{};
    for (final name in accounts.values) {
      if (!seen.add(name)) {
        duplicated.add(name);
      }
    }
    String labelOf(int uid, String name) =>
        duplicated.contains(name) ? tr.accountWithUid(username: name, uid: uid) : name;
    final label = _selectedUid == null ? tr.allAccounts : labelOf(_selectedUid!, _selectedUsername);

    return Padding(
      padding: edgeInsetsL12T4R12B4,
      child: Align(
        alignment: Alignment.centerLeft,
        child: PopupMenuButton<int>(
          key: _menuKey,
          tooltip: tr.filterAccount,
          initialValue: _selectedUid ?? _allAccounts,
          onSelected: (value) => _select(value == _allAccounts ? null : value, accounts),
          itemBuilder: (context) => [
            CheckedPopupMenuItem(value: _allAccounts, checked: _selectedUid == null, child: Text(tr.allAccounts)),
            for (final MapEntry(key: uid, value: name) in accounts.entries)
              CheckedPopupMenuItem(
                value: uid,
                checked: uid == _selectedUid,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text(
                      tr.accountUid(uid: uid),
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
          ],
          // The chip handles the tap and opens the menu anchored at itself, so the ripple keeps the chip shape.
          child: ActionChip(
            avatar: const Icon(Icons.filter_list),
            label: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            onPressed: () => _menuKey.currentState?.showButtonMenu(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadVisitHistoryPage;
    return BlocProvider(
      create: (context) => ThreadVisitHistoryBloc(context.repo())..add(const ThreadVisitHistoryFetchAllRequested()),
      child: BlocBuilder<ThreadVisitHistoryBloc, ThreadVisitHistoryState>(
        builder: (context, state) {
          // Most recently visited account first, the same order as the records.
          final accounts = <int, String>{};
          for (final record in state.history) {
            accounts.putIfAbsent(record.uid, () => record.username);
          }
          // Keep the selected account in the menu when its last record was removed during a refresh.
          if (_selectedUid != null) {
            accounts.putIfAbsent(_selectedUid!, () => _selectedUsername);
          }
          final history = _selectedUid == null
              ? state.history
              : state.history.where((record) => record.uid == _selectedUid).toList();
          final body = switch (state.status) {
            ThreadVisitHistoryStatus.initial ||
            ThreadVisitHistoryStatus.loadingData => const CenteredCircularIndicator(),
            ThreadVisitHistoryStatus.savingData || ThreadVisitHistoryStatus.success => _Body(
              history,
              emptyText: _selectedUid == null ? tr.empty : tr.emptyForAccount,
            ),
            ThreadVisitHistoryStatus.failure => buildRetryButton(
              context,
              () => context.read<ThreadVisitHistoryBloc>().add(const ThreadVisitHistoryFetchAllRequested()),
            ),
          };

          return Scaffold(
            appBar: AppBar(title: Text(tr.title), bottom: Tips(tr.localOnlyTip, sizePreferred: true)),
            body: Column(
              children: [
                _buildFilter(context, accounts),
                Expanded(
                  child: SafeArea(
                    top: false,
                    child: AnimatedSwitcher(duration: duration200, child: body),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body(this.models, {required this.emptyText});

  final List<ThreadVisitHistoryModel> models;

  /// Hint shown instead of the list when [models] is empty.
  final String emptyText;

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  final _refreshController = EasyRefreshController(controlFinishRefresh: true);
  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return EasyRefresh.builder(
      controller: _refreshController,
      scrollController: _scrollController,
      header: const MaterialHeader(),
      onRefresh: () => context.read<ThreadVisitHistoryBloc>().add(const ThreadVisitHistoryFetchAllRequested()),
      childBuilder: (context, physics) {
        if (widget.models.isEmpty) {
          // A list so pull-to-refresh still works on the empty page.
          return ListView(
            physics: physics,
            controller: _scrollController,
            padding: edgeInsetsL12T4R12,
            children: [
              sizedBoxW32H32,
              Center(
                child: Text(
                  widget.emptyText,
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.outline),
                ),
              ),
            ],
          );
        }
        return ListView.separated(
          controller: _scrollController,
          physics: physics,
          padding: edgeInsetsL12T4R12,
          itemCount: widget.models.length,
          itemBuilder: (context, index) {
            return ThreadVisitHistoryCard(widget.models[index]);
          },
          separatorBuilder: (_, _) => sizedBoxW4H4,
        );
      },
    );
  }
}
