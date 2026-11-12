import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/features/admin_tools/widgets/admin_widgets.dart';
import 'package:tsdm_client/features/medal_title_tools/widgets/common.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Cleaning up a spammer (`adminban` of the app API, plugin 3.9.0): the member's state and offences, the ban, its
/// days, the reason and what to clear; then, when their posts go to the recycle bin, the clearing batch by batch with
/// its progress. A clearing left unfinished (the page left, a failed answer, the app closed) goes on from where the
/// forum says it stopped (`clear_pending`, `post_left`).
class AdminBanPage extends StatefulWidget {
  /// Constructor.
  const AdminBanPage({this.repository, this.initialMember, this.writable, super.key});

  /// Injected for tests; the app's client otherwise.
  final AdminRepository? repository;

  /// The member the page starts with (a UID from a profile).
  final String? initialMember;

  /// Whether the account may post it; asked of the kept access when null.
  final bool? writable;

  @override
  State<AdminBanPage> createState() => _AdminBanPageState();
}

class _AdminBanPageState extends State<AdminBanPage> with AdminSessionLease {
  @override
  late final AdminRepository adminRepository = widget.repository ?? AdminRepository.network();

  late final _target = TextEditingController(text: widget.initialMember ?? '');
  final _reason = TextEditingController();
  AdminBanInfo? _info;
  AdminReply? _failure;
  bool _loading = false;
  bool _sending = false;

  /// Known writable (`write` 1): the submit button is shown only then.
  bool _writable = false;
  String _ban = 'post';
  int _days = 0;
  final _clear = <String>{'post'};
  String? _opId;

