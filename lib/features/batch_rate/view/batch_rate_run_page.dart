import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_batch_page.dart';
import 'package:tsdm_client/features/batch_rate/widgets/batch_rate_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Run a batch just made or run on ([BatchRateBatchPage.run]): its `run` form is posted again and again, one part at a
/// time, until the plugin says it is finished; then the result. A part not answered, or refused, stops the run with the
/// reason and a button to run on; leaving the page stops it too (the batches page runs it on later).
class BatchRateRunPage extends StatefulWidget {
  /// Constructor.
  const BatchRateRunPage({required this.start, required this.repository, this.popWhenDone = false, super.key});

  /// The batch to run.
  final BatchRateBatchPage start;

  /// The account's requests.
  final BatchRateRepository repository;

  /// Once finished, go back (to the batch's detail, which reads it again) instead of opening the result.
  final bool popWhenDone;

  @override
  State<BatchRateRunPage> createState() => _BatchRateRunPageState();
}

class _BatchRateRunPageState extends State<BatchRateRunPage> {
  /// Floors rated, and rated and to rate (the floors skipped left out), as the last part told; [_total] null before
  /// the first.
  int _done = 0;
  int? _total;
  bool _running = false;

  /// Why the run stopped; null while it runs.
  String? _stopped;

  @override
  void initState() {
    super.initState();
    // After the first frame: the requests read the translations of the page.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_run());
      }
    });
  }

  Future<void> _run() async {
    final form = widget.start.links.run;
    final batchId = widget.start.batch.batchId;
    if (_running) {
      return;
    }
    if (form == null) {
      setState(() => _stopped = context.t.general.failedToLoad);
      return;
    }
    setState(() {
      _running = true;
      _stopped = null;
    });
    final fallback = context.t.batchRate.stopped;
    // A part that takes nothing off three times in a row stops the run: never a loop without end.
    int? lastRemaining;
    int? lastDone;
    var still = 0;
    while (mounted) {
      BatchRateReply<BatchRateStep> reply;
      try {
        reply = await widget.repository.run(form, batchId);
      } on IdentityChangedException {
        if (mounted) {
          setState(() {
            _running = false;
            _stopped = context.t.general.accountChangedRetry;
          });
        }
        return;
      }
      if (!mounted) {
        return;
      }
      switch (reply) {
        case BatchRateAnswered(value: final step) when step.ok:
          setState(() {
            _total = step.total > 0 ? step.total : _total;
            // `done` is the floors rated so far; what is left (`remaining`) tells the same, and is what the plugin
            // counts down.
            _done = switch ((_total, step.remaining)) {
              (final total?, final remaining?) => (total - remaining).clamp(0, total),
              _ => step.done,
            };
          });
          if (step.finished) {
            await _showResult();
            return;
          }
          still = lastRemaining != null && (step.remaining ?? 0) >= lastRemaining && step.done <= (lastDone ?? 0)
              ? still + 1
              : 0;
          lastRemaining = step.remaining ?? 0;
          lastDone = step.done;
          if (still >= 3) {
            setState(() {
              _running = false;
              _stopped = fallback;
            });
            return;
          }
        case BatchRateAnswered(value: final step):
          setState(() {
            _running = false;
            _stopped = step.message.isEmpty ? fallback : context.displayText(step.message);
          });
          return;
        case BatchRateRefused() || BatchRateFailed():
          setState(() {
            _running = false;
            _stopped = batchRateReplyText(context, reply, fallback);
          });
          return;
      }
    }
  }

  Future<void> _showResult() async {
    if (widget.popWhenDone) {
      Navigator.of(context).pop();
      return;
    }
    final url = widget.start.links.resultUrl;
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => BatchRateBatchView(
          url: url,
          initial: url == null ? widget.start : null,
          repository: widget.repository,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.batchRate;
    final colorScheme = Theme.of(context).colorScheme;
    final batch = widget.start.batch;
    return Scaffold(
      appBar: AppBar(title: Text(tr.title)),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: appFormMaxWidth),
          child: Padding(
            padding: edgeInsetsL16T16R16B16,
            child: AppSurface(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '#${batch.batchId} · ${context.displayText(batch.forum)} · ${context.displayText(batch.modeText)}',
                  ),
                  sizedBoxW12H12,
                  // Unknown before the first part answered, while it runs.
                  LinearProgressIndicator(value: (_total ?? 0) > 0 ? _done / _total! : (_running ? null : 0)),
                  if (_total case final total?) ...[
                    sizedBoxW8H8,
                    Text(
                      tr.running(done: _done, total: total),
                      key: const ValueKey('batch-rate-progress'),
                    ),
                  ],
                  if (_stopped case final reason?) ...[
                    sizedBoxW12H12,
                    Text(reason, style: TextStyle(color: colorScheme.error)),
                    sizedBoxW8H8,
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: FilledButton(
                        key: const ValueKey('batch-rate-resume'),
                        onPressed: _running ? null : _run,
                        child: Text(tr.resume),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
