import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart';
import 'package:tsdm_client/features/red_packet/widgets/red_packet_dialog.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

/// Red envelope colors used by the forum, kept the same in both themes.
const _envelopeTop = Color(0xFFD1302F);
const _envelopeBottom = Color(0xFFB82A29);
const _envelopeText = Color(0xFFFDEEDE);
const _envelopeGold = Color(0xFFF4D493);

/// The red packet entry rendered inside a post body.
///
/// Shows the blessing and the status line of the packet; tapping opens [RedPacketDialog] which talks to the plugin.
class RedPacketCard extends StatelessWidget {
  /// Constructor.
  const RedPacketCard(this.entry, {this.elevation, super.key});

  /// Parsed entry.
  final RedPacketEntry entry;

  /// Elevation of the card.
  final double? elevation;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.redPacket;
    final textTheme = Theme.of(context).textTheme;
    // The form hash only exists in a thread page; other places (e.g. previews) can still show the card.
    final formHash = context.readOrNull<ThreadBloc>()?.state.replyParameters?.formHash;
    return Card(
      elevation: elevation,
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      color: _envelopeBottom,
      child: InkWell(
        onTap: () async => showRedPacketDialog(context, tid: entry.tid, formHash: formHash),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_envelopeTop, _envelopeBottom],
            ),
          ),
          child: Padding(
            padding: edgeInsetsL16T12R16B12,
            child: Row(
              children: [
                const Icon(Icons.redeem_outlined, color: _envelopeGold, size: 32),
                sizedBoxW12H12,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.bless.isEmpty ? tr.title : entry.bless,
                        style: textTheme.titleMedium?.copyWith(color: _envelopeText, fontWeight: FontWeight.bold),
                      ),
                      if (entry.statusText.isNotEmpty) ...[
                        sizedBoxW4H4,
                        Text(entry.statusText, style: textTheme.bodySmall?.copyWith(color: _envelopeText)),
                      ],
                    ],
                  ),
                ),
                sizedBoxW8H8,
                const Icon(Icons.chevron_right, color: _envelopeGold),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
