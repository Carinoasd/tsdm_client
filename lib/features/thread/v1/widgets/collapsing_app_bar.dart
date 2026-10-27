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

/// Hides an app bar once the user scrolls a list down some way and shows it again once scrolled up as far, or at the
/// top of the list, through [controller] (1 shown, 0 hidden).
///
/// Fed with the scroll notifications of the list ([onNotification]); only the list itself counts (depth 0, vertical):
/// a code block or a table scrolled sideways in a floor never moves the bar.
///
/// The bar follows the distance scrolled, not the direction a drag starts in: a screen that loses and finds the finger
/// again, or a thumb that wobbles, scrolls a few pixels each way and used to pull the bar out and in at every turn.
/// Now the list has to travel [threshold] in one direction since it last turned before the bar follows.
class AppBarCollapser {
  /// Constructor.
  AppBarCollapser(this.controller);

  /// How far the list travels in one direction before the bar follows, in logical pixels: about the height of the
  /// bar, well past the jitter of a flaky touch screen, short enough that a real scroll up shows the bar at once.
  static const double threshold = 56;

  /// The shown part of the bar.
  final AnimationController controller;

  /// Distance the list travelled in the direction it last moved: positive down the list (to later floors), negative
  /// up. Starts over when the list turns.
  double _travel = 0;

  /// Whether the user is scrolling the list (a drag, the fling after it), as the list told last. The list placing
  /// itself (a jump to a floor, back to the reading position, a page loaded above) is not the user and never moves
  /// the bar, as before.
  bool _userScrolling = false;

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
      _travel = 0;
      show();
      return false;
    }
    if (notification is UserScrollNotification) {
      _userScrolling = notification.direction != ScrollDirection.idle;
      return false;
    }
    if (notification is! ScrollUpdateNotification) {
      return false;
    }
    final metrics = notification.metrics;
    if (metrics.pixels <= metrics.minScrollExtent) {
      // Back at the top of the list (a drag, a fling, back to top): the bar too, however it got there.
      _travel = 0;
      show();
      return false;
    }
    if (!_userScrolling) {
      return false;
    }
    // Positive: the list goes down to later floors (the finger moves up). A turn starts the travel over.
    final delta = notification.scrollDelta ?? 0;
    if (delta == 0) {
      return false;
    }
    _travel = _travel.sign == delta.sign ? _travel + delta : delta;
    if (_travel >= threshold) {
      // A list that scrolls no farther than the bar keeps it (see [barHeight]).
      if (metrics.maxScrollExtent - metrics.minScrollExtent > barHeight) {
        hide();
      }
    } else if (_travel <= -threshold) {
      show();
    }
    return false;
  }
}
