import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// The app bar [child] of a page, shown in part: [shown] of its height, 1 the whole bar, 0 none of it (the status bar
/// area above it stays, in the bar's colors).
///
/// The bar keeps its own height and is cut at the bottom, so the breadcrumbs under the title go first and the title
/// after them: it rolls up under the status bar.
class CollapsingAppBar extends StatelessWidget implements PreferredSizeWidget {
  /// Constructor.
  const CollapsingAppBar({required this.shown, required this.child, super.key});

  /// Shown part of the bar, from 0 to 1.
  final double shown;

  /// The bar.
  final PreferredSizeWidget child;

  @override
  Size get preferredSize => Size.fromHeight(child.preferredSize.height * shown.clamp(0, 1));

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final full = child.preferredSize.height + top;
    return SizedBox(
      height: preferredSize.height + top,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topCenter,
          minHeight: full,
          maxHeight: full,
          child: child,
        ),
      ),
    );
  }
}

/// Hides an app bar while the user scrolls a list down and shows it again when scrolling up or at the top of the
/// list, through [controller] (1 shown, 0 hidden).
///
/// Fed with the scroll notifications of the list ([onNotification]); only the list itself counts (depth 0, vertical):
/// a code block or a table scrolled sideways in a floor never moves the bar.
class AppBarCollapser {
  /// Constructor.
  AppBarCollapser(this.controller);

  /// The shown part of the bar.
  final AnimationController controller;

  /// Whether the bar hides at all (the `collapseAppBarWhenScroll` setting); when false it is always shown.
  bool enabled = true;

  /// Height of the bar: a list that scrolls no farther than that keeps the bar (hiding it would only make room that
  /// the list cannot fill, and the bar would come and go at every drag).
  double barHeight = 0;

  /// Show the whole bar.
  void show() {
    if (controller.value < 1 && controller.status != AnimationStatus.forward) {
      unawaited(controller.forward());
    }
  }

  /// Hide the bar.
  void hide() {
    if (controller.value > 0 && controller.status != AnimationStatus.reverse) {
      unawaited(controller.reverse());
    }
  }

  /// Handle the scroll [notification] of the list; never stops it.
  bool onNotification(ScrollNotification notification) {
    if (notification.depth != 0 || notification.metrics.axis != Axis.vertical) {
      return false;
    }
    if (!enabled) {
      show();
      return false;
    }
    if (notification is UserScrollNotification) {
      // Told when the drag starts, still at the offset it starts from: the direction decides.
      switch (notification.direction) {
        case ScrollDirection.reverse:
          // The finger moves up: the list goes down to later floors.
          final metrics = notification.metrics;
          if (metrics.maxScrollExtent - metrics.minScrollExtent > barHeight) {
            hide();
          }
        case ScrollDirection.forward:
          show();
        case ScrollDirection.idle:
          break;
      }
    } else if (notification is ScrollUpdateNotification &&
        notification.metrics.pixels <= notification.metrics.minScrollExtent) {
      // Back at the top of the list (a fling, back to top): the bar too.
      show();
    }
    return false;
  }
}
