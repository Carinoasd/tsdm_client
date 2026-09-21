import 'dart:async';

/// Event for scrolling to top.
class ScrollToTopEvent {
  /// Constructor.
  const ScrollToTopEvent(this.tabIndex);

  /// The index of the navigation bar tab (0: Home, 1: Topics, 2: Settings).
  final int tabIndex;
}

/// Broadcast stream for scroll to top events.
final scrollToTopStream = StreamController<ScrollToTopEvent>.broadcast();