  /// The clearing running now, with the rows cleared of [_clearTotal].
  bool _clearing = false;
  int _clearTotal = 0;
  int _clearRemaining = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    onAdminTextChanged(_reason, () => _opId = null);
    unawaited(_loadWritable());
    if (_target.text.trim().isNotEmpty) unawaited(_load());
  }

  @override
  void dispose() {
    // A clearing running stops after its batch; where it stopped is kept for the next visit.
    _disposed = true;
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
    if (mounted && access != null) setState(() => _writable = access.canWrite(AdminActions.ban));
  }

  Future<void> _load() async {
    final target = _target.text.trim();
    if (target.isEmpty) return;
    setState(() {
      _loading = true;
      _failure = null;
    });
    final reply = await adminRepository.request(AdminActions.ban, query: adminTargetQuery(target), reauth: reauth);
    if (!mounted) return;
    final info = AdminBanInfo.fromJson(reply.json);
    setState(() {
      _loading = false;
      _opId = null;
      _info = info;
      _failure = info == null ? reply : null;
      if (info != null) {
        if (!info.member.clearPending) {
          // The forum has no clearing of this member open: a cursor kept from before goes nowhere.
          adminRepository.session.keepClearCursor(adminRepository.currentUid, info.member.member.uid, null);
        }
        if (!info.bans.contains(_ban)) _ban = info.bans.firstWhere((b) => b.isNotEmpty, orElse: () => '');
        if (!info.days.contains(_days)) _days = info.days.firstOrNull ?? 0;
        _clear.retainAll(info.clear);
      }
    });
  }

  String _banLabel(String ban) => switch (ban) {
    'post' => context.t.adminTools.banPost,
    'visit' => context.t.adminTools.banVisit,
    'status' => context.t.adminTools.banStatus,
    _ => context.t.adminTools.banNone,
  };

  String _clearLabel(String item) => switch (item) {
    'post' => context.t.adminTools.clearPost,
    'postcomment' => context.t.adminTools.clearPostcomment,
    'avatar' => context.t.adminTools.clearAvatar,
    'profile' => context.t.adminTools.clearProfile,
    _ => item,
  };

  String _daysLabel(int days) => days == 0 ? context.t.adminTools.permanent : context.t.adminTools.days(n: days);

  bool get _timed => _ban == 'post' || _ban == 'visit';

  static String _clock(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  Future<void> _submit(AdminBanInfo info) async {
    final tr = context.t.adminTools;
    final reason = _reason.text.trim();
    if (info.reasonRequired && reason.isEmpty) {
      showSnackBar(context: context, message: tr.reasonNeeded);
      return;
    }
    final clear = [
      for (final c in info.clear)
        if (_clear.contains(c)) c,
    ];
    final member = info.member.member;
    final ok = await showToolsConfirm(
      context,
      title: tr.ban,
      confirm: tr.confirm,
      destructive: true,
      content: [
        Text('${member.username} (${tr.uid(uid: member.uid)})'),
        sizedBoxW8H8,
        Text([_banLabel(_ban), if (_timed) _daysLabel(_days)].join(' · ')),
        if (clear.isNotEmpty) ...[sizedBoxW8H8, Text(clear.map(_clearLabel).join('\n'))],
        if (reason.isNotEmpty) ...[sizedBoxW8H8, Text(reason)],
      ],
    );
    if (!ok || !mounted) return;
    setState(() => _sending = true);
    final opId = _opId ??= newAdminOpId();
    final reply = await adminRepository.request(
      AdminActions.ban,
      form: {
        ...adminBanForm(uid: member.uid, ban: _ban, days: _timed ? _days : 0, reason: reason, clear: clear),
        'opid': opId,
      },
      reauth: reauth,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    final result = adminBanResultOf(reply.json);
    if (result == null) {
      final again = reply.json == null || reply.error == 'busy' || reply.error == 'admin_login';
      if (!again) _opId = null;
      showSnackBar(context: context, message: adminErrorText(context, reply));
      if (reply.error == 'duplicate') await _load();
      return;
    }
    _opId = null;
    showSnackBar(context: context, message: tr.done);
    if (result.clearPosts case final cp? when cp.pending) {
      final total = info.member.postRows > cp.remaining ? info.member.postRows : cp.remaining;
      await _runClear(member.uid, cp.cursor, total, cp.remaining);
    }
    if (mounted) await _load();
  }

  Future<void> _runClear(int target, String cursor, int total, int remaining) async {
    setState(() {
      _clearing = true;
      _clearTotal = total;
      _clearRemaining = remaining;
    });
    final outcome = await runAdminClear(
      adminRepository,
      target: target,
      cursor: cursor,
      total: total,
      remaining: remaining,
      reauth: reauth,
      stopped: () => _disposed,
      onStep: (step) {
        if (mounted) setState(() => _clearRemaining = step.remaining);
      },
    );
    if (!mounted) return;
    setState(() => _clearing = false);
    if (outcome.done) {
      showSnackBar(context: context, message: context.t.adminTools.clearDone);
    } else if (outcome.reply case final reply?) {
      if (reply.error == 'clear_start') _clear.add('post');
      showSnackBar(context: context, message: adminErrorText(context, reply));
    }
  }

  Widget _progress(int total, int remaining) {
    final done = (total - remaining).clamp(0, total);
    return Column(
      key: const ValueKey('admin-ban-progress'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LinearProgressIndicator(value: total > 0 ? done / total : null),
        sizedBoxW8H8,
        Text(context.t.adminTools.clearProgress(done: done, total: total)),
      ],
    );
  }

  Widget _clearCard(AdminBanInfo info) {
    final tr = context.t.adminTools;
    final member = info.member;
    if (_clearing) {
      return AppSurface(child: _progress(_clearTotal, _clearRemaining));
    }
    // Only a clearing the forum says is open goes on (`clear_pending`, the plugin's second round): it keeps the progress
    // itself, so the app closed meanwhile loses nothing. Without one a new ban with `post` starts it.
    if (!member.clearPending) {
      return const SizedBox.shrink();
    }
    final kept = adminRepository.session.clearCursor(adminRepository.currentUid, member.member.uid);
    final remaining = member.postLeft ?? kept?.remaining ?? member.postRows;
    final total = member.postRows > remaining ? member.postRows : remaining;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _progress(total, remaining),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.tonal(
              key: const ValueKey('admin-ban-resume'),
              onPressed: _writable && !_sending && !_loading
                  ? () async {
                      await _runClear(member.member.uid, kept?.cursor ?? adminClearStart, total, remaining);
                      if (mounted) await _load();
                    }
                  : null,
              child: Text(tr.clearResume),
            ),
          ),
        ],
      ),
    );
  }

  Widget _form(AdminBanInfo info) {
    final tr = context.t.adminTools;
    final enabled = !_sending && !_clearing && !_loading && _writable;
    return AppSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr.banType, style: Theme.of(context).textTheme.titleSmall),
          sizedBoxW8H8,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final b in info.bans)
                ChoiceChip(
                  key: ValueKey('admin-ban-type-${b.isEmpty ? 'none' : b}'),
                  label: Text(_banLabel(b)),
                  selected: _ban == b,
                  onSelected: enabled
                      ? (_) => setState(() {
                          _ban = b;
                          _opId = null;
                        })
                      : null,
                ),
            ],
          ),
          if (_timed) ...[
            sizedBoxW12H12,
            DropdownButtonFormField<int>(
              key: const ValueKey('admin-ban-days'),
              initialValue: _days,
              decoration: InputDecoration(border: const OutlineInputBorder(), labelText: tr.banDays),
              items: [for (final d in info.days) DropdownMenuItem(value: d, child: Text(_daysLabel(d)))],
              onChanged: enabled
                  ? (v) => setState(() {
                      _days = v ?? 0;
                      _opId = null;
                    })
                  : null,
            ),
          ],
          sizedBoxW12H12,
          TextField(
            key: const ValueKey('admin-ban-reason'),
            controller: _reason,
            enabled: enabled,
            maxLength: info.maxReason,
            decoration: InputDecoration(labelText: tr.reason, border: const OutlineInputBorder()),
          ),
          Text(tr.clearItems, style: Theme.of(context).textTheme.titleSmall),
          for (final c in info.clear)
            CheckboxListTile(
              key: ValueKey('admin-ban-clear-$c'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _clear.contains(c),
              title: Text(_clearLabel(c)),
              onChanged: enabled
                  ? (v) => setState(() {
                      if (v ?? false) {
                        _clear.add(c);
                      } else {
                        _clear.remove(c);
                      }
                      _opId = null;
                    })
                  : null,
            ),
          if (_writable)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton(
                key: const ValueKey('admin-ban-submit'),
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                  foregroundColor: Theme.of(context).colorScheme.onError,
                ),
                onPressed: enabled ? () => _submit(info) : null,
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
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr.ban)),
      body: ToolsBody(
        children: [
          AppSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AdminTargetField(
                  controller: _target,
                  label: tr.member,
                  enabled: !_sending && !_loading && !_clearing,
                  onLookup: () => unawaited(_load()),
                ),
                if (_loading) const LinearProgressIndicator(),
                if (info != null)
                  AdminMemberTile(
                    member: info.member.member,
                    extra: [
                      [
                        _banLabel(info.member.banned),
                        if (info.member.banned.isNotEmpty && info.member.banExpiry > 0)
                          tr.until(date: toolsDate(info.member.banExpiry)),
                      ].join(' · '),
                      tr.postCounts(posts: info.member.posts, threads: info.member.threads),
                    ].join('\n'),
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
          else if (info != null) ...[
            if (!info.can)
              AppStateView(
                key: const ValueKey('admin-ban-cannot'),
                icon: Icons.block_outlined,
                scrollable: false,
                message: adminWhyText(context, info.why),
              )
            else ...[
              _clearCard(info),
              sizedBoxW12H12,
              _form(info),
            ],
            if (info.crimes.isNotEmpty) ...[
              sizedBoxW16H16,
              Text(tr.crimes, style: textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
              sizedBoxW8H8,
              AppSurface(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (final c in info.crimes)
                      ListTile(
                        dense: true,
                        title: Text(context.displayText(c.text.isEmpty ? c.action : c.text)),
                        subtitle: Text(
                          [
                            if (tsdmAppWallClockTime(c.dateline, info.timeOffset) case final t?) _clock(t),
                            if (c.operator.isNotEmpty) c.operator,
                            if (c.reason.isNotEmpty) context.displayText(c.reason),
                          ].join(' · '),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }
}
