import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/admin_tools/repository/admin_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// What to tell about an admin answer that is not the page or the result: the forum's refusal, or why the request
/// gave nothing.
String adminErrorText(BuildContext context, AdminReply reply) {
  final tr = context.t.adminTools;
  if (reply.identityChanged) {
    return context.t.general.accountChangedRetry;
  }
  final json = reply.json;
  if (json == null) {
    return tr.errorFailed;
  }
  return switch (reply.error) {
    'admin_off' => tr.errorOff,
    'admin_noperm' => switch (reply.why) {
      'uids' => tr.errorUids,
      'cpaccess' => tr.errorCpaccess,
      'ip' => tr.errorIp,
      'allowpost' => tr.errorAllowpost,
      _ => tr.errorPerm,
    },
    'admin_login' => tr.errorLogin,
    'busy' => tr.errorBusy(n: reply.retryAfter > 0 ? reply.retryAfter : 3),
    'duplicate' => tr.errorDuplicate,
    'formhash' || 'opid' => tr.errorFormhash,
    'users' => switch (json['missing']) {
      final List<dynamic> missing when missing.isNotEmpty => tr.missing(
        names: missing.join(context.t.general.listSeparator),
      ),
      _ => tr.errorUsers,
    },
    'limit' => tr.creditTooMany(n: json['max'] is int ? json['max'] as int : 50),
    'reason' when json['max'] is int => '${tr.reason} ≤ ${json['max']}',
    'reason_required' => tr.reasonNeeded,
    'nouser' => tr.errorNouser,
    'self' => tr.errorSelf,
    'founder_only' => tr.errorFounderOnly,
    'founder' => tr.errorFounder,
    'group' || 'extgroup' || 'expgroup' => tr.errorGroup,
    'extgroups_toomany' => tr.extGroupsTooMany,
    'expiry' => tr.errorExpiry,
    'expgroup_same' => tr.errorExpgroupSame,
    'protected' => tr.errorProtected,
    'portal' => tr.errorPortal,
    'clear_start' => tr.errorClearStart,
    'clear_stuck' => tr.errorClearStuck,
    '' => tr.errorFailed,
    final code => switch (json['message']) {
      final String message when message.isNotEmpty => context.displayText(message),
      _ => tr.errorInvalid(code: code),
    },
  };
}

/// Call [onChanged] when the text of [controller] changes; not for a move of the cursor or the selection, which the
/// controller tells its listeners too (a write's `opid` is kept while the form stays the same).
void onAdminTextChanged(TextEditingController controller, VoidCallback onChanged) {
  var last = controller.text;
  controller.addListener(() {
    if (controller.text != last) {
      last = controller.text;
      onChanged();
    }
  });
}

/// Why the account may not change member [why] (`can` 0 of a member page).
String adminWhyText(BuildContext context, String why) => switch (why) {
  'self' => context.t.adminTools.errorSelf,
  'founder_only' => context.t.adminTools.errorFounderOnly,
  'protected' => context.t.adminTools.errorProtected,
  'portal' => context.t.adminTools.errorPortal,
  _ => context.t.adminTools.errorPerm,
};

/// The label of an admin level (0 none, 1, 2, 3).
String adminLevelLabel(BuildContext context, int adminId) => switch (adminId) {
  1 => context.t.adminTools.admin1,
  2 => context.t.adminTools.admin2,
  3 => context.t.adminTools.admin3,
  _ => context.t.adminTools.none,
};

/// The second login: the account's login password (and the security question when the forum asks it) for an admin
/// token. True once the token is kept. The password is sent once and never kept.
Future<bool> showAdminLoginDialog(BuildContext context, AdminRepository repository, AdminLoginInfo login) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AdminLoginDialog(repository: repository, login: login),
    ) ??
    false;

/// The admin login dialog, see [showAdminLoginDialog].
class AdminLoginDialog extends StatefulWidget {
  /// Constructor.
  const AdminLoginDialog({required this.repository, required this.login, super.key});

  /// Sends the login.
  final AdminRepository repository;

  /// The login state the forum answered.
  final AdminLoginInfo login;

  @override
  State<AdminLoginDialog> createState() => _AdminLoginDialogState();
}

class _AdminLoginDialogState extends State<AdminLoginDialog> {
  final _password = TextEditingController();
  final _answer = TextEditingController();
  late bool _askQuestion = widget.login.secques;
  int _question = 1;
  bool _busy = false;
  String? _message;
  DateTime? _lockedUntil;
  Timer? _tick;
  late final int _uid;

