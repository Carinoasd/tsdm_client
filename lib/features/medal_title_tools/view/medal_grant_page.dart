import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/medal_title_tools/models/models.dart';
import 'package:tsdm_client/features/medal_title_tools/repository/medal_title_tools_repository.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

const _webUrl = '$baseUrl/plugin.php?id=dsu_medalCenter:memcp&action=grant';

/// The thread id in [text]: a number, or a thread URL (`tid=…` or `thread-…-`).
int? threadIdOf(String text) {
  final v = text.trim();
  final m =
      RegExp(r'[?&]tid=(\d+)').firstMatch(v) ??
      RegExp(r'thread-(\d+)-').firstMatch(v) ??
      RegExp(r'^(\d+)$').firstMatch(v);
  return m == null ? null : int.tryParse(m[1]!);
}

/// Sending medals (`medalgrant` of the app API, medal centre 3.2): members by UID (or the repliers of a thread),
/// medals, an optional reason; a check of who has what before sending, and the sendings with taking them back.
///
/// The check is the website's check page made here; the medal centre checks everything again when the form arrives.
class MedalGrantPage extends StatefulWidget {
  /// Constructor.
  const MedalGrantPage({this.repository, super.key});

  /// Injected for tests; the account's network client otherwise.
  final MedalTitleToolsRepository? repository;

  @override
  State<MedalGrantPage> createState() => _MedalGrantPageState();
}

class _MedalGrantPageState extends State<MedalGrantPage> {
  late final MedalTitleToolsRepository _repo =
      widget.repository ?? MedalTitleToolsRepository.network(getIt.get<NetClientProvider>());
  final _members = TextEditingController();
  final _reason = TextEditingController();
  final _medalSearch = TextEditingController();
  GrantInfo? _info;
  bool _failed = false;
  bool _unsupported = false;
  bool _busy = false;
  int _recordPage = 1;
  final _chosen = <int>[];

  @override
  void initState() {
    super.initState();
    _medalSearch.addListener(() => setState(() {}));
    unawaited(_load());
  }

