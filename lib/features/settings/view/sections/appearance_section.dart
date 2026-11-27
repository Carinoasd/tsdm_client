part of '../settings_page.dart';

/// Width of the theme mode switch: four icon segments, each a 48 tap target (plus the outlines).
const _themeSwitchWidth = 200.0;

/// Width of the theme mode switch where the full one leaves no room for its title on the same row (a 384dp phone,
/// feedback 111): segments of 43, the whole switch still beside the title.
const _themeSwitchWidthNarrow = 172.0;

/// The value of the fourth segment of the theme mode switch, by time; the other three are the indexes of [ThemeMode].
const _scheduledSegment = 3;

/// Width of a settings row that is not text: side paddings (16 + 16), leading icon with its gap (24 + 16) and the gap
/// before the trailing widget (16), plus a little slack.
const _themeTileChromeWidth = 96.0;

Future<(AppLocale?, bool)?> _selectLanguageDialog(BuildContext context, String currentLocale) async {
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

Widget _themeModeTile(BuildContext context, int themeModeIndex, {required bool scheduled}) {
  final tr = context.t.settingsPage.appearanceSection;
  final title = tr.themeMode.title;
  final selected = scheduled ? _scheduledSegment : themeModeIndex;
  final subtitle = <String>[
    tr.themeMode.system,
    tr.themeMode.light,
    tr.themeMode.dark,
    tr.themeMode.scheduled,
  ][selected];
  // Icons only: four labels do not fit a phone at a large text scale; each segment has a tooltip. Of a fixed width,
  // so the row can tell whether the title still fits beside it; standard density and tap targets, so every segment
  // can be hit on 48 where the row has the room (compact and shrink wrapped they were 52 by 32).
  Widget themeSwitch(double width) => SizedBox(
    width: width,
    child: SegmentedButton<int>(
      showSelectedIcon: false,
      style: const ButtonStyle(
        // Four icons: a little less room around each, so the row still fits beside the title on a 384dp phone.
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
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
        ButtonSegment(
          value: _scheduledSegment,
          icon: const Icon(Icons.schedule_outlined),
          tooltip: tr.themeMode.scheduled,
        ),
      ],
      selected: {selected},
      onSelectionChanged: (selection) {
        final value = selection.first;
        final cubit = context.read<ThemeCubit>();
        final bloc = context.read<SettingsBloc>();
        // By time is its own setting, the theme mode stays what it was: a backup of this version restored on an
        // older one still has a theme mode the older one knows.
        if (value == _scheduledSegment) {
          cubit.setScheduled(scheduled: true);
          bloc.add(const SettingsValueChanged(SettingsKeys.themeModeScheduled, true));
          return;
        }
        cubit
          ..setThemeModeIndex(value)
          ..setScheduled(scheduled: false);
        bloc.add(SettingsValueChanged(SettingsKeys.themeMode, value));
        if (scheduled) {
          bloc.add(const SettingsValueChanged(SettingsKeys.themeModeScheduled, false));
        }
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
      final room = constraints.maxWidth - _themeTileChromeWidth - textWidth;
      // The full switch where it fits beside the title, the narrow one where only that does.
      final switchWidth = room >= _themeSwitchWidth ? _themeSwitchWidth : _themeSwitchWidthNarrow;
      if (room >= switchWidth) {
        return SectionListTile(
          key: const ValueKey('settings-theme-mode'),
          leading: const Icon(Icons.contrast_outlined),
          title: Text(title, maxLines: 1),
          subtitle: Text(subtitle, maxLines: 1),
          trailing: themeSwitch(switchWidth),
        );
      }
      return SectionListTile(
        key: const ValueKey('settings-theme-mode'),
        leading: const Icon(Icons.contrast_outlined),
        title: Text(title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [Text(subtitle), sizedBoxW8H8, themeSwitch(_themeSwitchWidth), sizedBoxW4H4],
        ),
      );
    },
  );
}

/// The hours of the day the app is dark, shown under the theme mode while the clock decides it.
Widget _darkScheduleTile(BuildContext context, DarkSchedule schedule) => SectionListTile(
  key: const ValueKey('settings-dark-schedule'),
  leading: const Icon(Icons.bedtime_outlined),
  title: Text(context.t.settingsPage.appearanceSection.darkSchedule.title),
  subtitle: Text(schedule.text),
  trailing: const Icon(Icons.chevron_right),
  onTap: () async {
    final picked = await showDarkScheduleDialog(context, schedule);
    if (picked == null || picked == schedule || !context.mounted) return;
    context.read<ThemeCubit>().setSchedule(picked);
    // Both at once: one notification of the settings, the page and the cubit see the new window once.
    await getIt.get<SettingsRepository>().setValues<int>([
      (SettingsKeys.darkScheduleStart, picked.start),
      (SettingsKeys.darkScheduleEnd, picked.end),
    ]);
  },
);

/// Pick the line height and the paragraph spacing of the post content and the widest the floors grow
/// ([ThreadContentLayoutDialog]) and save them.
Future<void> _pickThreadContentLayout(BuildContext context, PostTypography current, double contentScale) async {
  final picked = await showDialog<PostTypography>(
    context: context,
    builder: (_) => RootPage(
      DialogPaths.threadContentLayoutPicker,
      ThreadContentLayoutDialog(initial: current, contentScale: contentScale),
    ),
  );
  if (!context.mounted || picked == null) return;
  // All at once: the floors kept alive are laid out again once, not for each.
  await getIt.get<SettingsRepository>().setValues<double>([
    (SettingsKeys.threadContentLineHeight, picked.lineHeight),
    (SettingsKeys.threadContentParagraphSpacing, picked.paragraphSpacing),
    (SettingsKeys.threadContentMaxWidth, picked.maxWidth),
  ]);
}

/// Looks: theme, language, colors, fonts and how threads and lists are laid out.
class _AppearanceSection extends StatelessWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context) => SettingsSelect(
    select: (m) => (
      accentColor: m.accentColor,
      accentColorFollowSystem: m.accentColorFollowSystem,
      appIcon: m.appIcon,
      chineseDisplayMode: m.chineseDisplayMode,
      collapsePinnedThreads: m.collapsePinnedThreads,
      darkScheduleEnd: m.darkScheduleEnd,
      darkScheduleStart: m.darkScheduleStart,
      fontFamily: m.fontFamily,
      highRefreshRate: m.highRefreshRate,
      immersiveAllForums: m.immersiveAllForums,
      immersiveForums: m.immersiveForums,
      locale: m.locale,
      postMediaPreview: m.postMediaPreview,
      postTypography: m.postTypography,
      readingMaxWidth: m.readingMaxWidth,
      showShortcutInForumCard: m.showShortcutInForumCard,
      textScaleFactor: m.textScaleFactor,
      themeMode: m.themeMode,
      themeModeScheduled: m.themeModeScheduled,
      threadContentScale: m.threadContentScale,
      threadLinkCard: m.threadLinkCard,
      twoPaneLayout: m.twoPaneLayout,
    ),
    builder: (context, s) {
      final tr = context.t.settingsPage.appearanceSection;
      final settingsLocale = s.locale;
      final locale = appLocaleOfSetting(settingsLocale);
      final localeName = locale == null ? tr.languages.followSystem : context.t.locale;
      final themeModeIndex = s.themeMode;
      final themeModeScheduled = s.themeModeScheduled;
      final showForumCardShortcut = s.showShortcutInForumCard;
      final highRefreshRate = s.highRefreshRate;
      final accentColor = s.accentColor;
      final accentColorFollowSystem = s.accentColorFollowSystem;
      final fontFamily = s.fontFamily;
      final textScaleFactor = s.textScaleFactor;
      final threadContentScale = s.threadContentScale;
      final chineseDisplayMode = ChineseDisplayMode.fromIndex(s.chineseDisplayMode);
      final postTypography = s.postTypography.withMaxWidth(s.readingMaxWidth);
      final immersiveForums = ImmersiveForums.parse(
        s.immersiveForums,
        all: s.immersiveAllForums,
      );

      return AppTileGroup(
        title: tr.title,
        icon: Icons.palette_outlined,
        children: [
          _themeModeTile(context, themeModeIndex, scheduled: themeModeScheduled),
          if (themeModeScheduled)
            _darkScheduleTile(
              context,
              DarkSchedule(start: s.darkScheduleStart, end: s.darkScheduleEnd),
            ),
          SectionListTile(
            key: const ValueKey('settings-language'),
            leading: const Icon(Icons.translate_outlined),
            title: Text(tr.languages.title),
            subtitle: Text(localeName),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final localeGroup = await _selectLanguageDialog(context, locale?.languageTag ?? '');
              if (localeGroup == null) return;
              // Nothing below needs the page: a choice is kept and applied even when the page was left meanwhile.
              await chooseAppLanguage(getIt.get<SettingsRepository>(), localeGroup.$2 ? null : localeGroup.$1);
              await desktopUpdateWindowTitle();
              if (isAndroid) {
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
            key: const ValueKey('settings-accent-color'),
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
            key: const ValueKey('settings-font-family'),
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
            key: const ValueKey('settings-chinese-display'),
            leading: const Icon(Icons.translate_outlined),
            title: Text(tr.chineseDisplay.title),
            trailing: settingsTrailingValue(context, chineseDisplayModeName(context, chineseDisplayMode)),
            onTap: () async {
              final picked = await showSelectChineseDisplayDialog(context, chineseDisplayMode);
              if (picked == null || !context.mounted) {
                return;
              }
              context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.chineseDisplayMode, picked.index));
            },
          ),
          SectionListTile(
            key: const ValueKey('settings-text-scale'),
            leading: const Icon(Icons.text_increase_outlined),
            title: Text(tr.textScaleFactor.title),
            trailing: settingsTrailingValue(context, '${textScaleFactor.toStringAsFixed(2)}x'),
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
            trailing: settingsTrailingValue(context, '${threadContentScale.toStringAsFixed(1)}x'),
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
          // Line height, paragraph spacing and widest floors of the post content: one dialog with them and a preview.
          SectionListTile(
            key: const ValueKey('settings-reading-layout'),
            leading: const Icon(Icons.format_line_spacing_outlined),
            title: Text(tr.threadContentLayout.title),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async => _pickThreadContentLayout(context, postTypography, threadContentScale),
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.wrap_text_outlined),
            title: Text(tr.threadContentSplitLongParagraphs.title),
            subtitle: Text(tr.threadContentSplitLongParagraphs.detail),
            value: postTypography.splitLongParagraphs,
            onChanged: (v) => context.read<SettingsBloc>().add(
              SettingsValueChanged(SettingsKeys.threadContentSplitLongParagraphs, v),
            ),
          ),
          SectionSwitchListTile(
            key: const ValueKey('settings-thread-link-card'),
            secondary: const Icon(Icons.link_outlined),
            title: Text(tr.threadLinkCard.title),
            value: s.threadLinkCard,
            onChanged: (v) => context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.threadLinkCard, v)),
          ),
          SectionListTile(
            key: const ValueKey('settings-immersive-forums'),
            leading: const Icon(Icons.chrome_reader_mode_outlined),
            title: Text(tr.immersiveReading.title),
            trailing: settingsTrailingValue(
              context,
              immersiveForums.all
                  ? tr.immersiveReading.allForums
                  : immersiveForums.exact.isEmpty && immersiveForums.withSubforums.isEmpty
                  ? ''
                  : tr.immersiveReading.forumCount(
                      count: immersiveForums.exact.length + immersiveForums.withSubforums.length,
                    ),
            ),
            onTap: () async {
              final result = await showImmersiveForumsDialog(context, immersiveForums);
              if (result == null || !context.mounted) return;
              final bloc = context.read<SettingsBloc>();
              if (result.raw != immersiveForums.raw) {
                bloc.add(SettingsValueChanged(SettingsKeys.immersiveForums, result.raw));
              }
              if (result.all != immersiveForums.all) {
                bloc.add(SettingsValueChanged(SettingsKeys.immersiveAllForums, result.all));
              }
            },
          ),
          SectionListTile(
            leading: const Icon(Icons.article_outlined),
            title: Text(tr.threadCard.title),
            subtitle: Text(tr.threadCard.detail),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.pushNamed(ScreenPaths.settingsThreadAppearance.path),
          ),
          SectionListTile(
            leading: const Icon(Icons.dashboard_customize_outlined),
            title: Text(tr.homeLayout.title),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.pushNamed(ScreenPaths.settingsHomeLayout.path),
          ),
          SectionSwitchListTile(
            secondary: const Icon(Icons.shortcut_outlined),
            title: Text(tr.showShortcutInForumCard.title),
            subtitle: Text(tr.showShortcutInForumCard.detail),
            value: showForumCardShortcut,
            onChanged: (v) async =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.showShortcutInForumCard, v)),
          ),
          SectionSwitchListTile(
            key: const ValueKey('settings-collapse-pinned-threads'),
            secondary: const Icon(Icons.push_pin_outlined),
            title: Text(tr.collapsePinnedThreads.title),
            value: s.collapsePinnedThreads,
            onChanged: (v) async =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.collapsePinnedThreads, v)),
          ),
          SectionSwitchListTile(
            key: const ValueKey('settings-two-pane-layout'),
            secondary: const Icon(Icons.vertical_split_outlined),
            title: Text(tr.twoPaneLayout.title),
            value: s.twoPaneLayout,
            onChanged: (v) async =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.twoPaneLayout, v)),
          ),
          SectionSwitchListTile(
            key: const ValueKey('settings-post-media-preview'),
            secondary: const Icon(Icons.smart_display_outlined),
            title: Text(tr.postMediaPreview.title),
            value: s.postMediaPreview,
            onChanged: (v) async =>
                context.read<SettingsBloc>().add(SettingsValueChanged(SettingsKeys.postMediaPreview, v)),
          ),
          if (isAndroid || isIOS)
            SectionListTile(
              key: const ValueKey('settings-app-icon'),
              leading: const Icon(Icons.apps_outlined),
              title: Text(tr.appIcon.title),
              trailing: Image.asset(
                AppIcon.fromStoredName(s.appIcon).previewAsset,
                width: 32,
                height: 32,
                errorBuilder: (_, _, _) => const SizedBox(width: 32, height: 32),
              ),
              onTap: () async {
                final bloc = context.read<SettingsBloc>();
                final picked = await showSelectAppIconDialog(context, AppIcon.fromStoredName(s.appIcon));
                if (picked == null) return;
                bloc.add(SettingsValueChanged(SettingsKeys.appIcon, picked.storedName));
              },
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
    },
  );
}
