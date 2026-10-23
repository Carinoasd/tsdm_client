import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';

/// Corner radius of the content surfaces of the app, the homepage cards included.
const appSurfaceRadius = 18.0;

/// Corner radius of the small inner blocks of a surface (tool buttons, tags, quoted blocks).
const appInnerRadius = 12.0;

/// Widest a list of threads, forums or other rows grows; wider windows center it.
const appListMaxWidth = 960.0;

/// Widest the floors of a thread grow, so lines stay readable on desktop windows.
const appReadingMaxWidth = 920.0;

/// Widest a form or a detail page (profile, settings like pages) grows.
const appFormMaxWidth = 760.0;

/// Gap between two surfaces of a list on phones.
const appSurfaceGapCompact = 8.0;

/// Gap between two surfaces of a list on wider windows.
const appSurfaceGap = 12.0;

/// Window width from which pages may use a second column.
const appTwoColumnWidth = 840.0;

/// Shape shared by the content surfaces: rounded, with a hairline border in the theme's outline variant.
ShapeBorder appSurfaceShape(BuildContext context) => appSurfaceShapeOf(Theme.of(context).colorScheme);

/// [appSurfaceShape] for a [colorScheme], used to build the app theme.
RoundedRectangleBorder appSurfaceShapeOf(ColorScheme colorScheme) => RoundedRectangleBorder(
  borderRadius: BorderRadius.circular(appSurfaceRadius),
  side: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.6)),
);

/// Horizontal padding of page content for the available [width]: tighter on phones.
double appPagePadding(double width) => width < 600 ? 12 : 16;

/// A rounded content surface: the card of the homepage, reusable by every page.
///
/// Tappable when [onTap] or [onLongPress] is set; [padding] is applied inside the ink area.
class AppSurface extends StatelessWidget {
  /// Constructor.
  const AppSurface({
    required this.child,
    this.padding = edgeInsetsL16T12R16B12,
    this.onTap,
    this.onLongPress,
    this.color,
    this.margin = EdgeInsets.zero,
    super.key,
  });

  /// Content.
  final Widget child;

  /// Padding around [child].
  final EdgeInsetsGeometry padding;

  /// Tap callback.
  final VoidCallback? onTap;

  /// Long press callback.
  final VoidCallback? onLongPress;

  /// Background, the card color of the theme when null.
  final Color? color;

  /// Outer margin.
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final content = Padding(padding: padding, child: child);
    return Card(
      margin: margin,
      clipBehavior: Clip.antiAlias,
      shape: appSurfaceShape(context),
      color: color,
      child: onTap == null && onLongPress == null
          ? content
          : InkWell(onTap: onTap, onLongPress: onLongPress, child: content),
    );
  }
}

/// Title of a section inside a page or a surface: bold title, optional leading icon and trailing action.
class AppSectionHeader extends StatelessWidget {
  /// Constructor.
  const AppSectionHeader(
    this.title, {
    this.icon,
    this.trailing,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
    super.key,
  });

  /// Section title.
  final String title;

  /// Optional leading icon.
  final IconData? icon;

  /// Optional action at the end, usually a text button.
  final Widget? trailing;

  /// Padding around the header.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: padding,
      child: Row(
        children: [
          if (icon != null) ...[Icon(icon, size: 20, color: colorScheme.primary), sizedBoxW8H8],
          Expanded(
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Keeps [child] at most [maxWidth] wide and centered horizontally, for lists and pages on wide windows.
///
/// Phones are not affected: the constraint only matters once the window is wider than [maxWidth].
class AppContentWidth extends StatelessWidget {
  /// Constructor.
  const AppContentWidth({required this.child, this.maxWidth = appListMaxWidth, super.key});

  /// Content.
  final Widget child;

  /// Widest [child] grows.
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: child,
    ),
  );
}

/// Horizontal padding that centers content of at most [maxWidth] in a window of [width], at least [minPadding].
///
/// Use it as the padding of a scroll view so the scrollbar and the pull to refresh area keep the full width while the
/// rows stay readable.
EdgeInsets appCenteredPadding(double width, {double maxWidth = appListMaxWidth, double? minPadding}) {
  final min = minPadding ?? appPagePadding(width);
  final side = (width - maxWidth) / 2;
  final horizontal = side > min ? side : min;
  return EdgeInsets.symmetric(horizontal: horizontal);
}

/// Builds a scroll view whose rows are centered and at most [maxWidth] wide in the room the page really has.
///
/// [builder] gets the horizontal padding to use for the scroll view (see [appCenteredPadding]) and the full width of
/// the page (to choose a number of columns, see [appColumnsFor]); the scroll view
/// itself keeps the full width so scrolling, the scrollbar and pull to refresh work anywhere in the page. The room is
/// measured, not taken from the window, so a navigation rail or drawer beside the page is accounted for.
class AppCenteredList extends StatelessWidget {
  /// Constructor.
  const AppCenteredList({required this.builder, this.maxWidth = appListMaxWidth, super.key});

  /// Builds the scroll view with the given horizontal padding, knowing the full width of the page.
  final Widget Function(BuildContext context, EdgeInsets horizontalPadding, double width) builder;

  /// Widest the rows grow.
  final double maxWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) =>
        builder(context, appCenteredPadding(constraints.maxWidth, maxWidth: maxWidth), constraints.maxWidth),
  );
}

