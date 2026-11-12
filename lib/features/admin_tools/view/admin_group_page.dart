import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/admin_tools/widgets/admin_widgets.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Changing one member's user groups (`admingroup` of the app API, plugin 3.9.0): the main group, the related admin
/// level, the expiry and the group after it, the extended groups and their expiries, a reason and whether to notify.
///
/// The forum replaces the whole state with the form, so the form starts from the member's groups now and the
/// confirmation lists what was changed.
class AdminGroupPage extends StatefulWidget {
  /// Constructor.
  const AdminGroupPage({this.repository, this.initialMember, this.writable, super.key});

  /// Injected for tests; the app's client otherwise.
  final AdminRepository? repository;

  /// The member the page starts with (a UID from a profile).
  final String? initialMember;

  /// Whether the account may post it; asked of the kept access when null.
  final bool? writable;

  @override
  State<AdminGroupPage> createState() => _AdminGroupPageState();
}

class _AdminGroupPageState extends State<AdminGroupPage> with AdminSessionLease {
  @override
  late final AdminRepository adminRepository = widget.repository ?? AdminRepository.network();

  late final _target = TextEditingController(text: widget.initialMember ?? '');
  final _reason = TextEditingController();
  bool _notify = false;
  AdminGroupInfo? _info;
  AdminGroupDraft? _initial;
  AdminGroupDraft? _draft;
  AdminReply? _failure;
  bool _loading = false;
  bool _sending = false;

  /// Known writable (`write` 1): the submit button is shown only then.
  bool _writable = false;
  String? _opId;

  /// Answers read: the form is built anew for each, so no field keeps the member read before.
  int _loads = 0;

  @override
  void initState() {
    super.initState();
    onAdminTextChanged(_reason, () => _opId = null);
    _reason.addListener(() => setState(() {}));
    unawaited(_loadWritable());
    if (_target.text.trim().isNotEmpty) unawaited(_load());
  }

