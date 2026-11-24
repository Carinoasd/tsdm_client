import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/text_widget_span.dart';

/// Table info in newcomer report table.
///
/// Each info occupies a row in table.
class NewcomerReportInfo {
  /// Constructor.
  NewcomerReportInfo({required this.title, required this.data, this.richData});

  /// Info title.
  final String title;

  /// Info data, may be empty string.
  ///
  /// Lines are separated by `\n`.
  final String data;

  /// The value as it is in the post, shown in place of [data] when not null.
  ///
  /// Set for a value with images (an image field of a threadsort), which has no text.
  final List<InlineSpan>? richData;
}

/// Card for newcomer report table in thread.
///
/// Only used in newcomer subreddit.
///
/// Field names are in a column on the left, as wide as the longest name but not wider than the website's `7em` or 60%
/// of the card. Values take the rest of the row and wrap, the card never scrolls horizontally. An empty value shows
/// "-" like the website does.
///
/// In a post the card sits in a [WidgetSpan], which already scales it by the text scale of the post: put it in the post
/// with [textWidgetSpan], or its text is scaled twice.
class NewcomerReportCard extends StatelessWidget {
  /// Constructor.
  const NewcomerReportCard(this.data, {this.title, super.key});

  /// Data in table.
  final List<NewcomerReportInfo> data;

  /// Title of the card, the one the forum renders above the table.
  ///
  /// Use the default title when null or empty.
  final String? title;

  /// Max width of the field name column in `em` of the text, the website uses `th{width:7em}`.
  static const _titleColumnMaxEm = 7.0;

  /// Max fraction of the card width taken by the field name column, leaves room for values on narrow screens.
  ///
  /// The website never wraps a field name (`th{white-space:nowrap}`). A name of six characters at a large text scale
  /// on a 320 px screen needs more than half of the card, the values keep at least 40%.
  static const _titleColumnMaxFraction = 0.6;

  static const _cellPadding = EdgeInsets.symmetric(horizontal: 8, vertical: 6);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueStyle = theme.textTheme.bodyMedium;
    final titleStyle = valueStyle?.copyWith(color: theme.colorScheme.secondary);
    final emptyStyle = valueStyle?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final titleColumnMaxWidth =
        MediaQuery.textScalerOf(context).scale(valueStyle?.fontSize ?? 14) * _titleColumnMaxEm +
        _cellPadding.horizontal;
    final cardTitle = title?.trim() ?? '';

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: edgeInsetsL12T12R12B12,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.article_outlined, color: theme.colorScheme.primary),
                sizedBoxW4H4,
                Flexible(
                  child: Text(
                    cardTitle.isNotEmpty ? cardTitle : context.t.html.newcomerReportCard.title,
                    style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
              ],
            ),
            sizedBoxW8H8,
            Table(
              columnWidths: <int, TableColumnWidth>{
                0: MinColumnWidth(
                  const IntrinsicColumnWidth(),
                  MinColumnWidth(
                    FixedColumnWidth(titleColumnMaxWidth),
                    const FractionColumnWidth(_titleColumnMaxFraction),
                  ),
                ),
                1: const FlexColumnWidth(),
              },
              children: data
                  .mapIndexed(
                    (idx, e) => TableRow(
                      decoration: BoxDecoration(color: idx.isOdd ? theme.colorScheme.surfaceContainerHigh : null),
                      children: [
                        Padding(
                          padding: _cellPadding,
                          child: Text(e.title, style: titleStyle),
                        ),
                        Padding(
                          padding: _cellPadding,
                          child: switch (e) {
                            NewcomerReportInfo(:final richData?) when richData.isNotEmpty => Text.rich(
                              TextSpan(children: richData),
                              style: valueStyle,
                            ),
                            NewcomerReportInfo(data: '') => Text('-', style: emptyStyle),
                            NewcomerReportInfo(:final data) => Text(data, style: valueStyle),
                          },
                        ),
                      ],
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}