/// Separator between the surfaces of a list.
const appListSeparator = SizedBox(height: appSurfaceGapCompact);

/// Number of card columns that fit in [width]: one on phones, two from [appTwoColumnWidth].
int appColumnsFor(double width) => width >= appTwoColumnWidth ? 2 : 1;

/// Number of rows needed for [count] cards in [columns] columns.
int appRowCount(int count, int columns) => (count + columns - 1) ~/ columns;

/// One row of a card grid: the cards [row] * [columns] ... of the [count] cards built by [itemBuilder], top aligned.
///
/// Cards keep their own height; the last row is padded with empty room so every column keeps the same width.
class AppColumnsRow extends StatelessWidget {
  /// Constructor.
  const AppColumnsRow({
    required this.row,
    required this.columns,
    required this.count,
    required this.itemBuilder,
    this.gap = appSurfaceGapCompact,
    super.key,
  });

  /// Row index.
  final int row;

  /// Number of columns.
  final int columns;

  /// Total number of cards.
  final int count;

  /// Builds the card at an index.
  final IndexedWidgetBuilder itemBuilder;

  /// Gap between the columns.
  final double gap;

  @override
  Widget build(BuildContext context) {
    if (columns <= 1) {
      return itemBuilder(context, row);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var column = 0; column < columns; column++) ...[
          if (column > 0) SizedBox(width: gap),
          Expanded(
            child: row * columns + column < count ? itemBuilder(context, row * columns + column) : sizedBoxEmpty,
          ),
        ],
      ],
    );
  }
}

/// Empty, failure or informational state of a page or a section: icon, message, optional action.
///
/// Uses only data the caller provides; the message is expected to be a translated text.
class AppStateView extends StatelessWidget {
  /// Constructor.
  const AppStateView({
    required this.message,
    this.detail,
    this.icon = Icons.inbox_outlined,
    this.action,
    this.error = false,
    this.scrollable = true,
    super.key,
  });

  /// Message to show.
  final String message;

  /// Optional second line under [message]: why the page is empty, how something gets in it.
  final String? detail;

  /// Leading illustration icon.
  final IconData icon;

  /// Optional action, usually a retry button.
  final Widget? action;

  /// Use the error colors.
  final bool error;

  /// Scroll by itself when the room is too small.
  ///
  /// Set to false when the view is already inside a scroll view (e.g. to keep pull to refresh on an empty list).
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final content = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: error ? colorScheme.errorContainer : colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(appSurfaceRadius),
            ),
            child: SizedBox(
              width: 64,
              height: 64,
              child: Icon(icon, size: 32, color: error ? colorScheme.onErrorContainer : colorScheme.outline),
            ),
          ),
          sizedBoxW16H16,
          Text(
            message,
            textAlign: TextAlign.center,
            style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          if (detail != null) ...[
            sizedBoxW8H8,
            Text(
              detail!,
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(color: colorScheme.outline),
            ),
          ],
          if (action != null) ...[sizedBoxW16H16, action!],
        ],
      ),
    );
    if (!scrollable) {
      return Center(
        child: Padding(padding: edgeInsetsL24T24R24B24, child: content),
      );
    }
    return Center(
      child: SingleChildScrollView(padding: edgeInsetsL24T24R24B24, child: content),
    );
  }
}

/// [AppStateView] filling the viewport of a scroll view with the given [physics], so an empty list keeps its pull to
/// refresh.
class AppScrollableStateView extends StatelessWidget {
  /// Constructor.
  const AppScrollableStateView({required this.physics, required this.child, super.key});

  /// Physics of the scroll view, usually given by the refresh wrapper.
  final ScrollPhysics? physics;

