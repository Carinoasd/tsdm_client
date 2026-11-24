import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/uri.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/themes/app_surfaces.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';

/// What heads the floors of a thread: its place in the forum (a kicker, the forum it is in stressed), its title, and
/// a line of its figures: the thread type (opens the forum's threads of that type), views and replies, draft, the
/// local replied mark, and at the end the thread id ([onTapId]: the copy dialog).
///
/// It scrolls with the floors, at the top of the thread; the app bar keeps the title for when it is scrolled away.
class ThreadTitleHeader extends StatelessWidget {
  /// Constructor.
  const ThreadTitleHeader({
    required this.state,
    required this.title,
    required this.replied,
    required this.onTapId,
    super.key,
  });

  /// The thread.
  final ThreadState state;

  /// Title of the thread (the one the page was opened with until the thread is loaded).
  final String title;

  /// The current account replied in the thread (local mark, issue #21).
  final bool replied;

  /// The thread id was tapped.
  final VoidCallback onTapId;

  /// Width from which the title takes its larger size.
  static const wideWidth = 600.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final surfaces = AppSurfaces.of(context);
    final kickerStyle = textTheme.bodySmall?.copyWith(fontSize: 12.5, height: 1.4, color: colorScheme.onSurfaceVariant);
    final metaStyle = textTheme.bodySmall?.copyWith(
      fontSize: 12.5,
      height: 1.4,
      color: surfaces.muted,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final wide = MediaQuery.sizeOf(context).width >= wideWidth;

    Widget link(Widget child, {required VoidCallback onTap, Key? key}) => MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Semantics(
        link: true,
        child: GestureDetector(key: key, behavior: HitTestBehavior.opaque, onTap: onTap, child: child),
      ),
    );

    Widget iconText(IconData icon, String text, {Color? color}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color ?? surfaces.muted),
        sizedBoxW4H4,
        Flexible(
          child: Text(text, style: color == null ? metaStyle : metaStyle?.copyWith(color: color)),
        ),
      ],
    );

    final crumbs = state.breadcrumbs;
    final kicker = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final (index, e) in crumbs.indexed) ...[
          if (index > 0) Icon(Symbols.chevron_right_rounded, size: 16, color: colorScheme.onSurfaceVariant),
          link(
            key: ValueKey('thread-header-crumb-$index'),
            // The forum the thread is in, in the accent; the ones above it quiet.
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                e.description,
                style: index == crumbs.length - 1
                    ? kickerStyle?.copyWith(color: colorScheme.primary, fontWeight: FontWeight.bold)
                    : kickerStyle,
              ),
            ),
            onTap: () async {
              final gid = e.link.tryGetQueryParameters()?['gid'];
              if (gid != null) {
                await context.pushNamed(
                  ScreenPaths.forumGroup,
                  pathParameters: {'gid': gid},
                  queryParameters: {'title': e.description},
                );
                return;
              }
              await context.dispatchAsUrl(e.link.toString());
            },
          ),
        ],
      ],
    );

    final threadType = state.threadType;
    final typeID = threadType?.typeID;
    final fid = state.fid;
    final meta = Wrap(
      spacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (threadType != null && typeID != null && fid != null)
          link(
            key: const ValueKey('thread-header-type'),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Center(
                widthFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: surfaces.card, borderRadius: BorderRadius.circular(5)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    child: Text(
                      threadType.name,
                      style: metaStyle?.copyWith(fontSize: 12, color: colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
            ),
            onTap: () async => context.pushNamed(
              ScreenPaths.forum,
              pathParameters: {'fid': '$fid'},
              queryParameters: {'threadTypeName': threadType.name, 'threadTypeID': typeID},
            ),
          ),
        if (state.viewCount != null || state.replyCount != null)
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Center(
              widthFactor: 1,
              child: iconText(
                Symbols.bar_chart_rounded,
                context.t.threadPage.statistics(view: state.viewCount ?? 0, reply: state.replyCount ?? 0),
              ),
            ),
          ),
        if (state.isDraft) iconText(Symbols.edit_note_rounded, context.t.threadPage.draft),
        if (replied) iconText(Symbols.reply_rounded, context.t.threadPage.repliedMark, color: colorScheme.tertiary),
      ],
    );

    final id = link(
      key: const ValueKey('thread-header-tid'),
      ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
        child: Center(
          widthFactor: 1,
          child: iconText(Symbols.tag_rounded, '${context.t.threadPage.title} ${state.tid ?? ""}'),
        ),
      ),
      onTap: onTapId,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (crumbs.isNotEmpty) kicker,
        Text(
          context.displayText(title),
          style: textTheme.headlineSmall?.copyWith(
            fontSize: wide ? 28 : 22,
            height: 1.4,
            fontWeight: FontWeight.bold,
            color: colorScheme.onSurface,
          ),
        ),
        // The id at the end of the line of figures; below them when the line has no room for it.
        SizedBox(
          width: double.infinity,
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [meta, id],
          ),
        ),
      ],
    );
  }
}
