import 'package:flutter/material.dart';
import 'package:tsdm_client/features/notification/utils/push_rules.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/sections/settings_shared.dart';
import 'package:tsdm_client/features/theme/dark_schedule.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_check.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';

/// The categories the system notifications announce, in the order of the page, each with its name.
List<({NoticeCategory category, IconData icon, String title})> noticeCategoryItems(Translations t) {
  final tr = t.settingsPage.behaviorSection.noticeCategories;
  return [
    (category: NoticeCategory.reply, icon: Icons.reply_outlined, title: tr.reply),
    (category: NoticeCategory.mention, icon: Icons.alternate_email_outlined, title: tr.mention),
    (category: NoticeCategory.rate, icon: Icons.star_outline, title: tr.rate),
    (category: NoticeCategory.pm, icon: Icons.mail_outline, title: tr.pm),
    (category: NoticeCategory.system, icon: Icons.campaign_outlined, title: tr.system),
    (category: NoticeCategory.followedThread, icon: Icons.notifications_active_outlined, title: tr.followedThread),
    (category: NoticeCategory.forumNewThread, icon: Icons.fiber_new_outlined, title: tr.forumNewThread),
    (category: NoticeCategory.keywordAlert, icon: Icons.manage_search_outlined, title: tr.keywordAlert),
  ];
}

/// Whether the category [c] is announced with [settings].
bool noticeCategoryOn(SettingsMap settings, NoticeCategory c) => switch (c) {
  NoticeCategory.reply => settings.notifyReply,
  NoticeCategory.mention => settings.notifyMention,
  NoticeCategory.rate => settings.notifyRate,
  NoticeCategory.pm => settings.notifyPersonalMessage,
  NoticeCategory.system => settings.notifySystem,
  NoticeCategory.followedThread => settings.notifyFollowedThread,
  NoticeCategory.forumNewThread => settings.notifyForumNewThread,
  NoticeCategory.keywordAlert => settings.notifyKeywordAlert,
};

/// What the row of the settings page says of the categories: how many of them are announced.
String noticeCategoriesSummary(Translations t, SettingsMap settings) =>
    t.settingsPage.behaviorSection.noticeCategories.enabledOf(
      n: NoticeCategory.values.where((c) => noticeCategoryOn(settings, c)).length,
      total: NoticeCategory.values.length,
    );

