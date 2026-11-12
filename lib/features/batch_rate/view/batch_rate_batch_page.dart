import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/batch_rate/utils/batch_rate_access.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_run_page.dart';
import 'package:tsdm_client/features/batch_rate/widgets/batch_rate_widgets.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// A batch with its floors (schema 34: the result after a run, the detail of the batches): what was rated and skipped
/// and why, the rate of a floor taken back, the batch run on or taken back as a whole.
class BatchRateBatchView extends StatefulWidget {
  /// Constructor.
  const BatchRateBatchView({required this.repository, this.url, this.initial, super.key});

  /// The batch's page (its result or its detail), read when the page opens and after a change.
  final String? url;

  /// The batch shown first, read again from [url].
  final BatchRateBatchPage? initial;

  /// The account's requests.
  final BatchRateRepository repository;

  @override
  State<BatchRateBatchView> createState() => _BatchRateBatchViewState();
}

class _BatchRateBatchViewState extends State<BatchRateBatchView> {
  late BatchRateBatchPage? _page = widget.initial;
  String? _message;
  bool _failed = false;
  bool _busy = false;

  /// Taking the batch back: how many floors so far.
  int? _undoing;

  /// Where the batch is read again: [BatchRateBatchView.url], then its detail once a rate was taken back (the plugin
  /// answers the result of a batch with nothing rated any more with a sentence, not the batch).
  late String? _url = widget.url;

