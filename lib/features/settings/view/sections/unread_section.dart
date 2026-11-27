part of '../settings_page.dart';

/// Unread hints and badges, split from the appearance group so each group stays short.
class _UnreadSection extends StatelessWidget {
  const _UnreadSection();

  @override
  Widget build(BuildContext context) => SettingsSelect(
    select: (m) => (
      showUnreadBroadcastMessageBadge: m.showUnreadBroadcastMessageBadge,
      showUnreadInfoHint: m.showUnreadInfoHint,
      showUnreadNoticeBadge: m.showUnreadNoticeBadge,
      showUnreadPersonalMessageBadge: m.showUnreadPersonalMessageBadge,
    ),
    builder: (context, s) {
      final tr = context.t.settingsPage.appearanceSection;
      return AppTileGroup(
        title: tr.showUnreadInfoHint.title,
        icon: Icons.mark_email_unread_outlined,
        footer: AppNoticeBanner(message: tr.unreadBadgeLimitation),
        children: [
          SectionSwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: Text(tr.showUnreadInfoHint.title),
            subtitle: Text(tr.showUnreadInfoHint.detail),
            value: s.showUnreadInfoHint,
            onChanged: (v) async =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.showUnreadInfoHint, v)),
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.notifications_paused_outlined),
            title: Text(tr.unreadNoticeBadge),
            value: s.showUnreadNoticeBadge,
            onChanged: (v) =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.showUnreadNoticeBadge, v)),
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.notifications_active_outlined),
            title: Text(tr.unreadPersonalMessageBadge),
            value: s.showUnreadPersonalMessageBadge,
            onChanged: (v) =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.showUnreadPersonalMessageBadge, v)),
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.notification_important_outlined),
            title: Text(tr.unreadBroadcastMessageBadge),
            value: s.showUnreadBroadcastMessageBadge,
            onChanged: (v) =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.showUnreadBroadcastMessageBadge, v)),
          ),
        ],
      );
    },
  );
}
