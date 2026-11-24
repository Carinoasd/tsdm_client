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
import 'package:tsdm_client/widgets/app_surface.dart';

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
  const RedPacketDialog({
    required this.tid,
    required this.formHash,
    this.repository = const RedPacketRepository(),
    super.key,
  });

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
    final secondary = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final grabbed = _grabbed;
    final claimed = grabbed != null || info.claimed;
    final claimedAmount = grabbed?.amount ?? info.claimedAmount;
    final claimedBest = grabbed?.best ?? info.claimedBest;
    final canClaim = !claimed && info.state == RedPacketState.open;
    final canSeeRecords = claimed || info.isSender;
    // The server reports `claimed` instead of `open` once the user has a share; do the same after a grab in this dialog.
    final shownState = claimed && info.state == RedPacketState.open ? RedPacketState.claimed : info.state;

    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        AppInsetBlock(
          outlined: true,
          padding: edgeInsetsL12T12R12B12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (info.from.isNotEmpty) ...[Text(info.from, style: secondary), sizedBoxW4H4],
              Text(info.bless, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
              sizedBoxW8H8,
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  AppInfoPill(
                    icon: info.isRandom ? Icons.shuffle_outlined : Icons.drag_handle_outlined,
                    label: info.isRandom ? tr.modeRandom : tr.modeEven,
                  ),
                  AppInfoPill(icon: Icons.flag_outlined, label: _stateText(context.t, shownState)),
                ],
              ),
            ],
          ),
        ),
        if (claimed) ...[
          sizedBoxW12H12,
          AppInsetBlock(
            color: colorScheme.primaryContainer,
            padding: edgeInsetsL12T12R12B12,
            child: Row(
              children: [
                Icon(Icons.redeem, color: colorScheme.onPrimaryContainer),
                sizedBoxW8H8,
                Expanded(
                  child: Text(
                    grabbed != null && !grabbed.already
                        ? tr.grabbed(amount: claimedAmount ?? '?', unit: grabbed.unit ?? info.unit)
                        : tr.claimed(amount: claimedAmount ?? '?', unit: info.unit),
                    style: theme.textTheme.titleMedium?.copyWith(color: colorScheme.onPrimaryContainer),
                  ),
                ),
                if (claimedBest) ...[
                  sizedBoxW8H8,
                  AppInsetBlock(
                    color: colorScheme.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.emoji_events_outlined, size: 14, color: colorScheme.onPrimary),
                        sizedBoxW4H4,
                        Text(tr.best, style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.onPrimary)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (canClaim) ...[
          sizedBoxW12H12,
          if (info.hasPassword) ...[
            TextField(
              controller: _passwordController,
              decoration: InputDecoration(
                hintText: tr.passwordHint,
                prefixIcon: const Icon(Icons.password_outlined),
                filled: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
                isDense: true,
              ),
              enabled: !_grabbing,
              textInputAction: TextInputAction.done,
              onSubmitted: _grabbing ? null : (_) => unawaited(_grab()),
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
          AppNoticeBanner(message: _grabError!, tone: AppNoticeTone.error, selectable: true),
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
      return AppNoticeBanner(message: records.error!, tone: AppNoticeTone.error, selectable: true);
    }
    final unit = records.unit ?? info.unit;
    final colorScheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        AppSectionHeader(
          records.claimed != null && records.shares != null
              ? tr.recordsTitle(claimed: records.claimed!, shares: records.shares!)
              : tr.records,
          icon: Icons.leaderboard_outlined,
          padding: const EdgeInsets.only(bottom: 8),
        ),
        if (records.records.isEmpty)
          Text(tr.noRecords, style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant))
        else
          // The records scroll with the dialog; a nested list would fight the dialog's own scrolling.
          AppInsetBlock(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Column(
              children: [
                for (final (index, record) in records.records.indexed) ...[
                  if (index > 0) Divider(height: 1, color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                record.username,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              Text(
                                record.time,
                                style: theme.textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                        if (record.isBest) ...[
                          Icon(Icons.emoji_events_outlined, size: smallIconSize, color: colorScheme.primary),
                          sizedBoxW4H4,
                        ],
                        Text(
                          '${record.amount} $unit',
                          style: theme.textTheme.labelLarge?.copyWith(color: colorScheme.primary),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final tr = context.t.redPacket;
    if (_loading) {
      return const Padding(
        padding: edgeInsetsL24T24R24B24,
        child: Center(child: sizedCircularProgressIndicator),
      );
    }
    final info = _info;
    if (info != null) {
      return _buildInfo(context, info);
    }
    return AppNoticeBanner(
      message: _needLogin ? tr.needLogin : (_error ?? tr.noPacket),
      tone: _needLogin || _error == null ? AppNoticeTone.info : AppNoticeTone.error,
      icon: _needLogin ? Icons.login : null,
      selectable: !_needLogin,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.redPacket;
    return AlertDialog(
      title: Row(
        children: [
          AppIconTile(
            Icons.redeem_outlined,
            size: 36,
            color: Theme.of(context).colorScheme.errorContainer,
            foregroundColor: Theme.of(context).colorScheme.onErrorContainer,
          ),
          sizedBoxW12H12,
          Expanded(child: Text(tr.title)),
        ],
      ),
      content: SizedBox(width: 360, child: SingleChildScrollView(child: _buildBody(context))),
      actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.close))],
    );
  }
}