  /// State view, built with `scrollable: false`.
  final AppStateView child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      physics: physics,
      child: ConstrainedBox(
        constraints: BoxConstraints(minWidth: constraints.maxWidth, minHeight: constraints.maxHeight),
        child: child,
      ),
    ),
  );
}

/// Rounded square holding an icon: the leading block of a row in a surface (notices, sections, summaries).
class AppIconTile extends StatelessWidget {
  /// Constructor.
  const AppIconTile(this.icon, {this.size = 40, this.color, this.foregroundColor, super.key});

  /// Icon to show.
  final IconData icon;

  /// Width and height of the block.
  final double size;

  /// Background, the secondary container of the theme when null.
  final Color? color;

  /// Icon color, the on secondary container color of the theme when null.
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(appInnerRadius),
      ),
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(icon, size: size / 2, color: foregroundColor ?? colorScheme.onSecondaryContainer),
      ),
    );
  }
}

/// Small rounded piece of meta information (author, forum, time, counter) under the title of a card.
///
/// Wraps to several lines instead of overflowing when the text is long or the font is large.
class AppInfoPill extends StatelessWidget {
  /// Constructor.
  const AppInfoPill({required this.icon, required this.label, this.tooltip, this.large = false, super.key});

  /// Leading icon.
  final IconData icon;

  /// Text.
  final String label;

  /// Optional tooltip and semantic label explaining the value, for numbers without a caption.
  final String? tooltip;

  /// Bigger icon, text and padding, for cards shown large on wide windows.
  final bool large;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(appInnerRadius),
      ),
      child: Padding(
        padding: large
            ? const EdgeInsets.symmetric(horizontal: 10, vertical: 5)
            : const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: large ? 17 : 14, color: colorScheme.outline),
            SizedBox(width: large ? 6 : 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: (large ? textTheme.labelLarge : textTheme.labelSmall)?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (tooltip == null) {
      return pill;
    }
    return Tooltip(message: tooltip, child: pill);
  }
}

/// A group of form fields or settings inside a surface, with an optional section title.
///
/// The children are stacked with [gap] between them; each keeps its own width, text fields fill the surface.
class AppFormSection extends StatelessWidget {
  /// Constructor.
  const AppFormSection({
    required this.children,
    this.title,
    this.icon,
    this.trailing,
    this.gap = 12,
    this.padding = edgeInsetsL16T12R16B12,
    super.key,
  });

  /// Section title, no header when null.
  final String? title;

  /// Optional icon of the title.
  final IconData? icon;

  /// Optional action at the end of the title.
  final Widget? trailing;

  /// Fields of the section.
  final List<Widget> children;

  /// Room between two children.
  final double gap;

  /// Padding inside the surface.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => AppSurface(
    padding: padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (title != null)
          AppSectionHeader(title!, icon: icon, trailing: trailing, padding: const EdgeInsets.only(bottom: 8)),
        for (var i = 0; i < children.length; i++) ...[if (i > 0) SizedBox(height: gap), children[i]],
      ],
    ),
  );
}

/// Rounded block inside a surface: quoted text, the frame of an editor, the body of an embedded card.
class AppInsetBlock extends StatelessWidget {
  /// Constructor.
  const AppInsetBlock({
    required this.child,
    this.padding = edgeInsetsL12T8R12B8,
    this.color,
    this.outlined = false,
    super.key,
  });

  /// Content.
  final Widget child;

  /// Padding around [child].
  final EdgeInsetsGeometry padding;

  /// Background, the low surface container of the theme when null.
  final Color? color;

  /// Draw the hairline border of the surfaces.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(appInnerRadius),
        border: outlined ? Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.6)) : null,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

/// Tone of an [AppNoticeBanner].
enum AppNoticeTone {
  /// Neutral information.
  info,

  /// Something limits what the user can do (closed thread, blocked content).
  warning,

  /// Something failed or was refused.
  error,
}

/// One line (or a few) notice inside a page or a surface: icon, message, optional actions.
///
/// Used for the soft closed hint of a thread, a blocked floor, refused forms. The colors follow [tone].
class AppNoticeBanner extends StatelessWidget {
  /// Constructor.
  const AppNoticeBanner({
    required this.message,
    this.title,
    this.icon,
    this.tone = AppNoticeTone.info,
    this.actions = const [],
    this.selectable = false,
    this.child,
    super.key,
  });

  /// Optional bold first line.
  final String? title;

  /// Message.
  final String message;

  /// Optional content under the message (rendered html of the forum…), before the [actions].
  final Widget? child;

  /// Leading icon, chosen from [tone] when null.
  final IconData? icon;

  /// Colors of the banner.
  final AppNoticeTone tone;

