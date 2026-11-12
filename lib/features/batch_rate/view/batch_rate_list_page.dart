import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_batch_page.dart';
import 'package:tsdm_client/features/batch_rate/widgets/batch_rate_widgets.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The batches the account may see (schema 35), newest first, a page at a time; each opens its detail (run on, taken
/// back there).
class BatchRateListPage extends StatefulWidget {
  /// Constructor.
  const BatchRateListPage({required this.listUrl, this.repository, super.key});

  /// The batches' page, as the entry's answer named it.
  final String listUrl;

  /// Injected for tests; the account's network client otherwise.
  final BatchRateRepository? repository;

  @override
  State<BatchRateListPage> createState() => _BatchRateListPageState();
}

class _BatchRateListPageState extends State<BatchRateListPage> {
  late final BatchRateRepository _repo =
      widget.repository ?? BatchRateRepository.network(getIt.get<NetClientProvider>());
  BatchRateBatches? _data;
  String? _message;
  bool _failed = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    // After the first frame: the requests read the translations of the page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_load());
      }
    });
  }

  Future<void> _load({int page = 1}) async {
    setState(() {
      _loading = true;
      _failed = false;
      _message = null;
    });
    final failedText = context.t.general.failedToLoad;
    BatchRateReply<BatchRateBatches> reply;
    try {
      reply = await _repo.list(widget.listUrl, page: page);
    } on IdentityChangedException {
      if (mounted) {
        setState(() {
          _loading = false;
          _data = null;
          _message = context.t.general.accountChangedRetry;
        });
      }
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      switch (reply) {
        case BatchRateAnswered(:final value):
          _data = value;
        case BatchRateRefused() || BatchRateFailed():
          _data = null;
          _failed = reply is BatchRateFailed;
          _message = reply is BatchRateFailed ? null : batchRateReplyText(context, reply, failedText);
      }
    });
  }

  Future<void> _open(BatchRateBatches data, BatchRateBatch batch) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BatchRateBatchView(url: data.detailOf(batch.batchId), repository: _repo),
      ),
    );
    if (mounted) {
      await _load(page: data.page);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.batchRate;
    final data = _data;
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.batches)),
      body: data == null
          ? ToolsStateView(onRetry: _load, failed: _failed, message: _message)
          : ToolsBody(
              onRefresh: () => _load(page: data.page),
              children: [
                if (data.batches.isEmpty)
                  AppStateView(message: tr.empty)
                else
                  AppSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final b in data.batches)
                          ListTile(
                            key: ValueKey('batch-rate-batch-${b.batchId}'),
                            contentPadding: EdgeInsets.zero,
                            enabled: !_loading && data.detailOf(b.batchId) != null,
                            title: Text(
                              '#${b.batchId} · ${context.displayText(b.forum)} · ${context.displayText(b.modeText)}',
                            ),
                            subtitle: Text(
                              '${b.username} · ${toolsDateTime(b.dateline)}\n'
                              '${b.pending != null && b.pending! > 0 ? tr.countsPending(applied: b.applied, skipped: b.skipped, pending: b.pending!) : tr.counts(applied: b.applied, skipped: b.skipped)}',
                            ),
                            isThreeLine: true,
                            trailing: Text(
                              context.displayText(b.statusText),
                              style: textTheme.labelMedium?.copyWith(
                                color: b.status == 0 ? Theme.of(context).colorScheme.primary : null,
                              ),
                            ),
                            onTap: () => _open(data, b),
                          ),
                      ],
                    ),
                  ),
                sizedBoxW8H8,
                ToolsPager(
                  paging: (page: data.page, pages: data.pages, total: data.count),
                  enabled: !_loading,
                  onPage: (page) => _load(page: page),
                ),
              ],
            ),
    );
  }
}
