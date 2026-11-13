import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/models/modcp_recommend.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// The threads recommended in the forums the account moderates (the panel's 推荐主题): their place, title and end
/// changed one at a time, and taken off the list several at a time, where the forum orders the list by hand; read
/// only where it orders it itself.
class RecommendThreadsPage extends StatefulWidget {
  /// Constructor.
  const RecommendThreadsPage({required this.repository, super.key});

  /// The panel.
  final ModcpRepository repository;

  @override
  State<RecommendThreadsPage> createState() => _RecommendThreadsPageState();
}

class _RecommendThreadsPageState extends State<RecommendThreadsPage> {
  bool _loading = true;
  bool _sending = false;
  Either<AppException, ModcpAnswer<RecommendList>>? _answer;

  /// The forum asked, 0 for the one the panel chooses.
  int _fid = 0;

  /// The forums the panel offered, last read.
  List<ModcpForum> _forums = const [];

  final _picked = <int>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final answer = await widget.repository.fetchRecommends(fid: _fid).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      _answer = answer;
      _picked.clear();
      if (answer case Right(value: ModcpReady(:final value))) {
        if (value.forums.isNotEmpty) {
          _forums = value.forums;
        }
        if (value.fid > 0) {
          _fid = value.fid;
        }
      }
    });
  }

  RecommendList? get _list => switch (_answer) {
    Right(value: ModcpReady(:final value)) when value.fid > 0 => value,
    _ => null,
  };

  Future<void> _pick(int fid) async {
    _fid = fid;
    await _load();
  }

  Future<void> _switchForum(int current) async {
    final picked = await showModalBottomSheet<ModcpForum>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final forum in _forums)
              ListTile(
                key: ValueKey('modcp-switch-forum-${forum.fid}'),
                title: Text(context.displayText(forum.name)),
                selected: forum.fid == current,
                trailing: forum.fid == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(forum),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted && picked.fid != current) {
      await _pick(picked.fid);
    }
  }

  /// Send [list] with [edits] and [remove], once, then read the list again.
  Future<void> _send(RecommendList list, {Map<int, RecommendEdit> edits = const {}, Set<int> remove = const {}}) async {
    setState(() => _sending = true);
    final outcome = await widget.repository.saveRecommends(list, edits: edits, remove: remove).run();
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    showSnackBar(context: context, message: modcpOutcomeText(context, outcome));
    await _load();
  }

  Future<void> _edit(RecommendList list, RecommendedThread thread) async {
    final edit = await showDialog<RecommendEdit>(
      context: context,
      builder: (_) => _RecommendEditDialog(thread: thread),
    );
    if (edit != null && mounted) {
      await _send(list, edits: {thread.tid: edit});
    }
  }

  Future<void> _remove(RecommendList list) async {
    if (_picked.isEmpty || _sending) {
      return;
    }
    final tr = context.t.modcpRecommend;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => CustomAlertDialog.sync(
        title: AppDialogTitle(icon: Icons.thumb_down_alt_outlined, title: tr.remove, error: true),
        content: Text(context.t.modcp.selected(count: _picked.length)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.general.cancel)),
          TextButton(
            key: const ValueKey('modcp-recommend-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.general.ok, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if ((ok ?? false) && mounted) {
      await _send(list, remove: {..._picked});
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcpRecommend;
    final list = _list;
    final name = _forums.where((e) => e.fid == list?.fid).firstOrNull?.name;
    return PopScope(
      canPop: !_sending,
      child: Scaffold(
        appBar: AppBar(
          title: Text(name == null ? tr.title : '${tr.title} · ${context.displayText(name)}'),
          actions: [
            if (list != null && _forums.length > 1)
              IconButton(
                key: const ValueKey('modcp-switch-forum'),
                tooltip: context.t.modcp.switchForum,
                icon: const Icon(Icons.swap_horiz),
                onPressed: _sending ? null : () => _switchForum(list.fid),
              ),
          ],
        ),
        body: ModcpAnswerView<RecommendList>(
          repository: widget.repository,
          loading: _loading,
          answer: _answer,
          onReload: _load,
          builder: (context, list) => list.fid > 0 ? _threads(context, list) : _chooser(context, list),
        ),
      ),
    );
  }

  /// The forum asked is not one the account moderates (any more): the forums the panel offers.
  Widget _chooser(BuildContext context, RecommendList list) {
    final forums = list.forums.isNotEmpty ? list.forums : _forums;
    if (forums.isEmpty) {
      return AppStateView(icon: Icons.forum_outlined, message: context.t.modcp.noForums);
    }
    return AppCenteredList(
      builder: (context, padding, _) => ListView(
        padding: padding.copyWith(top: 8, bottom: 8),
        children: [
          AppSurface(
            child: Column(
              children: [
                for (final forum in forums)
                  ListTile(
                    key: ValueKey('modcp-forum-${forum.fid}'),
                    leading: const Icon(Icons.forum_outlined),
                    title: Text(context.displayText(forum.name)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _pick(forum.fid),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _facts(BuildContext context, RecommendedThread thread) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget fact(IconData icon, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Flexible(child: Text(text, style: style)),
      ],
    );
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        fact(Icons.format_list_numbered, '${thread.order}'),
        if (thread.author.isNotEmpty) fact(Icons.person_outline, context.displayText(thread.author)),
        if (thread.recommender.isNotEmpty) fact(Icons.thumb_up_alt_outlined, context.displayText(thread.recommender)),
        if (thread.expiration.isNotEmpty) fact(Icons.schedule, thread.expiration),
      ],
    );
  }

  Widget _threads(BuildContext context, RecommendList list) {
    if (list.threads.isEmpty) {
      return RefreshIndicator(
        onRefresh: _load,
        child: AppScrollableStateView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: AppStateView(
            icon: Icons.thumb_up_alt_outlined,
            message: context.t.modcpRecommend.empty,
            scrollable: false,
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    final all = list.threads.map((e) => e.tid).toSet();
    final allPicked = all.every(_picked.contains);
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: AppCenteredList(
              builder: (context, padding, _) => ListView.separated(
                padding: padding.copyWith(top: 8, bottom: 88),
                itemCount: list.threads.length,
                separatorBuilder: (_, _) => appListSeparator,
                itemBuilder: (context, index) {
                  final thread = list.threads[index];
                  final content = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.displayText(thread.subject), style: theme.textTheme.titleSmall),
                      const SizedBox(height: 6),
                      _facts(context, thread),
                    ],
                  );
                  if (!list.editable) {
                    return AppSurface(
                      key: ValueKey('modcp-recommend-${thread.tid}'),
                      child: Padding(padding: const EdgeInsets.all(16), child: content),
                    );
                  }
                  return ModcpPickCard(
                    key: ValueKey('modcp-recommend-${thread.tid}'),
                    picked: _picked.contains(thread.tid),
                    onChanged: _sending
                        ? null
                        : (v) => setState(() => v ? _picked.add(thread.tid) : _picked.remove(thread.tid)),
                    onTap: _sending ? null : () => _edit(list, thread),
                    child: content,
                  );
                },
              ),
            ),
          ),
        ),
        if (list.editable)
          ModcpPickBar(
            picked: _picked.length,
            allPicked: allPicked,
            sending: _sending,
            onPickAll: _sending ? null : () => setState(() => allPicked ? _picked.clear() : _picked.addAll(all)),
            actions: [
              TextButton(
                key: const ValueKey('modcp-recommend-remove'),
                onPressed: _picked.isEmpty || _sending ? null : () => _remove(list),
                style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                child: Text(context.t.modcpRecommend.remove),
              ),
            ],
          ),
      ],
    );
  }
}

/// The place, the title and the end of a recommended thread, changed; pops the change, null when cancelled.
class _RecommendEditDialog extends StatefulWidget {
  const _RecommendEditDialog({required this.thread});

  final RecommendedThread thread;

  @override
  State<_RecommendEditDialog> createState() => _RecommendEditDialogState();
}

class _RecommendEditDialogState extends State<_RecommendEditDialog> {
  late final _order = TextEditingController(text: '${widget.thread.order}');
  late final _subject = TextEditingController(text: widget.thread.subject);
  late String _expiration = widget.thread.expiration;

  @override
  void dispose() {
    _order.dispose();
    _subject.dispose();
    super.dispose();
  }

  /// [_expiration] as a time, null when there is none or it can not be read.
  DateTime? get _expirationTime => recommendExpirationTime(_expiration);

  Future<void> _pickExpiration() async {
    final now = DateTime.now();
    final current = _expirationTime ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (date == null || !mounted) {
      return;
    }
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(current));
    if (time == null || !mounted) {
      return;
    }
    setState(
      () => _expiration = recommendExpirationText(
        DateTime(date.year, date.month, date.day, time.hour, time.minute),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcpRecommend;
    final order = int.tryParse(_order.text.trim());
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.edit_outlined, title: context.t.modcp.subject),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            key: const ValueKey('modcp-recommend-subject'),
            controller: _subject,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(labelText: context.t.modcp.subject),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('modcp-recommend-order'),
            controller: _order,
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: tr.order),
          ),
          const SizedBox(height: 12),
          InkWell(
            key: const ValueKey('modcp-recommend-expiration'),
            onTap: _pickExpiration,
            borderRadius: BorderRadius.circular(4),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: tr.expiration,
                suffixIcon: _expiration.isEmpty
                    ? null
                    : IconButton(
                        key: const ValueKey('modcp-recommend-expiration-clear'),
                        icon: const Icon(Icons.clear),
                        onPressed: () => setState(() => _expiration = ''),
                      ),
              ),
              child: Text(_expiration.isEmpty ? context.t.moderate.noExpiration : _expiration),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        TextButton(
          key: const ValueKey('modcp-recommend-save'),
          onPressed: order == null
              ? null
              : () => Navigator.of(
                  context,
                ).pop<RecommendEdit>((order: order, subject: _subject.text.trim(), expiration: _expiration)),
          child: Text(context.t.modcp.save),
        ),
      ],
    );
  }
}
