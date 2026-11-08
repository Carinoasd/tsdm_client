import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/member_ban.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// Icon of banning a member from posting, or of lifting the ban ([undo]).
IconData memberBanIcon({bool undo = false}) => undo ? Icons.record_voice_over_outlined : Icons.voice_over_off_outlined;

/// Ban member [memberUid] from posting, or lift the ban, from a floor of forum [fid]: the moderation panel's window of
/// it (its password asked first when the panel asks it), confirmed by the moderator, sent once. True once the forum
/// carried it out.
Future<bool> showMemberBanDialog(
  BuildContext context, {
  required int memberUid,
  required int fid,
  ModerateRepository? repository,
}) async {
  final done = await showDialog<bool>(
    context: context,
    builder: (_) =>
        MemberBanDialog(memberUid: memberUid, fid: fid, repository: repository ?? ModerateRepository.network()),
  );
  return done ?? false;
}

/// The ban window of member [memberUid]: the days and the reason of a ban, or the reason of lifting it. Pops true once
/// the forum carried it out.
class MemberBanDialog extends StatefulWidget {
  /// Constructor.
  const MemberBanDialog({required this.memberUid, required this.fid, required this.repository, super.key});

  /// The member.
  final int memberUid;

  /// The forum the floor is in, where the panel is entered from.
  final int fid;

  /// Where the window comes from and goes to.
  final ModerateRepository repository;

  @override
  State<MemberBanDialog> createState() => _MemberBanDialogState();
}

class _MemberBanDialogState extends State<MemberBanDialog> {
  MemberBanForm? _form;

  /// The panel asks the moderator's password: the form hash of its login form.
  String? _loginFormHash;

  bool _loading = true;
  bool _sending = false;

  /// The forum's refusal, or why the window could not be had.
  String? _error;

  int? _days = memberBanDays.first;
  final _reason = TextEditingController();
  final _password = TextEditingController();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _reason.dispose();
    _password.dispose();
    super.dispose();
  }

  String _failure(AppException e, String fallback) =>
      e is IdentityChangedException ? context.t.general.accountChangedRetry : fallback;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _form = null;
      _loginFormHash = null;
    });
    final answer = await widget.repository.fetchMemberBanWindow(widget.memberUid).run();
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
      switch (answer) {
        case Right(value: MemberBanWindowReady(:final form)):
          _form = form;
        case Right(value: MemberBanNeedsLogin(:final formHash)):
          _loginFormHash = formHash;
        case Right(value: MemberBanWindowRefused(:final message)):
          _error = message.isNotEmpty ? message : context.t.moderate.failed;
        case Left(:final value):
          _error = _failure(value, context.t.general.failedToLoad);
      }
    });
  }

  Future<void> _login() async {
    final formHash = _loginFormHash;
    final password = _password.text;
    if (formHash == null || password.isEmpty) {
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final answer = await widget.repository.loginPanel(formHash: formHash, fid: widget.fid, password: password).run();
    if (!mounted) {
      return;
    }
    _password.clear();
    switch (answer) {
      case Right(value: ModeratePanelWrongPassword()):
        setState(() {
          _sending = false;
          _error = context.t.moderate.wrongPassword;
        });
      case Right(value: ModeratePanelRefused(:final message)):
        setState(() {
          _sending = false;
          _error = message.isNotEmpty ? message : context.t.moderate.failed;
        });
      case Left(value: IdentityChangedException()):
        setState(() {
          _sending = false;
          _error = context.t.general.accountChangedRetry;
        });
      case Right(value: ModeratePanelLoggedIn()) || Left():
        // Logged in, or the answer could not be read: the window tells (the panel asks again when it was wrong).
        _sending = false;
        await _load();
    }
  }

  Future<void> _send() async {
    final form = _form;
    if (form == null) {
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final outcome = await widget.repository.submitMemberBan(form, days: _days, reason: _reason.text).run();
    if (!mounted) {
      return;
    }
    switch (outcome) {
      case Right(value: MemberBanDone(:final message)):
        showSnackBar(context: context, message: message.isNotEmpty ? message : context.t.moderate.done);
        Navigator.of(context).pop(true);
      case Right(value: MemberBanRefused(:final message)):
        setState(() {
          _sending = false;
          _error = message.isNotEmpty ? message : context.t.moderate.failed;
        });
      case Right(value: MemberBanSessionEnded(:final formHash)):
        // Nothing was done: the password, then the window again.
        setState(() {
          _sending = false;
          _form = null;
          _loginFormHash = formHash;
        });
      case Left(:final value):
        setState(() {
          _sending = false;
          _error = _failure(value, context.t.moderate.failed);
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.moderate;
    final form = _form;
    final undo = form?.banned ?? false;
    final login = _loginFormHash != null;
    return PopScope(
      canPop: !_sending,
      child: CustomAlertDialog.sync(
        title: AppDialogTitle(
          icon: login ? Icons.admin_panel_settings_outlined : memberBanIcon(undo: undo),
          title: login ? tr.panelLogin : (undo ? tr.unbanMember : tr.banMember),
        ),
        content: _loading
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (login)
                      TextField(
                        controller: _password,
                        enabled: !_sending,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        autofocus: true,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _login(),
                        decoration: InputDecoration(labelText: tr.password),
                      ),
                    if (form != null) ...[
                      if (!form.banned) ...[
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
                        controller: _reason,
                        enabled: !_sending,
                        minLines: 1,
                        maxLines: 3,
                        decoration: InputDecoration(labelText: tr.reason),
                      ),
                    ],
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
          if (form == null && !login && !_loading)
            TextButton(onPressed: _load, child: Text(context.t.general.retry))
          else
            TextButton(
              onPressed: _sending || _loading ? null : (login ? _login : _send),
              child: _sending
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(context.t.general.ok),
            ),
        ],
      ),
    );
  }
}
