import 'dart:async';

import 'package:flutter/gestures.dart';
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
///   floor (its menu) is no tap. A tap that stops the list moving (a fling) is not one either. Only fingers and pens
///   tap: a mouse click does not (on a desktop the bar hidden has no system back to bring it back).
/// * a swipe sideways ([onSwipe]): told when the finger lifted [minSwipeDistance] away sideways from where it went
///   down and moved at least twice as far sideways as up or down. Never for a touch that scrolled anything sideways on
///   its way (a table, a code block, a gallery in a floor, at its end too), that scrolled the list itself up or down
///   past the touch slop (a drag askew: the list follows the finger from the moment it moves, a wobble is allowed),
///   that started at the edge of the screen (the back gesture of the system), with a second finger, or that held still
///   as long as a long press (a floor's menu opens: the finger then slides to its items). Only fingers and pens swipe: a
///   mouse dragging does not.
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

  /// The touch of [_pointer] moved past the touch slop: no long press any more.
  bool _movedPastSlop = false;

  /// Runs out when the touch of [_pointer] held still as long as a long press.
  Timer? _longPressTimer;

  /// The list (the one of the floors, not one in a floor) stopped since the last frame: a finger that just went down
  /// stopped it (a fling, a scroll to a floor), the scroll end told before the finger reaches here. A list that stops
  /// by itself does so in a frame and is cleared at its end.
  bool _listJustStopped = false;

  /// The finger down now stopped the list: its tap is no tap.
  bool _downStoppedList = false;

  /// What the tap being recognized is made with; null before its down.
  PointerDeviceKind? _tapKind;

  /// How far the list (the one of the floors) scrolled under the finger of [_pointer], up or down, in logical pixels.
  double _scrolledUnderFinger = 0;

  bool _onNotification(ScrollNotification notification) {
    if (_pointer != null && notification.metrics.axis == Axis.horizontal) {
      // Something scrolled sideways under the finger (or tried to, past its end): that was the swipe.
      _swipeBlocked = true;
    }
    if (_pointer != null &&
        notification is ScrollUpdateNotification &&
        notification.depth == 0 &&
        notification.metrics.axis == Axis.vertical &&
        notification.dragDetails != null) {
      // The list follows the finger up and down from the moment the tap below gives it up (no slop of its own, the
      // pointer being its alone then): a swipe wobbles it a little. Scrolled further than the touch slop, the finger
      // scrolled the list (a drag askew): no swipe on top of that.
      _scrolledUnderFinger += notification.scrollDelta ?? 0;
      if (_scrolledUnderFinger.abs() > kTouchSlop) {
        _swipeBlocked = true;
      }
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

  /// Fingers and pens: a mouse drag (any button) is no swipe, a mouse does not drag the list either; a mouse click is
  /// no tap.
  static bool _touches(PointerDeviceKind kind) =>
      kind == PointerDeviceKind.touch || kind == PointerDeviceKind.stylus || kind == PointerDeviceKind.invertedStylus;

  void _onPointerDown(PointerDownEvent event) {
    if (_pointer == null) {
      _downStoppedList = _listJustStopped;
    }
    if (!_touches(event.kind)) {
      return;
    }
    if (_pointer != null) {
      // A second finger: a pinch or the like, no swipe.
      _swipeBlocked = true;
      return;
    }
    _pointer = event.pointer;
    _start = event.position;
    final width = MediaQuery.sizeOf(context).width;
    _swipeBlocked =
        event.position.dx < ThreadReadingGestures.edgeWidth ||
        event.position.dx > width - ThreadReadingGestures.edgeWidth;
    _movedPastSlop = false;
    _scrolledUnderFinger = 0;
    _longPressTimer?.cancel();
    // Held still that long, the touch is a long press (a floor's menu opens), whatever it does after.
    _longPressTimer = Timer(kLongPressTimeout, () => _swipeBlocked = true);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _movedPastSlop) {
      return;
    }
    if ((event.position - _start).distance > kTouchSlop) {
      _movedPastSlop = true;
      _longPressTimer?.cancel();
      _longPressTimer = null;
    }
  }

  void _endTouch() {
    _pointer = null;
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _pointer) {
      return;
    }
    _endTouch();
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
      _endTouch();
    }
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  void _onTapDown(TapDownDetails details) => _tapKind = details.kind;

  void _onTap() {
    final kind = _tapKind;
    _tapKind = null;
    if (!_downStoppedList && kind != null && _touches(kind)) {
      widget.onTap?.call();
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _onPointerDown,
    onPointerMove: _onPointerMove,
    onPointerUp: _onPointerUp,
    onPointerCancel: _onPointerCancel,
    child: NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: GestureDetector(
        onTapDown: widget.onTap == null ? null : _onTapDown,
        onTap: widget.onTap == null ? null : _onTap,
        child: widget.child,
      ),
    ),
  );
}