/// Which categories the system notifications announce, how often the followed threads are checked, and the quiet
/// hours.
class SettingsNoticeCategoriesPage extends StatelessWidget {
  /// Constructor.
  const SettingsNoticeCategoriesPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.t.settingsPage.behaviorSection.noticeCategories.title)),
    body: SettingsSelect(
      select: (m) => (
        followedThreadCheckMinutes: m.followedThreadCheckMinutes,
        notifyFollowedThread: m.notifyFollowedThread,
        notifyForumNewThread: m.notifyForumNewThread,
        notifyKeywordAlert: m.notifyKeywordAlert,
        notifyMention: m.notifyMention,
        notifyPersonalMessage: m.notifyPersonalMessage,
        notifyQuietEnd: m.notifyQuietEnd,
        notifyQuietHours: m.notifyQuietHours,
        notifyQuietStart: m.notifyQuietStart,
        notifyRate: m.notifyRate,
        notifyReply: m.notifyReply,
        notifySystem: m.notifySystem,
      ),
      builder: (context, s) {
        final tr = context.t.settingsPage.behaviorSection.noticeCategories;
        final repo = getIt.get<SettingsRepository>();
        Widget category(NoticeCategory c, IconData icon, String title, {required bool value}) => SectionSwitchListTile(
          key: ValueKey('notice-category-${c.name}'),
          secondary: Icon(icon),
          title: Text(title),
          value: value,
          onChanged: (v) async => repo.setValue(c.settingsKey, v),
        );
        Future<void> pick(SettingsKeys<int> key, int minutes) async {
          final picked = await showTimePicker(
            context: context,
            initialTime: TimeOfDay(hour: minutes ~/ 60 % 24, minute: minutes % 60),
            builder: (context, child) =>
                MediaQuery(data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true), child: child!),
          );
          if (picked != null) {
            await repo.setValue(key, picked.hour * 60 + picked.minute);
          }
        }

        return SettingsSubPageBody(
          groups: [
            AppTileGroup(
              children: [
                category(NoticeCategory.reply, Icons.reply_outlined, tr.reply, value: s.notifyReply),
                category(NoticeCategory.mention, Icons.alternate_email_outlined, tr.mention, value: s.notifyMention),
                category(NoticeCategory.rate, Icons.star_outline, tr.rate, value: s.notifyRate),
                category(NoticeCategory.pm, Icons.mail_outline, tr.pm, value: s.notifyPersonalMessage),
                category(NoticeCategory.system, Icons.campaign_outlined, tr.system, value: s.notifySystem),
                category(
                  NoticeCategory.followedThread,
                  Icons.notifications_active_outlined,
                  tr.followedThread,
                  value: s.notifyFollowedThread,
                ),
                SectionListTile(
                  key: const ValueKey('notice-followed-thread-interval'),
                  leading: const Icon(Icons.update_outlined),
                  title: Text(tr.followedThreadInterval),
                  trailing: settingsTrailingValue(context, tr.followedThreadMinutes(n: s.followedThreadCheckMinutes)),
                  onTap: () async {
                    final picked = await showDialog<int>(
                      context: context,
                      builder: (context) => SimpleDialog(
                        title: Text(tr.followedThreadInterval),
                        children: [
                          for (final minutes in followedThreadCheckChoices)
                            SimpleDialogOption(
                              key: ValueKey('notice-followed-thread-interval-$minutes'),
                              onPressed: () => Navigator.of(context).pop(minutes),
                              child: Row(
                                children: [
                                  Expanded(child: Text(tr.followedThreadMinutes(n: minutes))),
                                  if (minutes == s.followedThreadCheckMinutes)
                                    Icon(Icons.check, color: Theme.of(context).colorScheme.primary),
                                ],
                              ),
                            ),
                        ],
                      ),
                    );
                    if (picked != null) {
                      await repo.setValue(SettingsKeys.followedThreadCheckMinutes, picked);
                    }
                  },
                ),
                category(
                  NoticeCategory.forumNewThread,
                  Icons.fiber_new_outlined,
                  tr.forumNewThread,
                  value: s.notifyForumNewThread,
                ),
                category(
                  NoticeCategory.keywordAlert,
                  Icons.manage_search_outlined,
                  tr.keywordAlert,
                  value: s.notifyKeywordAlert,
                ),
              ],
            ),
            AppTileGroup(
              children: [
                SectionSwitchListTile(
                  key: const ValueKey('notice-quiet-hours'),
                  secondary: const Icon(Icons.bedtime_outlined),
                  title: Text(tr.quietHours),
                  value: s.notifyQuietHours,
                  onChanged: (v) async => repo.setValue(SettingsKeys.notifyQuietHours, v),
                ),
                if (s.notifyQuietHours) ...[
                  SectionListTile(
                    key: const ValueKey('notice-quiet-start'),
                    leading: const Icon(Icons.nightlight_outlined),
                    title: Text(tr.quietStart),
                    trailing: settingsTrailingValue(context, DarkSchedule.timeText(s.notifyQuietStart)),
                    onTap: () async => pick(SettingsKeys.notifyQuietStart, s.notifyQuietStart),
                  ),
                  SectionListTile(
                    key: const ValueKey('notice-quiet-end'),
                    leading: const Icon(Icons.wb_sunny_outlined),
                    title: Text(tr.quietEnd),
                    trailing: settingsTrailingValue(context, DarkSchedule.timeText(s.notifyQuietEnd)),
                    onTap: () async => pick(SettingsKeys.notifyQuietEnd, s.notifyQuietEnd),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    ),
  );
}