  /// Buttons under the message.
  final List<Widget> actions;

  /// Let the user select and copy the message (forum messages).
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final (Color background, Color foreground, IconData defaultIcon) = switch (tone) {
      AppNoticeTone.info => (colorScheme.secondaryContainer, colorScheme.onSecondaryContainer, Icons.info_outline),
      AppNoticeTone.warning => (
        colorScheme.tertiaryContainer,
        colorScheme.onTertiaryContainer,
        Icons.lock_clock_outlined,
      ),
      AppNoticeTone.error => (colorScheme.errorContainer, colorScheme.onErrorContainer, Icons.error_outline),
    };
    final messageStyle = textTheme.bodyMedium?.copyWith(color: foreground);
    return AppInsetBlock(
      color: background,
      padding: edgeInsetsL12T12R12B12,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? defaultIcon, size: 20, color: foreground),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null) ...[
                  Text(
                    title!,
                    style: textTheme.titleSmall?.copyWith(color: foreground, fontWeight: FontWeight.bold),
                  ),
                  sizedBoxW4H4,
                ],
                if (selectable) SelectableText(message, style: messageStyle) else Text(message, style: messageStyle),
                if (child != null) ...[sizedBoxW4H4, child!],
                if (actions.isNotEmpty) ...[
                  sizedBoxW8H8,
                  Wrap(spacing: 8, runSpacing: 4, children: actions),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Background of an [AppEmbedCard] for the nesting [elevation] the HTML renderer gives its embedded cards.
///
/// Top level blocks (elevation 0 or null) use the low surface container, nested ones a higher container, so a block
/// inside another one stays distinct without shadows.
Color appEmbedColor(BuildContext context, double? elevation) {
  final colorScheme = Theme.of(context).colorScheme;
  return (elevation ?? 0) > 0.1 ? colorScheme.surfaceContainerHigh : colorScheme.surfaceContainerLow;
}

/// Frame of a special block embedded in a floor (locked content, poll, red packet, rate, bounty, code…).
///
/// A tinted rounded block with a header row (icon tile, bold title, optional subtitle and trailing widget) and the
/// [child] under it. Keeps the reading width of the floor; nothing is clipped, long titles wrap.
class AppEmbedCard extends StatelessWidget {
  /// Constructor.
  const AppEmbedCard({
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.child,
    this.accent,
    this.color,
    this.margin = const EdgeInsets.symmetric(vertical: 4),
    super.key,
  });

  /// Background of the block, the low surface container of the theme when null.
  ///
  /// Blocks nested in another block (a locked area inside a spoiler) pass a higher container to stand out.
  final Color? color;

  /// Icon of the header.
  final IconData icon;

  /// Title of the header.
  final String title;

  /// Optional second line of the header.
  final String? subtitle;

  /// Optional widget at the end of the header.
  final Widget? trailing;

  /// Body.
  final Widget? child;

  /// Background of the icon tile, the secondary container of the theme when null.
  final Color? accent;

  /// Outer margin.
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: margin,
      child: AppInsetBlock(
        outlined: true,
        color: color,
        padding: edgeInsetsL12T12R12B12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                AppIconTile(icon, size: 32, color: accent),
                sizedBoxW8H8,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
                      if (subtitle != null)
                        Text(subtitle!, style: textTheme.labelSmall?.copyWith(color: colorScheme.outline)),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            if (child != null) ...[sizedBoxW8H8, child!],
          ],
        ),
      ),
    );
  }
}

/// Bar pinned under a form: hairline on top, content centered at most [maxWidth] wide, above the system insets.
class AppBottomActionBar extends StatelessWidget {
  /// Constructor.
  const AppBottomActionBar({required this.child, this.maxWidth = appFormMaxWidth, super.key});

  /// Usually the submit button, maybe with a status line above it.
  final Widget child;

  /// Widest [child] grows.
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.6))),
      ),
      child: SafeArea(
        top: false,
        child: AppContentWidth(
          maxWidth: maxWidth,
          child: Padding(padding: edgeInsetsL16T12R16B12, child: child),
        ),
      ),
    );
  }
}

/// Title of a dialog: icon tile and a title that wraps instead of being cut.
///
/// Built from a [Row] with an [Expanded] text only, no [LayoutBuilder], so it is safe in the intrinsic layout of an
/// [AlertDialog]. [error] uses the error container colors (destructive confirmations).
class AppDialogTitle extends StatelessWidget {
  /// Constructor.
  const AppDialogTitle({
    required this.icon,
    required this.title,
    this.error = false,
    this.singleLine = false,
    super.key,
  });

