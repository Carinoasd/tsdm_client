part of '../settings_page.dart';

Future<void> _clearReadingTime(BuildContext context) async {
  final tr = context.t.settingsPage.othersSection;
  final confirmed = await showQuestionDialog(
    context: context,
    title: tr.clearReadingTime,
    message: tr.clearReadingTimeConfirm,
    dangerous: true,
  );
  if (!(confirmed ?? false) || !context.mounted) {
    return;
  }
  String message;
  try {
    await StorageReadingTimeStore(getIt.get<StorageProvider>()).clear();
    message = tr.readingTimeCleared;
  } on Object catch (e, st) {
    talker.error('failed to clear the reading time', e, st);
    if (!context.mounted) {
      return;
    }
    message = context.t.general.failedToLoad;
  }
  if (!context.mounted) {
    return;
  }
  showSnackBar(context: context, message: message);
}

/// Reading time, data saver, about, feedback, updates and links.
class _OtherSection extends StatelessWidget {
  const _OtherSection();

  @override
  Widget build(BuildContext context) => SettingsSelect(
    select: (m) => (
      clipboardLinkPrompt: m.clipboardLinkPrompt,
      dataSaverMode: m.dataSaverMode,
      enableUpdateCheckOnStartup: m.enableUpdateCheckOnStartup,
      inAppBrowserForAll: m.inAppBrowserForAll,
      inAppBrowserForForum: m.inAppBrowserForForum,
      readingTimeStats: m.readingTimeStats,
    ),
    builder: (context, s) {
      final tr = context.t.settingsPage.othersSection;
      final enableUpdateCheckOnStartup = s.enableUpdateCheckOnStartup;
      final dataSaverMode = DataSaverMode.fromIndex(s.dataSaverMode);
      return AppTileGroup(
        title: tr.title,
        icon: Icons.more_horiz_outlined,
        children: [
          SectionSwitchListTile(
            secondary: const Icon(Icons.timer_outlined),
            title: Text(tr.recordReadingTime),
            value: s.readingTimeStats,
            onChanged: (v) => context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.readingTimeStats, v)),
          ),
          SectionListTile(
            key: const ValueKey('settings-clear-reading-time'),
            leading: const Icon(Icons.delete_sweep_outlined),
            title: Text(tr.clearReadingTime),
            onTap: () async => _clearReadingTime(context),
          ),
          SectionListTile(
            key: const ValueKey('settings-data-saver-mode'),
            leading: const Icon(Icons.data_saver_on_outlined),
            title: Text(tr.dataSaver.title),
            subtitle: Text(dataSaverModeLabel(context, dataSaverMode)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await showSelectDataSaverMode(context, dataSaverMode);
              if (result == null || !context.mounted) return;
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.dataSaverMode, result.index));
            },
          ),
          SectionListTile(
            key: const ValueKey('settings-about'),
            leading: const Icon(Icons.info_outline),
            title: Text(tr.about),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async => context.pushNamed(ScreenPaths.about),
          ),
          SectionListTile(
            key: const ValueKey('settings-feedback'),
            leading: const Icon(Icons.feedback_outlined),
            title: Text(context.t.diagnostics.feedback),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async => context.pushNamed(ScreenPaths.feedback),
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.cloud_done_outlined),
            title: Text(tr.updateCheckOnStartup),
            value: enableUpdateCheckOnStartup,
            onChanged: (v) =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.enableUpdateCheckOnStartup, v)),
          ),
          if (inAppBrowserSupported) ...[
            SectionSwitchListTile(
              secondary: const Icon(Icons.travel_explore_outlined),
              title: Text(tr.inAppBrowserForForum),
              // All links in the in-app browser covers the forum pages too.
              value: s.inAppBrowserForForum || s.inAppBrowserForAll,
              onChanged: s.inAppBrowserForAll
                  ? null
                  : (v) => context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.inAppBrowserForForum, v)),
            ),
            SectionSwitchListTile(
              secondary: const Icon(Icons.public_outlined),
              title: Text(tr.inAppBrowserForAll),
              value: s.inAppBrowserForAll,
              onChanged: (v) =>
                  context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.inAppBrowserForAll, v)),
            ),
          ],
          SectionSwitchListTile(
            secondary: const Icon(Icons.content_paste_go_outlined),
            title: Text(tr.clipboardLinkPrompt),
            value: s.clipboardLinkPrompt,
            onChanged: (v) =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.clipboardLinkPrompt, v)),
          ),
          SectionListTile(
            key: const ValueKey('settings-update'),
            leading: const Icon(Icons.new_releases_outlined),
            title: Text(tr.update),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async => context.pushNamed(ScreenPaths.update),
          ),
          SectionListTile(
            leading: const Icon(Icons.history_outlined),
            title: Text(tr.changelog),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async => context.pushNamed(ScreenPaths.localChangelog),
          ),
        ],
      );
    },
  );
}