  @override
  void dispose() {
    _target.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _loadWritable() async {
    if (widget.writable case final w?) {
      _writable = w;
      return;
    }
    final access = await AdminAccessCache.check(adminRepository.currentUid, repository: adminRepository);
    if (mounted && access != null) setState(() => _writable = access.canWrite(AdminActions.group));
  }

  Future<void> _load() async {
    final target = _target.text.trim();
    if (target.isEmpty) return;
    setState(() {
      _loading = true;
      _failure = null;
    });
    final reply = await adminRepository.request(AdminActions.group, query: adminTargetQuery(target), reauth: reauth);
    if (!mounted) return;
    final info = AdminGroupInfo.fromJson(reply.json);
    setState(() {
      _loading = false;
      _opId = null;
      _loads++;
      _info = info;
      _failure = info == null ? reply : null;
      _initial = info == null ? null : AdminGroupDraft.of(info);
      _draft = _initial;
    });
  }

  void _edit(AdminGroupDraft draft) => setState(() {
    _draft = draft;
    _opId = null;
  });

  String _groupTitle(AdminGroupInfo info, int groupId, {List<AdminGroupOption>? from}) {
    if (groupId == 0) return context.t.adminTools.ordinaryMember;
    final title = [
      ...?from,
      ...info.groups,
      ...info.extGroups,
      ...info.expGroups,
    ].where((g) => g.groupId == groupId).firstOrNull?.title;
    return title == null ? '#$groupId' : context.displayText(title);
  }

  String _date(String date) => date.isEmpty ? context.t.adminTools.permanent : date;

  Future<String?> _pickDate(String current) async {
    final now = DateTime.now();
    final first = DateTime(now.year, now.month, now.day + 1);
    final parsed = DateTime.tryParse(current);
    final picked = await showDatePicker(
      context: context,
      firstDate: first,
      lastDate: DateTime(now.year + 20),
      initialDate: parsed != null && !parsed.isBefore(first) ? parsed : first,
    );
    if (picked == null) return null;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${picked.year}-${two(picked.month)}-${two(picked.day)}';
  }

  List<String> _changeLines(AdminGroupInfo info, AdminGroupDraft a, AdminGroupDraft b) {
    final tr = context.t.adminTools;
    final general = context.t.general;
    String line(String label, String value) => general.labelValue(label: label, value: value);
    String exp(AdminGroupDraft d) => d.expiry.isEmpty
        ? tr.permanent
        : '${d.expiry} → ${_groupTitle(info, d.expGroupId, from: info.expGroups)}'
              '${d.expAdminId > 0 ? ' (${adminLevelLabel(context, d.expAdminId)})' : ''}';
    String ext(AdminGroupDraft d) => d.extGroupIds.isEmpty
        ? tr.none
        : d.extGroupIds
              .map(
                (g) => [
                  _groupTitle(info, g, from: info.extGroups),
                  if ((d.extExpiry[g] ?? '').isNotEmpty) d.extExpiry[g],
                ].join(' '),
              )
              .join(general.listSeparator);
    String extExp(AdminGroupDraft d) => d.extGroupIds
        .map((g) => '${_groupTitle(info, g, from: info.extGroups)} ${_date(d.extExpiry[g] ?? '')}')
        .join(general.listSeparator);
    return [
      for (final f in adminGroupChanges(a, b))
        switch (f) {
          AdminGroupField.group => line(
            tr.mainGroup,
            '${_groupTitle(info, a.groupId)} → ${_groupTitle(info, b.groupId)}',
          ),
          AdminGroupField.adminId => line(
            tr.adminLevel,
            '${adminLevelLabel(context, a.adminId)} → ${adminLevelLabel(context, b.adminId)}',
          ),
          AdminGroupField.expiry => line(tr.expiry, '${exp(a)} → ${exp(b)}'),
          AdminGroupField.extGroups => line(tr.extGroups, '${ext(a)} → ${ext(b)}'),
          AdminGroupField.extExpiry => line(tr.extGroups, extExp(b)),
        },
    ];
  }

  Future<void> _submit(AdminGroupInfo info, AdminGroupDraft initial, AdminGroupDraft draft) async {
    final tr = context.t.adminTools;
    final lines = _changeLines(info, initial, draft);
    final reason = _reason.text.trim();
    if (lines.isEmpty) {
      showSnackBar(context: context, message: tr.noChanges);
      return;
    }
    if (info.reasonRequired && reason.isEmpty) {
      showSnackBar(context: context, message: tr.reasonNeeded);
      return;
    }
    if (!adminExtGroupsFit(draft.extGroupIds, info.maxExtLength)) {
      showSnackBar(context: context, message: tr.extGroupsTooMany);
      return;
    }
    final ok = await showToolsConfirm(
      context,
      title: tr.group,
      confirm: tr.confirm,
      destructive: true,
      content: [
        Text('${info.member.member.username} (${tr.uid(uid: info.member.member.uid)})'),
        sizedBoxW8H8,
        Text(lines.join('\n')),
        if (reason.isNotEmpty) ...[sizedBoxW8H8, Text(reason)],
      ],
    );
    if (!ok || !mounted) return;
    setState(() => _sending = true);
    final opId = _opId ??= newAdminOpId();
    final reply = await adminRepository.request(
      AdminActions.group,
      form: {
        ...adminGroupForm(uid: info.member.member.uid, info: info, draft: draft, reason: reason, notify: _notify),
        'opid': opId,
      },
      reauth: reauth,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (reply.ok && reply.json?['op'] == 'group') {
      _opId = null;
      _reason.clear();
      showSnackBar(context: context, message: tr.done);
      await _load();
      return;
    }
    final again = reply.json == null || reply.error == 'busy' || reply.error == 'admin_login';
    if (!again) _opId = null;
    showSnackBar(context: context, message: adminErrorText(context, reply));
    if (reply.error == 'duplicate') await _load();
  }

  Widget _form(AdminGroupInfo info, AdminGroupDraft initial, AdminGroupDraft draft) {
    final tr = context.t.adminTools;
    final enabled = !_sending && _writable;
    final selected = info.groupOf(draft.groupId);
    final expType = info.groupOf(draft.expGroupId)?.type;
    final reasonGiven = _reason.text.trim().isNotEmpty;
    final dropdownBorder = InputDecoration(border: const OutlineInputBorder(), labelText: tr.mainGroup);
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<int>(
            key: const ValueKey('admin-group-main'),
            initialValue: info.groups.any((g) => g.groupId == draft.groupId) ? draft.groupId : null,
            isExpanded: true,
            decoration: dropdownBorder,
            items: [
              for (final g in info.groups)
                DropdownMenuItem(
                  value: g.groupId,
                  enabled: g.allowed,
                  child: Text(
                    context.displayText(g.title),
                    style: g.allowed ? null : TextStyle(color: Theme.of(context).disabledColor),
                  ),
                ),
            ],
            onChanged: enabled ? (v) => _edit(draft.copyWith(groupId: v, adminId: 0)) : null,
          ),
          if (selected?.relatedAdmin ?? false) ...[
            sizedBoxW12H12,
            DropdownButtonFormField<int>(
              key: const ValueKey('admin-group-adminid'),
              initialValue: info.adminIds.contains(draft.adminId) ? draft.adminId : 0,
              decoration: InputDecoration(border: const OutlineInputBorder(), labelText: tr.adminLevel),
              items: [
                for (final a in {0, ...info.adminIds})
                  DropdownMenuItem(value: a, child: Text(adminLevelLabel(context, a))),
              ],
              onChanged: enabled ? (v) => _edit(draft.copyWith(adminId: v ?? 0)) : null,
            ),
          ],
          sizedBoxW12H12,
          InputDecorator(
            decoration: InputDecoration(border: const OutlineInputBorder(), labelText: tr.expiry),
            child: Row(
              children: [
                Expanded(child: Text(_date(draft.expiry), key: const ValueKey('admin-group-expiry'))),
                IconButton(
                  icon: const Icon(Icons.event_outlined),
                  onPressed: enabled
                      ? () async {
                          final d = await _pickDate(draft.expiry);
                          if (d != null && mounted) _edit(draft.copyWith(expiry: d));
                        }
                      : null,
                ),
                if (draft.expiry.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: enabled ? () => _edit(draft.copyWith(expiry: '', expGroupId: 0, expAdminId: 0)) : null,
                  ),
              ],
            ),
          ),
          if (draft.expiry.isNotEmpty) ...[
            sizedBoxW12H12,
            DropdownButtonFormField<int>(
              key: const ValueKey('admin-group-expgroup'),
              initialValue: info.expGroups.any((g) => g.groupId == draft.expGroupId) ? draft.expGroupId : null,
              isExpanded: true,
              decoration: InputDecoration(border: const OutlineInputBorder(), labelText: tr.expGroup),
              items: [
                for (final g in info.expGroups)
                  DropdownMenuItem(
                    value: g.groupId,
                    enabled: g.groupId != draft.groupId,
                    child: Text(g.groupId == 0 ? tr.ordinaryMember : context.displayText(g.title)),
                  ),
              ],
              onChanged: enabled ? (v) => _edit(draft.copyWith(expGroupId: v ?? 0, expAdminId: 0)) : null,
            ),
            if (draft.expGroupId == 0 || expType == 'member') ...[
              sizedBoxW12H12,
              DropdownButtonFormField<int>(
                key: const ValueKey('admin-group-expadmin'),
                initialValue: info.adminIds.contains(draft.expAdminId) ? draft.expAdminId : 0,
                decoration: InputDecoration(border: const OutlineInputBorder(), labelText: tr.expAdmin),
                items: [
                  for (final a in {0, ...info.adminIds})
                    DropdownMenuItem(value: a, child: Text(adminLevelLabel(context, a))),
                ],
                onChanged: enabled ? (v) => _edit(draft.copyWith(expAdminId: v ?? 0)) : null,
              ),
            ],
          ],
          sizedBoxW12H12,
          Text(tr.extGroups, style: Theme.of(context).textTheme.titleSmall),
          for (final g in info.extGroups)
            CheckboxListTile(
              key: ValueKey('admin-group-ext-${g.groupId}'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: draft.extGroupIds.contains(g.groupId),
              title: Text(context.displayText(g.title)),
              secondary: draft.extGroupIds.contains(g.groupId)
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: enabled && g.allowed
                              ? () async {
                                  final d = await _pickDate(draft.extExpiry[g.groupId] ?? '');
                                  if (d != null && mounted) {
                                    _edit(draft.copyWith(extExpiry: {...draft.extExpiry, g.groupId: d}));
                                  }
                                }
                              : null,
                          child: Text(_date(draft.extExpiry[g.groupId] ?? '')),
                        ),
                        if ((draft.extExpiry[g.groupId] ?? '').isNotEmpty)
                          IconButton(
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: enabled && g.allowed
                                ? () => _edit(draft.copyWith(extExpiry: {...draft.extExpiry}..remove(g.groupId)))
                                : null,
                          ),
                      ],
                    )
                  : null,
              onChanged: enabled && g.allowed
                  ? (v) => _edit(
                      draft.copyWith(
                        extGroupIds: v ?? false
                            ? [...draft.extGroupIds, g.groupId]
                            : draft.extGroupIds.where((e) => e != g.groupId).toList(),
                        extExpiry: v ?? false ? draft.extExpiry : ({...draft.extExpiry}..remove(g.groupId)),
                      ),
                    )
                  : null,
            ),
          sizedBoxW12H12,
          TextField(
            key: const ValueKey('admin-group-reason'),
            controller: _reason,
            enabled: enabled,
            maxLength: info.maxReason,
            decoration: InputDecoration(labelText: tr.reason, border: const OutlineInputBorder()),
          ),
          SwitchListTile(
            key: const ValueKey('admin-group-notify'),
            contentPadding: EdgeInsets.zero,
            title: Text(tr.notify),
            // The forum notifies only with a reason.
            value: _notify && reasonGiven,
            onChanged: enabled && reasonGiven
                ? (v) => setState(() {
                    _notify = v;
                    _opId = null;
                  })
                : null,
          ),
          if (_writable)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton(
                key: const ValueKey('admin-group-submit'),
                onPressed: _sending || _loading ? null : () => _submit(info, initial, draft),
                child: Text(tr.submit),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.adminTools;
    final info = _info;
    final initial = _initial;
    final draft = _draft;
    return Scaffold(
      appBar: AppBar(title: Text(tr.group)),
      body: ToolsBody(
        children: [
          AppSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AdminTargetField(
                  controller: _target,
                  label: tr.member,
                  enabled: !_sending && !_loading,
                  onLookup: () => unawaited(_load()),
                ),
                if (_loading) const LinearProgressIndicator(),
                if (info != null)
                  AdminMemberTile(
                    member: info.member.member,
                    extra: [
                      tr.credits(n: info.member.credits),
                      if (info.member.expiryTime > 0) tr.until(date: adminPadDate(info.member.expiryDate)),
                    ].join(' · '),
                  ),
              ],
            ),
          ),
          sizedBoxW12H12,
          if (_failure case final failure?)
            AppStateView(
              icon: Icons.error_outline,
              error: true,
              scrollable: false,
              message: adminErrorText(context, failure),
            )
          else if (info != null && !info.can)
            AppStateView(
              key: const ValueKey('admin-group-cannot'),
              icon: Icons.block_outlined,
              scrollable: false,
              message: adminWhyText(context, info.why),
            )
          else if (info != null && initial != null && draft != null)
            KeyedSubtree(key: ValueKey('admin-group-form-$_loads'), child: _form(info, initial, draft)),
        ],
      ),
    );
  }
}
