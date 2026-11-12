import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/batch_rate/models/batch_rate.dart';
import 'package:tsdm_client/features/batch_rate/repository/batch_rate_repository.dart';
import 'package:tsdm_client/features/batch_rate/view/batch_rate_confirm_page.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// A floor of the thread on screen that may be picked.
typedef BatchRateFloor = ({int pid, int floor, String author});

/// Pick the floors of thread [tid] to rate in a batch: by floor numbers (`3~5 10 15~20`, `30~` to the last; any page
/// of the thread), or one by one among the [floors] loaded on the thread's page. Then the confirmation.
class BatchRateFloorsPage extends StatefulWidget {
  /// Constructor.
  const BatchRateFloorsPage({
    required this.info,
    required this.tid,
    required this.floors,
    this.repository,
    super.key,
  });

  /// What the entry was offered with.
  final BatchRateInfo info;

  /// The thread.
  final int tid;

  /// The floors loaded on the thread's page, in their order.
  final List<BatchRateFloor> floors;

  /// Injected for tests; the account's network client otherwise.
  final BatchRateRepository? repository;

  @override
  State<BatchRateFloorsPage> createState() => _BatchRateFloorsPageState();
}

class _BatchRateFloorsPageState extends State<BatchRateFloorsPage> {
  /// The first floor is the thread's author's: from the second by default, as the website does.
  final _range = TextEditingController(text: '2~');
  bool _byRange = true;
  final _picked = <int>{};

  @override
  void dispose() {
    _range.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    final BatchRateSelection selection;
    if (_byRange) {
      final floors = parseBatchRateFloors(_range.text, maxSegments: widget.info.floorSegments);
      if (floors == null) {
        showSnackBar(context: context, message: context.t.batchRate.badFloors);
        return;
      }
      selection = BatchRateSelection.floors(fid: widget.info.fid, tid: widget.tid, floors: floors);
    } else {
      if (_picked.isEmpty) {
        return;
      }
      selection = BatchRateSelection.posts(
        fid: widget.info.fid,
        tid: widget.tid,
        pids: [
          for (final f in widget.floors)
            if (_picked.contains(f.pid)) f.pid,
        ],
      );
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => BatchRateConfirmPage(info: widget.info, selection: selection, repository: widget.repository),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.batchRate;
    final all = widget.floors.isNotEmpty && widget.floors.every((f) => _picked.contains(f.pid));
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.title),
        actions: [
          if (!_byRange)
            IconButton(
              key: const ValueKey('batch-rate-select-all'),
              icon: const Icon(Icons.select_all_outlined),
              tooltip: tr.selectAll,
              onPressed: () => setState(() {
                if (all) {
                  _picked.clear();
                } else {
                  _picked.addAll(widget.floors.map((f) => f.pid));
                }
              }),
            ),
        ],
      ),
      body: ToolsBody(
        children: [
          SegmentedButton<bool>(
            key: const ValueKey('batch-rate-way'),
            segments: [
              ButtonSegment(value: true, label: Text(tr.byRange)),
              ButtonSegment(value: false, label: Text(tr.byPick), enabled: widget.floors.isNotEmpty),
            ],
            selected: {_byRange},
            onSelectionChanged: (v) => setState(() => _byRange = v.first),
          ),
          sizedBoxW12H12,
          if (_byRange)
            TextField(
              key: const ValueKey('batch-rate-range'),
              controller: _range,
              decoration: InputDecoration(labelText: tr.floors, border: const OutlineInputBorder()),
              onSubmitted: (_) => _next(),
            )
          else
            AppSurface(
              child: Column(
                children: [
                  for (final f in widget.floors)
                    CheckboxListTile(
                      key: ValueKey('batch-rate-floor-${f.pid}'),
                      contentPadding: EdgeInsets.zero,
                      value: _picked.contains(f.pid),
                      title: Text('${tr.floor(n: f.floor)} · ${f.author}'),
                      onChanged: (v) => setState(() => v ?? false ? _picked.add(f.pid) : _picked.remove(f.pid)),
                    ),
                ],
              ),
            ),
          sizedBoxW12H12,
          Row(
            children: [
              if (!_byRange) Text(tr.picked(count: _picked.length)),
              const Spacer(),
              FilledButton(
                key: const ValueKey('batch-rate-next'),
                onPressed: _byRange || _picked.isNotEmpty ? _next : null,
                child: Text(tr.next),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
