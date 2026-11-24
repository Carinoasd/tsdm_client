import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/cached_image/cached_image_provider.dart';

/// Widget to show the rate statistics for a post.
class RateCard extends StatelessWidget {
  /// Constructor.
  const RateCard(this.rate, this.pid, {super.key});

  /// Id of post the rate info lives on.
  final String pid;

  /// Rate model.
  final Rate rate;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final threadInfo = context.readOrNull<ThreadBloc>()?.state;
    final tid = threadInfo?.tid;
    final threadTitle = threadInfo?.title;
    final pid = this.pid;

    // Column width.
    // The first column is user info and last column is always "rate reason",
    // these two columns should have a flex column width.
    // The rest columns are always short enough to constrains in fixed width.
    final columnWidths = <int, TableColumnWidth>{
      for (final i in List.generate(rate.attrList.length - 1, (v) => v)) i + 1: const IntrinsicColumnWidth(),
    };
    columnWidths[0] = const FixedColumnWidth(150);
    columnWidths[rate.attrList.length + 1] = const FixedColumnWidth(200);

    // ,
    // Header cells: small bold labels in the outline color.
    final tableHeaders = [context.t.rateCard.user, ...rate.attrList]
        .map<Widget>(
          (e) => Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
            child: Text(
              e,
              style: textTheme.labelMedium?.copyWith(color: colorScheme.onSurfaceVariant, fontWeight: FontWeight.bold),
            ),
          ),
        )
        .toList();

    // Score cells keep the forum's text; only the sign picks the color (display only).
    Color scoreColor(String value) {
      final v = value.trim();
      if (v.startsWith('-')) {
        return colorScheme.error;
      }
      return v.isEmpty || v == '0' ? colorScheme.onSurfaceVariant : colorScheme.primary;
    }

    final tableContent = rate.records
        .mapIndexed(
          (idx, e) => TableRow(
            decoration: BoxDecoration(color: idx.isEven ? colorScheme.surfaceContainerHigh : null),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () async => context.dispatchAsUrl(e.user.url),
                      // TODO: Add hero here.
                      child: CircleAvatar(
                        radius: 16,
                        backgroundImage: CachedImageProvider(
                          e.user.avatarUrl ?? noAvatarUrl,
                          fallbackImageUrl: noAvatarUrl,
                          usage: ImageUsageInfoUserAvatar(e.user.name),
                        ),
                      ),
                    ),
                    sizedBoxW8H8,
                    Expanded(
                      child: GestureDetector(
                        onTap: () async => context.dispatchAsUrl(e.user.url),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            e.user.name,
                            textAlign: TextAlign.left,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.bodyMedium,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ...e.attrValueList.map(
                (e) => Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                  child: Text(e, style: textTheme.bodyMedium?.copyWith(color: scoreColor(e))),
                ),
              ),
            ],
          ),
        )
        .toList();

    return AppEmbedCard(
      icon: Icons.rate_review_outlined,
      title: context.t.rateCard.title(userCount: '${rate.userCount}'),
      subtitle: context.t.rateCard.total(total: rate.rateStatus ?? '-'),
      trailing: IconButton(
        icon: Icon(Icons.bar_chart_outlined, color: colorScheme.primary),
        tooltip: context.t.rateCard.viewAll,
        onPressed: tid == null
            ? null
            : () async => context.pushNamed(
                ScreenPaths.rateLog,
                pathParameters: {'tid': tid, 'pid': pid},
                queryParameters: {'threadTitle': threadTitle, 'total': rate.rateStatus},
              ),
      ),
      // The table scrolls sideways inside its own rounded block when there are many attributes.
      child: ClipRRect(
        borderRadius: BorderRadius.circular(appInnerRadius),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            columnWidths: columnWidths,
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            children: [
              TableRow(children: tableHeaders),
              ...tableContent,
            ],
          ),
        ),
      ),
    );
  }
}
