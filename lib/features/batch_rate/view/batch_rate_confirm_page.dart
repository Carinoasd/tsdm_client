import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/batch_rate/utils/batch_rate_access.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_batch_page.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_run_page.dart';
import 'package:tsdm_client/features/batch_rate/widgets/batch_rate_widgets.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The confirmation of a batch rate (schema 33): the scores (with the range and the quota left), the thresholds, the
/// reason and the notice; in a thread the names left out and the anti-flood switches, the floor numbers; then every
/// floor picked, rated or skipped with the plugin's reason, and its multiple. A change is computed again by the plugin
/// (`recalc`) before the batch is sent; it is sent only once the plugin does not block it and the quota is enough.
class BatchRateConfirmPage extends StatefulWidget {
  /// Constructor.
  const BatchRateConfirmPage({required this.info, required this.selection, this.repository, super.key});

  /// What the entry was offered with (the quota, the reasons, the limits).
  final BatchRateInfo info;

  /// The floors picked.
  final BatchRateSelection selection;

  /// Injected for tests; the account's network client otherwise.
  final BatchRateRepository? repository;

  @override
  State<BatchRateConfirmPage> createState() => _BatchRateConfirmPageState();
}

class _BatchRateConfirmPageState extends State<BatchRateConfirmPage> {
  late final BatchRateRepository _repo =
      widget.repository ?? BatchRateRepository.network(getIt.get<NetClientProvider>());

  BatchRateConfirm? _confirm;
  BatchRateSettings? _settings;

  /// The plugin's refusal, or the failure, when there is no confirmation to show.
  String? _message;
  bool _failed = false;
  bool _busy = false;

  /// A setting changed since the plugin last computed the confirmation.
  bool _stale = false;

  /// A sending was not answered: the batch may have been made, it is not sent again from here.
  bool _sentUnknown = false;

  final _scores = <int, TextEditingController>{};
  final _conds = <int, TextEditingController>{};
  final _mults = <int, TextEditingController>{};
  final _reason = TextEditingController();
  final _exclude = TextEditingController();
  final _floors = TextEditingController();

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

