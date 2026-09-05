import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:tsdm_client/features/red_packet/repository/red_packet_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// App bar button claiming today's daily red packet.
///
/// Shown while the homepage carries the daily red packet config; hides itself once claimed (or when the server says it
/// was already claimed today).
class DailyRedPacketButton extends StatefulWidget {
  /// Constructor.
  const DailyRedPacketButton({
    required this.config,
    required this.formHash,
    this.repository = const RedPacketRepository(),
    super.key,
  });

  /// Today's packet.
  final DailyRedPacketConfig config;

  /// Form hash of the current session.
  final String formHash;

  /// Repository talking to the plugin.
  final RedPacketRepository repository;

  @override
  State<DailyRedPacketButton> createState() => _DailyRedPacketButtonState();
}

class _DailyRedPacketButtonState extends State<DailyRedPacketButton> with LoggerMixin {
  bool _claiming = false;
  bool _gone = false;

  Future<void> _claim() async {
    final tr = context.t.redPacket.daily;
    setState(() => _claiming = true);
    final result = await widget.repository.claimDaily(formHash: widget.formHash).run();
    if (!mounted) {
      return;
    }
    final String message;
    var gone = false;
    switch (result) {
      case Left(:final value):
        handle(value);
        message = tr.failed(err: value.message ?? '$value');
      case Right(:final value) when value.ok:
        message = tr.claimed(amount: value.amount ?? '?', unit: value.unit ?? widget.config.unit);
        gone = true;
      case Right(:final value) when value.already:
        message = value.error ?? tr.alreadyClaimed;
        gone = true;
      case Right(:final value):
        message = tr.failed(err: value.error ?? '');
    }
    setState(() {
      _claiming = false;
      _gone = gone;
    });
    showSnackBar(context: context, message: message);
  }

  @override
  Widget build(BuildContext context) {
    if (_gone) {
      return sizedBoxEmpty;
    }
    final tooltip = context.t.redPacket.daily.tooltip;
    if (_claiming) {
      return IconButton(icon: sizedCircularProgressIndicator, tooltip: tooltip, onPressed: null);
    }
    return IconButton(icon: const Icon(Icons.redeem_outlined), tooltip: tooltip, onPressed: _claim);
  }
}
