import 'package:tsdm_client/features/points/models/models.dart';

/// Days the trend reads: eight weeks, so the weekly bars have eight full weeks.
const pointsTrendDays = 56;

/// Days of the line chart.
const pointsTrendLineDays = 30;

/// Weeks of the bar chart.
const pointsTrendWeeks = 8;

/// The signed number of a printed change ("+2", "-5", "+1,000"); null for what is not a number ("清零"). Points
/// are whole numbers on the forum, a decimal reads as none.
///
/// Marked as public for testing.
int? signedChangeOf(String printed) {
  final text = printed.replaceAll(',', '').replaceAll(' ', '').trim();
  if (text.isEmpty) {
    return null;
  }
  return int.tryParse(text.startsWith('+') ? text.substring(1) : text);
}

/// The kinds of points changed by [changes], the most changed first (the order they show up in breaks a tie).
///
/// Marked as public for testing.
List<String> pointsKindsOf(Iterable<PointsChange> changes) {
  final counts = <String, int>{};
  for (final change in changes) {
    for (final MapEntry(:key, :value) in change.changeMap.entries) {
      if (signedChangeOf(value) != null) {
        counts[key] = (counts[key] ?? 0) + 1;
      }
    }
  }
  final kinds = counts.keys.toList();
  // List.sort is not stable: the index of the first appearance breaks the tie.
  final order = {for (var i = 0; i < kinds.length; i++) kinds[i]: i};
  return kinds
    ..sort((a, b) => counts[b]! != counts[a]! ? counts[b]!.compareTo(counts[a]!) : order[a]!.compareTo(order[b]!));
}

/// The net change of the points [kind] on every one of the [days] days ending at [today] (the forum's calendar day),
/// oldest first. A day without a record is 0.
///
/// Marked as public for testing.
List<int> dailyNetOf(Iterable<PointsChange> changes, String kind, DateTime today, {int days = pointsTrendLineDays}) {
  final result = List<int>.filled(days, 0);
  final end = DateTime(today.year, today.month, today.day);
  for (final change in changes) {
    final value = signedChangeOf(change.changeMap[kind] ?? '');
    if (value == null) {
      continue;
    }
    final day = DateTime(change.time.year, change.time.month, change.time.day);
    final index = days - 1 - _daysBetween(day, end);
    if (index >= 0 && index < days) {
      result[index] += value;
    }
  }
  return result;
}

/// The net change of the points [kind] of every one of the [weeks] weeks (seven days each) ending at [today],
/// oldest first.
///
/// Marked as public for testing.
List<int> weeklyNetOf(Iterable<PointsChange> changes, String kind, DateTime today, {int weeks = pointsTrendWeeks}) {
  final daily = dailyNetOf(changes, kind, today, days: weeks * 7);
  return [
    for (var week = 0; week < weeks; week++) daily.skip(week * 7).take(7).fold(0, (sum, value) => sum + value),
  ];
}

/// Whole calendar days from [from] to [to], independent of daylight saving.
int _daysBetween(DateTime from, DateTime to) =>
    DateTime.utc(to.year, to.month, to.day).difference(DateTime.utc(from.year, from.month, from.day)).inDays;