  @override
  void initState() {
    super.initState();
    _uid = widget.repository.currentUid;
    if (widget.login.locked) {
      _lock(widget.login.retryAfter);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    _password.dispose();
    _answer.dispose();
    super.dispose();
  }

  void _lock(int seconds) {
    _lockedUntil = DateTime.now().add(Duration(seconds: seconds > 0 ? seconds : 60));
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_remaining <= 0) {
        _tick?.cancel();
        setState(() {
          _lockedUntil = null;
          _message = null;
        });
      } else {
        setState(() {});
      }
    });
  }

  int get _remaining => _lockedUntil == null ? 0 : _lockedUntil!.difference(DateTime.now()).inSeconds + 1;

  String _clock(int seconds) => '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  Future<void> _submit() async {
    if (_password.text.isEmpty || _busy) return;
    final navigator = Navigator.of(context);
    setState(() {
      _busy = true;
      _message = null;
    });
    final password = _password.text;
    _password.clear();
    final reply = await widget.repository.login(
      password: password,
      questionId: _askQuestion ? _question : 0,
      answer: _askQuestion ? _answer.text : '',
    );
    if (!mounted) return;
    if (reply.ok && widget.repository.session.holds(_uid)) {
      navigator.pop(true);
      return;
    }
    if (reply.identityChanged || reply.error == 'admin_off' || reply.error == 'admin_noperm') {
      // The page then shows the login it asked for: the real reason is told here.
      showSnackBar(context: context, message: adminErrorText(context, reply));
      navigator.pop(false);
      return;
    }
    final login = AdminLoginInfo.fromJson(reply.json?['login']);
    setState(() {
      _busy = false;
      switch (reply.error) {
        case 'admin_password':
          _message = context.t.adminTools.wrongPassword(n: login.triesLeft);
        case 'admin_secques':
          _askQuestion = true;
          _message = context.t.adminTools.needQuestion;
        case 'admin_locked':
          _lock(reply.retryAfter > 0 ? reply.retryAfter : login.retryAfter);
          _message = null;
        default:
          _message = adminErrorText(context, reply);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.adminTools;
    final locked = _lockedUntil != null && _remaining > 0;
    final error = Theme.of(context).colorScheme.error;
    return AlertDialog(
      scrollable: true,
      title: Text(tr.loginTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('admin-login-password'),
            controller: _password,
            obscureText: true,
            autofocus: true,
            enabled: !locked && !_busy,
            autofillHints: const [AutofillHints.password],
            decoration: InputDecoration(labelText: tr.password, border: const OutlineInputBorder()),
            onSubmitted: (_) => unawaited(_submit()),
          ),
          if (_askQuestion) ...[
            sizedBoxW12H12,
            DropdownButtonFormField<int>(
              key: const ValueKey('admin-login-question'),
              initialValue: _question,
              isExpanded: true,
              decoration: InputDecoration(labelText: tr.question, border: const OutlineInputBorder()),
              items: [
                for (final (i, q) in [
                  tr.questions.q1,
                  tr.questions.q2,
                  tr.questions.q3,
                  tr.questions.q4,
                  tr.questions.q5,
                  tr.questions.q6,
                  tr.questions.q7,
                ].indexed)
                  DropdownMenuItem(
                    value: i + 1,
                    child: Text(q, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: locked || _busy ? null : (v) => setState(() => _question = v ?? 1),
            ),
            sizedBoxW12H12,
            TextField(
              key: const ValueKey('admin-login-answer'),
              controller: _answer,
              enabled: !locked && !_busy,
              decoration: InputDecoration(labelText: tr.answer, border: const OutlineInputBorder()),
            ),
          ],
          if (locked) ...[
            sizedBoxW12H12,
            Text(
              tr.lockedFor(time: _clock(_remaining)),
              style: TextStyle(color: error),
            ),
          ] else if (_message case final m?) ...[
            sizedBoxW12H12,
            Text(
              m,
              key: const ValueKey('admin-login-message'),
              style: TextStyle(color: error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(context.t.general.cancel),
        ),
        FilledButton(
          key: const ValueKey('admin-login-submit'),
          onPressed: locked || _busy ? null : () => unawaited(_submit()),
          child: _busy
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(tr.verify),
        ),
      ],
    );
  }
}

/// What an admin page shares: the second login asked again when the forum asks it, and whether the account may post
/// the page's action ([loadAdminWritable]).
///
/// The token is not ended when the page closes: it is kept as long as the forum keeps it ([AdminSession]), so another
/// admin page opened next does not ask the password again.
mixin AdminPageSession<T extends StatefulWidget> on State<T> {
  /// The repository the page sends with.
  AdminRepository get adminRepository;

  /// Ask the password again when the forum asks for the admin login.
  Future<bool> reauth(AdminLoginInfo login) async =>
      mounted && await showAdminLoginDialog(context, adminRepository, login);

  /// Known writable (`write` 1): the submit button is shown only then.
  bool adminWritable = false;

  /// What the account may use could not be asked: the page shows the failure and a retry instead of its form.
  bool adminAccessFailed = false;

  /// Whether the account may post [action]: [given] when the page was told, else [ask] (the kept access by default).
  Future<void> loadAdminWritable(String action, {bool? given, Future<AdminAccess?> Function()? ask}) async {
    if (given != null) {
      adminWritable = given;
      return;
    }
    if (adminAccessFailed) setState(() => adminAccessFailed = false);
    final access =
        await (ask ?? () => AdminAccessCache.check(adminRepository.currentUid, repository: adminRepository))();
    if (!mounted) return;
    setState(() {
      adminAccessFailed = access == null;
      adminWritable = access?.canWrite(action) ?? false;
    });
  }

  /// The failure shown when what the account may use could not be asked, with [onRetry].
  Widget adminAccessFailure(BuildContext context, VoidCallback onRetry) => AppStateView(
    key: const ValueKey('admin-access-failed'),
    icon: Icons.error_outline,
    error: true,
    message: context.t.general.failedToLoad,
    action: TextButton(onPressed: onRetry, child: Text(context.t.general.retry)),
  );
}

/// Ends the admin token by hand ([AdminRepository.logout]); shown while one is kept for the account in use.
class AdminLogoutButton extends StatelessWidget {
  /// Constructor.
  const AdminLogoutButton({required this.repository, super.key});

  /// The repository whose session it ends.
  final AdminRepository repository;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: repository.session,
    builder: (context, _) => repository.session.holds(repository.currentUid)
        ? IconButton(
            key: const ValueKey('admin-logout'),
            icon: const Icon(Icons.lock_outline),
            tooltip: context.t.adminTools.logout,
            onPressed: () => unawaited(repository.logout()),
          )
        : const SizedBox.shrink(),
  );
}

/// A member of an admin page: the username, the UID and the main group.
class AdminMemberTile extends StatelessWidget {
  /// Constructor.
  const AdminMemberTile({required this.member, this.trailing, this.extra, super.key});

  /// The member.
  final AdminMember member;

  /// A widget after the text.
  final Widget? trailing;

  /// More lines below.
  final String? extra;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: const Icon(Icons.person_outline),
    title: Text(member.username),
    subtitle: Text(
      [
        '${context.t.adminTools.uid(uid: member.uid)} · ${context.displayText(member.group)}',
        if (extra?.isNotEmpty ?? false) extra!,
      ].join('\n'),
    ),
    trailing: trailing,
  );
}

/// The field naming the member(s) a page works on, with the button that looks them up.
class AdminTargetField extends StatelessWidget {
  /// Constructor.
  const AdminTargetField({
    required this.controller,
    required this.label,
    required this.onLookup,
    this.multiline = false,
    this.enabled = true,
    super.key,
  });

  /// The text.
  final TextEditingController controller;

  /// The label.
  final String label;

  /// Look up.
  final VoidCallback onLookup;

  /// Several members, one a line.
  final bool multiline;

  /// Editable.
  final bool enabled;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: TextField(
          key: const ValueKey('admin-target'),
          controller: controller,
          enabled: enabled,
          minLines: 1,
          maxLines: multiline ? 6 : 1,
          textInputAction: multiline ? TextInputAction.newline : TextInputAction.search,
          decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          onSubmitted: multiline ? null : (_) => onLookup(),
        ),
      ),
      const SizedBox(width: 8),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: FilledButton.tonal(
          key: const ValueKey('admin-lookup'),
          onPressed: enabled ? onLookup : null,
          child: Text(context.t.adminTools.lookup),
        ),
      ),
    ],
  );
}
