import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Where a list travelled far enough to: down the list (to later rows) or up.
enum ScrollTravelDirection {
  /// Down the list, the finger moving up.
  down,

  /// Up the list, the finger moving down.
  up,
}

/// Tells when the user scrolled a list some way in one direction, for what follows the scrolling (an app bar that
/// hides, a button that folds or goes): fed with the list's scroll notifications, [onNotification] answers
/// [ScrollTravelDirection.down] once the list travelled [threshold] down since it last turned, [ScrollTravelDirection.up]
/// once as far up, and null until then.
///
/// Following the direction every drag starts in instead (`UserScrollNotification.direction`) answers a touch screen
/// that loses and finds the finger again a few pixels away, or a thumb that wobbles, with the bar or button going out
/// and in at every turn. Only the user's scrolling counts (a drag, the fling after it): the list placing itself (a
/// jump to a row, back to a saved position, a page loaded above) is told by no `UserScrollNotification` and never
/// answers, nor does the bounce past an end of the list. Only vertical scrolling of the list the user is scrolling
/// counts (the one that told of the drag), not a list nested in it or around it moving in the same drag; the depth of
/// the notification is the caller's to check.
class ScrollTravel {
  /// Constructor.
  ScrollTravel({this.threshold = defaultThreshold});

  /// The usual [threshold]: about the height of an app bar, well past the jitter of a flaky touch screen, short enough
  /// that a real scroll answers at once.
  static const double defaultThreshold = 56;

  /// How far the list travels in one direction before [onNotification] answers, in logical pixels.
  final double threshold;

  /// Distance the list travelled in the direction it last moved: positive down the list, negative up. Starts over when
  /// the list turns.
  double _travel = 0;

  /// The list the user is scrolling, as the list told last (`UserScrollNotification`, with its scrollable's context):
  /// only its updates count, not those of a list nested in it or around it that moves in the same drag. Null while
  /// no list is.
  BuildContext? _scrolling;
  bool _userScrolling = false;

  /// The scroll [notification] of the list: the direction the list travelled far enough in, null when it did not (yet).
  ScrollTravelDirection? onNotification(ScrollNotification notification) {
    if (notification.metrics.axis != Axis.vertical) {
      return null;
    }
    if (notification is UserScrollNotification) {
      _userScrolling = notification.direction != ScrollDirection.idle;
      _scrolling = notification.context;
      return null;
    }
    if (notification is! ScrollUpdateNotification || !_userScrolling || notification.context != _scrolling) {
      return null;
    }
    // Only the part of the move within the list counts: past an end (the bounce of a pull or a fling there, the spring
    // back) the list is not going anywhere, and a drag that starts past the end counts from the end.
    final metrics = notification.metrics;
    final after = metrics.pixels;
    final before = after - (notification.scrollDelta ?? 0);
    final delta =
        after.clamp(metrics.minScrollExtent, metrics.maxScrollExtent) -
        before.clamp(metrics.minScrollExtent, metrics.maxScrollExtent);
    if (delta == 0) {
      return null;
    }
    // Positive: the list goes down (the finger moves up). A turn starts the travel over.
    _travel = _travel.sign == delta.sign ? _travel + delta : delta;
    if (_travel >= threshold) {
      return ScrollTravelDirection.down;
    }
    if (_travel <= -threshold) {
      return ScrollTravelDirection.up;
    }
    return null;
  }

  /// Forget the travel so far: the list is somewhere the caller decided about on its own (its top), the following
  /// stopped.
  void reset() => _travel = 0;
}
