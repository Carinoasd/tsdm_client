import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/features/profile/bloc/my_titles_cubit.dart';
import 'package:tsdm_client/features/profile/models/secondary_title.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';

/// Card to show a secondary title, tap to use it.
///
/// The image keeps its natural 184x100 ratio inside the card padding (at most its natural width), the current title is
/// marked with an outline and a label below the name instead of a corner ribbon covering the image.
class SecondaryTitleCard extends StatelessWidget {
  /// Constructor.
  const SecondaryTitleCard(this.title, {super.key});

  /// The title.
  final SecondaryTitle title;

  @override
  Widget build(BuildContext context) {
    final activated = context.select<MyTitlesCubit, bool>(
      (cubit) => cubit.state.titles.firstWhereOrNull((e) => e.id == title.id)?.activated ?? false,
    );
    final loading = context.select<MyTitlesCubit, bool>((cubit) => cubit.state.status == MyTitlesStatus.switchingTitle);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      color: activated ? colorScheme.secondaryContainer : colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: activated ? colorScheme.primary : colorScheme.outlineVariant,
          width: activated ? 2 : 1,
        ),
      ),
      child: InkWell(
        onTap: loading || activated ? null : () async => context.read<MyTitlesCubit>().setSecondaryTitle(title.id),
        child: Padding(
          padding: edgeInsetsL12T12R12B12,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final badgeWidth = math.min(constraints.maxWidth, badgeImageSize.width);
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SecondaryTitleBadge(
                    title.imageUrl,
                    width: badgeWidth,
                    semanticLabel: context.displayText(title.name),
                  ),
                  sizedBoxW8H8,
                  Text(
                    context.displayText(title.name),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.labelLarge?.copyWith(
                      color: loading
                          ? colorScheme.outline
                          : activated
                          ? colorScheme.onSecondaryContainer
                          : null,
                      fontWeight: activated ? FontWeight.bold : null,
                    ),
                  ),
                  sizedBoxW4H4,
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (activated) ...[
                        Icon(Icons.check_circle, size: 16, color: colorScheme.primary),
                        sizedBoxW4H4,
                        Text(
                          context.t.myTitlesPage.current,
                          style: textTheme.labelMedium?.copyWith(color: colorScheme.primary),
                        ),
                        sizedBoxW8H8,
                      ],
                      Text('ID ${title.id}', style: textTheme.labelSmall?.copyWith(color: colorScheme.outline)),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
