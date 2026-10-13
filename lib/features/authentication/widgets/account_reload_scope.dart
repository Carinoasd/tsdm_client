import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart' show AuthStatus;
import 'package:tsdm_client/features/authentication/utils/account_changes.dart';

/// Builds [child] afresh once the account in use changed (see [listenAccountChanges]), for a page that shows what the
/// forum rendered for the account that opened it, like the boards and threads it may see (GitHub #184 follow-up: the
/// forum pages kept those of the previous account after a quick switch).
///
/// Everything below this widget is created again: its blocs load for the new account as on a page just opened, and
/// nothing of the previous account stays, the requests still pending for it included (their answers reach a closed
/// bloc). A page that keeps something through the reload (a filter, for example) takes it over when it creates its
/// bloc again.
///
/// Only the page on top reloads at once. A page under another page or a dialog (the avatar menu the switch came from)
/// reloads when it shows again, once whatever the number of changes in between: reloading every open page sent one
/// request each.
class AccountReloadScope extends StatefulWidget {
  /// Constructor.
  const AccountReloadScope({required this.child, super.key});

  /// The page content, built afresh for another account.
  final Widget child;

  @override
  State<AccountReloadScope> createState() => _AccountReloadScopeState();
}

class _AccountReloadScopeState extends State<AccountReloadScope> {
  StreamSubscription<AuthStatus>? _accountSub;

  /// Number of reloads so far, the key of [AccountReloadScope.child].
  int _reloads = 0;

  /// Whether the route of this page is the one on top, no other page or dialog above it.
  bool _onTop = true;

  /// The account changed while another page or a dialog covered this one: reload once it shows again.
  bool _reloadWhenShown = false;

  void _onAccountChanged() {
    if (!mounted) {
      return;
    }
    if (!_onTop) {
      _reloadWhenShown = true;
      return;
    }
    setState(() => _reloads++);
  }

  @override
  void initState() {
    super.initState();
    _accountSub = listenAccountChanges(
      context.read<AuthenticationRepository>(),
      // Nothing to clear: the page stays readable while logging in.
      onLoggingIn: () {},
      onChanged: _onAccountChanged,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Depends on this part of the route only. Rebuilding here costs little: the child is the same widget.
    _onTop = ModalRoute.isCurrentOf(context) ?? true;
    if (_onTop && _reloadWhenShown) {
      _reloadWhenShown = false;
      // The build that follows creates the page again.
      _reloads++;
    }
  }

  @override
  void dispose() {
    unawaited(_accountSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(key: ValueKey(_reloads), child: widget.child);
}
