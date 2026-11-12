import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fpdart/fpdart.dart' show Either, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/features/moderate/models/modcp_json_pages.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_pages_widgets.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The notes the moderators leave each other on the panel's first page (`modcp_home`): leave one (who sees it, for how
/// many days), and delete those the account may (its own; any for an administrator).
class ModcpNotesPage extends StatefulWidget {
  /// Constructor.
  const ModcpNotesPage({required this.repository, super.key});

  /// The panel's pages.
  final ModcpPagesRepository repository;

  @override
  State<ModcpNotesPage> createState() => _ModcpNotesPageState();
}

class _ModcpNotesPageState extends State<ModcpNotesPage> {
  bool _loading = true;
  bool _sending = false;
  Either<AppException, ModcpAnswer<ModcpHome>>? _answer;
  final _picked = <int>{};
  final _message = TextEditingController();
  final _days = TextEditingController();
  bool _toSupermod = true;
  bool _toModerator = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _message.dispose();
    _days.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() => _loading = true);
    final answer = await widget.repository.fetchHome().run();
    if (!mounted || generation != _generation) {
      return;
    }
    _show(answer);
  }

  void _show(Either<AppException, ModcpAnswer<ModcpHome>> answer) => setState(() {
    _loading = false;
    _answer = answer;
    if (answer case Right(value: ModcpReady(:final value))) {
      final listed = {for (final n in value.notes) n.id};
      _picked.retainWhere(listed.contains);
      if (_days.text.isEmpty) {
        _days.text = '${value.addForm?.daysDefault ?? 30}';
      }
    }
  });

  /// Show the page the panel drew after a form; the page again when it drew none.
  Future<void> _after(ModcpPosted<ModcpHome>? posted) async {
    if (posted?.page case final page?) {
      _generation++;
      _show(Right(ModcpReady(page)));
    } else {
      await _load();
    }
  }

  Future<void> _add(ModcpHome home) async {
    final message = _message.text.trim();
    if (message.isEmpty || _sending) {
      return;
    }
    setState(() => _sending = true);
    final outcome = await widget.repository
        .addNote(
          home,
          message: message,
          toSupermod: _toSupermod,
          toModerator: _toModerator,
          days: int.tryParse(_days.text.trim()) ?? 0,
        )
        .run();
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    final result = outcome.map((e) => e.outcome);
    showSnackBar(
      context: context,
      message: modcpPagesOutcomeText(context, result, done: context.t.modcpPages.noteAdded),
    );
    if (result case Right(value: ModcpWriteDone() || ModcpWriteUnknown())) {
      _message.clear();
    }
    await _after(outcome.toNullable());
  }

  Future<void> _delete(ModcpHome home) async {
    final ids = [
      for (final n in home.notes)
        if (_picked.contains(n.id)) n.id,
    ];
    if (ids.isEmpty || _sending) {
      return;
    }
    final tr = context.t.modcpPages;
    final ok = await showToolsConfirm(
      context,
      title: tr.deleteNotes,
      confirm: context.t.modcp.delete,
      destructive: true,
      content: [Text(context.t.modcp.selected(count: ids.length))],
    );
    if (!ok || !mounted) {
      return;
    }
    setState(() => _sending = true);
    final outcome = await widget.repository.deleteNotes(home, ids).run();
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    final result = outcome.map((e) => e.outcome);
    showSnackBar(
      context: context,
      message: modcpPagesOutcomeText(context, result, done: context.t.modcp.done(count: ids.length)),
    );
    if (result case Right(value: ModcpWriteDone())) {
      setState(_picked.clear);
    }
    await _after(outcome.toNullable());
  }

  Widget _compose(ModcpHome home) {
    final tr = context.t.modcpPages;
    return AppSurface(
      key: const ValueKey('modcp-note-compose'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('modcp-note-message'),
            controller: _message,
            enabled: !_sending,
            minLines: 2,
            maxLines: 6,
            decoration: InputDecoration(labelText: context.t.modcp.content, border: const OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                key: const ValueKey('modcp-note-supermod'),
                label: Text(tr.toSupermod),
                selected: _toSupermod,
                onSelected: _sending ? null : (v) => setState(() => _toSupermod = v),
              ),
              FilterChip(
                key: const ValueKey('modcp-note-moderator'),
                label: Text(tr.toModerator),
                selected: _toModerator,
                onSelected: _sending ? null : (v) => setState(() => _toModerator = v),
              ),
              SizedBox(
                width: 120,
                child: TextField(
                  key: const ValueKey('modcp-note-days'),
                  controller: _days,
                  enabled: !_sending,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
                  decoration: InputDecoration(isDense: true, labelText: tr.days, border: const OutlineInputBorder()),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton(
              key: const ValueKey('modcp-note-add'),
              onPressed: _sending || _message.text.trim().isEmpty ? null : () => _add(home),
              child: Text(tr.addNote),
            ),
          ),
        ],
      ),
    );
  }

  Widget _note(ModcpNote note) {
    final theme = Theme.of(context);
    final tr = context.t.modcpPages;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(note.message, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 6),
        modcpMutedLine(context, [
          note.admin,
          toolsDateTime(note.dateline),
          if (note.expiration > 0) tr.expires(date: toolsDate(note.expiration)),
          [if (note.toSupermod) tr.toSupermod, if (note.toModerator) tr.toModerator].join('、'),
        ]),
      ],
    );
    if (!note.canDelete) {
      return AppSurface(key: ValueKey('modcp-note-${note.id}'), child: content);
    }
    return ModcpPickCard(
      key: ValueKey('modcp-note-${note.id}'),
      picked: _picked.contains(note.id),
      onChanged: _sending ? null : (picked) => setState(() => picked ? _picked.add(note.id) : _picked.remove(note.id)),
      child: content,
    );
  }

  Widget _page(ModcpHome home) {
    final deletable = [
      for (final n in home.notes)
        if (n.canDelete) n.id,
    ];
    final allPicked = deletable.isNotEmpty && deletable.every(_picked.contains);
    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: AppCenteredList(
              builder: (context, padding, _) => ListView.separated(
                padding: padding.copyWith(top: 8, bottom: 8),
                itemCount: home.notes.length + 1 + (home.notes.isEmpty ? 1 : 0),
                separatorBuilder: (_, _) => appListSeparator,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return home.addForm == null ? const SizedBox.shrink() : _compose(home);
                  }
                  if (home.notes.isEmpty) {
                    return AppStateView(
                      icon: Icons.sticky_note_2_outlined,
                      message: context.t.modcpPages.notesEmpty,
                      scrollable: false,
                    );
                  }
                  return _note(home.notes[index - 1]);
                },
              ),
            ),
          ),
        ),
        if (deletable.isNotEmpty && home.deleteForm != null)
          ModcpPickBar(
            picked: _picked.length,
            allPicked: allPicked,
            sending: _sending,
            onPickAll: _sending ? null : () => setState(() => allPicked ? _picked.clear() : _picked.addAll(deletable)),
            actions: [
              TextButton(
                key: const ValueKey('modcp-notes-delete'),
                onPressed: _picked.isEmpty || _sending ? null : () => _delete(home),
                style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
                child: Text(context.t.modcp.delete),
              ),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.t.modcpPages.notes)),
    body: ModcpAnswerView<ModcpHome>(
      repository: widget.repository.panel,
      loading: _loading && _answer == null,
      answer: _answer,
      onReload: _load,
      builder: (context, home) => _page(home),
    ),
  );
}
