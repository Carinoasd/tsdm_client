import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/warning_log.dart';
import 'package:tsdm_client/features/moderate/repository/warning_log_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The warned mark of a floor: a tap shows the warnings of the floor's author [authorUid], asked from thread [tid].
/// Only the mark without either (an anonymous floor, a floor outside a thread).
class WarnedFloorMark extends StatelessWidget {
  /// Constructor.
  const WarnedFloorMark({required this.tid, required this.authorUid, this.repository, super.key});

  /// The thread the floor is in.
  final int? tid;

  /// The floor's author.
  final int? authorUid;

  /// Where the warnings come from; the forum by default.
  final WarningLogRepository? repository;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(Icons.report_outlined, size: 20, color: Theme.of(context).colorScheme.error);
    final mark = Tooltip(message: context.t.moderate.warned, child: icon);
    if ((tid, authorUid) case (final tid?, final uid?) when tid > 0 && uid > 0) {
      return InkResponse(
        key: const ValueKey('floor-warned-mark'),
        radius: 18,
        onTap: () => unawaited(showWarningLog(context, tid: tid, uid: uid, repository: repository)),
        child: mark,
      );
    }
    return mark;
  }
}

/// Show the warnings of member [uid], asked from thread [tid].
Future<void> showWarningLog(
  BuildContext context, {
  required int tid,
  required int uid,
  WarningLogRepository? repository,
}) => showCustomBottomSheet<void>(
  context: context,
  title: context.t.warningLog.title,
  builder: (_) => WarningLogView(tid: tid, uid: uid, repository: repository ?? WarningLogRepository.network()),
);

/// The warnings of a member, see [showWarningLog].
class WarningLogView extends StatefulWidget {
  /// Constructor.
  const WarningLogView({required this.tid, required this.uid, required this.repository, super.key});

  /// The thread asked from.
  final int tid;

  /// The member.
  final int uid;

  /// Where they come from.
  final WarningLogRepository repository;

  @override
  State<WarningLogView> createState() => _WarningLogViewState();
}

class _WarningLogViewState extends State<WarningLogView> {
  Either<AppException, WarningLogAnswer>? _answer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _answer = null);
    final answer = await widget.repository.fetch(tid: widget.tid, uid: widget.uid);
    if (mounted) setState(() => _answer = answer);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final children = switch (_answer) {
      null => [
        const Center(
          child: Padding(padding: EdgeInsets.all(24), child: CircularIndicator()),
        ),
      ],
      Right(value: WarningLogShown(:final log)) => [
        if (log.records.isEmpty) Center(child: Text(context.t.general.noData)),
        for (final (i, record) in log.records.indexed)
          ListTile(
            key: ValueKey('warning-record-$i'),
            contentPadding: EdgeInsets.zero,
            title: Text(record.reason.isEmpty ? '-' : context.displayText(record.reason)),
            subtitle: Text(
              [context.displayText(record.operator), record.time].where((e) => e.isNotEmpty).join(' · '),
              style: muted,
            ),
          ),
        if (log.summary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(context.displayText(log.summary), style: muted),
          ),
      ],
      Right(value: WarningLogRefused(:final message)) => [
        Text(message.isEmpty ? context.t.general.failedToLoad : context.displayText(message)),
      ],
      Left(:final value) => [
        Text(
          value is IdentityChangedException ? context.t.general.accountChangedRetry : context.t.general.failedToLoad,
          style: TextStyle(color: theme.colorScheme.error),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(onPressed: _load, child: Text(context.t.general.retry)),
        ),
      ],
    };
    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: children);
  }
}
