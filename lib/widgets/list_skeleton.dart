import 'package:flutter/material.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/loading_shimmer.dart';

/// A rounded opaque block standing for a line of text, a picture or a chip while a page loads, painted by the
/// [LoadingShimmer] around it.
///
/// [width] null fills the room ([widthFactor] of it when set).
class SkeletonBlock extends StatelessWidget {
  /// Constructor.
  const SkeletonBlock({this.width, this.widthFactor, this.height = 14, this.radius = 6, super.key});

  /// Width, the whole room when null.
  final double? width;

  /// Part of the room taken when [width] is null.
  final double? widthFactor;

  /// Height.
  final double height;

  /// Corner radius.
  final double radius;

  @override
  Widget build(BuildContext context) {
    final block = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width ?? double.infinity,
        height: height,
        child: const ColoredBox(color: Colors.white),
      ),
    );
    if (width != null || widthFactor == null) {
      return block;
    }
    return FractionallySizedBox(alignment: AlignmentDirectional.centerStart, widthFactor: widthFactor, child: block);
  }
}

/// A card of a list that is still loading: the surface of the cards with a leading square ([leading], its size) and
/// lines of text ([lines], the part of the width each takes), optionally a row of [pills] under them.
class SkeletonCard extends StatelessWidget {
  /// Constructor.
  const SkeletonCard({this.leading, this.lines = const [1, 0.6], this.pills = 0, super.key});

  /// Size of the leading square, none when null.
  final double? leading;

  /// The part of the width each line of text takes.
  final List<double> lines;

  /// Number of small pills (author, time, counters) under the lines.
  final int pills;

  @override
  Widget build(BuildContext context) {
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, factor) in lines.indexed) ...[
          if (i > 0) sizedBoxW8H8,
          SkeletonBlock(widthFactor: factor, height: i == 0 ? 16 : 14),
        ],
        if (pills > 0) ...[
          sizedBoxW12H12,
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (var i = 0; i < pills; i++) SkeletonBlock(width: i == 0 ? 72 : 52, height: 20, radius: 10)],
          ),
        ],
      ],
    );
    return AppSurface(
      child: LoadingShimmer(
        child: leading == null
            ? text
            : Row(
                children: [
                  SkeletonBlock(width: leading, height: leading!, radius: appInnerRadius),
                  sizedBoxW12H12,
                  Expanded(child: text),
                ],
              ),
      ),
    );
  }
}

/// Tells assistive technologies that the page is loading, its skeleton [child] left out of the semantics tree.
class SkeletonSemantics extends StatelessWidget {
  /// Constructor.
  const SkeletonSemantics({required this.child, super.key});

  /// The skeleton.
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    label: context.t.loadState.loading,
    liveRegion: true,
    child: ExcludeSemantics(child: child),
  );
}

/// The skeleton of a list of thread cards while its first page loads: [count] cards in the list's centered column,
/// shimmering unless the system asks for less motion. Takes the place of the spinner over the whole page.
class ThreadListSkeleton extends StatelessWidget {
  /// Constructor.
  const ThreadListSkeleton({this.count = 8, super.key});

  /// Number of cards.
  final int count;

  @override
  Widget build(BuildContext context) => SkeletonSemantics(
    child: AppCenteredList(
      builder: (context, side, _) => ListView.separated(
        physics: const NeverScrollableScrollPhysics(),
        padding: side.copyWith(top: 8, bottom: 8),
        itemCount: count,
        itemBuilder: (_, index) => SkeletonCard(lines: index.isEven ? const [1, 0.55] : const [0.85], pills: 3),
        separatorBuilder: (_, _) => appListSeparator,
      ),
    ),
  );
}