  /// Icon of the tile.
  final IconData icon;

  /// Title text.
  final String title;

  /// Use the error colors.
  final bool error;

  /// Keep the title on one line, shrinking its text when the dialog is too narrow, instead of wrapping.
  final bool singleLine;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final text = singleLine
        ? FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(title, maxLines: 1),
          )
        : Text(title);
    return Row(
      children: [
        AppIconTile(
          icon,
          size: 36,
          color: error ? colorScheme.errorContainer : null,
          foregroundColor: error ? colorScheme.onErrorContainer : null,
        ),
        sizedBoxW12H12,
        Expanded(child: text),
      ],
    );
  }
}

/// A group of setting like rows (list tiles, switches) in one surface: optional section header, rows separated by
/// hairlines, optional footer (a notice) under them.
///
/// The rows keep their own ink; the surface clips it to the rounded corners. Use one group per section of a settings
/// or a details page instead of loose tiles on the page ground.
class AppTileGroup extends StatelessWidget {
  /// Constructor.
  const AppTileGroup({required this.children, this.title, this.icon, this.trailing, this.footer, super.key});

  /// Section title, no header when null.
  final String? title;

  /// Icon of the header.
  final IconData? icon;

  /// Optional action at the end of the header.
  final Widget? trailing;

  /// Rows of the group.
  final List<Widget> children;

  /// Optional block under the rows, usually an [AppNoticeBanner].
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final divider = Divider(
      height: 1,
      thickness: 1,
      indent: 16,
      endIndent: 16,
      color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4),
    );
    return AppSurface(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null)
            AppSectionHeader(
              title!,
              icon: icon,
              trailing: trailing,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            ),
          for (var i = 0; i < children.length; i++) ...[if (i > 0) divider, children[i]],
          if (footer != null) Padding(padding: edgeInsetsL12T4R12B12, child: footer),
          if (footer == null && title != null) const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// Filled, rounded decoration of the form fields of pages and dialogs; helper and error texts may wrap.
InputDecoration appFieldDecoration({String? label, String? hint, String? helper, IconData? icon, Widget? suffix}) =>
    InputDecoration(
      labelText: label,
      hintText: hint,
      helperText: helper,
      helperMaxLines: 3,
      errorMaxLines: 3,
      prefixIcon: icon == null ? null : Icon(icon),
      suffixIcon: suffix,
      filled: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(appInnerRadius)),
    );

/// Borderless filled decoration of the pickers (dropdowns) on page surfaces.
///
/// The floating label stays inside the filled area (Material filled style) instead of straddling an invisible outline
/// at the top edge; focus draws the usual bottom indicator. Every border state is set so the theme's outline borders
/// do not come back.
InputDecoration appPickerDecoration(BuildContext context, {required String label, IconData? icon}) {
  final radius = BorderRadius.circular(appInnerRadius);
  final none = UnderlineInputBorder(borderRadius: radius, borderSide: BorderSide.none);
  return InputDecoration(
    labelText: label,
    prefixIcon: icon == null ? null : Icon(icon),
    filled: true,
    contentPadding: const EdgeInsetsDirectional.fromSTEB(12, 10, 12, 10),
    border: none,
    enabledBorder: none,
    disabledBorder: none,
    focusedBorder: UnderlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: Theme.of(context).colorScheme.primary, width: 2),
    ),
  );
}

/// Page switcher of a paged result: previous, "current / total" (opens [onJump]) and next.
///
/// A null callback disables its button. Tooltips come from [MaterialLocalizations], no extra translation is needed.
class AppPager extends StatelessWidget {
  /// Constructor.
  const AppPager({
    required this.current,
    required this.total,
    this.onPrevious,
    this.onNext,
    this.onJump,
    super.key,
  });

  /// Current page, null when unknown.
  final int? current;

  /// Total pages, null when unknown.
  final int? total;

  /// Go to the previous page.
  final VoidCallback? onPrevious;

  /// Go to the next page.
  final VoidCallback? onNext;

  /// Pick a page.
  final VoidCallback? onJump;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final localizations = MaterialLocalizations.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(appInnerRadius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: localizations.previousPageTooltip,
            visualDensity: VisualDensity.compact,
            onPressed: onPrevious,
          ),
          TextButton(
            onPressed: onJump,
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
            child: Text('${current ?? '-'} / ${total ?? '-'}'),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: localizations.nextPageTooltip,
            visualDensity: VisualDensity.compact,
            onPressed: onNext,
          ),
        ],
      ),
    );
  }
}
