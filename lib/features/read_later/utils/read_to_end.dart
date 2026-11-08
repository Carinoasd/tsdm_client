/// How close to the end of the list (in logical pixels) the last floor counts as read.
const readToEndExtent = 48.0;

/// Whether the thread on screen was read to its last floor: floors from the forum (not an offline copy, not one
/// author's floors) in order from the first one, read on from the start of the thread or from where the reading
/// stopped ([readOnFromStart]; a jump to the last page does not read the thread), the last page loaded and the list
/// scrolled to its end ([extentAfter] is what is left below the screen; a list short enough not to scroll has none).
bool hasReadToEnd({
  required bool loaded,
  required bool offline,
  required bool onlyOneAuthor,
  required bool readOnFromStart,
  required bool newestFirst,
  required bool canLoadMore,
  required bool hasFloors,
  required double extentAfter,
}) =>
    loaded &&
    !offline &&
    !onlyOneAuthor &&
    readOnFromStart &&
    !newestFirst &&
    !canLoadMore &&
    hasFloors &&
    extentAfter <= readToEndExtent;

/// Works out whether the floors on screen go on from the start of the thread, for [hasReadToEnd].
///
/// Every load that replaces the floors starts a new generation (`ThreadState.generation`, one step on each). The floors
/// of a generation are read on from the start when the first page is among them, or when the load was asked to go on
/// from where the reading was: the page opened where the reading stopped, the jump to it, a refresh of floors that were.
/// A jump to the last page is none of these, also not after a load that failed.
final class ReadOnTracker {
  int? _generation;
  int? _continueFor;

  /// Whether the floors of the generation seen last go on from the start.
  bool readOnFromStart = false;

  /// The next load that replaces the floors of [generation] goes on from where the reading stopped.
  void continueFrom(int generation) => _continueFor = generation + 1;

  /// The next load that replaces the floors of [generation] shows the same reading again (a refresh).
  void keepFrom(int generation) => _continueFor = readOnFromStart ? generation + 1 : null;

  /// The floors of [generation] are on screen ([firstPage] the first page among them). [openedResumed]: the page opened
  /// where the reading stopped, which counts for the first floors shown.
  void floorsShown({required int generation, required int firstPage, required bool openedResumed}) {
    if (generation == _generation) {
      return;
    }
    readOnFromStart = firstPage == 1 || _continueFor == generation || (_generation == null && openedResumed);
    _generation = generation;
    _continueFor = null;
  }
}
