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
  int? _selectedUid;
  String _selectedUsername = '';
  @override
  Widget build(BuildContext context) {
    final tr = context.t.threadVisitHistoryPage;
    return BlocProvider(
      create: (context) => ThreadVisitHistoryBloc(context.repo())..add(const ThreadVisitHistoryFetchAllRequested()),
      child: BlocBuilder<ThreadVisitHistoryBloc, ThreadVisitHistoryState>(
        builder: (context, state) {
          final accounts = <int, String>{};
          for (final record in state.history) {
            accounts.putIfAbsent(record.uid, () => record.username);
          }
          // Keep the selected account available if its last record was removed during refresh.
          if (_selectedUid != null) {
            accounts.putIfAbsent(_selectedUid!, () => _selectedUsername);
          }
          final history = _selectedUid == null
              ? state.history
              : state.history.where((record) => record.uid == _selectedUid).toList();
          final body = switch (state.status) {
            ThreadVisitHistoryStatus.initial ||
            ThreadVisitHistoryStatus.loadingData => const CenteredCircularIndicator(),
            ThreadVisitHistoryStatus.savingData || ThreadVisitHistoryStatus.success => _Body(history),
            ThreadVisitHistoryStatus.failure => buildRetryButton(
              context,
              () => context.read<ThreadVisitHistoryBloc>().add(const ThreadVisitHistoryFetchAllRequested()),
            ),
          };

          return Scaffold(
            appBar: AppBar(title: Text(tr.title), bottom: Tips(tr.localOnlyTip, sizePreferred: true)),
            body: Column(
              children: [
                PopupMenuButton<String>(
                  tooltip: tr.filterAccount,
                  initialValue: _selectedUid?.toString() ?? 'all',
                  onSelected: (value) => setState(() {
                    _selectedUid = int.tryParse(value);
                    _selectedUsername = accounts[_selectedUid] ?? '';
                  }),
                  itemBuilder: (context) => [
                    PopupMenuItem(value: 'all', child: Text(tr.allAccounts)),
                    for (final account in accounts.entries)
                      PopupMenuItem(
                        value: account.key.toString(),
                        child: Text('${account.value} (UID: ${account.key})'),
                      ),
                  ],
                  child: Padding(
                    padding: edgeInsetsL12T12R12B12,
                    child: Row(
                      children: [
                        const Icon(Icons.filter_list),
                        sizedBoxW12H12,
                        Expanded(
                          child: Text(
                            _selectedUid == null ? tr.allAccounts : '$_selectedUsername (UID: $_selectedUid)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const Icon(Icons.arrow_drop_down),
                      ],
                    ),
                  ),
                ),
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
  const _Body(this.models);

  final List<ThreadVisitHistoryModel> models;

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
