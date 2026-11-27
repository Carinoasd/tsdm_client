import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// The moderators of a forum group, as the site lists them in the group header ("分区版主: a, b"), GitHub #22.
///
/// Tapping a name opens that user's profile.
class GroupModeratorsRow extends StatelessWidget {
  /// Constructor.
  const GroupModeratorsRow({required this.moderators, this.large = false, super.key});

  /// Moderator names, in the site's order.
  final List<String> moderators;

  /// Bigger icon, label and chips, matching the large forum cards of the wide topics page.
  final bool large;

  @override
  Widget build(BuildContext context) {
    if (moderators.isEmpty) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final colors = groupModeratorsColors(theme);
    // A block in a soft tone of the primary color above the forum cards of the group (the list already gives the
    // side padding): shield icon, label, one rounded chip per name. With the faint line of the cards in a light
    // theme.
    return Padding(
      padding: EdgeInsets.only(bottom: large ? 12 : 8),
      child: DecoratedBox(
        key: const ValueKey('group-moderators'),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BorderRadius.circular(appInnerRadius),
          border: colors.line == null ? null : Border.all(color: colors.line!),
        ),
        child: Padding(
          padding: large ? const EdgeInsets.symmetric(horizontal: 16, vertical: 12) : edgeInsetsL12T8R12B8,
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: large ? 8 : 6,
            runSpacing: large ? 6 : 4,
            children: [
              Icon(Icons.admin_panel_settings_outlined, size: large ? 22 : 18, color: colors.foreground),
              Text(
                context.t.topicsPage.moderators,
                style: (large ? textTheme.titleSmall : textTheme.labelMedium)?.copyWith(
                  color: colors.foreground,
                  fontWeight: FontWeight.bold,
                ),
              ),
              for (final name in moderators)
                ActionChip(
                  avatar: Icon(Icons.person_outline, size: large ? 18 : 16, color: scheme.onSurfaceVariant),
                  label: Text(name),
                  visualDensity: large ? VisualDensity.standard : VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
                  side: BorderSide.none,
                  backgroundColor: colors.chip,
                  labelStyle: (large ? textTheme.labelLarge : textTheme.labelMedium)?.copyWith(color: scheme.onSurface),
                  onPressed: () async =>
                      context.pushNamed(ScreenPaths.profile, queryParameters: <String, String>{'username': name}),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The colors of [GroupModeratorsRow] in [theme], all opaque so the contrast on them is known:
///
/// * `background`: the primary container laid over the card color, 45% in a light theme and 35% in a dark one (the
///   tone of the greeting of the homepage, softer than the container itself);
/// * `foreground`: the icon and the label, the color on the primary container;
/// * `chip`: the ground of a name, the page color, with the on surface color on it;
/// * `line`: the faint line of the cards in a light theme, none in a dark one.
({Color background, Color foreground, Color chip, Color? line}) groupModeratorsColors(ThemeData theme) {
  final scheme = theme.colorScheme;
  final surfaces = AppSurfaces.ofTheme(theme);
  final dark = theme.brightness == Brightness.dark;
  return (
    background: Color.alphaBlend(scheme.primaryContainer.withValues(alpha: dark ? 0.35 : 0.45), surfaces.card),
    foreground: scheme.onPrimaryContainer,
    chip: surfaces.page,
    line: dark ? null : surfaces.line,
  );
}
