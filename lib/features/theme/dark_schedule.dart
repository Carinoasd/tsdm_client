import 'package:flutter/material.dart';

/// Minutes in a day.
const int _minutesPerDay = 24 * 60;

/// The hours of a day the app is dark, from [start] to [end] in minutes after midnight.
///
/// A window that ends before it starts runs over midnight (22:00 to 07:00); one with the same start and end is empty.
@immutable
final class DarkSchedule {
  /// Constructor, both times in minutes after midnight; a value outside the day wraps around.
  const DarkSchedule({this.start = defaultStart, this.end = defaultEnd});

  /// Minutes after midnight the window starts at by default (22:00).
  static const int defaultStart = 22 * 60;

  /// Minutes after midnight the window ends at by default (07:00).
  static const int defaultEnd = 7 * 60;

  /// The window when nothing was set.
  static const DarkSchedule defaults = DarkSchedule();

  /// Start of the window.
  final int start;

  /// End of the window.
  final int end;

  int get _start => _wrap(start);

  int get _end => _wrap(end);

  /// Whether [now] is inside the dark hours.
  bool isDark(DateTime now) {
    final start = _start;
    final end = _end;
    if (start == end) {
      return false;
    }
    final minute = now.hour * 60 + now.minute;
    return start < end ? minute >= start && minute < end : minute >= start || minute < end;
  }

  /// The next moment after [now] the answer of [isDark] changes, null when it never does.
  DateTime? nextBoundary(DateTime now) {
    final start = _start;
    final end = _end;
    if (start == end) {
      return null;
    }
    DateTime? best;
    // Today and tomorrow: one of the four is the first one after now.
    for (var day = 0; day <= 1; day++) {
      for (final minute in [start, end]) {
        final at = DateTime(now.year, now.month, now.day + day, minute ~/ 60, minute % 60);
        if (at.isAfter(now) && (best == null || at.isBefore(best))) {
          best = at;
        }
      }
    }
    return best;
  }

  /// [minutes] after midnight as `HH:mm`.
  static String timeText(int minutes) {
    final wrapped = _wrap(minutes);
    return '${(wrapped ~/ 60).toString().padLeft(2, '0')}:${(wrapped % 60).toString().padLeft(2, '0')}';
  }

  /// The window as `HH:mm–HH:mm`.
  String get text => '${timeText(start)}–${timeText(end)}';

  @override
  bool operator ==(Object other) => other is DarkSchedule && other._start == _start && other._end == _end;

  @override
  int get hashCode => Object.hash(_start, _end);

  @override
  String toString() => 'DarkSchedule($text)';
}

int _wrap(int minute) => ((minute % _minutesPerDay) + _minutesPerDay) % _minutesPerDay;
