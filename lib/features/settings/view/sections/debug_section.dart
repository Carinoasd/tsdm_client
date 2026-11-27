part of '../settings_page.dart';

/// Troubleshooting rows, collapsed by default.
class _DebugSection extends StatelessWidget {
  const _DebugSection();

  @override
  Widget build(BuildContext context) => SettingsSelect(
    select: (m) =>
        (enableDebugOperations: m.enableDebugOperations, systemNotificationsOptIn: m.systemNotificationsOptIn),
    builder: (context, s) {
      final enableDebugOperations = s.enableDebugOperations;
      final tr = context.t.settingsPage.debugSection;
      return AppTileGroup(
        title: tr.title,
        icon: Icons.bug_report_outlined,
        children: [
          // Collapsed by default: these rows are only for troubleshooting.
          ExpansionTile(
            key: const ValueKey('settings-debug-expansion'),
            // Same side padding as the section rows (SectionListTile): the theme's 10px put the warning icon 6px left
            // of every other icon of the page (feedback 110).
            tilePadding: edgeInsetsL16R16,
            leading: const Icon(Icons.warning_amber_outlined),
            title: Text(tr.tip),
            shape: const Border(),
            collapsedShape: const Border(),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            // Kept built (off stage) while collapsed: the search of the settings finds these rows too.
            maintainState: true,
            children: [
              SectionSwitchListTile(
                secondary: const Icon(Icons.developer_board_outlined),
                title: Text(tr.enableDebugOperations.title),
                subtitle: Text(tr.enableDebugOperations.detail),
                value: enableDebugOperations,
                onChanged: (v) =>
                    context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.enableDebugOperations, v)),
              ),
              SectionListTile(
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text(tr.viewLog.title),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async => context.pushNamed(ScreenPaths.debugLog),
              ),
              Builder(
                builder: (context) => SectionListTile(
                  leading: const Icon(Icons.medical_information_outlined),
                  title: Text(context.t.diagnostics.export),
                  onTap: () async => exportDiagnostics(context, shareOrigin: shareOriginOf(context)),
                ),
              ),
              Builder(
                builder: (context) => SectionListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: Text(tr.exportLog.title),
                  onTap: () async => exportCurrentLog(context, shareOrigin: shareOriginOf(context)),
                ),
              ),
              SectionListTile(
                leading: const Icon(Icons.history_outlined),
                title: Text(tr.viewHistoryLog.title),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async => context.pushNamed(ScreenPaths.debugHistoricalLog),
              ),
              SectionListTile(
                leading: const Icon(Icons.folder_copy_outlined),
                title: Text(tr.copyDatabaseDir),
                onTap: () async {
                  final path = (await databaseFile).parent.path;
                  if (!context.mounted) return;
                  await copyToClipboard(context, path);
                },
              ),
              // Android, and iOS / macOS / Linux once their notifications are on.
              if (isAndroid || systemNotificationGate.switchOn(enabled: s.systemNotificationsOptIn))
                SectionListTile(
                  leading: const Icon(Icons.notification_add_outlined),
                  title: Text(tr.testNotification.title),
                  subtitle: Text(tr.testNotification.detail),
                  onTap: () async => showLocalNotification(
                    context,
                    NotificationAutoSyncInfoNotice(
                      msg: tr.testNotification.title,
                      notice: 1,
                      personalMessage: 0,
                      broadcastMessage: 0,
                      timestamp: DateTime.now().millisecondsSinceEpoch,
                    ),
                  ),
                ),
            ],
          ),
        ],
      );
    },
  );
}
