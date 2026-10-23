import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/multi_user/bloc/switch_user_bloc.dart';
import 'package:tsdm_client/features/multi_user/utils/switch_account.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/single_line_text.dart';

/// The accounts saved on this device, for the "switch account" button of the "me" tab.
///
/// The account in use first, marked; one tap on another one switches to it the way the avatar menu does
/// ([switchAccount]: its toasts, one switch at a time, none while a reply is being sent), an account whose login expired
/// opens the login page with its name instead. Below them, adding an account and the manage accounts page.
///
/// While a switch runs the dialog cannot be dismissed and every row waits; it closes once the account is switched.
class AccountSwitchDialog extends StatefulWidget {
  /// Constructor.
  const AccountSwitchDialog({super.key});

  @override
  State<AccountSwitchDialog> createState() => _AccountSwitchDialogState();
}

class _AccountSwitchDialogState extends State<AccountSwitchDialog> {
  static final _tileShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(appInnerRadius));

  /// Null where the app's providers are missing (tests of other widgets): no account list then.
  AuthenticationRepository? _auth;

  /// Saved accounts, subscribed once: the drift stream queries again for every new subscriber.
  Stream<List<StoredAccount>>? _accounts;

  /// Runs the switches started here; closing it with the dialog ends nothing else (see [switchAccount]).
  SwitchUserBloc? _switchUserBloc;

  /// Uid of the account being switched to; while set the dialog cannot be dismissed and every row waits.
  int? _switchingUid;

  bool get _switching => _switchingUid != null;

  /// Unread notifications of the other accounts, by uid, counted once per dialog from what is stored for them.
  final _unread = <int, Future<int>>{};

  Future<int> _unreadOf(int uid) =>
      _unread[uid] ??= countUnreadNotificationTotal(storage: getIt.get<StorageProvider>(), uid: uid);

  @override
  void initState() {
    super.initState();
    _auth = context.readOrNull<AuthenticationRepository>();
    if (_auth != null && getIt.isRegistered<StorageProvider>()) {
      _accounts = getIt.get<StorageProvider>().allAccountsStream();
      _switchUserBloc = SwitchUserBloc(_auth!);
    }
  }

  @override
  void dispose() {
    unawaited(_switchUserBloc?.close());
    super.dispose();
  }

  Future<void> _switchTo(UserLoginInfo user) async {
    if (_switching || isSwitchingAccount || _switchUserBloc == null) {
      return;
    }
    setState(() => _switchingUid = user.uid);
    final result = await switchAccount(context, bloc: _switchUserBloc!, userInfo: user);
    if (!mounted) {
      return;
    }
    if (result == SwitchAccountResult.switched) {
      // The pages follow the new account by themselves (`AuthStatus` subscribers).
      Navigator.of(context).pop();
      return;
    }
    // Stays open: the toast told why, and an expired login now shows on its row.
    setState(() => _switchingUid = null);
  }

  /// Close the dialog and open [path], with [query].
  Future<void> _open(String path, {Map<String, String> query = const {}}) async {
    context.pop();
    await context.pushNamed(path, queryParameters: query);
  }

  Widget _buildAccounts(BuildContext context, List<StoredAccount> accounts) {
    // Also the account whose stored session was not verified yet, like the manage accounts page.
    final currentUid = _auth!.effectiveCurrentUid;
    final saved = accounts
        .where((e) => (e.user.username?.isNotEmpty ?? false) && e.user.uid != null && e.user.uid != 0)
        .toList();
    // The account in use first, the others in the order of the manage accounts page.
    final current = saved.where((e) => e.user.uid == currentUid);
    final others = saved.where((e) => e.user.uid != currentUid);
    final tr = context.t.manageAccountPage;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    Widget row(StoredAccount account) {
      final user = account.user;
      final inUse = user.uid == currentUid;
      final expired = account.sessionExpiredAt != null;
      return ListTile(
        key: ValueKey('account-switch-${user.uid}'),
        shape: _tileShape,
        enabled: !_switching,
        leading: SizedBox(
          width: 36,
          height: 36,
          child: HeroUserAvatar(username: user.username!, avatarUrl: avatarUrlOfUid('${user.uid}'), disableHero: true),
        ),
        title: SingleLineText(user.username!),
        subtitle: inUse
            ? Text(context.t.mePage.inUse, style: textTheme.bodySmall?.copyWith(color: colorScheme.primary))
            : expired
            ? Text(tr.sessionExpired.hint, style: textTheme.bodySmall?.copyWith(color: colorScheme.error))
            : null,
        trailing: inUse
            ? Icon(Icons.check_circle, color: colorScheme.primary)
            : _switchingUid == user.uid
            ? sizedCircularProgressIndicator
            : expired
            ? const Icon(Icons.login_outlined)
            : _UnreadCount(count: _unreadOf(user.uid!)),
        onTap: inUse
            ? null
            // A dead login cannot be switched to; logging in again is the way, like on the manage accounts page.
            : () async => expired ? _open(ScreenPaths.login, query: {'username': '${user.username}'}) : _switchTo(user),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [...current.map(row), ...others.map(row)],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.manageAccountPage;
    final divider = Divider(
      height: 9,
      indent: 16,
      endIndent: 16,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.6),
    );
    return PopScope(
      canPop: !_switching,
      child: CustomAlertDialog.sync(
        title: Text(context.t.mePage.switchAccount),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_accounts != null)
              StreamBuilder(
                stream: _accounts,
                builder: (context, snapshot) => _buildAccounts(context, snapshot.data ?? const []),
              ),
            divider,
            ListTile(
              key: const ValueKey('account-switch-add'),
              shape: _tileShape,
              enabled: !_switching,
              leading: const Icon(Icons.person_add_alt_outlined),
              title: Text(tr.addUser),
              onTap: () async => _open(ScreenPaths.login),
            ),
            ListTile(
              key: const ValueKey('account-switch-manage'),
              shape: _tileShape,
              enabled: !_switching,
              leading: const Icon(Icons.manage_accounts_outlined),
              title: Text(tr.title),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async => _open(ScreenPaths.manageAccount),
            ),
          ],
        ),
      ),
    );
  }
}

/// The number of unread notifications of an account in the list, nothing while counting or with none.
class _UnreadCount extends StatelessWidget {
  const _UnreadCount({required this.count});

  final Future<int> count;

  @override
  Widget build(BuildContext context) => FutureBuilder<int>(
    future: count,
    builder: (context, snapshot) {
      final n = snapshot.data ?? 0;
      if (n <= 0) {
        return const SizedBox.shrink();
      }
      return Semantics(
        label: context.t.currentAccount.unread(count: n),
        excludeSemantics: true,
        child: Badge(label: Text(n > 99 ? '99+' : '$n'), largeSize: 20),
      );
    },
  );
}