  @override
  void dispose() {
    _members.dispose();
    _reason.dispose();
    _medalSearch.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final info = await _repo.grant(page: _recordPage);
      if (!mounted) return;
      setState(() {
        _info = info ?? _info;
        _unsupported = info == null;
      });
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _import(GrantInfo info) async {
    final url = info.threadUrl;
    if (url == null) return;
    final tr = context.t.medalTitleTools;
    final tid = TextEditingController();
    final from = TextEditingController();
    final to = TextEditingController();
    var noOwner = true;
    final go = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          scrollable: true,
          title: Text(tr.grantImport),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: tid,
                decoration: InputDecoration(labelText: tr.grantImportTid),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: from,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: tr.grantImportFrom),
                    ),
                  ),
                  sizedBoxW12H12,
                  Expanded(
                    child: TextField(
                      controller: to,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: tr.grantImportTo),
                    ),
                  ),
                ],
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: noOwner,
                title: Text(tr.grantImportNoOwner),
                onChanged: (v) => setLocal(() => noOwner = v ?? true),
              ),
              Text(tr.grantImportHint, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(context.t.general.cancel)),
            FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(tr.grantImportButton)),
          ],
        ),
      ),
    );
    final id = threadIdOf(tid.text);
    final f = int.tryParse(from.text.trim()) ?? 0;
    final t = int.tryParse(to.text.trim()) ?? 0;
    tid.dispose();
    from.dispose();
    to.dispose();
    if (go != true || !mounted) return;
    if (id == null) {
      showSnackBar(context: context, message: tr.grantImportBadTid);
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await _repo.threadRepliers(url, tid: id, from: f, to: t, noOwner: noOwner);
      if (!mounted) return;
      if (r.error != null) {
        showSnackBar(context: context, message: r.error!.isEmpty ? context.t.general.failedToLoad : r.error!);
        return;
      }
      final have = splitUids(_members.text).uids;
      final add = r.uids.where((u) => !have.contains(u)).toList();
      final room = (info.maxUsers - have.length).clamp(0, info.maxUsers);
      final put = add.take(room).toList();
      if (put.isNotEmpty) {
        final base = _members.text.trimRight();
        _members.text = '${base.isEmpty ? '' : '$base\n'}${put.join(', ')}';
      }
      var message = tr.grantImported(subject: r.subject, total: r.total, added: put.length);
      if (r.total > r.uids.length || add.length > put.length) {
        message += '；${tr.grantImportFull(max: info.maxUsers)}';
      }
      showSnackBar(context: context, message: message);
    } on Exception {
      if (mounted) showSnackBar(context: context, message: context.t.general.failedToLoad);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check(GrantInfo info) async {
    final tr = context.t.medalTitleTools;
    final split = splitUids(_members.text);
    final form = info.grantForm;
    final lookupUrl = info.lookupUrl;
    if (form == null || lookupUrl == null) return;
    if (split.uids.isEmpty) {
      showSnackBar(context: context, message: tr.grantNeedMembers);
      return;
    }
    if (_chosen.isEmpty) {
      showSnackBar(context: context, message: tr.grantNeedMedals);
      return;
    }
    if (split.uids.length > info.maxUsers ||
        _chosen.length > info.maxMedals ||
        split.uids.length * _chosen.length > info.maxPairs) {
      showSnackBar(
        context: context,
        message: tr.grantTooMany(users: info.maxUsers, medals: info.maxMedals, pairs: info.maxPairs),
      );
      return;
    }
    setState(() => _busy = true);
    ({List<GrantPerson> users, List<String> missing})? found;
    try {
      found = await _repo.lookup(lookupUrl, split.uids, _chosen);
    } on Exception {
      found = null;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (found == null) {
      showSnackBar(context: context, message: context.t.general.failedToLoad);
      return;
    }
    final users = found.users;
    var give = 0;
    for (final u in users) {
      give += _chosen.where((m) => !u.has.contains(m)).length;
    }
    final skip = users.length * _chosen.length - give;
    final reason = _reason.text.trim();
    final names = {for (final m in info.medals) m.id: m.name};
    final ok = await showToolsConfirm(
      context,
      title: tr.grantConfirmTitle,
      confirm: give > 0 ? tr.grantSend(n: give) : context.t.general.ok,
      content: [
        Text(tr.grantSummary(users: users.length, medals: _chosen.length, give: give, skip: skip)),
        sizedBoxW8H8,
        Text(_chosen.map((m) => '「${names[m] ?? '#$m'}」').join()),
        sizedBoxW8H8,
        Text(users.map((u) => '${u.name}（${u.uid}）').join('、'), style: Theme.of(context).textTheme.bodySmall),
        if (found.missing.isNotEmpty) ...[
          sizedBoxW8H8,
          AppNoticeBanner(
            tone: AppNoticeTone.warning,
            message: tr.grantMissing(list: found.missing.join('、')),
          ),
        ],
        if (split.bad.isNotEmpty) ...[
          sizedBoxW8H8,
          AppNoticeBanner(
            tone: AppNoticeTone.warning,
            message: tr.grantBad(list: split.bad.join('、')),
          ),
        ],
        sizedBoxW8H8,
        Text(reason.isEmpty ? tr.grantNoReason : tr.grantReasonLine(reason: reason)),
        if (give == 0) ...[sizedBoxW8H8, AppNoticeBanner(message: tr.grantNothing)],
      ],
    );
    if (!ok || give == 0 || !mounted) return;
    setState(() => _busy = true);
    await showFormResult(
      context,
      () => _repo.submit(form, {
        'grant_users': users.map((u) => u.uid).join(','),
        'grant_medalids': _chosen.join(','),
        'grant_reason': reason,
      }),
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _recordPage = 1;
    });
    await _load();
  }

  Future<void> _revoke(GrantInfo info, {GrantRow? row, GrantBatch? batch}) async {
    final tr = context.t.medalTitleTools;
    final form = row != null ? info.revokeForm : info.revokeBatchForm;
    if (form == null) return;
    final ok = await showToolsConfirm(
      context,
      title: tr.grantRevokeConfirmTitle,
      confirm: tr.grantRevoke,
      destructive: true,
      content: [
        Text(
          row != null
              ? tr.grantRevokeConfirm(
                  user: row.username.isEmpty ? 'UID ${row.uid}' : row.username,
                  medal: row.medalName,
                )
              : tr.grantRevokeBatchConfirm(n: batch!.canRevoke),
        ),
      ],
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    await showFormResult(
      context,
      () => _repo.submit(form, row != null ? {'logid': '${row.id}'} : {'batch': '${batch!.batch}'}),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  Widget _medalPicker(GrantInfo info, TranslationsMedalTitleToolsEn tr) {
    final k = _medalSearch.text.trim().toLowerCase();
    final hits = info.medals
        .where((m) => k.isEmpty || m.name.toLowerCase().contains(k) || '${m.id}'.startsWith(k))
        .take(30)
        .toList();
    final byId = {for (final m in info.medals) m.id: m};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr.grantMedals(n: _chosen.length), style: Theme.of(context).textTheme.titleSmall),
        sizedBoxW8H8,
        if (_chosen.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final id in _chosen)
                InputChip(
                  avatar: ToolsImage(byId[id]?.imageUrl, width: 16, height: 26),
                  label: Text('${byId[id]?.name ?? '#$id'} #$id'),
                  onDeleted: _busy ? null : () => setState(() => _chosen.remove(id)),
                ),
            ],
          ),
        sizedBoxW8H8,
        TextField(
          controller: _medalSearch,
          decoration: InputDecoration(
            hintText: tr.grantMedalSearch,
            prefixIcon: const Icon(Icons.search),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 280),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final m in hits)
                CheckboxListTile(
                  dense: true,
                  value: _chosen.contains(m.id),
                  secondary: ToolsImage(m.imageUrl, width: 22, height: 36),
                  title: Text(m.name),
                  subtitle: Text('#${m.id} · ${m.days > 0 ? tr.days(n: m.days) : tr.permanent}'),
                  onChanged: _busy
                      ? null
                      : (v) => setState(() {
                          if (v ?? false) {
                            if (_chosen.length < info.maxMedals && !_chosen.contains(m.id)) _chosen.add(m.id);
                          } else {
                            _chosen.remove(m.id);
                          }
                        }),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _batch(GrantInfo info, GrantBatch b, TranslationsMedalTitleToolsEn tr) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final state = b.revoked == 0
        ? null
        : b.revoked >= b.count
        ? tr.grantRevokedAll
        : tr.grantRevokedSome(n: b.revoked);
    return AppSurface(
      key: ValueKey('batch-${b.batch}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                toolsDateTime(b.dateline),
                style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
              ),
              if (info.canRevokeAll && b.opName.isNotEmpty)
                Text(tr.grantSentBy(name: b.opName), style: textTheme.bodySmall),
              Text(
                tr.grantBatchSummary(users: b.users, medals: b.medals, count: b.count),
                style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              if (state != null) Text(state, style: textTheme.labelMedium?.copyWith(color: colorScheme.error)),
            ],
          ),
          if (b.reason.isNotEmpty) ...[sizedBoxW4H4, Text(tr.grantReasonLine(reason: b.reason))],
          if (b.canRevoke > 1)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: _busy ? null : () => _revoke(info, batch: b),
                icon: const Icon(Icons.undo),
                label: Text(tr.grantRevokeBatch(n: b.canRevoke)),
              ),
            ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            initiallyExpanded: b.rows.length <= 5,
            title: Text(tr.grantDetails(n: b.rows.length), style: textTheme.bodyMedium),
            children: [
              for (final r in b.rows)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: ToolsImage(r.imageUrl, width: 22, height: 36),
                  title: Text('${r.username.isEmpty ? 'UID ${r.uid}' : r.username} · ${r.medalName}'),
                  subtitle: Text(
                    r.revoked
                        ? '${tr.grantRevoked} ${r.revokeName} ${r.revokeTime > 0 ? toolsDateTime(r.revokeTime) : ''}'
                        : (r.expiration > 0 ? tr.expiresOn(date: toolsDate(r.expiration)) : tr.permanent),
                  ),
                  trailing: r.canRevoke
                      ? TextButton(
                          onPressed: _busy ? null : () => _revoke(info, row: r),
                          child: Text(tr.grantRevoke),
                        )
                      : Text(r.revoked ? tr.grantRevoked : tr.grantSent),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.medalTitleTools;
    final info = _info;
    final textTheme = Theme.of(context).textTheme;
    final usable = info != null && info.canGrant && info.supported && info.grantForm != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.grantTitle),
        actions: [
          IconButton(
            tooltip: context.t.general.openInBrowser,
            icon: const Icon(Icons.open_in_browser_outlined),
            onPressed: () async => context.dispatchAsUrl(_webUrl, external: true),
          ),
        ],
      ),
      body: !usable
          ? ToolsStateView(
              onRetry: _load,
              failed: _failed,
              message: info == null
                  ? (_unsupported ? tr.unsupported : null)
                  : !info.canGrant
                  ? tr.noPermission
                  : tr.unsupported,
              webUrl: info == null || info.canGrant ? _webUrl : null,
            )
          : ToolsBody(
              onRefresh: _load,
              children: [
                Text(
                  tr.grantLimits(users: info.maxUsers, medals: info.maxMedals, pairs: info.maxPairs),
                  style: textTheme.bodySmall,
                ),
                sizedBoxW12H12,
                AppSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _members,
                        minLines: 3,
                        maxLines: 8,
                        keyboardType: TextInputType.multiline,
                        decoration: InputDecoration(
                          labelText: tr.grantMembers,
                          hintText: tr.grantMembersHint,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      if (info.threadUrl != null)
                        TextButton.icon(
                          onPressed: _busy ? null : () => _import(info),
                          icon: const Icon(Icons.forum_outlined),
                          label: Text(tr.grantImport),
                        ),
                      sizedBoxW12H12,
                      _medalPicker(info, tr),
                      sizedBoxW12H12,
                      TextField(
                        controller: _reason,
                        maxLength: info.maxReason > 0 ? info.maxReason : null,
                        decoration: InputDecoration(
                          labelText: tr.grantReason,
                          helperText: tr.grantReasonHint,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      sizedBoxW8H8,
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: FilledButton.icon(
                          onPressed: _busy ? null : () => _check(info),
                          icon: const Icon(Icons.fact_check_outlined),
                          label: Text(tr.grantNext),
                        ),
                      ),
                    ],
                  ),
                ),
                sizedBoxW16H16,
                Text(
                  info.canRevokeAll ? tr.grantRecordsAll : tr.grantRecords,
                  style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                sizedBoxW4H4,
                Text(info.canRevokeAll ? tr.grantRevokeHintAdmin : tr.grantRevokeHint, style: textTheme.bodySmall),
                sizedBoxW8H8,
                if (info.batches.isEmpty)
                  Text(tr.grantRecordsEmpty)
                else
                  for (final b in info.batches) ...[_batch(info, b, tr), const SizedBox(height: appSurfaceGap)],
                ToolsPager(
                  paging: info.paging,
                  enabled: !_busy,
                  onPage: (n) {
                    _recordPage = n;
                    unawaited(_load());
                  },
                ),
              ],
            ),
    );
  }
}
