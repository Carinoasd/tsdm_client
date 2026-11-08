/// How close to the end of the list (in logical pixels) the last floor counts as read.
const readToEndExtent = 48.0;

/// Whether the thread on screen was read to its last floor: floors from the forum (not an offline copy, not one
/// author's floors) in order from the first one, the last page loaded and the list scrolled to its end ([extentAfter]
/// is what is left below the screen; a list short enough not to scroll has none).
bool hasReadToEnd({
  required bool loaded,
  required bool offline,
  required bool onlyOneAuthor,
  required bool newestFirst,
  required bool canLoadMore,
  required bool hasFloors,
  required double extentAfter,
}) =>
    loaded && !offline && !onlyOneAuthor && !newestFirst && !canLoadMore && hasFloors && extentAfter <= readToEndExtent;
