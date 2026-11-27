part of '../settings_page.dart';

/// The account: its pages, and the way to the cross-device sync with what it is at.
class _AccountSection extends StatefulWidget {
  const _AccountSection();

  @override
  State<_AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends State<_AccountSection> {
  /// A login or logout while the page shows: the rows follow the account in use.
  StreamSubscription<AuthStatus>? _authSub;

  @override
  void initState() {
    super.initState();
    _authSub = context.readOrNull<AuthenticationRepository>()?.status.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    unawaited(_authSub?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: TsdmAppApi.pluginInfo,
    builder: (context, _, _) {
      final signedIn = context.readOrNull<AuthenticationRepository>()?.effectiveCurrentUid != null;
      // Only once the forum's plugin said it keeps the devices (`status`, plugin 3.6.0), for an account in use.
      final devices = TsdmAppApi.knowsDevice && signedIn;
      final tr = context.t.settingsPage.accountSection;
      return AppTileGroup(
        title: tr.title,
        icon: Icons.manage_accounts_outlined,
        children: [
          SectionListTile(
            key: const ValueKey('settings-manage-account'),
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(tr.mgmt),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async => context.pushNamed(ScreenPaths.manageAccount),
          ),
          if (signedIn) ...[
            SectionListTile(
              key: const ValueKey('settings-account-security'),
              leading: const Icon(Icons.password_outlined),
              title: Text(tr.security),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async => context.pushNamed(ScreenPaths.accountSecurity),
            ),
            SectionListTile(
              key: const ValueKey('settings-privacy'),
              leading: const Icon(Icons.privacy_tip_outlined),
              title: Text(tr.privacy),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async => context.pushNamed(ScreenPaths.privacySettings),
            ),
          ],
          if (devices)
            SectionListTile(
              key: const ValueKey('settings-login-devices'),
              leading: const Icon(Icons.devices_outlined),
              title: Text(tr.loginDevices),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async => context.pushNamed(ScreenPaths.loginDevices),
            ),
          // The switch and what it carries are on a page of their own (`settings-cross-device-sync` is the switch
          // there): this row tells what it is at.
          SettingsSelect(
            select: (m) => crossDeviceSyncSummary(context.t, m),
            builder: (context, summary) => SectionListTile(
              key: const ValueKey('settings-cross-device-sync-entry'),
              leading: const Icon(Icons.sync_outlined),
              title: Text(tr.crossDeviceSync.title),
              trailing: _valueAndChevron(context, summary),
              onTap: () async => context.pushNamed(ScreenPaths.settingsCrossDeviceSync.path),
            ),
          ),
        ],
      );
    },
  );
}

/// The end of a row that opens a page and tells what that page is at: the value, then the chevron.
Widget _valueAndChevron(BuildContext context, String value) => Row(
  mainAxisSize: MainAxisSize.min,
  children: [settingsTrailingValue(context, value), sizedBoxW4H4, const Icon(Icons.chevron_right)],
);
