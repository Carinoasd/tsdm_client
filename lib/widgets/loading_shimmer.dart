import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

/// Widget to show a shimmer as data loading state.
///
/// The blocks of [child] (opaque shapes, see `SkeletonBlock`) are painted in the theme's quiet surface tones with a
/// light sweeping across them; the sweep stands still when the system asks for less motion ("remove animations").
class LoadingShimmer extends StatelessWidget {
  /// Constructor.
  const LoadingShimmer({required this.child, super.key});

  /// Shimmer shape widget.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Shimmer.fromColors(
      baseColor: colorScheme.surfaceContainerHighest,
      highlightColor: colorScheme.surfaceContainerLow,
      enabled: !reduceMotion,
      child: child,
    );
  }
}
