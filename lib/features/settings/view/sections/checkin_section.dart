part of '../settings_page.dart';

Future<String?> _showSetCheckinFeelingDialog(BuildContext context, String defaultFeeling) async {
  return showDialog<String>(
    context: context,
    builder: (context) => RootPage(DialogPaths.selectCheckinFeeling, CheckinFeelingDialog(defaultFeeling)),
  );
}

Future<String?> _showSetCheckinMessageDialog(BuildContext context, String defaultMessage) async {
  return showDialog<String>(
    context: context,
    builder: (context) => RootPage(DialogPaths.selectCheckinMessage, CheckinMessageDialog(defaultMessage)),
  );
}

/// Check in: feeling, message and the automatic ones.
class _CheckinSection extends StatelessWidget {
  const _CheckinSection();

  @override
  Widget build(BuildContext context) => SettingsSelect(
    select: (m) => (
      autoCheckin: m.autoCheckin,
      autoDailyRedPacket: m.autoDailyRedPacket,
      checkinFeeling: m.checkinFeeling,
      checkinMessage: m.checkinMessage,
    ),
    builder: (context, s) {
      final tr = context.t.settingsPage.checkinSection;
      final checkinFeeling = s.checkinFeeling;
      final checkinMessage = s.checkinMessage;
      final autoCheckin = s.autoCheckin;

      return AppTileGroup(
        title: tr.title,
        icon: Icons.event_available_outlined,
        children: [
          SectionListTile(
            leading: const Icon(Icons.emoji_emotions_outlined),
            title: Text(tr.feeling),
            subtitle: Text(CheckinFeeling.from(checkinFeeling).translate(context)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await _showSetCheckinFeelingDialog(context, checkinFeeling);
              if (result == null) return;
              if (!context.mounted) return;
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.checkinFeeling, result));
            },
          ),
          SectionListTile(
            leading: const Icon(Icons.textsms_outlined),
            title: Text(tr.anythingToSay),
            subtitle: Text(checkinMessage),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final result = await _showSetCheckinMessageDialog(context, checkinMessage);
              if (result == null) return;
              if (!context.mounted) return;
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.checkinMessage, result));
            },
          ),
          SectionSwitchListTile(
            key: const ValueKey('settings-auto-checkin'),
            secondary: Icon(MdiIcons.autoFix),
            title: Text(tr.autoCheckin.title),
            subtitle: Text(tr.autoCheckin.detail),
            value: autoCheckin,
            onChanged: (v) async => context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.autoCheckin, v)),
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.redeem_outlined),
            title: Text(tr.autoDailyRedPacket.title),
            subtitle: Text(tr.autoDailyRedPacket.detail),
            value: s.autoDailyRedPacket,
            onChanged: (v) =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.autoDailyRedPacket, v)),
          ),
        ],
      );
    },
  );
}
