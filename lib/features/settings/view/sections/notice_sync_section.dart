part of '../settings_page.dart';

/// Whether system notifications are posted, with the switch at [optIn] so the page follows it: always on Android
/// and Windows, on iOS, macOS and Linux once turned on.
bool _postsNotifications({required bool optIn}) =>
    alwaysPostsNotifications || systemNotificationGate.switchOn(enabled: optIn);

Future<void> _applyBackgroundSyncSettings(BuildContext context) async {
  final result = await getIt.get<BackgroundSyncController>().applySettings(getIt.get<SettingsRepository>());
  if (result != BackgroundSyncApplyResult.failed || !context.mounted) return;
  showSnackBar(context: context, message: context.t.backgroundService.startFailed);
}

/// Notice sync: interval, Android permissions, the background service and the way to the notification categories.
class _NoticeSyncSection extends StatefulWidget {
  const _NoticeSyncSection();

  @override
  State<_NoticeSyncSection> createState() => _NoticeSyncSectionState();
}

class _NoticeSyncSectionState extends State<_NoticeSyncSection> {
  /// Set while the system notifications of iOS, macOS or Linux are being turned on (the system may be asking).
  bool _turningOnSystemNotifications = false;

  /// iOS, macOS, Linux: turn the system notifications on (asking the permission now) or off. Not allowed or not
  /// available: the switch stays off and a short message says why.
  Future<void> _toggleSystemNotifications(BuildContext context, {required bool enable}) async {
    if (!enable) {
      await turnOffAppSystemNotifications();
      return;
    }
    final tr = context.t.settingsPage.behaviorSection.systemNotifications;
    setState(() => _turningOnSystemNotifications = true);
    final OptInNoticeResult result;
    try {
      result = await turnOnAppSystemNotifications();
    } finally {
      if (mounted) setState(() => _turningOnSystemNotifications = false);
    }
    if (!context.mounted) return;
    switch (result) {
      case OptInNoticeResult.granted:
        break;
      case OptInNoticeResult.denied:
        showSnackBar(context: context, message: tr.denied);
      case OptInNoticeResult.unavailable:
        showSnackBar(context: context, message: tr.unavailable);
    }
  }

  Future<void> _toggleBackgroundSync(BuildContext context, {required bool enable}) async {
    await getIt.get<SettingsRepository>().setValue(SettingsKeys.enableBackgroundMessageService, enable);
    if (enable && context.mounted) {
      unawaited(
        askNotificationPermission(
          context,
          trigger: NotificationPermissionTrigger.settings,
          loggedIn: context.readOrNull<AuthenticationRepository>()?.currentUser != null,
          cubit: context.read<AndroidPermissionCubit>(),
        ),
      );
    }
    if (!context.mounted) return;
    await _applyBackgroundSyncSettings(context);
  }

  /// Let the auto sync poll every saved account, or the account in use only. The in-app auto sync reads it on its next
  /// poll; a running background service (Android) reads the settings again and ticks right away.
  Future<void> _toggleBackgroundSyncAllAccounts(BuildContext context, {required bool enable}) async {
    await getIt.get<SettingsRepository>().setValue(SettingsKeys.backgroundSyncAllAccounts, enable);
    if (!isAndroid || !context.mounted) return;
    await _applyBackgroundSyncSettings(context);
  }

