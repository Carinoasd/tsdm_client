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

const _webUrl = '$baseUrl/plugin.php?id=tsdmtitle:tsdmtitle&action=issue';

/// Members of a title issue: UIDs or names, one a line or separated by commas (as the title plugin reads them).
List<String> issueMembers(String text) => <String>{
  for (final t in text.split(RegExp(r'[\r\n,，]+')).map((e) => e.trim()))
    if (t.isNotEmpty) t,
}.toList();

/// Issuing titles (`titleissue` of the app API, title plugin 6.2): give titles to members for some days or for good,
/// or take them back, with a note; the latest issues. The title plugin's own form, checked again by the plugin.
class TitleIssuePage extends StatefulWidget {
  /// Constructor.
  const TitleIssuePage({this.repository, super.key});

  /// Injected for tests; the account's network client otherwise.
  final MedalTitleToolsRepository? repository;

  @override
  State<TitleIssuePage> createState() => _TitleIssuePageState();
}

class _TitleIssuePageState extends State<TitleIssuePage> {
  late final MedalTitleToolsRepository _repo =
      widget.repository ?? MedalTitleToolsRepository.network(getIt.get<NetClientProvider>());
  final _members = TextEditingController();
  final _days = TextEditingController(text: '0');
  final _note = TextEditingController();
  final _search = TextEditingController();
  IssueInfo? _info;
  bool _failed = false;
  bool _unsupported = false;
  bool _busy = false;
  bool _grant = true;
  final _chosen = <int>[];

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    unawaited(_load());
  }

  @override
  void dispose() {
    _members.dispose();
    _days.dispose();
    _note.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _failed = false);
    try {
      final info = await _repo.issue();
      if (!mounted) return;
      setState(() {
        _info = info ?? _info;
        _unsupported = info == null;
      });
    } on Exception {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _submit(IssueInfo info) async {
    final tr = context.t.medalTitleTools;
    final form = info.form;
    if (form == null) return;
    final members = issueMembers(_members.text).take(info.maxUsers).toList();
    if (members.isEmpty) {
      showSnackBar(context: context, message: tr.issueNeedMembers);
      return;
    }
    if (_chosen.isEmpty) {
      showSnackBar(context: context, message: tr.issueNeedTitles);
      return;
    }
    final days = (int.tryParse(_days.text.trim()) ?? 0).clamp(0, info.maxDays);
    final op = _grant ? tr.issueGrant : tr.issueRevoke;
    final names = {for (final t in info.titles) t.id: t.name};
    final ok = await showToolsConfirm(
      context,
      title: tr.issueConfirmTitle(op: op),
      confirm: op,
      destructive: !_grant,
      content: [
        Text(
          _grant
              ? tr.issueConfirm(
                  op: op,
                  titles: _chosen.length,
                  users: members.length,
                  duration: days > 0 ? tr.days(n: days) : tr.permanent,
                )
              : tr.issueConfirmRevoke(titles: _chosen.length, users: members.length),
        ),
        sizedBoxW8H8,
        Text(_chosen.map((id) => '「${names[id] ?? '#$id'}」').join()),
        sizedBoxW8H8,
        Text(members.join('、'), style: Theme.of(context).textTheme.bodySmall),
      ],
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    await showFormResult(
      context,
      () => _repo.submit(form, {
        'issueop': _grant ? 'grant' : 'revoke',
        'issuetitles': _chosen.join(','),
        'issueusers': members.join('\n'),
        'issuedays': '$days',
        'issuenote': _note.text.trim(),
      }),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.medalTitleTools;
    final info = _info;
    final textTheme = Theme.of(context).textTheme;
    final usable = info != null && info.canIssue && info.supported && info.form != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr.issueTitle),
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
                  : !info.canIssue && info.supported
                  ? tr.noPermission
                  : tr.unsupported,
              webUrl: _webUrl,
            )
          : ToolsBody(
              onRefresh: _load,
              children: [
                AppSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SegmentedButton<bool>(
                        segments: [
                          ButtonSegment(value: true, label: Text(tr.issueGrant), icon: const Icon(Icons.add)),
                          ButtonSegment(value: false, label: Text(tr.issueRevoke), icon: const Icon(Icons.remove)),
                        ],
                        selected: {_grant},
                        onSelectionChanged: _busy ? null : (v) => setState(() => _grant = v.first),
                      ),
                      sizedBoxW12H12,
                      TextField(
                        controller: _members,
                        minLines: 3,
                        maxLines: 8,
                        decoration: InputDecoration(
                          labelText: tr.issueMembers,
                          hintText: tr.issueMembersHint(n: info.maxUsers),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      sizedBoxW12H12,
                      Text(
                        tr.issueTitles(n: _chosen.length, max: info.maxTitles),
                        style: textTheme.titleSmall,
                      ),
                      sizedBoxW8H8,
                      if (_chosen.isNotEmpty)
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final id in _chosen)
                              InputChip(
                                label: Text(
                                  '${info.titles.where((t) => t.id == id).firstOrNull?.name ?? '#$id'} #$id',
                                ),
                                onDeleted: _busy ? null : () => setState(() => _chosen.remove(id)),
                              ),
                          ],
                        ),
                      sizedBoxW8H8,
                      TextField(
                        controller: _search,
                        decoration: InputDecoration(
                          hintText: tr.search,
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
                            for (final t
                                in info.titles
                                    .where((t) {
                                      final k = _search.text.trim().toLowerCase();
                                      return k.isEmpty || t.name.toLowerCase().contains(k) || '${t.id}'.startsWith(k);
                                    })
                                    .take(30))
                              CheckboxListTile(
                                dense: true,
                                value: _chosen.contains(t.id),
                                secondary: ToolsImage(t.imageUrl, width: 74, height: 40),
                                title: Text(t.name),
                                subtitle: Text('#${t.id}${t.enabled ? '' : ' · ${tr.issueDisabled}'}'),
                                onChanged: _busy
                                    ? null
                                    : (v) => setState(() {
                                        if (v ?? false) {
                                          if (_chosen.length < info.maxTitles && !_chosen.contains(t.id)) {
                                            _chosen.add(t.id);
                                          }
                                        } else {
                                          _chosen.remove(t.id);
                                        }
                                      }),
                              ),
                          ],
                        ),
                      ),
                      sizedBoxW12H12,
                      if (_grant) ...[
                        TextField(
                          controller: _days,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: tr.issueDays, border: const OutlineInputBorder()),
                        ),
                        sizedBoxW12H12,
                      ],
                      TextField(
                        controller: _note,
                        maxLength: info.maxNote > 0 ? info.maxNote : null,
                        decoration: InputDecoration(labelText: tr.issueNote, border: const OutlineInputBorder()),
                      ),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: FilledButton(
                          onPressed: _busy ? null : () => _submit(info),
                          child: Text(_grant ? tr.issueGrant : tr.issueRevoke),
                        ),
                      ),
                    ],
                  ),
                ),
                sizedBoxW16H16,
                Text(tr.issueRecords, style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                sizedBoxW8H8,
                if (info.logs.isEmpty)
                  Text(tr.issueRecordsEmpty)
                else
                  AppSurface(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final l in info.logs)
                          ListTile(
                            dense: true,
                            title: Text('${l.grant ? tr.issueGrant : tr.issueRevoke} · ${l.title}'),
                            subtitle: Text(
                              [
                                tr.issueLogLine(by: l.by, to: l.to.isEmpty ? 'UID ${l.toUid}' : l.to),
                                toolsDateTime(l.dateline),
                                if (l.grant) l.days > 0 ? tr.days(n: l.days) : tr.permanent,
                                if (l.note.isNotEmpty) l.note,
                              ].join(' · '),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}
