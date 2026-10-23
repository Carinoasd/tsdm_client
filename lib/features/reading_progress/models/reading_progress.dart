import 'package:flutter/foundation.dart';

/// Where an account stopped reading a thread, kept with the thread's visit record (`ThreadVisitHistory`).
@immutable
final class ReadingProgress {
  /// Constructor.
  const ReadingProgress({this.page, this.pid, this.floor, this.seenReplies});

  /// The page (oldest floor first) of the floor at the top of the screen, null when not known.
  final int? page;

  /// Post id of that floor; null while at the start of the thread.
  final int? pid;

  /// Number of that floor as the thread prints it; null when not known, 1 at the start of the thread.
  final int? floor;

  /// The thread's replies when it was read (as the lists count them): the lists tell the replies posted since.
  final int? seenReplies;

  /// Whether the reading went past the first screen of the thread: only then is it worth going on with.
  bool get pastFirstScreen => (floor ?? 1) > 1 || (page ?? 1) > 1;

  /// Replies posted since the thread was read, out of the [replies] a list counts now; 0 when not known.
  int newRepliesOf(int? replies) {
    final seen = seenReplies;
    if (seen == null || replies == null || replies <= seen) {
      return 0;
    }
    return replies - seen;
  }

  @override
  bool operator ==(Object other) =>
      other is ReadingProgress &&
      other.page == page &&
      other.pid == pid &&
      other.floor == floor &&
      other.seenReplies == seenReplies;

  @override
  int get hashCode => Object.hash(page, pid, floor, seenReplies);

  @override
  String toString() => 'ReadingProgress(page: $page, pid: $pid, floor: $floor, seenReplies: $seenReplies)';
}
