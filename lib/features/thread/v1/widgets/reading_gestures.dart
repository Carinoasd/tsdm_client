import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Where a swipe across the floors goes: to the left the next page, to the right the page before.
enum ThreadSwipe {
  /// Swiped to the left.
  next,

  /// Swiped to the right.
  previous,
}

/// The reading gestures of the floors of the thread page, around the list of floors ([child]):
///
/// * a tap that nothing in the floors takes ([onTap]): a link, a picture, a button or the floor's own tap
///   (`ThreadFloorInteractionMode.tapToReply`) win the tap first, as they are deeper in the tree; a long press on a
///   floor (its menu) is no tap. A tap that stops the list moving (a fling) is not one either.
/// * a swipe sideways ([onSwipe]): told when the finger lifted [minSwipeDistance] away sideways from where it went
///   down and moved at least twice as far sideways as up or down. Never for a touch that scrolled anything sideways on
///   its way (a table, a code block, a gallery in a floor, at its end too), that started at the edge of the screen (the
///   back gesture of the system), or with a second finger.
///
/// Neither competes with the gestures of the floors: the swipe is read from the pointer itself ([Listener]), the tap
/// is the last one asked.
class ThreadReadingGestures extends StatefulWidget {
  /// Constructor.
  const ThreadReadingGestures({required this.child, this.onTap, this.onSwipe, super.key});

  /// How far sideways a swipe goes at least, in logical pixels.
  static const double minSwipeDistance = 48;

  /// Width of the edges of the screen a swipe does not start from, in logical pixels.
  static const double edgeWidth = 24;

  /// A tap nothing in the floors took; null for none.
  final VoidCallback? onTap;

  /// A swipe sideways; null when swiping does nothing.
  final ValueChanged<ThreadSwipe>? onSwipe;

  /// The list of floors.
  final Widget child;

  @override
  State<ThreadReadingGestures> createState() => _ThreadReadingGesturesState();
}

class _ThreadReadingGesturesState extends State<ThreadReadingGestures> {
  /// The finger followed for a swipe, null while none is down.
  int? _pointer;
  Offset _start = Offset.zero;

  /// The touch of [_pointer] is no swipe whatever it does.
  bool _swipeBlocked = false;

  /// The list (the one of the floors, not one in a floor) stopped since the last frame: a finger that just went down
  /// stopped it (a fling, a scroll to a floor), the scroll end told before the finger reaches here. A list that stops
  /// by itself does so in a frame and is cleared at its end.
  bool _listJustStopped = false;

  /// The finger down now stopped the list: its tap is no tap.
  bool _downStoppedList = false;

  bool _onNotification(ScrollNotification notification) {
    if (_pointer != null && notification.metrics.axis == Axis.horizontal) {
      // Something scrolled sideways under the finger (or tried to, past its end): that was the swipe.
      _swipeBlocked = true;
    }
    if (notification is ScrollEndNotification &&
        notification.depth == 0 &&
        notification.metrics.axis == Axis.vertical &&
        !_listJustStopped) {
      _listJustStopped = true;
      SchedulerBinding.instance
        ..addPostFrameCallback((_) => _listJustStopped = false)
        ..scheduleFrame();
    }
    return false;
  }

  void _onPointerDown(PointerDownEvent event) {
    if (_pointer != null) {
      // A second finger: a pinch or the like, no swipe.
      _swipeBlocked = true;
      return;
    }
    _pointer = event.pointer;
    _start = event.position;
    _downStoppedList = _listJustStopped;
    final width = MediaQuery.sizeOf(context).width;
    _swipeBlocked =
        event.position.dx < ThreadReadingGestures.edgeWidth ||
        event.position.dx > width - ThreadReadingGestures.edgeWidth;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) {
      return;
    }
    _pointer = null;
    final onSwipe = widget.onSwipe;
    if (_swipeBlocked || onSwipe == null) {
      return;
    }
    final moved = event.position - _start;
    if (moved.dx.abs() > ThreadReadingGestures.minSwipeDistance && moved.dx.abs() > 2 * moved.dy.abs()) {
      onSwipe(moved.dx < 0 ? ThreadSwipe.next : ThreadSwipe.previous);
    }
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) {
      _pointer = null;
    }
  }

  void _onTap() {
    if (!_downStoppedList) {
      widget.onTap?.call();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _onPointerDown,
    onPointerUp: _onPointerUp,
    onPointerCancel: _onPointerCancel,
    child: NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: GestureDetector(onTap: widget.onTap == null ? null : _onTap, child: widget.child),
    ),
  );
}
