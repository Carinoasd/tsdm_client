import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Either, Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/member_ban.dart';
import 'package:tsdm_client/features/moderate/models/modcp_members.dart';
import 'package:tsdm_client/features/moderate/models/modcp_panel.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/member_ban_dialog.dart';
import 'package:tsdm_client/features/moderate/widgets/modcp_widgets.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// The members of the panel: look one up by name or UID, ban or lift the ban, edit the profile, and the banned IPs;
/// each only when the panel's menu offers it to the account.
class ModcpMembersPage extends StatefulWidget {
  /// Constructor.
  const ModcpMembersPage({required this.repository, super.key});

  /// The panel.
  final ModcpRepository repository;

  @override
  State<ModcpMembersPage> createState() => _ModcpMembersPageState();
}

class _ModcpMembersPageState extends State<ModcpMembersPage> {
  bool _loading = true;
  Either<AppException, ModcpAnswer<ModcpMenu>>? _menu;

  final _query = TextEditingController();
  bool _byUid = false;

  /// The last query asked, asked again after a change.
  ModcpMemberQuery? _asked;
  bool _searching = false;
  Either<AppException, ModcpAnswer<ModcpMemberLookup>>? _found;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMenu());
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadMenu() async {
    setState(() => _loading = true);
    final menu = await widget.repository.fetchMenu(loggedIn: true).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      _menu = menu;
    });
  }

  ModcpMenu? get _ready => switch (_menu) {
    Right(value: ModcpReady(:final value)) => value,
    _ => null,
  };

  Future<void> _search() async {
    final text = _query.text.trim();
    final menu = _ready;
    if (text.isEmpty || menu == null || _searching) {
      return;
    }
    final uid = int.tryParse(text) ?? 0;
    if (_byUid && uid <= 0) {
      return;
    }
    await _lookup(_byUid ? ModcpMemberQuery.uid(uid) : ModcpMemberQuery.name(text), menu);
  }

  Future<void> _lookup(ModcpMemberQuery query, ModcpMenu menu) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _asked = query;
      _searching = true;
    });
    final found = await widget.repository.lookupMember(query, edit: !menu.canBanMember).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _searching = false;
      _found = found;
    });
  }

  Future<void> _reload() async {
    final query = _asked;
    final menu = _ready;
    if (query != null && menu != null) {
      await _lookup(query, menu);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcp;
    final menu = _ready;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.members),
        actions: [
          if (menu?.canBanIp ?? false)
            IconButton(
              key: const ValueKey('modcp-ipban'),
              tooltip: tr.ipBan,
              icon: const Icon(Icons.public_off_outlined),
              onPressed: () => unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => IpBanPage(repository: widget.repository)),
                ),
              ),
            ),
        ],
      ),
      body: ModcpAnswerView<ModcpMenu>(
        repository: widget.repository,
        loading: _loading,
        answer: _menu,
        onReload: _loadMenu,
        builder: _body,
      ),
    );
  }

  Widget _body(BuildContext context, ModcpMenu menu) {
    final tr = context.t.modcp;
    if (!menu.canBanMember && !menu.canEditMember) {
      return AppStateView(icon: Icons.person_off_outlined, message: context.t.general.noPermission);
    }
    return AppCenteredList(
      builder: (context, padding, _) => ListView(
        padding: padding.copyWith(top: 12, bottom: 24),
        children: [
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, label: Text(tr.byName)),
              ButtonSegment(value: true, label: Text(tr.byUid)),
            ],
            selected: {_byUid},
            onSelectionChanged: (v) => setState(() => _byUid = v.first),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('modcp-member-query'),
            controller: _query,
            keyboardType: _byUid ? TextInputType.number : TextInputType.text,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              labelText: _byUid ? tr.byUid : tr.byName,
              suffixIcon: IconButton(
                key: const ValueKey('modcp-member-search'),
                tooltip: tr.search,
                icon: const Icon(Icons.search),
                onPressed: _searching ? null : _search,
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (_searching)
            const Center(
              child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()),
            )
          else if (_found case final found?)
            _result(context, menu, found),
        ],
      ),
    );
  }

  Widget _result(BuildContext context, ModcpMenu menu, Either<AppException, ModcpAnswer<ModcpMemberLookup>> found) {
    final theme = Theme.of(context);
    switch (found) {
      case Right(value: ModcpNeedsLogin()):
        // The panel's session ended since the menu was read.
        return Center(
          child: TextButton(onPressed: _loadMenu, child: Text(context.t.moderate.panelLogin)),
        );
      case Right(value: ModcpReady(value: ModcpMemberLookup(:final member?))):
        return _MemberCard(
          member: member,
          canEdit: menu.canEditMember,
          repository: widget.repository,
          onChanged: _reload,
        );
      case Right(value: ModcpReady(value: ModcpMemberLookup(:final edit?))):
        return AppSurface(
          child: ListTile(
            key: ValueKey('modcp-member-${edit.memberUid}'),
            title: Text(edit.username),
            subtitle: Text('UID ${edit.memberUid}'),
            trailing: TextButton(
              key: const ValueKey('modcp-member-edit'),
              onPressed: () => _openEdit(edit.memberUid),
              child: Text(context.t.modcp.editMember),
            ),
          ),
        );
      case Right(value: ModcpReady(value: ModcpMemberLookup(:final note))) when note.isNotEmpty:
        return Text(
          note,
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.error),
        );
      case Right(value: ModcpRefused(:final message)) when message.isNotEmpty:
        return Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.error),
        );
      case Left(value: IdentityChangedException()):
        return Text(context.t.general.accountChangedRetry, textAlign: TextAlign.center);
      default:
        return Text(context.t.general.failedToLoad, textAlign: TextAlign.center);
    }
  }

  Future<void> _openEdit(int memberUid) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MemberEditPage(memberUid: memberUid, repository: widget.repository),
      ),
    );
    if (saved ?? false) {
      await _reload();
    }
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({required this.member, required this.canEdit, required this.repository, required this.onChanged});

  final ModcpMember member;
  final bool canEdit;
  final ModcpRepository repository;
  final Future<void> Function() onChanged;

  Future<void> _change(BuildContext context, ModcpBanChoice choice) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _BanDialog(member: member, choice: choice, repository: repository),
    );
    if (done ?? false) {
      await onChanged();
    }
  }

  Future<void> _edit(BuildContext context) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MemberEditPage(memberUid: member.memberUid, repository: repository),
      ),
    );
    if (saved ?? false) {
      await onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tr = context.t.modcp;
    return Column(
      key: ValueKey('modcp-member-${member.memberUid}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSurface(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(member.username, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                modcpMutedLine(context, ['UID ${member.memberUid}', member.status]),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final choice in member.choices)
                      FilledButton.tonalIcon(
                        key: ValueKey('modcp-ban-${choice.value}'),
                        onPressed: () => _change(context, choice),
                        icon: Icon(memberBanIcon(undo: !choice.isBan)),
                        label: Text(choice.isBan ? choice.label : tr.lift),
                      ),
                    if (canEdit)
                      OutlinedButton.icon(
                        key: const ValueKey('modcp-member-edit'),
                        onPressed: () => _edit(context),
                        icon: const Icon(Icons.edit_outlined),
                        label: Text(tr.editMember),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (member.crimes.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
            child: Text(tr.crimes, style: theme.textTheme.titleSmall),
          ),
          AppSurface(
            child: Column(
              children: [
                for (final crime in member.crimes)
                  ListTile(
                    title: Text(crime.reason.isNotEmpty ? crime.reason : crime.action),
                    subtitle: Text(
                      [if (crime.reason.isNotEmpty) crime.action, crime.time, crime.operator].join(' · '),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Change the member to [choice]: the days of a ban and the reason, sent once. Pops true once the forum carried it out.
class _BanDialog extends StatefulWidget {
  const _BanDialog({required this.member, required this.choice, required this.repository});

  final ModcpMember member;
  final ModcpBanChoice choice;
  final ModcpRepository repository;

  @override
  State<_BanDialog> createState() => _BanDialogState();
}

class _BanDialogState extends State<_BanDialog> {
  int? _days = memberBanDays.first;
  final _reason = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    final outcome = await widget.repository
        .submitMemberBan(widget.member, widget.choice, days: _days, reason: _reason.text)
        .run();
    if (!mounted) {
      return;
    }
    if (modcpDone(outcome)) {
      showSnackBar(context: context, message: modcpOutcomeText(context, outcome));
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _sending = false;
      _error = modcpOutcomeText(context, outcome);
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.moderate;
    final choice = widget.choice;
    return PopScope(
      canPop: !_sending,
      child: CustomAlertDialog.sync(
        title: AppDialogTitle(
          icon: memberBanIcon(undo: !choice.isBan),
          title: choice.isBan ? choice.label : context.t.modcp.lift,
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (choice.isBan) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final days in memberBanDays)
                      ChoiceChip(
                        label: Text(days == null ? tr.noExpiration : tr.banDays(days: days)),
                        selected: _days == days,
                        onSelected: _sending ? null : (_) => setState(() => _days = days),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const ValueKey('modcp-ban-reason'),
                controller: _reason,
                enabled: !_sending,
                minLines: 1,
                maxLines: 3,
                decoration: InputDecoration(labelText: tr.reason),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SelectableText(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _sending ? null : () => Navigator.of(context).pop(false),
            child: Text(context.t.general.cancel),
          ),
          TextButton(
            key: const ValueKey('modcp-ban-confirm'),
            onPressed: _sending ? null : _send,
            child: _sending
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(context.t.general.ok),
          ),
        ],
      ),
    );
  }
}

/// The panel's 编辑用户 window of member [memberUid]: the self-introduction, the signature, clearing the avatar. Pops
/// true once saved.
class MemberEditPage extends StatefulWidget {
  /// Constructor.
  const MemberEditPage({required this.memberUid, required this.repository, super.key});

  /// The member.
  final int memberUid;

  /// The panel.
  final ModcpRepository repository;

  @override
  State<MemberEditPage> createState() => _MemberEditPageState();
}

class _MemberEditPageState extends State<MemberEditPage> {
  bool _loading = true;
  Either<AppException, ModcpAnswer<MemberEditForm>>? _answer;
  final _bio = TextEditingController();
  final _signature = TextEditingController();
  bool _clearAvatar = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _bio.dispose();
    _signature.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final found = await widget.repository.lookupMember(ModcpMemberQuery.uid(widget.memberUid), edit: true).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      _answer = switch (found) {
        Right(value: ModcpReady(value: ModcpMemberLookup(:final edit?))) when edit.memberUid == widget.memberUid =>
          Right(ModcpReady(edit)),
        Right(value: ModcpReady(value: ModcpMemberLookup(:final note))) => Right(ModcpRefused(note)),
        Right(value: ModcpNeedsLogin(:final formHash)) => Right(ModcpNeedsLogin(formHash: formHash)),
        Right(value: ModcpRefused(:final message)) => Right(ModcpRefused(message)),
        Left(:final value) => Left(value),
      };
      if (_answer case Right(value: ModcpReady(value: final form))) {
        _bio.text = form.bio;
        _signature.text = form.signature;
        _clearAvatar = false;
      }
    });
  }

  Future<void> _save(MemberEditForm form) async {
    setState(() => _sending = true);
    final outcome = await widget.repository
        .submitMemberEdit(form, bio: _bio.text, signature: _signature.text, clearAvatar: _clearAvatar)
        .run();
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    showSnackBar(context: context, message: modcpOutcomeText(context, outcome));
    if (modcpDone(outcome)) {
      Navigator.of(context).pop(true);
    } else if (outcome case Right(value: ModcpWriteSessionEnded())) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcp;
    return PopScope(
      canPop: !_sending,
      child: Scaffold(
        appBar: AppBar(title: Text(tr.editMember)),
        body: ModcpAnswerView<MemberEditForm>(
          repository: widget.repository,
          loading: _loading,
          answer: _answer,
          onReload: _load,
          builder: (context, form) => AppCenteredList(
            builder: (context, padding, _) => ListView(
              padding: padding.copyWith(top: 12, bottom: 24),
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(form.username),
                  subtitle: Text('UID ${form.memberUid}'),
                ),
                const SizedBox(height: 8),
                TextField(
                  key: const ValueKey('modcp-edit-bio'),
                  controller: _bio,
                  enabled: !_sending,
                  minLines: 2,
                  maxLines: 8,
                  decoration: InputDecoration(labelText: tr.bio, border: const OutlineInputBorder()),
                ),
                const SizedBox(height: 16),
                TextField(
                  key: const ValueKey('modcp-edit-signature'),
                  controller: _signature,
                  enabled: !_sending,
                  minLines: 2,
                  maxLines: 8,
                  decoration: InputDecoration(labelText: tr.signature, border: const OutlineInputBorder()),
                ),
                CheckboxListTile(
                  key: const ValueKey('modcp-edit-clear-avatar'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _clearAvatar,
                  onChanged: _sending ? null : (v) => setState(() => _clearAvatar = v ?? false),
                  title: Text(tr.clearAvatar),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  key: const ValueKey('modcp-edit-save'),
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

/// The panel's 禁止 IP page: the banned IPs, adding one, deleting those the account may.
class IpBanPage extends StatefulWidget {
  /// Constructor.
  const IpBanPage({required this.repository, super.key});

  /// The panel.
  final ModcpRepository repository;

  @override
  State<IpBanPage> createState() => _IpBanPageState();
}

class _IpBanPageState extends State<IpBanPage> {
  bool _loading = true;
  bool _sending = false;
  Either<AppException, ModcpAnswer<IpBanList>>? _answer;
  final _picked = <String>{};

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final answer = await widget.repository.fetchIpBans().run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      _answer = answer;
      _picked.clear();
    });
  }

  IpBanList? get _list => switch (_answer) {
    Right(value: ModcpReady(:final value)) => value,
    _ => null,
  };

  Future<void> _report(Either<AppException, ModcpWriteOutcome> outcome) async {
    showSnackBar(context: context, message: modcpOutcomeText(context, outcome));
    await _load();
  }

  Future<void> _add() async {
    final list = _list;
    if (list == null || _sending) {
      return;
    }
    final asked = await showDialog<(String, int)>(context: context, builder: (_) => const _IpBanAddDialog());
    if (asked == null || !mounted) {
      return;
    }
    setState(() => _sending = true);
    final outcome = await widget.repository.addIpBan(list, asked.$1, asked.$2).run();
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    await _report(outcome);
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
    final outcome = await widget.repository.deleteIpBans(list, _picked.toList()).run();
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    await _report(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcp;
    return Scaffold(
      appBar: AppBar(title: Text(tr.ipBan)),
      floatingActionButton: _list == null
          ? null
          : FloatingActionButton(
              key: const ValueKey('modcp-ipban-add'),
              tooltip: tr.add,
              onPressed: _sending ? null : _add,
              child: const Icon(Icons.add),
            ),
      body: ModcpAnswerView<IpBanList>(
        repository: widget.repository,
        loading: _loading,
        answer: _answer,
        onReload: _load,
        builder: (context, list) {
          if (list.entries.isEmpty) {
            return RefreshIndicator(
              onRefresh: _load,
              child: AppScrollableStateView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: AppStateView(icon: Icons.public_outlined, message: tr.ipBanEmpty, scrollable: false),
              ),
            );
          }
          final deletable = list.entries.where((e) => e.deletable).map((e) => e.id).toSet();
          final allPicked = deletable.isNotEmpty && deletable.every(_picked.contains);
          return Column(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: AppCenteredList(
                    builder: (context, padding, _) => ListView.separated(
                      padding: padding.copyWith(top: 8, bottom: 88),
                      itemCount: list.entries.length,
                      separatorBuilder: (_, _) => appListSeparator,
                      itemBuilder: (context, index) {
                        final entry = list.entries[index];
                        return ModcpPickCard(
                          key: ValueKey('modcp-ipban-${entry.id}'),
                          picked: _picked.contains(entry.id),
                          onChanged: !entry.deletable || _sending
                              ? null
                              : (v) => setState(() => v ? _picked.add(entry.id) : _picked.remove(entry.id)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(entry.ip, style: Theme.of(context).textTheme.titleSmall),
                              const SizedBox(height: 4),
                              modcpMutedLine(context, [entry.location, entry.admin, '${entry.start} – ${entry.end}']),
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
                      key: const ValueKey('modcp-ipban-delete'),
                      onPressed: _picked.isEmpty || _sending ? null : _delete,
                      style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
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

class _IpBanAddDialog extends StatefulWidget {
  const _IpBanAddDialog();

  @override
  State<_IpBanAddDialog> createState() => _IpBanAddDialogState();
}

class _IpBanAddDialogState extends State<_IpBanAddDialog> {
  final _ip = TextEditingController();
  int _days = ipBanDays[2];

  @override
  void dispose() {
    _ip.dispose();
    super.dispose();
  }

  void _ok() {
    final ip = _ip.text.trim();
    if (ip.isNotEmpty) {
      Navigator.of(context).pop((ip, _days));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.modcp;
    return CustomAlertDialog.sync(
      title: AppDialogTitle(icon: Icons.public_off_outlined, title: tr.ipBan),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const ValueKey('modcp-ipban-ip'),
            controller: _ip,
            autofocus: true,
            autocorrect: false,
            keyboardType: TextInputType.url,
            onSubmitted: (_) => _ok(),
            decoration: InputDecoration(labelText: tr.ip),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final days in ipBanDays)
                ChoiceChip(
                  label: Text(context.t.moderate.banDays(days: days)),
                  selected: _days == days,
                  onSelected: (_) => setState(() => _days = days),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.t.general.cancel)),
        TextButton(key: const ValueKey('modcp-ipban-confirm'), onPressed: _ok, child: Text(context.t.general.ok)),
      ],
    );
  }
}
