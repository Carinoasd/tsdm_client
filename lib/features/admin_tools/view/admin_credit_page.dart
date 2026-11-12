import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/admin_tools/widgets/admin_widgets.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Rewarding and penalizing members' credits (`admincredit` of the app API, plugin 3.9.0): the members by UID or name,
/// looked up first; each credit's change, a reason and whether to notify; the result per member.
class AdminCreditPage extends StatefulWidget {
  /// Constructor.
  const AdminCreditPage({this.repository, this.initialMembers, this.writable, super.key});

  /// Injected for tests; the app's client otherwise.
  final AdminRepository? repository;

  /// The members the page starts with (a UID from a profile).
  final String? initialMembers;

  /// Whether the account may post it; asked of the kept access when null.
  final bool? writable;

  @override
  State<AdminCreditPage> createState() => _AdminCreditPageState();
}

class _AdminCreditPageState extends State<AdminCreditPage> with AdminSessionLease {
  @override
  late final AdminRepository adminRepository = widget.repository ?? AdminRepository.network();

  late final _targets = TextEditingController(text: widget.initialMembers ?? '');
  final _reason = TextEditingController();
  final _deltas = <int, TextEditingController>{};
  bool _notify = false;
  AdminCreditInfo? _info;
  AdminReply? _failure;
  bool _loading = true;
  bool _sending = false;
  bool _writable = true;
  AdminCreditResult? _result;

  /// The id of the write being sent; kept while the same form is sent again.
  String? _opId;

  @override
  void initState() {
    super.initState();
    _reason.addListener(_formChanged);
    unawaited(_loadWritable());
    unawaited(_load());
  }

