import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/account_security/cubit/account_security_cubit.dart';
import 'package:tsdm_client/features/account_security/models/account_security.dart';
import 'package:tsdm_client/features/account_security/repository/account_security_repository.dart';
import 'package:tsdm_client/features/account_security/utils/account_security_parser.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/in_app_browser/utils/open_forum_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The password, the security question and the email of the account in use, changed through the forum's account
/// center.
class AccountSecurityPage extends StatelessWidget {
  /// Constructor.
  const AccountSecurityPage({this.repository, super.key});

  /// The repository to use, a new one by default (the tests give theirs).
  final AccountSecurityRepository? repository;

  @override
  Widget build(BuildContext context) {
    final auth = context.repo<AuthenticationRepository>();
    final uid = auth.effectiveCurrentUid;
    final tr = context.t.accountSecurityPage;
    if (uid == null) {
      return Scaffold(
        appBar: AppBar(title: Text(tr.title)),
        body: AppStateView(icon: Icons.login_outlined, message: context.t.general.needLogin),
      );
    }
    final repository = this.repository ?? AccountSecurityRepository();
    return RepositoryProvider.value(
      value: repository,
      child: BlocProvider(
        create: (_) {
          final cubit = AccountSecurityCubit(repository: repository, uid: uid);
          unawaited(cubit.load());
          return cubit;
        },
        child: BlocBuilder<AccountSecurityCubit, (AccountPageStatus, AccountSecurityOverview?)>(
          builder: (context, state) => Scaffold(
            appBar: AppBar(title: Text(tr.title)),
            body: SafeArea(bottom: false, child: _body(context, uid, state)),
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, int uid, (AccountPageStatus, AccountSecurityOverview?) state) {
    final cubit = context.read<AccountSecurityCubit>();
    final overview = state.$2;
    if (overview == null) {
      return switch (state.$1) {
        AccountPageStatus.failed => AppStateView(
          icon: Icons.error_outline,
          error: true,
          message: context.t.general.failedToLoad,
          action: FilledButton.tonal(onPressed: cubit.load, child: Text(context.t.general.retry)),
        ),
        _ => const CenteredCircularIndicator(),
      };
    }
    return RefreshIndicator(
      onRefresh: cubit.load,
      child: AppCenteredList(
        maxWidth: appFormMaxWidth,
        builder: (context, padding, _) => ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: padding.copyWith(top: 12, bottom: 24).add(context.safePadding()),
          children: [
            AppTileGroup(
              children: [
                for (final item in overview.items)
                  ListTile(
                    leading: AppIconTile(switch (item.method) {
                      AccountMethod.password => Icons.password_outlined,
                      AccountMethod.question => Icons.help_outline,
                      AccountMethod.email => Icons.email_outlined,
                    }),
                    title: Text(item.title),
                    subtitle: item.value.isEmpty ? null : Text(item.value),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async => _change(context, uid, overview.formHash, item),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _change(BuildContext context, int uid, String formHash, AccountSecurityItem item) async {
    final repository = context.read<AccountSecurityRepository>();
    final cubit = context.read<AccountSecurityCubit>();
    final message = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BlocProvider(
        create: (_) {
          final c = AccountFormCubit(repository: repository, uid: uid, method: item.method, formHash: formHash);
          unawaited(c.open());
          return c;
        },
        child: _AccountFormDialog(title: item.title),
      ),
    );
    if (message == null || !context.mounted) {
      return;
    }
    if (item.method != AccountMethod.password) {
      showSnackBar(context: context, message: message.isEmpty ? context.t.accountSecurityPage.changed : message);
      await cubit.load();
      return;
    }
    // The forum ends every session of the account with a new password (`common_member.password` is replaced): the
    // login on this device is dead, log in again with the new one.
    final auth = context.repo<AuthenticationRepository>();
    final username = auth.effectiveCurrentUser?.username;
    await getIt.get<StorageProvider>().markSessionExpired(uid);
    if (!context.mounted) {
      return;
    }
    showSnackBar(context: context, message: context.t.accountSecurityPage.passwordChanged);
    context.pushReplacementNamed(
      ScreenPaths.login,
      queryParameters: {if (username != null && username.isNotEmpty) 'username': username},
    );
  }
}

/// The form of a way of the account center: the current password when the forum asks for it, then the forum's fields.
/// Pops the forum's message once changed.
class _AccountFormDialog extends StatefulWidget {
  const _AccountFormDialog({required this.title});

  final String title;

  @override
  State<_AccountFormDialog> createState() => _AccountFormDialogState();
}

class _AccountFormDialogState extends State<_AccountFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _texts = <String, TextEditingController>{};
  final _choices = <String, String>{};

  /// The current password was asked: its field stays while it is checked.
  bool _asked = false;

  @override
  void dispose() {
    _current.dispose();
    for (final c in _texts.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _text(String name) => _texts.putIfAbsent(name, TextEditingController.new);

  @override
  Widget build(BuildContext context) {
    final tr = context.t.accountSecurityPage;
    return BlocConsumer<AccountFormCubit, AccountFormState>(
      listenWhen: (prev, curr) => prev.messageSeq != curr.messageSeq || curr.status == AccountFormStatus.done,
      listener: (context, state) {
        if (state.status == AccountFormStatus.done) {
          Navigator.of(context).pop(state.message);
          return;
        }
        showSnackBar(context: context, message: state.message.isNotEmpty ? state.message : tr.resultUnknown);
      },
      builder: (context, state) {
        final cubit = context.read<AccountFormCubit>();
        final busy = state.status == AccountFormStatus.opening || state.status == AccountFormStatus.submitting;
        final (Widget content, List<Widget> actions) = switch (state.status) {
          AccountFormStatus.opening when state.form == null && !_asked => (
            const SizedBox(height: 96, child: CenteredCircularIndicator()),
            <Widget>[],
          ),
          AccountFormStatus.needsPassword || AccountFormStatus.opening => (
            TextFormField(
              controller: _current,
              autofocus: true,
              obscureText: true,
              enabled: !busy,
              autofillHints: const [AutofillHints.password],
              decoration: appFieldDecoration(label: tr.currentPassword, icon: Icons.lock_outline),
              validator: (v) => (v ?? '').isEmpty ? context.t.loginPage.passwordEmpty : null,
              onFieldSubmitted: (_) async => _verify(cubit),
            ),
            [
              FilledButton(
                onPressed: busy ? null : () async => _verify(cubit),
                child: busy ? const _ButtonProgress() : Text(context.t.general.ok),
              ),
            ],
          ),
          AccountFormStatus.otherCheck => (
            Text(tr.otherCheck),
            [
              FilledButton(
                onPressed: () async {
                  // Signed in with the account in use where the in-app browser runs.
                  final router = GoRouter.of(context);
                  final failed = context.t.openInAppPage.browserLaunchFailed;
                  Navigator.of(context).pop();
                  final opened = await openForumPageInBrowser(router, accountCenterUrl);
                  final page = router.routerDelegate.navigatorKey.currentContext;
                  if (!opened && page != null && page.mounted) {
                    showSnackBar(context: page, message: failed);
                  }
                },
                child: Text(context.t.general.openInBrowser),
              ),
            ],
          ),
          AccountFormStatus.failed => (
            Text(state.message.isNotEmpty ? state.message : context.t.general.failedToLoad),
            [FilledButton.tonal(onPressed: cubit.open, child: Text(context.t.general.retry))],
          ),
          AccountFormStatus.ready || AccountFormStatus.submitting || AccountFormStatus.done => (
            _fields(state.form!, enabled: state.status == AccountFormStatus.ready),
            [
              FilledButton(
                onPressed: state.status == AccountFormStatus.ready ? () async => _submit(cubit, state.form!) : null,
                child: state.status == AccountFormStatus.ready ? Text(context.t.general.ok) : const _ButtonProgress(),
              ),
            ],
          ),
        };
        // Never closed while the forum handles a post: a password changed meanwhile would leave the login dead unseen.
        return PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: Text(widget.title),
            scrollable: true,
            content: Form(
              key: _formKey,
              child: ConstrainedBox(constraints: const BoxConstraints(minWidth: 280), child: content),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.of(context).pop(),
                child: Text(context.t.general.cancel),
              ),
              ...actions,
            ],
          ),
        );
      },
    );
  }

  Widget _fields(AccountMethodForm form, {required bool enabled}) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final (i, f) in form.fields.indexed) ...[
        if (i > 0) const SizedBox(height: 12),
        switch (f) {
          AccountTextField(:final name, :final label, :final obscure) => TextFormField(
            controller: _text(name),
            autofocus: i == 0,
            enabled: enabled,
            obscureText: obscure,
            keyboardType: form.method == AccountMethod.email ? TextInputType.emailAddress : null,
            autofillHints: obscure ? const [AutofillHints.newPassword] : null,
            decoration: appFieldDecoration(label: label),
            // The password and the email are required; an answer may be left empty with "no question".
            validator: (v) => form.method == AccountMethod.question || (v ?? '').isNotEmpty
                ? null
                : (obscure ? context.t.loginPage.passwordEmpty : context.t.accountSecurityPage.required),
          ),
          AccountChoiceField(:final name, :final label, :final options, :final initial) =>
            DropdownButtonFormField<String>(
              initialValue: _choices[name] ?? initial,
              isExpanded: true,
              decoration: appFieldDecoration(label: label),
              items: [
                for (final (value, text) in options)
                  DropdownMenuItem(
                    value: value,
                    child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: enabled ? (v) => setState(() => _choices[name] = v ?? initial) : null,
            ),
        },
      ],
    ],
  );

  Future<void> _verify(AccountFormCubit cubit) async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    final password = _current.text;
    setState(() => _asked = true);
    await cubit.open(currentPassword: password);
    if (mounted && cubit.state.status == AccountFormStatus.ready) {
      // Not kept once checked.
      _current.clear();
    }
  }

  Future<void> _submit(AccountFormCubit cubit, AccountMethodForm form) async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    await cubit.submit({
      for (final f in form.fields)
        f.name: switch (f) {
          AccountTextField(:final name) => _text(name).text,
          AccountChoiceField(:final name, :final initial) => _choices[name] ?? initial,
        },
    });
  }
}

class _ButtonProgress extends StatelessWidget {
  const _ButtonProgress();

  @override
  Widget build(BuildContext context) =>
      const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2));
}
