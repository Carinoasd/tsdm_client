import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/list_skeleton.dart';
import 'package:tsdm_client/widgets/loading_shimmer.dart';

/// Placeholder widget for topics page.
///
/// The skeleton of the forum list while it loads the first time: a row of group tabs, then forum cards (icon, name,
/// counters) in the list's centered column.
class TopicsPlaceholder extends StatelessWidget {
  /// Constructor.
  const TopicsPlaceholder({this.count = 8, super.key});

  /// Number of forum cards.
  final int count;

  @override
  Widget build(BuildContext context) {
    return SkeletonSemantics(
      child: AppCenteredList(
        builder: (context, side, _) => ListView.separated(
          physics: const NeverScrollableScrollPhysics(),
          padding: side.copyWith(top: 8, bottom: 16),
          itemCount: count + 1,
          itemBuilder: (context, index) => index == 0
              ? const Padding(
                  padding: edgeInsetsT4B4,
                  child: LoadingShimmer(
                    child: Row(
                      children: [
                        SkeletonBlock(width: 72, height: 28, radius: 14),
                        sizedBoxW8H8,
                        SkeletonBlock(width: 72, height: 28, radius: 14),
                        sizedBoxW8H8,
                        SkeletonBlock(width: 72, height: 28, radius: 14),
                        sizedBoxW8H8,
                        SkeletonBlock(width: 56, height: 28, radius: 14),
                      ],
                    ),
                  ),
                )
              : SkeletonCard(leading: 40, lines: index.isEven ? const [0.45, 0.8] : const [0.6, 0.7]),
          separatorBuilder: (context, index) => appListSeparator,
        ),
      ),
    );
  }
}