  @override
  void dispose() {
    _targets.dispose();
    _reason.dispose();
    for (final c in _deltas.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _formChanged() => _opId = null;

  Future<void> _loadWritable() async {
    if (widget.writable case final w?) {
      _writable = w;
      return;
    }
    final access = await AdminAccessCache.check(adminRepository.currentUid, repository: adminRepository);
    if (mounted && access != null) setState(() => _writable = access.canWrite(AdminActions.credit));
  }

  Future<void> _load() async {
    final targets = adminTargetsOf(_targets.text);
    setState(() {
      _loading = true;
      _failure = null;
      _result = null;
    });
    final reply = await adminRepository.request(
      AdminActions.credit,
      query: {
        if (targets.uids.isNotEmpty) 'uids': targets.uids.join(','),
        if (targets.usernames.isNotEmpty) 'usernames': targets.usernames.join('\n'),
      },
      reauth: reauth,
    );
    if (!mounted) return;
    final info = AdminCreditInfo.fromJson(reply.json);
    setState(() {
      _loading = false;
      _opId = null;
      if (info == null) {
        _failure = reply;
        return;
      }
      _info = info;
      for (final c in info.credits) {
        _deltas.putIfAbsent(c.id, () => TextEditingController()..addListener(_formChanged));
      }
    });
  }

  Future<void> _submit(AdminCreditInfo info) async {
    final tr = context.t.adminTools;
    if (info.members.isEmpty || info.missing.isNotEmpty) {
      showSnackBar(
        context: context,
        message: info.missing.isNotEmpty ? tr.missing(names: info.missing.join('、')) : tr.errorUsers,
      );
      return;
    }
    if (info.members.length > info.maxUsers) {
      showSnackBar(
        context: context,
        message: tr.creditTooMany(n: info.maxUsers),
      );
      return;
    }
    final deltas = adminCreditDeltasOf({for (final e in _deltas.entries) e.key: e.value.text});
    if (deltas == null || deltas.values.any((v) => v.abs() > info.maxDelta)) {
      showSnackBar(
        context: context,
        message: tr.creditBadValue(max: info.maxDelta),
      );
      return;
    }
    if (deltas.isEmpty) {
      showSnackBar(context: context, message: tr.creditNoChange);
      return;
    }
    if (info.reasonRequired && _reason.text.trim().isEmpty) {
      showSnackBar(context: context, message: tr.reasonNeeded);
      return;
    }
    final names = {for (final c in info.credits) c.id: context.displayText(c.title)};
    final ok = await showToolsConfirm(
      context,
      title: tr.credit,
      confirm: tr.confirm,
      destructive: deltas.values.any((v) => v < 0),
      content: [
        Text(info.members.map((m) => m.member.username).join('、')),
        sizedBoxW8H8,
        Text(
          deltas.entries.map((e) => '${names[e.key] ?? '#${e.key}'} ${e.value > 0 ? '+' : ''}${e.value}').join('\n'),
        ),
        if (_reason.text.trim().isNotEmpty) ...[sizedBoxW8H8, Text(_reason.text.trim())],
      ],
    );
    if (!ok || !mounted) return;
    setState(() => _sending = true);
    final opId = _opId ??= newAdminOpId();
    final reply = await adminRepository.request(
      AdminActions.credit,
      form: {
        ...adminCreditForm(
          uids: [for (final m in info.members) m.member.uid],
          deltas: deltas,
          reason: _reason.text,
          notify: _notify,
        ),
        'opid': opId,
      },
      reauth: reauth,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    final result = adminCreditResultOf(reply.json);
    if (result != null) {
      setState(() {
        _opId = null;
        _result = result;
        _info = AdminCreditInfo(
          credits: info.credits,
          members: result.members.isEmpty ? info.members : result.members,
          missing: const [],
          maxUsers: info.maxUsers,
          maxDelta: info.maxDelta,
          maxReason: info.maxReason,
          reasonRequired: info.reasonRequired,
        );
        for (final c in _deltas.values) {
          c.clear();
        }
        _opId = null;
      });
      showSnackBar(context: context, message: tr.done);
      return;
    }
    // The same form may be sent again after a failed request, `busy` or a login not finished: same operation id.
    final again = reply.json == null || reply.error == 'busy' || reply.error == 'admin_login';
    if (!again) _opId = null;
    showSnackBar(context: context, message: adminErrorText(context, reply));
    if (reply.error == 'duplicate') await _load();
  }

  String _creditLine(AdminCreditInfo info, Map<int, int> credits) => [
    for (final c in info.credits) '${context.displayText(c.title)} ${credits[c.id] ?? 0}${c.unit}',
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final tr = context.t.adminTools;
    final info = _info;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr.credit)),
      body: info == null
          ? (_loading
                ? const Center(child: CircularProgressIndicator())
                : AppStateView(
                    icon: Icons.error_outline,
                    error: true,
                    message: adminErrorText(context, _failure ?? AdminReply.failed),
                    action: TextButton(onPressed: _load, child: Text(context.t.general.retry)),
                  ))
          : ToolsBody(
              children: [
                AppSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AdminTargetField(
                        controller: _targets,
                        label: tr.members,
                        multiline: true,
                        enabled: !_sending && !_loading,
                        onLookup: () => unawaited(_load()),
                      ),
                      if (_loading) const LinearProgressIndicator(),
                      for (final m in info.members)
                        AdminMemberTile(member: m.member, extra: _creditLine(info, m.credits)),
                      if (info.missing.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            tr.missing(names: info.missing.join('、')),
                            key: const ValueKey('admin-credit-missing'),
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        ),
                    ],
                  ),
                ),
                sizedBoxW12H12,
                AppSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          for (final c in info.credits)
                            SizedBox(
                              width: 150,
                              child: TextField(
                                key: ValueKey('admin-credit-${c.id}'),
                                controller: _deltas[c.id],
                                enabled: !_sending,
                                keyboardType: const TextInputType.numberWithOptions(signed: true),
                                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'^[+-]?\d*'))],
                                decoration: InputDecoration(
                                  labelText: context.displayText(c.title),
                                  suffixText: c.unit.isEmpty ? null : c.unit,
                                  border: const OutlineInputBorder(),
                                ),
                              ),
                            ),
                        ],
                      ),
                      sizedBoxW12H12,
                      TextField(
                        key: const ValueKey('admin-credit-reason'),
                        controller: _reason,
                        enabled: !_sending,
                        maxLength: info.maxReason,
                        decoration: InputDecoration(labelText: tr.reason, border: const OutlineInputBorder()),
                      ),
                      SwitchListTile(
                        key: const ValueKey('admin-credit-notify'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(tr.notify),
                        value: _notify,
                        onChanged: _sending
                            ? null
                            : (v) => setState(() {
                                _notify = v;
                                _opId = null;
                              }),
                      ),
                      if (_writable)
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child: FilledButton(
                            key: const ValueKey('admin-credit-submit'),
                            onPressed: _sending || _loading || info.members.isEmpty ? null : () => _submit(info),
                            child: Text(tr.submit),
                          ),
                        ),
                    ],
                  ),
                ),
                if (_result case final result?) ...[
                  sizedBoxW12H12,
                  AppSurface(
                    key: const ValueKey('admin-credit-result'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          [
                            tr.creditResult,
                            if (result.notified > 0) tr.notified(n: result.notified),
                          ].join(' · '),
                          style: theme.textTheme.titleSmall,
                        ),
                        sizedBoxW8H8,
                        Text(
                          [
                            for (final c in info.credits)
                              if (result.changed[c.id] case final v?)
                                '${context.displayText(c.title)} ${v > 0 ? '+' : ''}$v${c.unit}',
                          ].join(' · '),
                        ),
                        for (final m in result.members)
                          AdminMemberTile(member: m.member, extra: _creditLine(info, m.credits)),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
