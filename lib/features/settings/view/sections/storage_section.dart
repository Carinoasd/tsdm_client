part of '../settings_page.dart';

/// Storage: caches, offline threads and where downloads go.
class _StorageSection extends StatelessWidget {
  const _StorageSection();

  @override
  Widget build(BuildContext context) => SettingsSelect(
    select: (m) => (
      autoClearImageCacheDuration: m.autoClearImageCacheDuration,
      enableAutoClearImageCache: m.enableAutoClearImageCache,
      offlineThreads: m.offlineThreads,
      offlineThreadsLimit: m.offlineThreadsLimit,
    ),
    builder: (context, s) {
      final tr = context.t.settingsPage.storageSection;
      final enableAutoClearImageCache = s.enableAutoClearImageCache;
      final autoClearImageDurationSec = s.autoClearImageCacheDuration;
      final offlineThreads = s.offlineThreads;
      final offlineThreadsLimit = s.offlineThreadsLimit;
      Duration? autoClearImageDuration;
      if (autoClearImageDurationSec > 0) {
        autoClearImageDuration = Duration(seconds: autoClearImageDurationSec);
      }

      return AppTileGroup(
        title: tr.title,
        icon: Icons.storage_outlined,
        children: [
          SectionListTile(
            key: const ValueKey('settings-clear-cache'),
            leading: const Icon(Icons.cleaning_services_outlined),
            title: Text(tr.clearCache),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async => showClearCacheBottomSheet(context: context),
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.image_not_supported_outlined),
            title: Text(tr.scheduledCleaning.title),
            subtitle: Text(tr.scheduledCleaning.details),
            value: enableAutoClearImageCache,
            onChanged: (v) =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.enableAutoClearImageCache, v)),
          ),
          SectionListTile(
            enabled: enableAutoClearImageCache,
            leading: const Icon(Symbols.auto_timer_rounded),
            title: Text(tr.scheduledCleaning.duration.title),
            trailing: autoClearImageDuration != null
                ? settingsTrailingValue(context, autoClearImageDuration.readable(context))
                : null,
            onTap: () async {
              final seconds = await showDialog<int>(
                context: context,
                builder: (_) => RootPage(
                  DialogPaths.autoClearImageCacheDuration,
                  AutoClearImageCacheDurationDialog(autoClearImageDurationSec),
                ),
              );
              if (seconds == null || !context.mounted) return;
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.autoClearImageCacheDuration, seconds));
            },
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.cloud_download_outlined),
            title: Text(tr.offlineThreads.title),
            subtitle: Text(tr.offlineThreads.detail),
            value: offlineThreads,
            onChanged: (v) async {
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.offlineThreads, v));
              if (!v) {
                // Off means nothing kept: what was saved goes too.
                await appOfflineThreads.clear();
              }
            },
          ),
          SectionListTile(
            enabled: offlineThreads,
            leading: const Icon(Icons.format_list_numbered_outlined),
            title: Text(tr.offlineThreads.limit.title),
            subtitle: Text(tr.offlineThreads.limit.detail),
            trailing: settingsTrailingValue(context, tr.offlineThreads.limit.value(count: offlineThreadsLimit)),
            onTap: () async {
              final limit = await showDialog<int>(
                context: context,
                builder: (_) =>
                    RootPage(DialogPaths.offlineThreadsLimit, OfflineThreadsLimitDialog(offlineThreadsLimit)),
              );
              if (limit == null || !context.mounted) return;
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.offlineThreadsLimit, limit));
              await appOfflineThreads.trim(limit);
            },
          ),
          if (canChooseDownloadDirectory) const AttachmentDownloadDirectoryTile(),
        ],
      );
    },
  );
}