  @override
  void dispose() {
    for (final c in [..._scores.values, ..._conds.values, ..._mults.values, _reason, _exclude, _floors]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _failed = false;
      _message = null;
    });
    await _apply(() => _repo.confirm(widget.info, widget.selection));
  }

  /// Show the confirmation [ask] answers; a refusal or a failure keeps the one shown (if any) and tells it.
  ///
  /// A failure of a sending tells to look at the batches ([sending]): the batch may have been made.
  Future<void> _apply(Future<BatchRateReply<BatchRatePosted>> Function() ask, {bool sending = false}) async {
    setState(() => _busy = true);
    final tr = context.t.batchRate;
    final changed = context.t.general.accountChangedRetry;
    final failedText = context.t.general.failedToLoad;
    BatchRateReply<BatchRatePosted> reply;
    try {
      reply = await ask();
    } on IdentityChangedException {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = changed;
          _confirm = null;
        });
      }
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() => _busy = false);
    switch (reply) {
      case BatchRateAnswered(value: final BatchRateConfirm confirm):
        _take(confirm);
      case BatchRateAnswered(value: final BatchRateBatchPage page):
        BatchRateAccess.forget(page.uid, fid: widget.info.fid);
        // A batch with nothing left to run (`run 0`) is shown as it is.
        await Navigator.of(context).pushReplacement(
          MaterialPageRoute<void>(
            builder: (_) => page.run
                ? BatchRateRunPage(start: page, repository: _repo)
                : BatchRateBatchView(url: page.links.resultUrl, initial: page, repository: _repo),
          ),
        );
      case BatchRateRefused() || BatchRateFailed():
        final text = batchRateReplyText(context, reply, sending ? tr.unconfirmed : failedText);
        if (sending && reply is BatchRateFailed) {
          setState(() => _sentUnknown = true);
        }
        if (_confirm == null) {
          setState(() {
            _failed = reply is BatchRateFailed;
            _message = reply is BatchRateFailed ? null : text;
          });
        } else {
          showSnackBar(context: context, message: text, showCloseIcon: true);
        }
    }
  }

  void _take(BatchRateConfirm confirm) {
    final settings = BatchRateSettings.of(confirm);
    TextEditingController keep(Map<int, TextEditingController> map, int key, String text) {
      final c = map.putIfAbsent(key, () => TextEditingController()..addListener(_changed));
      if (c.text != text) {
        c.text = text;
      }
      return c;
    }

    for (final credit in confirm.credits) {
      keep(_scores, credit.id, credit.score == 0 ? '' : '${credit.score}');
      keep(_conds, credit.id, credit.cond);
    }
    for (final item in confirm.items) {
      keep(_mults, item.pid, '${item.mult}');
    }
    void set(TextEditingController c, String text) {
      if (c.text != text) {
        c.text = text;
      }
    }

    set(_reason, settings.reason);
    set(_exclude, settings.exclude);
    set(_floors, settings.floors);
    setState(() {
      _confirm = confirm;
      _settings = settings;
      _stale = false;
    });
  }

  void _changed() {
    final confirm = _confirm;
    final settings = _settings;
    if (confirm == null || settings == null) {
      return;
    }
    for (final e in _scores.entries) {
      settings.scores[e.key] = int.tryParse(e.value.text.trim()) ?? 0;
    }
    for (final e in _conds.entries) {
      settings.conds[e.key] = e.value.text;
    }
    for (final item in confirm.items) {
      settings.mults[item.pid] = int.tryParse(_mults[item.pid]?.text.trim() ?? '') ?? 1;
    }
    settings
      ..reason = _reason.text
      ..exclude = _exclude.text
      ..floors = _floors.text;
    setState(() => _stale = true);
  }

  Future<void> _recalc() async {
    final confirm = _confirm;
    final settings = _settings;
    if (confirm == null || settings == null || _busy) {
      return;
    }
    if (confirm.mode == BatchRateMode.range) {
      final floors = parseBatchRateFloors(settings.floors, maxSegments: widget.info.floorSegments);
      if (floors == null) {
        showSnackBar(context: context, message: context.t.batchRate.badFloors);
        return;
      }
      settings.floors = floors;
    }
    await _apply(() => _repo.recalc(confirm, settings));
  }

  Future<void> _send() async {
    final confirm = _confirm;
    final settings = _settings;
    if (confirm == null ||
        settings == null ||
        _busy ||
        _stale ||
        _sentUnknown ||
        batchRateHolds(confirm, settings, multMax: widget.info.multMax).isNotEmpty) {
      return;
    }
    final tr = context.t.batchRate;
    final ok = await showToolsConfirm(
      context,
      title: tr.title,
      confirm: tr.send,
      content: [
        Text(tr.confirmSend(apply: confirm.apply)),
        sizedBoxW8H8,
        for (final credit in confirm.credits)
          if (settings.scored[credit.id] case final score?)
            Text('${context.displayText(credit.title)} ${score > 0 ? '+' : ''}$score${credit.unit}'),
      ],
    );
    if (!ok || !mounted) {
      return;
    }
    await _apply(() => _repo.submit(confirm, settings), sending: true);
  }

  void _setSwitch(void Function(BatchRateSettings s) change) {
    final settings = _settings;
    if (settings == null) {
      return;
    }
    change(settings);
    setState(() => _stale = true);
  }

  String _holdText(BatchRateHold hold) {
    final tr = context.t.batchRate;
    return switch (hold) {
      BatchRateHold.blocked => '',
      BatchRateHold.nothing => tr.holdNothing,
      BatchRateHold.noScore => tr.holdNoScore,
      BatchRateHold.reason => tr.holdReason,
      BatchRateHold.quota => tr.holdQuota,
      BatchRateHold.mult => tr.holdMult(max: widget.info.multMax),
      BatchRateHold.range => tr.holdRange,
    };
  }

  Widget _head(BatchRateConfirm c) {
    final tr = context.t.batchRate;
    final textTheme = Theme.of(context).textTheme;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.displayText(c.forum), style: textTheme.titleMedium),
          sizedBoxW4H4,
          Text(tr.summary(total: c.total, apply: c.apply)),
          if (c.chunks > 1) Text(tr.chunks(count: c.chunks), style: textTheme.bodySmall),
          if (c.mode == BatchRateMode.range) ...[
            sizedBoxW12H12,
            TextField(
              key: const ValueKey('batch-rate-floors'),
              enabled: !_busy,
              controller: _floors,
              decoration: InputDecoration(labelText: tr.floors, border: const OutlineInputBorder()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _credits(BatchRateConfirm c, BatchRateSettings s) {
    final tr = context.t.batchRate;
    final colorScheme = Theme.of(context).colorScheme;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final credit in c.credits) ...[
            Builder(
              builder: (context) {
                final quota = c.quota.where((q) => q.id == credit.id).firstOrNull;
                final entry = widget.info.credits.where((e) => e.id == credit.id).firstOrNull;
                final left = quota != null ? quota.left : entry?.left;
                final limited = quota != null ? quota.left != null : (entry != null && entry.daily > 0);
                final helper = [
                  tr.range(min: credit.min, max: credit.max),
                  if (quota != null && s.scored.containsKey(credit.id)) tr.need(need: quota.need),
                  if (limited && left != null) tr.left(left: left) else if (entry != null) tr.unlimited,
                ].join(' · ');
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('batch-rate-score-${credit.id}'),
                        enabled: !_busy,
                        controller: _scores[credit.id],
                        keyboardType: const TextInputType.numberWithOptions(signed: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^-?\d*'))],
                        decoration: InputDecoration(
                          labelText: context.displayText(credit.title),
                          helperText: helper,
                          helperStyle: quota != null && !quota.ok ? TextStyle(color: colorScheme.error) : null,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    if (c.inThread) ...[
                      sizedBoxW8H8,
                      SizedBox(
                        width: 120,
                        child: TextField(
                          key: ValueKey('batch-rate-cond-${credit.id}'),
                          enabled: !_busy,
                          controller: _conds[credit.id],
                          keyboardType: const TextInputType.numberWithOptions(signed: true),
                          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^-?\d*'))],
                          decoration: InputDecoration(
                            labelText: tr.atLeast(title: context.displayText(credit.title)),
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
            sizedBoxW12H12,
          ],
          TextField(
            key: const ValueKey('batch-rate-reason'),
            enabled: !_busy,
            controller: _reason,
            decoration: InputDecoration(
              labelText: c.reasonRequired ? '${tr.reason} *' : tr.reason,
              border: const OutlineInputBorder(),
            ),
          ),
          if (widget.info.reasonChoices.isNotEmpty) ...[
            sizedBoxW8H8,
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in widget.info.reasonChoices)
                  ActionChip(label: Text(context.displayText(r)), onPressed: _busy ? null : () => _reason.text = r),
              ],
            ),
          ],
          SwitchListTile(
            key: const ValueKey('batch-rate-notify'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr.notify),
            value: s.notify || c.notifyForced,
            onChanged: c.notifyForced || _busy ? null : (v) => _setSwitch((s) => s.notify = v),
          ),
        ],
      ),
    );
  }

  Widget _antispam(BatchRateConfirm c, BatchRateSettings s) {
    final tr = context.t.batchRate;
    final locked = c.antispam.locked;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('batch-rate-exclude'),
            enabled: !_busy,
            controller: _exclude,
            decoration: InputDecoration(labelText: tr.exclude, border: const OutlineInputBorder()),
          ),
          SwitchListTile(
            key: const ValueKey('batch-rate-rated'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr.skipRated),
            value: !c.ratedOverridden && (s.rated || locked),
            onChanged: locked || c.ratedOverridden || _busy ? null : (v) => _setSwitch((s) => s.rated = v),
          ),
          SwitchListTile(
            key: const ValueKey('batch-rate-same'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr.skipSame),
            value: s.same || locked,
            onChanged: locked || _busy ? null : (v) => _setSwitch((s) => s.same = v),
          ),
        ],
      ),
    );
  }

  Widget _actions(BatchRateConfirm c, BatchRateSettings s) {
    final tr = context.t.batchRate;
    final colorScheme = Theme.of(context).colorScheme;
    final holds = batchRateHolds(c, s, multMax: widget.info.multMax);
    final notes = [
      if (_sentUnknown) tr.unconfirmed,
      if (_stale) tr.holdStale,
      ...c.errors.map(context.displayText),
      for (final h in holds)
        if (_holdText(h) case final text when text.isNotEmpty) text,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final n in notes)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(n, style: TextStyle(color: colorScheme.error)),
          ),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              key: const ValueKey('batch-rate-recalc'),
              onPressed: _busy ? null : _recalc,
              child: Text(tr.recalc),
            ),
            FilledButton(
              key: const ValueKey('batch-rate-send'),
              onPressed: _busy || _stale || _sentUnknown || holds.isNotEmpty ? null : _send,
              child: Text(tr.send),
            ),
          ],
        ),
      ],
    );
  }

  Widget _items(BatchRateConfirm c, BatchRateSettings s) {
    final out = batchRateOutOfRange(c, s);
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final item in c.items)
            BatchRateItemTile(
              key: ValueKey('batch-rate-item-${item.pid}'),
              item: item,
              marked: out.contains(item.pid),
              trailing: item.pending
                  ? SizedBox(
                      width: 64,
                      child: TextField(
                        key: ValueKey('batch-rate-mult-${item.pid}'),
                        enabled: !_busy,
                        controller: _mults[item.pid],
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        textAlign: TextAlign.center,
                        decoration: InputDecoration(
                          prefixText: '×',
                          isDense: true,
                          border: const OutlineInputBorder(),
                          errorText: out.contains(item.pid) ? '' : null,
                        ),
                      ),
                    )
                  : null,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.batchRate;
    final c = _confirm;
    final s = _settings;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.title),
        bottom: _busy && c != null
            ? const PreferredSize(preferredSize: Size.fromHeight(2), child: LinearProgressIndicator(minHeight: 2))
            : null,
      ),
      body: c == null || s == null
          ? ToolsStateView(onRetry: _load, failed: _failed, message: _message)
          : ToolsBody(
              children: [
                _head(c),
                sizedBoxW12H12,
                _credits(c, s),
                if (c.inThread) ...[sizedBoxW12H12, _antispam(c, s)],
                sizedBoxW12H12,
                _actions(c, s),
                sizedBoxW12H12,
                _items(c, s),
              ],
            ),
    );
  }
}