  @override
  Widget build(BuildContext context) => SettingsSelect(
    select: (m) => (
      autoSyncNoticeSeconds: m.autoSyncNoticeSeconds,
      backgroundSyncAllAccounts: m.backgroundSyncAllAccounts,
      enableBackgroundMessageService: m.enableBackgroundMessageService,
      notificationDirectReply: m.notificationDirectReply,
      notificationHideContent: m.notificationHideContent,
      systemNotificationsOptIn: m.systemNotificationsOptIn,
    ),
    builder: (context, s) {
      final tr = context.t.settingsPage.behaviorSection;
      final autoSyncNoticeSeconds = s.autoSyncNoticeSeconds;
      Duration? autoSyncNoticeDuration;
      if (autoSyncNoticeSeconds > 0) {
        autoSyncNoticeDuration = Duration(seconds: autoSyncNoticeSeconds);
      }

      return AppTileGroup(
        title: tr.autoSyncNotice.title,
        icon: Icons.sync_outlined,
        children: [
          SectionListTile(
            key: const ValueKey('settings-auto-sync-notice'),
            leading: const Icon(Icons.sync_outlined),
            title: Text(tr.autoSyncNotice.title),
            subtitle: Text(tr.autoSyncNotice.detail),
            trailing: settingsTrailingValue(
              context,
              autoSyncNoticeDuration?.readable(context) ?? context.t.general.never,
            ),
            onTap: () async {
              final seconds = await showDialog<int>(
                context: context,
                builder: (_) =>
                    RootPage(DialogPaths.selectAutoSyncDuration, AutoSyncNoticeDialog(autoSyncNoticeSeconds)),
              );
              if (seconds == null || !context.mounted) return;
              if (seconds > 0) {
                context.read<AutoNotificationCubit>().start(Duration(seconds: seconds));
                unawaited(
                  askNotificationPermission(
                    context,
                    trigger: NotificationPermissionTrigger.settings,
                    loggedIn: context.readOrNull<AuthenticationRepository>()?.currentUser != null,
                    cubit: context.read<AndroidPermissionCubit>(),
                  ),
                );
              } else {
                context.read<AutoNotificationCubit>().stop();
              }
              await getIt.get<SettingsRepository>().setValue(SettingsKeys.autoSyncNoticeSeconds, seconds);
              if (isAndroid && context.mounted) {
                await _applyBackgroundSyncSettings(context);
              }
            },
          ),
          // iOS, macOS, Linux: off by default, the permission asked when turned on.
          if (systemNotificationGate.platform.optIn)
            SectionSwitchListTile(
              key: const ValueKey('system-notifications-opt-in'),
              secondary: const Icon(Icons.notifications_outlined),
              title: Text(tr.systemNotifications.title),
              value: systemNotificationGate.switchOn(enabled: s.systemNotificationsOptIn),
              onChanged: _turningOnSystemNotifications
                  ? null
                  : (v) async => _toggleSystemNotifications(context, enable: v),
            ),
          if (isAndroid) AndroidPermissionTiles(backgroundServiceOn: s.enableBackgroundMessageService),
          if (isAndroid)
            // P13: the service the system may stop for good shows it (the battery row above asks for the exemption).
            BlocBuilder<AndroidPermissionCubit, AndroidPermissionState>(
              buildWhen: (previous, current) => previous.ignoreBattery != current.ignoreBattery,
              builder: (context, permissions) {
                final atRisk = backgroundReceiveAtRisk(
                  serviceOn: s.enableBackgroundMessageService,
                  ignoreBattery: permissions.ignoreBattery,
                );
                return SectionSwitchListTile(
                  key: const ValueKey('settings-background-message-service'),
                  secondary: atRisk
                      ? Icon(Icons.cloud_off_outlined, color: Theme.of(context).colorScheme.error)
                      : const Icon(Icons.cloud_sync_outlined),
                  title: Text(tr.backgroundMessageService.title),
                  subtitle: Text(tr.backgroundMessageService.detail),
                  value: s.enableBackgroundMessageService,
                  onChanged: (v) async => _toggleBackgroundSync(context, enable: v),
                );
              },
            ),
          // Only where the other accounts are polled too (Android, Windows): nothing would change elsewhere.
          if (alwaysPostsNotifications)
            SectionSwitchListTile(
              key: const ValueKey('background-sync-all-accounts'),
              secondary: const Icon(Icons.switch_account_outlined),
              title: Text(tr.backgroundSyncAllAccounts.title),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr.backgroundSyncAllAccounts.detail),
                  Text(
                    tr.backgroundSyncAllAccounts.seenNote,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              value: s.backgroundSyncAllAccounts,
              onChanged: (v) async => _toggleBackgroundSyncAllAccounts(context, enable: v),
            ),
          // What the system notifications show, on the lock screen too.
          if (_postsNotifications(optIn: s.systemNotificationsOptIn))
            SectionSwitchListTile(
              key: const ValueKey('notification-hide-content'),
              secondary: const Icon(Icons.visibility_off_outlined),
              title: Text(tr.notificationHideContent.title),
              subtitle: Text(tr.notificationHideContent.detail),
              value: s.notificationHideContent,
              onChanged: (v) async => getIt.get<SettingsRepository>().setValue(SettingsKeys.notificationHideContent, v),
            ),
          // Android only: the reply typed in a notification (`direct_reply.dart`).
          if (isAndroid)
            SectionSwitchListTile(
              key: const ValueKey('notification-direct-reply'),
              secondary: const Icon(Icons.quickreply_outlined),
              title: Text(tr.notificationDirectReply.title),
              value: s.notificationDirectReply,
              onChanged: (v) async => getIt.get<SettingsRepository>().setValue(SettingsKeys.notificationDirectReply, v),
            ),
          // Which of them are announced, and when not: on a page of their own.
          if (_postsNotifications(optIn: s.systemNotificationsOptIn))
            SettingsSelect(
              select: (m) => noticeCategoriesSummary(context.t, m),
              builder: (context, summary) => SectionListTile(
                key: const ValueKey('settings-notice-categories'),
                leading: const Icon(Icons.notifications_active_outlined),
                title: Text(tr.noticeCategories.title),
                trailing: _valueAndChevron(context, summary),
                onTap: () async => context.pushNamed(ScreenPaths.settingsNoticeCategories.path),
              ),
            ),
          // Every platform: where notifications are not posted, the page lists what was found.
          SectionListTile(
            key: const ValueKey('notice-forum-watch'),
            leading: const Icon(Icons.fiber_new_outlined),
            title: Text(tr.noticeCategories.forumWatch),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async => context.pushNamed(ScreenPaths.forumWatch),
          ),
        ],
      );
    },
  );
}
