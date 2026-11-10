import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Forces the touch gestures of links on ([useMobileLinkGesture]): true for a phone's, false for a desktop's, null
/// for the platform's.
///
/// Tests run on a desktop host; this lets them press links the way a phone does.
@visibleForTesting
bool? debugMobileLinkGestureOverride;

/// Whether links in rendered content take the touch gestures of a phone ([LinkTapGestureRecognizer]).
bool get useMobileLinkGesture => debugMobileLinkGestureOverride ?? isMobile;

/// The recognizer of a link on a phone: a tap opens it ([onTap]), a long press shows what it is ([onLongPress]).
///
/// Unlike a [LongPressGestureRecognizer] whose cancel opens the link, it claims the touch it acts on:
///
/// * Lifted before [kLongPressTimeout], within the touch slop: it wins the gesture arena, then calls [onTap]. A
///   tappable container around the content (a card's ink well) loses the touch instead of opening its own page too
///   (GitHub #339).
/// * Held until [kLongPressTimeout]: it wins the arena and calls [onLongPress]; lifting the finger then does nothing.
/// * Moved past the touch slop (a scroll starting on the link), or the touch taken by another recognizer, or
///   cancelled: nothing is called.
///
/// It is a [TapGestureRecognizer], so the semantics of a text span take its [onTap] as the link's action (a
/// paragraph supports no other recognizer type there).
class LinkTapGestureRecognizer extends TapGestureRecognizer {
  /// Constructor.
  LinkTapGestureRecognizer({super.debugOwner});

  /// Called when the link is held until [kLongPressTimeout].
  VoidCallback? onLongPress;

  /// Pending long press of the touch being tracked.
  Timer? _longPressTimer;

  /// Whether the touch being tracked became a long press: its end is not a tap.
  bool _longPressed = false;

  @override
  void addAllowedPointer(PointerDownEvent event) {
    final first = state == GestureRecognizerState.ready;
    super.addAllowedPointer(event);
    if (first && state == GestureRecognizerState.possible) {
      _longPressed = false;
      _stopLongPressTimer();
      _longPressTimer = Timer(kLongPressTimeout, _didLongPress);
    }
  }

  @override
  void handlePrimaryPointer(PointerEvent event) {
    super.handlePrimaryPointer(event);
    if (event is PointerUpEvent) {
      _stopLongPressTimer();
      // Lifted in time and in place: claim the touch, so that the tap fires here ([acceptGesture]) and the other
      // members of the arena (an ink well around the content) are rejected before the arena is swept. Nothing
      // happens when the arena was already won (the only member): the tap fired in the call above.
      if (!_longPressed) {
        resolve(GestureDisposition.accepted);
      }
    }
  }

  @override
  void handleTapUp({required PointerDownEvent down, required PointerUpEvent up}) {
    if (_longPressed) {
      // The end of a long press, not a tap.
      return;
    }
    super.handleTapUp(down: down, up: up);
  }

  void _didLongPress() {
    _longPressTimer = null;
    if (state != GestureRecognizerState.possible) {
      return;
    }
    _longPressed = true;
    resolve(GestureDisposition.accepted);
    if (onLongPress != null) {
      invokeCallback<void>('onLongPress', onLongPress!);
    }
  }

  @override
  void rejectGesture(int pointer) {
    if (pointer == primaryPointer) {
      _stopLongPressTimer();
    }
    super.rejectGesture(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _stopLongPressTimer();
    super.didStopTrackingLastPointer(pointer);
  }

  @override
  void dispose() {
    _stopLongPressTimer();
    super.dispose();
  }

  void _stopLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  @override
  String get debugDescription => 'link tap';
}
