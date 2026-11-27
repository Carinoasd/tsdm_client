import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/view/sections/settings_shared.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';

/// One list the cross-device sync may carry besides what it always does.
typedef CrossDeviceSyncItem = ({SettingsKeys<bool> key, IconData icon, String title, bool on});

/// The lists the user chooses to sync, in the order of the page, each with whether it is on in [settings].
///
/// The reading progress, the phrases and the block lists are synced whenever the sync is on: they have no switch.
List<CrossDeviceSyncItem> crossDeviceSyncItems(Translations t, SettingsMap settings) {
  final tr = t.settingsPage.accountSection.crossDeviceSync;
  return [
    (
      key: SettingsKeys.crossDeviceSyncRateTemplates,
      icon: Icons.star_border_outlined,
      title: tr.rateTemplates,
      on: settings.crossDeviceSyncRateTemplates,
    ),
    (
      key: SettingsKeys.crossDeviceSyncSettings,
      icon: Icons.tune_outlined,
      title: tr.settings,
      on: settings.crossDeviceSyncSettings,
    ),
    (
      key: SettingsKeys.crossDeviceSyncDrafts,
      icon: Icons.drafts_outlined,
      title: tr.drafts,
      on: settings.crossDeviceSyncDrafts,
    ),
    (
      key: SettingsKeys.crossDeviceSyncBookmarks,
      icon: Icons.turned_in_not_outlined,
      title: tr.bookmarks,
      on: settings.crossDeviceSyncBookmarks,
    ),
    (
      key: SettingsKeys.crossDeviceSyncPinnedForums,
      icon: Icons.push_pin_outlined,
      title: tr.pinnedForums,
      on: settings.crossDeviceSyncPinnedForums,
    ),
    (
      key: SettingsKeys.crossDeviceSyncForumWatch,
      icon: Icons.notifications_active_outlined,
      title: tr.forumWatch,
      on: settings.crossDeviceSyncForumWatch,
    ),
    (
      key: SettingsKeys.crossDeviceSyncReplyTemplates,
      icon: Icons.quickreply_outlined,
      title: tr.replyTemplates,
      on: settings.crossDeviceSyncReplyTemplates,
    ),
    (
      key: SettingsKeys.crossDeviceSyncReadLater,
      icon: Icons.watch_later_outlined,
      title: tr.readLater,
      on: settings.crossDeviceSyncReadLater,
    ),
    (
      key: SettingsKeys.crossDeviceSyncFollowedThreads,
      icon: Icons.notification_add_outlined,
      title: tr.followedThreads,
      on: settings.crossDeviceSyncFollowedThreads,
    ),
    (
      key: SettingsKeys.crossDeviceSyncCustomImages,
      icon: Icons.collections_outlined,
      title: tr.customImages,
      on: settings.crossDeviceSyncCustomImages,
    ),
  ];
}

/// What the row of the settings page says of the sync: off, or on with how many of the lists to choose are synced
/// ("on" stands first: the sync carries the reading progress, the phrases and the block lists with none of them).
String crossDeviceSyncSummary(Translations t, SettingsMap settings) {
  final tr = t.settingsPage.accountSection.crossDeviceSync;
  if (!settings.crossDeviceSync) {
    return tr.off;
  }
  final items = crossDeviceSyncItems(t, settings);
  return tr.onWith(n: items.where((e) => e.on).length, total: items.length);
}

/// The cross-device sync: its switch, and under it what it carries besides the reading progress, the phrases and the
/// block lists.
class SettingsCrossDeviceSyncPage extends StatelessWidget {
  /// Constructor.
  const SettingsCrossDeviceSyncPage({super.key});

  @override
  Widget build(BuildContext context) {
    final tr = context.t.settingsPage.accountSection.crossDeviceSync;
    return Scaffold(
      appBar: AppBar(title: Text(tr.title)),
      body: SettingsSelect(
        select: (m) =>
            (on: m.crossDeviceSync, items: [for (final e in crossDeviceSyncItems(context.t, m)) e.on].join()),
        builder: (context, s) {
          final items = crossDeviceSyncItems(context.t, context.read<SettingsBloc>().state.settingsMap);
          return SettingsSubPageBody(
            groups: [
              AppTileGroup(
                children: [
                  SectionSwitchListTile(
                    key: const ValueKey('settings-cross-device-sync'),
                    secondary: const Icon(Icons.sync_outlined),
                    title: Text(tr.title),
                    subtitle: Text(tr.always),
                    value: s.on,
                    onChanged: (v) async =>
                        context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.crossDeviceSync, v)),
                  ),
                ],
              ),
              if (s.on)
                AppTileGroup(
                  title: tr.choose,
                  icon: Icons.checklist_outlined,
                  children: [
                    for (final item in items)
                      SectionSwitchListTile(
                        key: ValueKey('settings-${item.key.name}'),
                        secondary: Icon(item.icon),
                        title: Text(item.title),
                        value: item.on,
                        onChanged: (v) async => context.read<SettingsBloc>().add(SettingsValueChanged(item.key, v)),
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}
