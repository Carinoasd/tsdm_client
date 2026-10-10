import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_symbols_icons/material_symbols_icons.dart';
import 'package:system_theme/system_theme.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/color.dart';
import 'package:tsdm_client/extensions/duration.dart';
import 'package:tsdm_client/features/background_sync/background_sync_controller.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/root/stream/scroll_to_top_stream.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/settings/bloc/android_permission_cubit.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/backup_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/view/debug_showcase_page.dart';
import 'package:tsdm_client/features/settings/widgets/android_permission_tiles.dart';
import 'package:tsdm_client/features/settings/widgets/auto_clear_image_cache_duration_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/auto_sync_notice_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/backup_secrets_dialogs.dart';
import 'package:tsdm_client/features/settings/widgets/check_in_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/clear_cache_bottom_sheet.dart';
import 'package:tsdm_client/features/settings/widgets/color_picker_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/font_family_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/font_scale_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/language_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/proxy_settings_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/select_thread_floor_interaction_mode_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/thread_content_scale_dialog.dart';
import 'package:tsdm_client/features/theme/cubit/theme_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/connection/native.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/log_redaction.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/utils/window_configs.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/color_palette.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';
import 'package:tsdm_client/widgets/shutdown.dart';

/// Width of the theme mode switch: three compact icon segments.
const _themeSwitchWidth = 156.0;

/// Width of a settings row that is not text: side paddings (16 + 16), leading icon with its gap (24 + 16) and the gap
/// before the trailing widget (16), plus a little slack.
const _themeTileChromeWidth = 96.0;

/// Window width from which the settings groups are laid out in two columns.
const _settingsTwoColumnWidth = 1200.0;

/// Widest the two columns of settings grow together.
const _settingsTwoColumnMaxWidth = 1240.0;

/// Settings page of the app.
class SettingsPage extends StatefulWidget {
  /// Constructor.
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
  final scrollController = ScrollController();
  late final StreamSubscription<ScrollToTopEvent> _scrollToTopSub; // 新增

  final _permissionCubit = AndroidPermissionCubit();
  String? _logExportPath;

  Future<(AppLocale?, bool)?> selectLanguageDialog(BuildContext context, String currentLocale) async {
    return showDialog<(AppLocale?, bool)>(
      context: context,
      builder: (context) => RootPage(DialogPaths.selectLanguage, LanguageDialog(currentLocale)),
    );
  }

