import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// The site's announcements (the panel's 公告): listed, added, edited, and deleted when the panel offers it (the
/// account's own).
class AnnouncementsPage extends StatefulWidget {
  /// Constructor.
  const AnnouncementsPage({required this.repository, super.key});

  /// The panel.
  final ModcpRepository repository;

  @override
  State<AnnouncementsPage> createState() => _AnnouncementsPageState();
}

class _AnnouncementsPageState extends State<AnnouncementsPage> {
  bool _loading = true;
  bool _sending = false;
  Either<AppException, ModcpAnswer<AnnouncementList>>? _answer;
  final _picked = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final answer = await widget.repository.fetchAnnouncements().run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      _answer = answer;
      _picked.clear();
    });
  }

  AnnouncementList? get _list => switch (_answer) {
    Right(value: ModcpReady(:final value)) => value,
    _ => null,
  };

  Future<void> _open({AnnouncementForm? blank, int id = 0}) async {
    final list = _list;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AnnouncementEditPage(
          repository: widget.repository,
          form: blank,
          id: id,
          known: {for (final e in list?.items ?? const <AnnouncementItem>[]) e.id},
        ),
      ),
    );
    if (saved ?? false) {
      await _load();
    }
  }

  Future<void> _delete() async {
    final list = _list;
    if (list == null || _picked.isEmpty || _sending) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => CustomAlertDialog.sync(
        title: AppDialogTitle(icon: Icons.delete_outline, title: context.t.modcp.delete, error: true),
        content: Text(context.t.modcp.selected(count: _picked.length)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.general.cancel)),
          TextButton(
            key: const ValueKey('modcp-delete-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.t.general.ok, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    setState(() => _sending = true);
    final outcome = await widget.repository.deleteAnnouncements(list, _picked.toList()).run();
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    showSnackBar(context: context, message: modcpOutcomeText(context, outcome));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcp;
    final blank = _list?.blank;
    return Scaffold(
      appBar: AppBar(title: Text(tr.announcements)),
      floatingActionButton: blank == null
          ? null
          : FloatingActionButton(
              key: const ValueKey('modcp-announcement-add'),
              tooltip: tr.newAnnouncement,
              onPressed: _sending ? null : () => _open(blank: blank),
              child: const Icon(Icons.add),
            ),
      body: ModcpAnswerView<AnnouncementList>(
        repository: widget.repository,
        loading: _loading,
        answer: _answer,
        onReload: _load,
        builder: (context, list) {
          if (list.items.isEmpty) {
            return RefreshIndicator(
              onRefresh: _load,
              child: AppScrollableStateView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: AppStateView(icon: Icons.campaign_outlined, message: tr.announcementsEmpty, scrollable: false),
              ),
            );
          }
          final deletable = list.items.where((e) => e.deletable).map((e) => e.id).toSet();
          final allPicked = deletable.isNotEmpty && deletable.every(_picked.contains);
          final theme = Theme.of(context);
          return Column(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: AppCenteredList(
                    builder: (context, padding, _) => ListView.separated(
                      padding: padding.copyWith(top: 8, bottom: 88),
                      itemCount: list.items.length,
                      separatorBuilder: (_, _) => appListSeparator,
                      itemBuilder: (context, index) {
                        final item = list.items[index];
                        return ModcpPickCard(
                          key: ValueKey('modcp-announcement-${item.id}'),
                          picked: _picked.contains(item.id),
                          onChanged: !item.deletable || _sending
                              ? null
                              : (v) => setState(() => v ? _picked.add(item.id) : _picked.remove(item.id)),
                          onTap: _sending ? null : () => _open(id: int.parse(item.id)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(context.displayText(item.subject), style: theme.textTheme.titleSmall),
                              const SizedBox(height: 4),
                              modcpMutedLine(context, [item.author, item.type, '${item.start} – ${item.end}']),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
              if (deletable.isNotEmpty)
                ModcpPickBar(
                  picked: _picked.length,
                  allPicked: allPicked,
                  sending: _sending,
                  onPickAll: _sending
                      ? null
                      : () => setState(() => allPicked ? _picked.clear() : _picked.addAll(deletable)),
                  actions: [
                    TextButton(
                      key: const ValueKey('modcp-announcement-delete'),
                      onPressed: _picked.isEmpty || _sending ? null : _delete,
                      style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                      child: Text(tr.delete),
                    ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

/// An announcement filled in: a new one ([form] the panel's blank form), or announcement [id] read first. Pops true
/// once the forum keeps it.
class AnnouncementEditPage extends StatefulWidget {
  /// Constructor.
  const AnnouncementEditPage({required this.repository, this.form, this.id = 0, this.known = const {}, super.key});

  /// The panel.
  final ModcpRepository repository;

  /// The blank form of a new announcement.
  final AnnouncementForm? form;

  /// The announcement edited, 0 for a new one.
  final int id;

  /// The announcements listed before (a new one is told by its id not among them).
  final Set<String> known;

  @override
  State<AnnouncementEditPage> createState() => _AnnouncementEditPageState();
}

class _AnnouncementEditPageState extends State<AnnouncementEditPage> {
  bool _loading = false;
  bool _sending = false;
  Either<AppException, ModcpAnswer<AnnouncementForm>>? _answer;

  final _subject = TextEditingController();
  final _message = TextEditingController();
  AnnouncementType _type = AnnouncementType.text;
  String _start = '';
  String _end = '';

  /// The fields hold the form read (or what was typed since).
  bool _filled = false;

  /// Saving was tried with a field left empty: the empty ones are marked.
  bool _tried = false;

  @override
  void initState() {
    super.initState();
    if (widget.form case final form?) {
      _answer = Right(ModcpReady(form));
      _fill(form);
    } else {
      unawaited(_load());
    }
  }

  @override
  void dispose() {
    _subject.dispose();
    _message.dispose();
    super.dispose();
  }

  void _fill(AnnouncementForm form) {
    _filled = true;
    _subject.text = form.subject;
    _message.text = form.message;
    _type = form.type;
    _start = form.start;
    _end = form.end;
  }

  /// The form: announcement [AnnouncementEditPage.id], or a blank one from the list's page.
  Future<Either<AppException, ModcpAnswer<AnnouncementForm>>> _fetch() async {
    if (widget.id > 0) {
      return widget.repository.fetchAnnouncement(widget.id).run();
    }
    final answer = await widget.repository.fetchAnnouncements().run();
    return answer.map(
      (a) => switch (a) {
        ModcpReady(value: AnnouncementList(:final blank?)) => ModcpReady(blank),
        ModcpReady() => const ModcpRefused<AnnouncementForm>(''),
        ModcpNeedsLogin(:final formHash) => ModcpNeedsLogin<AnnouncementForm>(formHash: formHash),
        ModcpRefused(:final message) => ModcpRefused<AnnouncementForm>(message),
      },
    );
  }

  /// Read the form again; what was typed is kept once filled in.
  Future<void> _load() async {
    setState(() => _loading = true);
    final answer = await _fetch();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      _answer = answer;
      if (answer case Right(value: ModcpReady(value: final form)) when !_filled) {
        _fill(form);
      }
    });
  }

  Future<void> _pickDate({required bool start}) async {
    final current = DateTime.tryParse(_normalizedDate(start ? _start : _end)) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) {
      return;
    }
    final text = '${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
    setState(() => start ? _start = text : _end = text);
  }

  /// A date as the forum prints it (`2026-11-1`) in the form [DateTime.tryParse] reads.
  static String _normalizedDate(String date) {
    final parts = date.split('-');
    if (parts.length != 3) {
      return '';
    }
    return [parts[0], parts[1].padLeft(2, '0'), parts[2].padLeft(2, '0')].join('-');
  }

  Future<void> _save(AnnouncementForm form) async {
    if (_subject.text.trim().isEmpty || _message.text.trim().isEmpty) {
      setState(() => _tried = true);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _sending = true);
    final outcome = await widget.repository
        .submitAnnouncement(
          form,
          subject: _subject.text,
          type: _type,
          start: _start,
          end: _end,
          message: _message.text,
          known: widget.known,
        )
        .run();
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    showSnackBar(context: context, message: modcpOutcomeText(context, outcome));
    if (modcpDone(outcome)) {
      Navigator.of(context).pop(true);
    } else if (outcome case Right(value: ModcpWriteSessionEnded())) {
      // Nothing was saved: the password, then the form again (what was typed is kept).
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcp;
    return PopScope(
      canPop: !_sending,
      child: Scaffold(
        appBar: AppBar(title: Text(widget.id > 0 ? tr.editAnnouncement : tr.newAnnouncement)),
        body: ModcpAnswerView<AnnouncementForm>(
          repository: widget.repository,
          loading: _loading,
          answer: _answer,
          onReload: _load,
          builder: (context, form) => AppCenteredList(
            builder: (context, padding, _) => ListView(
              padding: padding.copyWith(top: 12, bottom: 24),
              children: [
                TextField(
                  key: const ValueKey('modcp-announcement-subject'),
                  controller: _subject,
                  enabled: !_sending,
                  onChanged: _tried ? (_) => setState(() {}) : null,
                  decoration: InputDecoration(
                    labelText: tr.subject,
                    errorText: _tried && _subject.text.trim().isEmpty ? tr.required : null,
                  ),
                ),
                const SizedBox(height: 16),
                SegmentedButton<AnnouncementType>(
                  segments: [
                    ButtonSegment(value: AnnouncementType.text, label: Text(tr.typeText)),
                    ButtonSegment(value: AnnouncementType.link, label: Text(tr.typeLink)),
                  ],
                  selected: {_type},
                  onSelectionChanged: _sending ? null : (v) => setState(() => _type = v.first),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: _DateField(
                        key: const ValueKey('modcp-announcement-start'),
                        label: tr.startDate,
                        value: _start,
                        onTap: _sending ? null : () => _pickDate(start: true),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _DateField(
                        key: const ValueKey('modcp-announcement-end'),
                        label: tr.endDate,
                        value: _end.isEmpty ? context.t.moderate.noExpiration : _end,
                        onTap: _sending ? null : () => _pickDate(start: false),
                        onClear: _end.isEmpty || _sending ? null : () => setState(() => _end = ''),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('modcp-announcement-message'),
                  controller: _message,
                  enabled: !_sending,
                  onChanged: _tried ? (_) => setState(() {}) : null,
                  minLines: _type == AnnouncementType.text ? 4 : 1,
                  maxLines: _type == AnnouncementType.text ? 12 : 1,
                  keyboardType: _type == AnnouncementType.link ? TextInputType.url : TextInputType.multiline,
                  decoration: InputDecoration(
                    labelText: _type == AnnouncementType.link ? tr.typeLink : tr.content,
                    errorText: _tried && _message.text.trim().isEmpty ? tr.required : null,
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  key: const ValueKey('modcp-announcement-save'),
                  onPressed: _sending ? null : () => _save(form),
                  child: _sending
                      ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(tr.save),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.value, required this.onTap, this.onClear, super.key});

  final String label;
  final String value;
  final VoidCallback? onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(4),
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: onClear == null ? null : IconButton(icon: const Icon(Icons.clear), onPressed: onClear),
      ),
      child: Text(value),
    ),
  );
}
