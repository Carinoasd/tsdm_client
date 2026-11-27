import 'dart:async';
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
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/color.dart';
import 'package:tsdm_client/extensions/duration.dart';
import 'package:tsdm_client/features/app_lock/cubit/app_lock_cubit.dart';
import 'package:tsdm_client/features/app_lock/widgets/app_lock_settings_section.dart';
import 'package:tsdm_client/features/attachment_download/utils/download_location.dart';
import 'package:tsdm_client/features/attachment_download/widgets/attachment_download_directory_tile.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/background_sync/background_sync_controller.dart';
import 'package:tsdm_client/features/boss_key/widgets/boss_key_tiles.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/diagnostics/diagnostics_export.dart';
import 'package:tsdm_client/features/in_app_browser/utils/link_routing.dart';
import 'package:tsdm_client/features/local_notice/notification_permission_prompt.dart';
import 'package:tsdm_client/features/local_notice/opt_in_notifications.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/offline_thread/repository/offline_thread_repository.dart';
import 'package:tsdm_client/features/reading_time/repository/reading_time_repository.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/settings/bloc/android_permission_cubit.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/backup_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/settings/repositories/webdav_backup_repository.dart';
import 'package:tsdm_client/features/settings/view/cross_device_sync_page.dart';
import 'package:tsdm_client/features/settings/view/debug_showcase_page.dart';
import 'package:tsdm_client/features/settings/view/notice_categories_page.dart';
import 'package:tsdm_client/features/settings/view/sections/settings_shared.dart';
import 'package:tsdm_client/features/settings/view/settings_search.dart';
import 'package:tsdm_client/features/settings/widgets/android_permission_tiles.dart';
import 'package:tsdm_client/features/settings/widgets/auto_clear_image_cache_duration_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/auto_sync_notice_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/backup_secrets_dialogs.dart';
import 'package:tsdm_client/features/settings/widgets/check_in_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/clear_cache_bottom_sheet.dart';
import 'package:tsdm_client/features/settings/widgets/color_picker_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/dark_schedule_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/font_family_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/font_scale_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/immersive_forums_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/language_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/offline_threads_limit_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/proxy_settings_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/select_app_icon_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/select_chinese_display_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/select_data_saver_mode_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/select_post_image_auto_load_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/select_thread_floor_interaction_mode_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/select_thread_open_position_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/thread_content_layout_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/thread_content_scale_dialog.dart';
import 'package:tsdm_client/features/settings/widgets/upload_image_settings.dart';
import 'package:tsdm_client/features/settings/widgets/webdav_backup_group.dart';
import 'package:tsdm_client/features/theme/cubit/theme_cubit.dart';
import 'package:tsdm_client/features/theme/dark_schedule.dart';
import 'package:tsdm_client/features/thread/v1/utils/immersive_forums.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/data_saver_mode.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/models/post_image_auto_load.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/connection/native.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/app_icon.dart';
import 'package:tsdm_client/utils/app_language.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_converter.dart';
import 'package:tsdm_client/utils/clipboard.dart';
import 'package:tsdm_client/utils/desktop_tray_policy.dart';
import 'package:tsdm_client/utils/html/post_typography.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_bottom_sheet.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/utils/tray_helper.dart';
import 'package:tsdm_client/utils/window_configs.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/color_palette.dart';
import 'package:tsdm_client/widgets/section_list_tile.dart';
import 'package:tsdm_client/widgets/section_switch_list_tile.dart';
import 'package:tsdm_client/widgets/shutdown.dart';

part 'sections/account_section.dart';
part 'sections/advanced_section.dart';
part 'sections/appearance_section.dart';
part 'sections/backup_section.dart';
part 'sections/behavior_section.dart';
part 'sections/checkin_section.dart';
part 'sections/debug_section.dart';
part 'sections/notice_sync_section.dart';
part 'sections/other_section.dart';
part 'sections/storage_section.dart';
part 'sections/unread_section.dart';
part 'sections/window_section.dart';

/// Window width from which the settings groups are laid out in two columns.
const _settingsTwoColumnWidth = 1200.0;

