import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/repository/red_packet_repository.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/themes/widget_themes.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Show the red packet of thread [tid].
///
/// [formHash] is required to claim; when null the dialog still shows the packet but asks to reload the thread.
Future<void> showRedPacketDialog(BuildContext context, {required String tid, required String? formHash}) async =>
    showDialog<void>(
      context: context,
      builder: (context) => RootPage(DialogPaths.redPacket, RedPacketDialog(tid: tid, formHash: formHash)),
    );

/// Dialog showing a red packet: its info, the claim button and the claimed shares (手氣榜).
class RedPacketDialog extends StatefulWidget {
  /// Constructor.
  const RedPacketDialog({required this.tid, required this.formHash, this.repository = const RedPacketRepository(), super.key});

  /// Thread id of the packet.
  final String tid;

  /// Form hash of the current session, needed to claim.
  final String? formHash;

  /// Repository talking to the plugin.
  final RedPacketRepository repository;

  @override
  State<RedPacketDialog> createState() => _RedPacketDialogState();
}

class _RedPacketDialogState extends State<RedPacketDialog> with LoggerMixin {
  final _passwordController = TextEditingController();

  bool _loading = true;
  RedPacketInfo? _info;
  String? _error;
  bool _needLogin = false;

  bool _grabbing = false;
  RedPacketGrabResult? _grabbed;
  String? _grabError;