  Future<(Color?, bool)?> _showAccentColorPickerDialog(BuildContext context) async {
    final colorValue = getIt.get<SettingsRepository>().currentSettings.accentColor;
    if (!context.mounted) return null;
    return showCustomBottomSheet<(Color?, bool)>(
      title: context.t.colorPickerDialog.title,
      context: context,
      builder: (context) =>
          RootPage(DialogPaths.colorPicker, ColorPickerDialog(currentColorValue: colorValue, blocContext: context)),
      bottomBar: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton.icon(
            icon: const Icon(Icons.restart_alt_outlined),
            label: Text(context.t.general.reset),
            onPressed: () async => context.pop((null, true)),
          ),
        ],
      ),
    );
  }

  /// Value of a row shown at its end, in the secondary color, never wider than a third of the row.
  Widget _trailingValue(BuildContext context, String value) => ConstrainedBox(
    constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width / 3),
    child: Text(
      value,
      textAlign: TextAlign.end,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.secondary),
    ),
  );

  Widget _buildAccountSection(BuildContext context, SettingsState state) {
    final tr = context.t.settingsPage.accountSection;
    return AppTileGroup(
      title: tr.title,
      icon: Icons.manage_accounts_outlined,
      children: [
        SectionListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: Text(tr.mgmt),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async => context.pushNamed(ScreenPaths.manageAccount),
        ),
      ],
    );
  }

  Widget _buildThemeModeTile(BuildContext context, int themeModeIndex) {
    final tr = context.t.settingsPage.appearanceSection;
    final title = tr.themeMode.title;
    final subtitle = <String>[tr.themeMode.system, tr.themeMode.light, tr.themeMode.dark][themeModeIndex];
    // Icons only: three labels do not fit a phone at a large text scale; each segment has a tooltip. Compact and of a
    // fixed width, so the row can tell whether the title still fits beside it.
    final themeSwitch = SizedBox(
      width: _themeSwitchWidth,
      child: SegmentedButton<int>(
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        segments: [
          ButtonSegment(
            value: ThemeMode.light.index,
            icon: const Icon(Icons.light_mode_outlined),
            tooltip: tr.themeMode.light,
          ),
          ButtonSegment(
            value: ThemeMode.system.index,
            icon: const Icon(Icons.auto_mode_outlined),
            tooltip: tr.themeMode.system,
          ),
          ButtonSegment(
            value: ThemeMode.dark.index,
            icon: const Icon(Icons.dark_mode_outlined),
            tooltip: tr.themeMode.dark,
          ),
        ],
        selected: {themeModeIndex},
        onSelectionChanged: (selection) {
          final themeIndex = selection.first;
          context.read<ThemeCubit>().setThemeModeIndex(themeIndex);
          context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.themeMode, themeIndex));
        },
      ),
    );
    // The switch sits at the end of the row, in one line with the title (feedback 111: below the text it left the
    // right side of the row empty), but only while the title and the current mode still fit beside it: on a narrow
    // phone the title was squeezed into one character per line (feedback on 1.29.1). Then it goes below the text.
    return LayoutBuilder(
      builder: (context, constraints) {
        final textTheme = Theme.of(context).textTheme;
        final textScaler = MediaQuery.textScalerOf(context);
        final direction = Directionality.of(context);
        double widthOf(String text, TextStyle? style) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style),
            textScaler: textScaler,
            textDirection: direction,
            maxLines: 1,
          )..layout();
          final width = painter.width;
          painter.dispose();
          return width;
        }

        final textWidth = math.max(widthOf(title, textTheme.bodyLarge), widthOf(subtitle, textTheme.bodyMedium));
        final beside = constraints.maxWidth - _themeTileChromeWidth - _themeSwitchWidth >= textWidth;
        if (beside) {
          return SectionListTile(
            leading: const Icon(Icons.contrast_outlined),
            title: Text(title, maxLines: 1),
            subtitle: Text(subtitle, maxLines: 1),
            trailing: themeSwitch,
          );
        }
        return SectionListTile(
          leading: const Icon(Icons.contrast_outlined),
          title: Text(title),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Text(subtitle), sizedBoxW8H8, themeSwitch, sizedBoxW4H4],
          ),
        );
      },
    );
  }

  Widget _buildAppearanceSection(BuildContext context, SettingsState state) {
    final tr = context.t.settingsPage.appearanceSection;
    final settingsLocale = state.settingsMap.locale;
    final locale = AppLocale.values.firstWhereOrNull((v) => v.languageTag == settingsLocale);
    final localeName = locale == null ? tr.languages.followSystem : context.t.locale;
    final themeModeIndex = state.settingsMap.themeMode;
    final showForumCardShortcut = state.settingsMap.showShortcutInForumCard;
    final highRefreshRate = state.settingsMap.highRefreshRate;
    final accentColor = state.settingsMap.accentColor;
    final accentColorFollowSystem = state.settingsMap.accentColorFollowSystem;
    final fontFamily = state.settingsMap.fontFamily;
    final textScaleFactor = state.settingsMap.textScaleFactor;
    final threadContentScale = state.settingsMap.threadContentScale;

    return AppTileGroup(
      title: tr.title,
      icon: Icons.palette_outlined,
      children: [
        _buildThemeModeTile(context, themeModeIndex),
        SectionListTile(
          leading: const Icon(Icons.translate_outlined),
          title: Text(tr.languages.title),
          subtitle: Text(localeName),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final localeGroup = await selectLanguageDialog(context, locale?.languageTag ?? '');
            if (localeGroup == null) return;
            if (localeGroup.$2) {
              await LocaleSettings.useDeviceLocale();
              await desktopUpdateWindowTitle();
              if (!context.mounted) return;
              await getIt.get<SettingsRepository>().setValue(SettingsKeys.locale, '');
            } else {
              await LocaleSettings.setLocale(localeGroup.$1!);
              await desktopUpdateWindowTitle();
              if (!context.mounted) return;
              await getIt.get<SettingsRepository>().setValue(SettingsKeys.locale, localeGroup.$1!.languageTag);
            }
            if (isAndroid && context.mounted) {
              unawaited(getIt.get<BackgroundSyncController>().applySettings(getIt.get<SettingsRepository>()));
            }
          },
        ),
        SectionSwitchListTile(
          secondary: const Icon(Icons.border_color_outlined),
          title: Text(tr.colorSchemeFollowSystem.title),
          subtitle: Text(tr.colorSchemeFollowSystem.detail),
          value: accentColorFollowSystem,
          onChanged: (v) async {
            context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.accentColorFollowSystem, v));
            if (v) {
              await SystemTheme.accentColor.load();
              if (!context.mounted) return;
              final systemColor = SystemTheme.accentColor.accent;
              context.read<ThemeCubit>().setAccentColor(systemColor);
            } else {
              context.read<ThemeCubit>().setAccentColor(
                Color(accentColor >= 0 ? accentColor : SettingsKeys.accentColor.defaultValue),
              );
            }
          },
        ),
        SectionListTile(
          enabled: !accentColorFollowSystem,
          leading: const Icon(Icons.color_lens_outlined),
          title: Text(tr.colorScheme.title),
          subtitle: accentColorFollowSystem ? Text(tr.colorScheme.overrideWithSystem) : null,
          trailing: accentColor < 0 || accentColorFollowSystem ? null : ColorPalette(color: Color(accentColor)),
          onTap: () async {
            final color = await _showAccentColorPickerDialog(context);
            if (color == null) return;
            if (!context.mounted) return;
            if (color.$2) {
              context.read<ThemeCubit>().setAccentColor(Color(SettingsKeys.accentColor.defaultValue));
              context.read<SettingsBloc>().add(
                SettingsValueChanged(SettingsKeys.accentColor, SettingsKeys.accentColor.defaultValue),
              );
              return;
            }
            context.read<ThemeCubit>().setAccentColor(color.$1!);
            context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.accentColor, color.$1!.valueA));
          },
        ),
        SectionListTile(
          leading: const Icon(Icons.font_download_outlined),
          title: Text(tr.fontFamily.title),
          subtitle: fontFamily.isEmpty ? null : Text(fontFamily),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final selectedFont = await showDialog<String>(
              context: context,
              builder: (_) => RootPage(DialogPaths.fontPicker, FontFamilyDialog(fontFamily)),
            );
            if (selectedFont == null || !context.mounted) return;
            context.read<ThemeCubit>().setFontFamily(selectedFont);
            context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.fontFamily, selectedFont));
          },
        ),
        SectionListTile(
          leading: const Icon(Icons.text_increase_outlined),
          title: Text(tr.textScaleFactor.title),
          trailing: _trailingValue(context, '${textScaleFactor.toStringAsFixed(2)}x'),
          onTap: () async {
            final selectedScale = await showDialog<double>(
              context: context,
              builder: (_) => RootPage(DialogPaths.textScalePicker, TextScaleDialog(textScaleFactor)),
            );
            if (!context.mounted || selectedScale == null) return;
            context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.textScaleFactor, selectedScale));
          },
        ),
        SectionListTile(
          leading: const Icon(Icons.format_size_outlined),
          title: Text(tr.threadContentScale.title),
          subtitle: Text(tr.threadContentScale.detail),
          trailing: _trailingValue(context, '${threadContentScale.toStringAsFixed(1)}x'),
          onTap: () async {
            final selectedScale = await showDialog<double>(
              context: context,
              builder: (_) =>
                  RootPage(DialogPaths.threadContentScalePicker, ThreadContentScaleDialog(threadContentScale)),
            );
            if (!context.mounted || selectedScale == null) return;
            context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.threadContentScale, selectedScale));
          },
        ),
        SectionListTile(
          leading: const Icon(Icons.article_outlined),
          title: Text(tr.threadCard.title),
          subtitle: Text(tr.threadCard.detail),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => context.pushNamed(ScreenPaths.settingsThreadAppearance.path),
        ),
        SectionSwitchListTile(
          secondary: const Icon(Icons.shortcut_outlined),
          title: Text(tr.showShortcutInForumCard.title),
          subtitle: Text(tr.showShortcutInForumCard.detail),
          value: showForumCardShortcut,
          onChanged: (v) async =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.showShortcutInForumCard, v)),
        ),
        if (isAndroid)
          SectionSwitchListTile(
            secondary: const Icon(Icons.speed_outlined),
            title: Text(tr.highRefreshRate.title),
            subtitle: Text(tr.highRefreshRate.detail),
            value: highRefreshRate,
            onChanged: (v) => context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.highRefreshRate, v)),
          ),
      ],
    );
  }

  /// Unread hints and badges, split from the appearance group so each group stays short.
  Widget _buildUnreadSection(BuildContext context, SettingsState state) {
    final tr = context.t.settingsPage.appearanceSection;
    final settings = state.settingsMap;
    return AppTileGroup(
      title: tr.showUnreadInfoHint.title,
      icon: Icons.mark_email_unread_outlined,
      footer: AppNoticeBanner(message: tr.unreadBadgeLimitation),
      children: [
        SectionSwitchListTile(
          secondary: const Icon(Icons.notifications_outlined),
          title: Text(tr.showUnreadInfoHint.title),
          subtitle: Text(tr.showUnreadInfoHint.detail),
          value: settings.showUnreadInfoHint,
          onChanged: (v) async =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.showUnreadInfoHint, v)),
        ),
        SectionSwitchListTile(
          secondary: const Icon(Icons.notifications_paused_outlined),
          title: Text(tr.unreadNoticeBadge),
          value: settings.showUnreadNoticeBadge,
          onChanged: (v) =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.showUnreadNoticeBadge, v)),
        ),
        SectionSwitchListTile(
          secondary: const Icon(Icons.notifications_active_outlined),
          title: Text(tr.unreadPersonalMessageBadge),
          value: settings.showUnreadPersonalMessageBadge,
          onChanged: (v) =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.showUnreadPersonalMessageBadge, v)),
        ),
        SectionSwitchListTile(
          secondary: const Icon(Icons.notification_important_outlined),
          title: Text(tr.unreadBroadcastMessageBadge),
          value: settings.showUnreadBroadcastMessageBadge,
          onChanged: (v) =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.showUnreadBroadcastMessageBadge, v)),
        ),
      ],
    );
  }

  Widget _buildWindowSection(BuildContext context, SettingsState state) {
    final tr = context.t.settingsPage.windowSection;
    final windowRememberSize = state.settingsMap.windowRememberSize;
    final windowRememberPosition = state.settingsMap.windowRememberPosition;
    final windowInCenter = state.settingsMap.windowInCenter;

    return AppTileGroup(
      title: tr.title,
      icon: Icons.desktop_windows_outlined,
      footer: AppNoticeBanner(message: tr.disableHint, selectable: true),
      children: [
        SectionSwitchListTile(
          secondary: const Icon(Icons.settings_overscan_outlined),
          title: Text(tr.windowRememberSize.title),
          subtitle: Text(tr.windowRememberSize.detail),
          value: windowRememberSize,
          onChanged: (v) => context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.windowRememberSize, v)),
        ),
        SectionSwitchListTile(
          secondary: const Icon(Icons.open_with_outlined),
          title: Text(tr.windowRememberPosition.title),
          subtitle: Text(tr.windowRememberPosition.detail),
          value: windowRememberPosition,
          onChanged: (v) =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.windowRememberPosition, v)),
        ),
        SectionSwitchListTile(
          secondary: const Icon(Icons.filter_center_focus_outlined),
          title: Text(tr.windowInCenter.title),
          subtitle: Text(tr.windowInCenter.detail),
          value: windowInCenter,
          onChanged: (v) => context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.windowInCenter, v)),
        ),
      ],
    );
  }

  Future<void> _applyBackgroundSyncSettings(BuildContext context) async {
    final result = await getIt.get<BackgroundSyncController>().applySettings(getIt.get<SettingsRepository>());
    if (result != BackgroundSyncApplyResult.failed || !context.mounted) return;
    showSnackBar(context: context, message: context.t.backgroundService.startFailed);
  }

  Future<void> _toggleBackgroundSync(BuildContext context, {required bool enable}) async {
    await getIt.get<SettingsRepository>().setValue(SettingsKeys.enableBackgroundMessageService, enable);
    if (enable) {
      unawaited(_permissionCubit.requestNotification(openSettingsWhenPermanentlyDenied: false));
    }
    if (!context.mounted) return;
    await _applyBackgroundSyncSettings(context);
  }

  /// Reading and editing behavior: order, floor interaction, editor parser and the templates.
  Widget _buildBehaviorSection(BuildContext context, SettingsState state) {
    final tr = context.t.settingsPage.behaviorSection;
    final threadReverseOrder = state.settingsMap.threadReverseOrder;
    final enableBBCodeParser = state.settingsMap.enableEditorBBCodeParser;
    final threadFloorInteractionMode = state.settingsMap.threadFloorInteractionMode;

    return AppTileGroup(
      title: tr.title,
      icon: Icons.tune_outlined,
      children: [
        SectionSwitchListTile(
          secondary: const Icon(Icons.align_vertical_top_outlined),
          title: Text(tr.threadReverseOrder.title),
          subtitle: Text(tr.threadReverseOrder.detail),
          value: threadReverseOrder,
          onChanged: (v) async =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.threadReverseOrder, v)),
        ),
        SectionListTile(
          leading: const Icon(Icons.touch_app_outlined),
          title: Text(tr.threadFloorInteractionMode.title),
          subtitle: Text(tr.threadFloorInteractionMode.detail),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async {
            final result = await showSelectThreadFloorInteractionMode(context, threadFloorInteractionMode);
            if (result == null) return;
            if (!context.mounted) return;
            context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.threadFloorInteractionMode, result));
          },
        ),
        SectionSwitchListTile(
          secondary: const Icon(Icons.code_outlined),
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(child: Text(tr.editorBBCodeParser.title)),
              sizedBoxW8H8,
              IconButton(
                icon: Icon(Icons.help_outline, color: Theme.of(context).colorScheme.secondary),
                tooltip: tr.editorBBCodeParser.tip.title,
                onPressed: () async => showMessageSingleButtonDialog(
                  context: context,
                  title: tr.editorBBCodeParser.tip.title,
                  message: tr.editorBBCodeParser.tip.detail,
                ),
              ),
            ],
          ),
          value: enableBBCodeParser,
          onChanged: (v) async =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.enableEditorBBCodeParser, v)),
        ),
        SectionListTile(
          leading: const Icon(Icons.star_rate_outlined),
          title: Text(context.t.fastRateTemplate.title),
          subtitle: Text(context.t.fastRateTemplate.details),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async => context.pushNamed(ScreenPaths.fastRateTemplate, pathParameters: {'pick': 'false'}),
        ),
        SectionListTile(
          leading: const Icon(Icons.quickreply_outlined),
          title: Text(context.t.fastReplyTemplate.title),
          subtitle: Text(context.t.fastReplyTemplate.details),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async => context.pushNamed(ScreenPaths.fastReplyTemplate, pathParameters: {'pick': 'false'}),
        ),
      ],
    );
  }

  /// Notice sync: interval, Android permissions and the background service.
  Widget _buildNoticeSyncSection(BuildContext context, SettingsState state) {
    final tr = context.t.settingsPage.behaviorSection;
    final autoSyncNoticeSeconds = state.settingsMap.autoSyncNoticeSeconds;
    Duration? autoSyncNoticeDuration;
    if (autoSyncNoticeSeconds > 0) {
      autoSyncNoticeDuration = Duration(seconds: autoSyncNoticeSeconds);
    }

    return AppTileGroup(
      title: tr.autoSyncNotice.title,
      icon: Icons.sync_outlined,
      children: [
        SectionListTile(
          leading: const Icon(Icons.sync_outlined),
          title: Text(tr.autoSyncNotice.title),
          subtitle: Text(tr.autoSyncNotice.detail),
          trailing: _trailingValue(context, autoSyncNoticeDuration?.readable(context) ?? context.t.general.never),
          onTap: () async {
            final seconds = await showDialog<int>(
              context: context,
              builder: (_) => RootPage(DialogPaths.selectAutoSyncDuration, AutoSyncNoticeDialog(autoSyncNoticeSeconds)),
            );
            if (seconds == null || !context.mounted) return;
            if (seconds > 0) {
              context.read<AutoNotificationCubit>().start(Duration(seconds: seconds));
              unawaited(_permissionCubit.requestNotification(openSettingsWhenPermanentlyDenied: false));
            } else {
              context.read<AutoNotificationCubit>().stop();
            }
            await getIt.get<SettingsRepository>().setValue(SettingsKeys.autoSyncNoticeSeconds, seconds);
            if (isAndroid && context.mounted) {
              await _applyBackgroundSyncSettings(context);
            }
          },
        ),
        if (isAndroid) const AndroidPermissionTiles(),
        if (isAndroid)
          SectionSwitchListTile(
            secondary: const Icon(Icons.cloud_sync_outlined),
            title: Text(tr.backgroundMessageService.title),
            subtitle: Text(tr.backgroundMessageService.detail),
            value: state.settingsMap.enableBackgroundMessageService,
            onChanged: (v) async => _toggleBackgroundSync(context, enable: v),
          ),
      ],
    );
  }

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

  Widget _buildCheckinSection(BuildContext context, SettingsState state) {
    final tr = context.t.settingsPage.checkinSection;
    final checkinFeeling = state.settingsMap.checkinFeeling;
    final checkinMessage = state.settingsMap.checkinMessage;
    final autoCheckin = state.settingsMap.autoCheckin;

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
          value: state.settingsMap.autoDailyRedPacket,
          onChanged: (v) => context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.autoDailyRedPacket, v)),
        ),
      ],
    );
  }

  Widget _buildStorageSection(BuildContext context, SettingsState state) {
    final tr = context.t.settingsPage.storageSection;
    final enableAutoClearImageCache = state.settingsMap.enableAutoClearImageCache;
    final autoClearImageDurationSec = state.settingsMap.autoClearImageCacheDuration;
    Duration? autoClearImageDuration;
    if (autoClearImageDurationSec > 0) {
      autoClearImageDuration = Duration(seconds: autoClearImageDurationSec);
    }

    return AppTileGroup(
      title: tr.title,
      icon: Icons.storage_outlined,
      children: [
        SectionListTile(
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
              ? _trailingValue(context, autoClearImageDuration.readable(context))
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
      ],
    );
  }

  /// Network: debug showcase (debug builds) and the proxy.
  Widget _buildAdvanceSection(BuildContext context, SettingsState state) {
    final netClientUseProxy = state.settingsMap.netClientUseProxy;
    final netClientProxy = state.settingsMap.netClientProxy;
    final useDetectedProxy = state.settingsMap.useDetectedProxyWhenStartup;
    String? host;
    String? port;
    if (netClientProxy.contains(':')) {
      final parts = netClientProxy.split(':');
      host = parts.elementAtOrNull(0);
      port = parts.elementAtOrNull(1);
    }
    final proxyAutomated = isAndroid || isMacOS || isIOS;
    final tr = context.t.settingsPage.advancedSection;

    return AppTileGroup(
      title: tr.title,
      icon: Icons.settings_ethernet_outlined,
      children: [
        if (!kReleaseMode)
          SectionListTile(
            leading: const Icon(Icons.developer_mode_outlined),
            title: const Text('DEBUG SHOWCASE'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async =>
                Navigator.push(context, MaterialPageRoute<void>(builder: (context) => const DebugShowcasePage())),
          ),
        if (proxyAutomated)
          SectionListTile(
            leading: Icon(MdiIcons.networkOutline),
            title: Text(tr.useProxy),
            subtitle: Text(tr.proxySettings.automatedOnPlatform),
            enabled: false,
          )
        else
          SectionSwitchListTile(
            secondary: Icon(MdiIcons.networkOutline),
            title: Text(tr.useProxy),
            value: netClientUseProxy,
            onChanged: (v) {
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.netClientUseProxy, v));
              showSnackBar(context: context, message: context.t.general.affectAfterRestart);
            },
          ),
        if (!proxyAutomated)
          SectionSwitchListTile(
            secondary: const Icon(Symbols.network_manage),
            title: Text(tr.proxySettings.useDetectProxy.title),
            subtitle: Text(tr.proxySettings.useDetectProxy.detail),
            value: useDetectedProxy,
            onChanged: netClientUseProxy && !proxyAutomated
                ? (v) async => context.read<SettingsBloc>().add(
                    SettingsValueChanged(SettingsKeys.useDetectedProxyWhenStartup, v),
                  )
                : null,
          ),
        if (!proxyAutomated)
          SectionListTile(
            enabled: netClientUseProxy && !useDetectedProxy && !proxyAutomated,
            leading: const Icon(Icons.network_locked_outlined),
            title: Text(tr.proxySettings.title),
            subtitle: host == null || port == null ? null : Text('$host:$port'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async => showDialog<void>(
              context: context,
              builder: (context) => RootPage(DialogPaths.setupProxy, ProxySettingsDialog(host: host, port: port)),
              barrierDismissible: false,
            ),
          ),
      ],
    );
  }

  /// Export and import of the app data; the texts about what the backup holds are kept as they are.
  Widget _buildBackupSection(BuildContext context, SettingsState state) {
    final tr = context.t.settingsPage.advancedSection;
    return AppTileGroup(
      title: tr.backupTitle,
      icon: Icons.backup_outlined,
      children: [
        SectionListTile(
          leading: const Icon(Icons.download_outlined),
          title: Text(tr.exportData),
          subtitle: Text(tr.exportDataDetail),
          onTap: () async {
            final choice = await showExportBackupDialog(context);
            if (choice == null || !context.mounted) return;
            final data = await const BackupRepository().exportSanitized(
              await databaseFile,
              secretsPassword: choice.password,
            );
            final stamp = DateTime.now().microsecondsSinceEpoch;
            final name = choice.password == null
                ? 'tsdm_client_data_$stamp.db'
                : 'tsdm_client_data_${stamp}_accounts.db';
            if (isDesktop) {
              final filePath = await FilePicker.platform.saveFile(dialogTitle: tr.exportData, fileName: name);
              if (filePath == null) return;
              await File(filePath).writeAsBytes(data, flush: true);
            } else {
              await FilePicker.platform.saveFile(dialogTitle: tr.exportData, fileName: name, bytes: data);
            }
          },
        ),
        SectionListTile(
          leading: const Icon(Icons.upload_outlined),
          title: Text(tr.importData.title),
          onTap: () async {
            final ok = await showQuestionDialog(
              context: context,
              title: tr.importData.title,
              message: tr.importData.tip,
            );
            if (ok != true || !context.mounted) return;
            final files = await FilePicker.platform.pickFiles(dialogTitle: tr.importData.title);
            if (files == null || !context.mounted) return;
            final file = files.files.firstOrNull;
            if (file == null || file.path == null) {
              showSnackBar(context: context, message: tr.importData.invalidData);
              return;
            }
            await _importBackup(context, File(file.path!));
          },
        ),
      ],
    );
  }

  Future<void> _importBackup(BuildContext context, File source) async {
    final tr = context.t.settingsPage.advancedSection.importData;
    const repository = BackupRepository();
    final schemaVersion = getIt.get<AppDatabase>().schemaVersion;
    final check = await repository.validate(source, currentSchemaVersion: schemaVersion);
    if (!context.mounted) return;
    if (!check.ok) {
      await showMessageSingleButtonDialog(
        context: context,
        title: tr.title,
        message: tr.invalidDetail(reason: _backupProblemText(context, check)),
      );
      return;
    }
    BackupSecretsPayload? secrets;
    if (await repository.containsSecrets(source)) {
      if (!context.mounted) return;
      secrets = await _unlockSecrets(context, repository, source);
    }
    if (!context.mounted) return;
    final ok = await showQuestionDialog(context: context, title: tr.title, message: tr.tip);
    if (ok != true || !context.mounted) return;
    BackupValidation? invalid;
    BackupReplaceException? replaceFailure;
    try {
      await getIt.get<StorageProvider>().dispose();
      await repository.replaceDatabase(
        target: await databaseFile,
        source: source,
        currentSchemaVersion: schemaVersion,
        secrets: secrets,
      );
    } on BackupInvalidException catch (e) {
      invalid = e.validation;
    } on BackupReplaceException catch (e) {
      replaceFailure = e;
    }
    if (context.mounted) {
      final String message;
      if (invalid != null) {
        message = tr.invalidDetail(reason: _backupProblemText(context, invalid));
      } else if (replaceFailure != null) {
        message = replaceFailure.restored ? tr.restored : tr.replaceFailed;
      } else {
        message = secrets == null ? tr.success : tr.successWithAccounts;
      }
      await showMessageSingleButtonDialog(context: context, title: tr.title, message: message);
    }
    await exitApp();
  }

  Future<BackupSecretsPayload?> _unlockSecrets(BuildContext context, BackupRepository repository, File source) async {
    final tr = context.t.settingsPage.advancedSection.importData.unlock;
    var wrongPassword = false;
    while (true) {
      if (!context.mounted) return null;
      final password = await showUnlockBackupDialog(context, wrongPassword: wrongPassword);
      if (password == null) return null;
      try {
        return await repository.unlockSecrets(source, password: password);
      } on BackupSecretsPasswordException catch (e) {
        if (e.unsupported) {
          if (context.mounted) showSnackBar(context: context, message: tr.unsupported);
          return null;
        }
        wrongPassword = true;
      }
    }
  }

  String _backupProblemText(BuildContext context, BackupValidation check) {
    final tr = context.t.settingsPage.advancedSection.importData;
    return switch (check.problem) {
      BackupProblem.unreadable => tr.problem.unreadable,
      BackupProblem.notSqlite => tr.problem.notSqlite,
      BackupProblem.corrupted => tr.problem.corrupted,
      BackupProblem.missingTables => tr.problem.missingTables,
      BackupProblem.invalidVersion => tr.problem.invalidVersion,
      BackupProblem.newerSchema => tr.problem.newerSchema(version: check.detail ?? ''),
      null => '',
    };
  }

  Widget _buildDebugSection(BuildContext context, SettingsState state) {
    final enableDebugOperations = state.settingsMap.enableDebugOperations;
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
            SectionListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: Text(tr.exportLog.title),
              subtitle: _logExportPath == null ? null : Text(tr.exportLog.detail(path: _logExportPath!)),
              onTap: () async {
                final logData = talker.history.map((e) => redactSensitive(e.generateTextMessage())).join('\n');
                final outputFile = await FilePicker.platform.saveFile(
                  fileName: 'log_${DateTime.now().millisecondsSinceEpoch}.txt',
                  bytes: utf8.encode(logData),
                );
                if (outputFile == null) {
                  setState(() => _logExportPath = null);
                } else {
                  setState(() => _logExportPath = outputFile);
                }
              },
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
            if (isAndroid)
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
  }

  Widget _buildOtherSection(BuildContext context, SettingsState state) {
    final tr = context.t.settingsPage.othersSection;
    final enableUpdateCheckOnStartup = state.settingsMap.enableUpdateCheckOnStartup;
    return AppTileGroup(
      title: tr.title,
      icon: Icons.more_horiz_outlined,
      children: [
        SectionListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(tr.about),
          trailing: const Icon(Icons.chevron_right),
          onTap: () async => context.pushNamed(ScreenPaths.about),
        ),
        SectionSwitchListTile(
          secondary: const Icon(Icons.cloud_done_outlined),
          title: Text(tr.updateCheckOnStartup),
          value: enableUpdateCheckOnStartup,
          onChanged: (v) =>
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.enableUpdateCheckOnStartup, v)),
        ),
        SectionListTile(
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
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_permissionCubit.refresh());

    // 新增：监听返回顶部事件
    _scrollToTopSub = scrollToTopStream.stream.listen((event) {
      if (event.tabIndex == 2 && mounted && scrollController.hasClients && scrollController.offset > 0) {
        unawaited(scrollController.animateTo(0, duration: const Duration(milliseconds: 300), curve: Curves.easeOut));
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_permissionCubit.close());
    unawaited(_scrollToTopSub.cancel()); // 新增
    scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_permissionCubit.refresh());
    }
  }

  /// Stacks [groups] with the gap of the lists.
  Widget _column(List<Widget> groups) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < groups.length; i++) ...[if (i > 0) const SizedBox(height: appSurfaceGap), groups[i]],
    ],
  );

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsBloc, SettingsState>(
      builder: (context, state) {
        // Two columns on wide windows: looks and account on the start side, behavior and data on the end side.
        final start = [
          _buildAccountSection(context, state),
          _buildAppearanceSection(context, state),
          _buildUnreadSection(context, state),
          if (isDesktop) _buildWindowSection(context, state),
          _buildCheckinSection(context, state),
        ];
        final end = [
          _buildBehaviorSection(context, state),
          _buildNoticeSyncSection(context, state),
          _buildStorageSection(context, state),
          _buildAdvanceSection(context, state),
          _buildBackupSection(context, state),
          _buildDebugSection(context, state),
          _buildOtherSection(context, state),
        ];
        return BlocProvider<AndroidPermissionCubit>.value(
          value: _permissionCubit,
          child: Scaffold(
            appBar: AppBar(title: Text(context.t.navigation.settings)),
            body: SafeArea(
              left: false,
              top: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final twoColumns = constraints.maxWidth >= _settingsTwoColumnWidth;
                  final padding = appCenteredPadding(
                    constraints.maxWidth,
                    maxWidth: twoColumns ? _settingsTwoColumnMaxWidth : appFormMaxWidth,
                  );
                  return ListView(
                    controller: scrollController,
                    padding: padding.copyWith(top: 12, bottom: 24),
                    children: [
                      if (twoColumns)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _column(start)),
                            const SizedBox(width: appSurfaceGap),
                            Expanded(child: _column(end)),
                          ],
                        )
                      else
                        _column([...start, ...end]),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