/// Widest the two columns of settings grow together.
const _settingsTwoColumnMaxWidth = 1240.0;

/// Settings page of the app.
///
/// Each group is a widget of its own (`sections/`) that builds from the settings it reads and from nothing else: a
/// switch builds its group again, not the page. The rows the cross-device sync carries and the notification categories
/// are on pages of their own; the search in the app bar finds the rows of all of them.
class SettingsPage extends StatefulWidget {
  /// Constructor.
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
  final scrollController = ScrollController();

  final _permissionCubit = AndroidPermissionCubit();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_permissionCubit.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_permissionCubit.close());
    scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_permissionCubit.refresh());
    }
  }

  /// The rows the search finds: those of this page as they are built now, and those of its sub pages.
  List<SettingsSearchEntry> _searchEntries() {
    if (!mounted) {
      return const [];
    }
    final settings = context.read<SettingsBloc>().state.settingsMap;
    return collectSettingsSearchEntries(
      context as Element,
      t: context.t,
      settings: settings,
      noticeCategories: _postsNotifications(optIn: settings.systemNotificationsOptIn),
    );
  }

  /// Open the search; what it gives back is opened from here, where the rows and their contexts still are.
  Future<void> _search() async {
    final picked = await Navigator.of(
      context,
    ).push<SettingsSearchEntry>(MaterialPageRoute(builder: (_) => SettingsSearchPage(collect: _searchEntries)));
    if (picked == null || !mounted) {
      return;
    }
    final route = picked.route;
    if (route != null) {
      await context.pushNamed(route);
      return;
    }
    final row = picked.element;
    if (row == null || !row.mounted) {
      return;
    }
    // A row of a collapsed group is built but not on the screen: the group is opened first, so the row is where a
    // tap on it would find it (the share sheet of the exports points from the row on an iPad and on macOS).
    if (row.findAncestorWidgetOfExactType<Offstage>()?.offstage ?? false) {
      final group = ExpansibleController.maybeOf(row);
      if (group == null) {
        return;
      }
      group.expand();
      await Future<void>.delayed(kThemeAnimationDuration + const Duration(milliseconds: 50));
      if (!mounted || !row.mounted) {
        return;
      }
    }
    await Scrollable.ensureVisible(row, alignment: 0.3, duration: const Duration(milliseconds: 200));
    if (!mounted || !row.mounted) {
      return;
    }
    final widget = row.widget;
    if (widget is ListTile && widget.enabled) {
      widget.onTap?.call();
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
    // Two columns on wide windows: looks and account on the start side, behavior and data on the end side.
    final start = [
      const _AccountSection(),
      if (getIt.isRegistered<AppLockCubit>()) const AppLockSettingsSection(),
      const _AppearanceSection(),
      const _UnreadSection(),
      if (isDesktop) const _WindowSection(),
      const _CheckinSection(),
    ];
    final end = [
      const _BehaviorSection(),
      SettingsSelect(
        select: (m) => (m.uploadImageMaxSide, m.uploadImageQuality, m.editImageBeforeUpload),
        builder: (context, _) => UploadImageSettingsGroup(context.read<SettingsBloc>().state.settingsMap),
      ),
      const _NoticeSyncSection(),
      const _StorageSection(),
      const _AdvancedSection(),
      const _BackupSection(),
      if (getIt.isRegistered<WebdavBackupRepository>())
        WebdavBackupGroup(
          repository: getIt.get<WebdavBackupRepository>(),
          importBackup: (file) => _importBackup(context, file),
        ),
      const _DebugSection(),
      const _OtherSection(),
    ];
    return BlocProvider<AndroidPermissionCubit>.value(
      value: _permissionCubit,
      child: Scaffold(
        appBar: AppBar(
          title: Text(context.t.navigation.settings),
          actions: [
            IconButton(
              key: const ValueKey('settings-search'),
              icon: const Icon(Icons.search_outlined),
              tooltip: context.t.settingsPage.search.title,
              onPressed: _search,
            ),
          ],
        ),
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
  }
}
