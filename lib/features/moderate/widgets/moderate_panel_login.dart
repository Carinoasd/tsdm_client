import 'package:flutter/material.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The moderation panel's password, asked when the forum asks it again; sent once per tap through [login] and kept
/// nowhere. [onLoggedIn] loads the page again once logged in, or when the answer could not be read (the page then
/// asks again when the password was wrong).
class ModeratePanelLoginView extends StatefulWidget {
  /// Constructor.
  const ModeratePanelLoginView({required this.login, required this.onLoggedIn, super.key});

  /// Send the password.
  final AsyncEither<ModeratePanelLogin> Function(String password) login;

  /// Load the page again.
  final Future<void> Function() onLoggedIn;

  @override
  State<ModeratePanelLoginView> createState() => _ModeratePanelLoginViewState();
}

class _ModeratePanelLoginViewState extends State<ModeratePanelLoginView> {
  final _password = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final password = _password.text;
    if (password.isEmpty || _sending) {
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final answer = await widget.login(password).run();
    if (!mounted) {
      return;
    }
    switch (answer) {
      case Right(value: ModeratePanelWrongPassword()):
        _password.clear();
        setState(() {
          _sending = false;
          _error = context.t.moderate.wrongPassword;
        });
      case Right(value: ModeratePanelRefused(:final message)):
        _password.clear();
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
        // Logged in, or the answer could not be read: the page tells (it asks again when the password was wrong).
        _password.clear();
        await widget.onLoggedIn();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.moderate;
    return AppCenteredList(
      maxWidth: 420,
      builder: (context, padding, _) => ListView(
        padding: padding.copyWith(top: 32, bottom: 32),
        children: [
          Icon(Icons.admin_panel_settings_outlined, size: 48, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 12),
          Text(tr.panelLogin, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 24),
          TextField(
            controller: _password,
            enabled: !_sending,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _login(),
            decoration: InputDecoration(labelText: tr.password, errorText: _error),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _sending ? null : _login,
            child: _sending
                ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(context.t.general.ok),
          ),
        ],
      ),
    );
  }
}