  bool _loadingRecords = false;
  RedPacketRecordsResult? _records;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final result = await widget.repository.open(widget.tid).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      switch (result) {
        case Left(:final value):
          handle(value);
          _error = value.message ?? '$value';
        case Right(:final value):
          _info = value.info;
          _error = value.error;
          _needLogin = value.needLogin;
      }
    });
  }

  Future<void> _grab() async {
    final tr = context.t.redPacket;
    final formHash = widget.formHash;
    if (formHash == null) {
      setState(() => _grabError = tr.needFormHash);
      return;
    }
    setState(() {
      _grabbing = true;
      _grabError = null;
    });
    final result = await widget.repository
        .grab(tid: widget.tid, formHash: formHash, password: _passwordController.text.trim())
        .run();
    if (!mounted) {
      return;
    }
    setState(() {
      _grabbing = false;
      switch (result) {
        case Left(:final value):
          handle(value);
          _grabError = tr.failed(err: value.message ?? '$value');
        case Right(:final value) when value.ok:
          _grabbed = value;
        case Right(:final value) when value.badPassword:
          _grabError = value.error ?? tr.badPassword;
        case Right(:final value) when value.needReply:
          _grabError = value.error ?? tr.needReply;
        case Right(:final value) when value.allTaken:
          _grabError = value.error ?? tr.stateDone;
          final info = _info;
          if (info != null) {
            _info = RedPacketInfo(
              tid: info.tid,
              from: info.from,
              bless: info.bless,
              hasPassword: info.hasPassword,
              splitMode: info.splitMode,
              unit: info.unit,
              state: RedPacketState.done,
              isSender: info.isSender,
              claimed: info.claimed,
              claimedAmount: info.claimedAmount,
              claimedBest: info.claimedBest,
            );
          }
        case Right(:final value):
          _grabError = value.error ?? tr.failed(err: value.state ?? '');
      }
    });
  }

  Future<void> _loadRecords() async {
    setState(() => _loadingRecords = true);
    final result = await widget.repository.records(widget.tid).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loadingRecords = false;
      _records = switch (result) {
        Left(:final value) => RedPacketRecordsResult(error: value.message ?? '$value'),
        Right(:final value) => value,
      };
    });
  }

  String _stateText(Translations t, RedPacketState state) => switch (state) {
    RedPacketState.open => t.redPacket.stateOpen,
    RedPacketState.claimed => t.redPacket.stateClaimed,
    RedPacketState.done => t.redPacket.stateDone,
    RedPacketState.withdrawn => t.redPacket.stateWithdrawn,
    RedPacketState.expired => t.redPacket.stateExpired,
    RedPacketState.closed => t.redPacket.stateClosed,
    RedPacketState.unknown => state.name,
  };

  Widget _buildInfo(BuildContext context, RedPacketInfo info) {
    final tr = context.t.redPacket;
    final theme = Theme.of(context);
    final secondary = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline);
    final grabbed = _grabbed;
    final claimed = grabbed != null || info.claimed;
    final claimedAmount = grabbed?.amount ?? info.claimedAmount;
    final claimedBest = grabbed?.best ?? info.claimedBest;
    final canClaim = !claimed && info.state == RedPacketState.open;
    final canSeeRecords = claimed || info.isSender;
    // The server reports `claimed` instead of `open` once the user has a share; do the same after a grab in this dialog.
    final shownState = claimed && info.state == RedPacketState.open ? RedPacketState.claimed : info.state;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (info.from.isNotEmpty) Text(info.from, style: secondary),
        sizedBoxW4H4,
        Text(info.bless, style: theme.textTheme.titleLarge),
        sizedBoxW4H4,
        Text('${info.isRandom ? tr.modeRandom : tr.modeEven} · ${_stateText(context.t, shownState)}', style: secondary),
        if (claimed) ...[
          sizedBoxW12H12,
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.redeem, color: theme.colorScheme.primary),
                  sizedBoxW8H8,
                  Text(
                    grabbed != null && !grabbed.already
                        ? tr.grabbed(amount: claimedAmount ?? '?', unit: grabbed.unit ?? info.unit)
                        : tr.claimed(amount: claimedAmount ?? '?', unit: info.unit),
                    style: theme.textTheme.titleMedium,
                  ),
                ],
              ),
              if (claimedBest) Chip(label: Text(tr.best), visualDensity: VisualDensity.compact),
            ],
          ),
        ],
        if (canClaim) ...[
          sizedBoxW12H12,
          if (info.hasPassword) ...[
            TextField(
              controller: _passwordController,
              decoration: InputDecoration(hintText: tr.passwordHint, border: const OutlineInputBorder(), isDense: true),
              enabled: !_grabbing,
            ),
            sizedBoxW8H8,
          ],
          FilledButton.icon(
            onPressed: _grabbing ? null : _grab,
            icon: _grabbing ? sizedCircularProgressIndicator : const Icon(Icons.redeem_outlined),
            label: Text(tr.claim),
          ),
        ],
        if (_grabError != null) ...[
          sizedBoxW8H8,
          Text(_grabError!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.error)),
        ],
        if (canSeeRecords) ...[sizedBoxW12H12, _buildRecords(context, info)],
      ],
    );
  }

  Widget _buildRecords(BuildContext context, RedPacketInfo info) {
    final tr = context.t.redPacket;
    final theme = Theme.of(context);
    final records = _records;
    if (_loadingRecords) {
      return const Center(child: sizedCircularProgressIndicator);
    }
    if (records == null) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _loadRecords,
          icon: const Icon(Icons.leaderboard_outlined),
          label: Text(tr.records),
        ),
      );
    }
    if (records.error != null) {
      return Text(records.error!, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline));
    }
    final unit = records.unit ?? info.unit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          records.claimed != null && records.shares != null
              ? tr.recordsTitle(claimed: records.claimed!, shares: records.shares!)
              : tr.records,
          style: theme.textTheme.titleSmall,
        ),
        sizedBoxW4H4,
        if (records.records.isEmpty)
          Text(tr.noRecords, style: theme.textTheme.bodySmall)
        else
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: records.records.length,
              itemBuilder: (context, index) {
                final record = records.records[index];
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(record.username, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(record.time),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (record.isBest) ...[
                        Icon(Icons.emoji_events_outlined, size: smallIconSize, color: theme.colorScheme.primary),
                        sizedBoxW4H4,
                      ],
                      Text('${record.amount} $unit'),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final tr = context.t.redPacket;
    final theme = Theme.of(context);
    if (_loading) {
      return const Padding(padding: edgeInsetsL24T24R24B24, child: Center(child: sizedCircularProgressIndicator));
    }
    final info = _info;
    if (info != null) {
      return _buildInfo(context, info);
    }
    return Text(
      _needLogin ? tr.needLogin : (_error ?? tr.noPacket),
      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.redPacket;
    return AlertDialog(
      title: Row(children: [const Icon(Icons.redeem_outlined), sizedBoxW8H8, Text(tr.title)]),
      content: SizedBox(width: 360, child: SingleChildScrollView(child: _buildBody(context))),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.close))],
    );
  }
}