  @override
  void initState() {
    super.initState();
    if (widget.url != null) {
      // After the first frame: the requests read the translations of the page.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_load());
        }
      });
    }
  }

  Future<void> _load() async {
    final url = _url;
    if (url == null) {
      return;
    }
    setState(() {
      _failed = false;
      _message = null;
    });
    final failedText = context.t.general.failedToLoad;
    BatchRateReply<BatchRateBatchPage> reply;
    try {
      reply = await widget.repository.batchPage(url);
    } on IdentityChangedException {
      if (mounted) {
        setState(() {
          _page = null;
          _message = context.t.general.accountChangedRetry;
        });
      }
      return;
    }
    if (!mounted) {
      return;
    }
    switch (reply) {
      case BatchRateAnswered(:final value):
        setState(() => _page = value);
      case BatchRateRefused() || BatchRateFailed():
        if (_page == null) {
          setState(() {
            _failed = reply is BatchRateFailed;
            _message = reply is BatchRateFailed ? null : batchRateReplyText(context, reply, failedText);
          });
        } else {
          showSnackBar(context: context, message: batchRateReplyText(context, reply, failedText));
        }
    }
  }

  Future<void> _resume(BatchRateBatchPage page) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BatchRateRunPage(
          start: BatchRateBatchPage(
            uid: page.uid,
            formHash: page.formHash,
            batch: page.batch,
            items: null,
            run: true,
            links: page.links,
          ),
          repository: widget.repository,
          popWhenDone: true,
        ),
      ),
    );
    if (mounted) {
      await _load();
    }
  }

  Future<void> _undoItem(BatchRateBatchPage page, BatchRateItem item) async {
    final form = page.links.undoItem;
    if (form == null || _busy) {
      return;
    }
    final tr = context.t.batchRate;
    final ok = await showToolsConfirm(
      context,
      title: tr.undo,
      confirm: tr.undo,
      destructive: true,
      content: [Text(tr.undoItemConfirm(floor: item.position, author: item.author))],
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _busy = true);
    final fallback = tr.unconfirmed;
    String message;
    try {
      final reply = await widget.repository.undoItem(form, item.itemId);
      if (!mounted) {
        return;
      }
      message = switch (reply) {
        BatchRateAnswered(value: final step) when step.ok => tr.undone,
        BatchRateAnswered(value: final step) => step.message.isEmpty ? fallback : context.displayText(step.message),
        _ => batchRateReplyText(context, reply, fallback),
      };
      if (reply case BatchRateAnswered(value: final step) when step.ok) {
        // The quota of the moderator came back: the entries read it again.
        BatchRateAccess.forget(page.uid, fid: page.batch.fid);
        _url = BatchRateRepository.detailUrlOf(page.batch.batchId) ?? _url;
      }
    } on IdentityChangedException {
      message = context.t.general.accountChangedRetry;
    }
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    showSnackBar(context: context, message: message, showCloseIcon: true);
    await _load();
  }

  Future<void> _undoBatch(BatchRateBatchPage page) async {
    final form = page.links.undoBatch;
    if (form == null || _busy) {
      return;
    }
    final tr = context.t.batchRate;
    final ok = await showToolsConfirm(
      context,
      title: tr.undoBatch,
      confirm: tr.undoBatch,
      destructive: true,
      content: [Text(tr.undoBatchConfirm(id: page.batch.batchId))],
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() {
      _busy = true;
      _undoing = 0;
    });
    final fallback = tr.unconfirmed;
    String? message;
    int? lastRemaining;
    var still = 0;
    try {
      while (mounted) {
        final reply = await widget.repository.undoBatch(form, page.batch.batchId);
        if (!mounted) {
          return;
        }
        if (reply case BatchRateAnswered(value: final step) when step.ok) {
          setState(() => _undoing = (_undoing ?? 0) + step.done);
          // Something was taken back (or all of it was already): the result may now be the plugin's sentence.
          if (step.done > 0 || step.finished) {
            _url = BatchRateRepository.detailUrlOf(page.batch.batchId) ?? _url;
          }
          if (step.finished) {
            BatchRateAccess.forget(page.uid, fid: page.batch.fid);
            message = tr.undone;
            break;
          }
          // A part that takes nothing back three times in a row stops: never a loop without end.
          still = lastRemaining != null && (step.remaining ?? 0) >= lastRemaining && step.done == 0 ? still + 1 : 0;
          lastRemaining = step.remaining ?? 0;
          if (still >= 3) {
            message = fallback;
            break;
          }
          continue;
        }
        message = switch (reply) {
          BatchRateAnswered(value: final step) => step.message.isEmpty ? fallback : context.displayText(step.message),
          _ => batchRateReplyText(context, reply, fallback),
        };
        break;
      }
    } on IdentityChangedException {
      message = context.t.general.accountChangedRetry;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _undoing = null;
    });
    if (message != null) {
      showSnackBar(context: context, message: message, showCloseIcon: true);
    }
    await _load();
  }

  Widget _head(BatchRateBatchPage page) {
    final tr = context.t.batchRate;
    final textTheme = Theme.of(context).textTheme;
    final b = page.batch;
    final scores = [
      for (final s in b.scores) '${context.displayText(s.title)} ${s.score > 0 ? '+' : ''}${s.score}',
    ].join('  ');
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('#${b.batchId} · ${context.displayText(b.statusText)}', style: textTheme.titleMedium),
          sizedBoxW4H4,
          Text('${context.displayText(b.forum)} · ${context.displayText(b.modeText)}'),
          Text('${b.username} · ${toolsDateTime(b.dateline)}', style: textTheme.bodySmall),
          if (scores.isNotEmpty) Text(scores),
          if (b.conds.isNotEmpty) Text(b.conds.map(context.displayText).join('  ')),
          if (b.reason.isNotEmpty) Text(context.displayText(b.reason)),
          sizedBoxW4H4,
          Text(
            b.pending != null && b.pending! > 0
                ? tr.countsPending(applied: b.applied, skipped: b.skipped, pending: b.pending!)
                : tr.counts(applied: b.applied, skipped: b.skipped),
          ),
          if (_undoing case final n?) ...[sizedBoxW8H8, Text(tr.undoing(done: n)), const LinearProgressIndicator()],
          if ((b.canContinue && page.links.run != null) || (b.canUndo && page.links.undoBatch != null)) ...[
            sizedBoxW8H8,
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (b.canUndo && page.links.undoBatch != null)
                  OutlinedButton(
                    key: const ValueKey('batch-rate-undo-batch'),
                    onPressed: _busy ? null : () => _undoBatch(page),
                    child: Text(tr.undoBatch),
                  ),
                if (b.canContinue && page.links.run != null)
                  FilledButton(
                    key: const ValueKey('batch-rate-continue'),
                    onPressed: _busy ? null : () => _resume(page),
                    child: Text(tr.resume),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.batchRate;
    final page = _page;
    return Scaffold(
      appBar: AppBar(title: Text(page == null ? tr.result : '${tr.title} #${page.batch.batchId}')),
      body: page == null
          ? ToolsStateView(onRetry: _load, failed: _failed, message: _message)
          : ToolsBody(
              onRefresh: _url == null ? null : _load,
              children: [
                _head(page),
                sizedBoxW12H12,
                AppSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final item in page.items ?? const <BatchRateItem>[])
                        BatchRateItemTile(
                          key: ValueKey('batch-rate-item-${item.itemId}'),
                          item: item,
                          trailing: item.canUndo && page.batch.canUndoItem && page.links.undoItem != null
                              ? TextButton(
                                  key: ValueKey('batch-rate-undo-${item.itemId}'),
                                  onPressed: _busy ? null : () => _undoItem(page, item),
                                  child: Text(tr.undo),
                                )
                              : null,
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
