import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/notice_info.dart';
import 'package:universal_html/parsing.dart';

/// Weeks of the weekly counts.
const rateStatsWeeks = 8;

/// Raters listed.
const rateStatsTopCount = 10;

/// One rating the user received, read from a rate notice.
final class RateEvent {
  /// Constructor.
  const RateEvent({required this.raterId, required this.rater, required this.time, required this.scores});

  /// Uid of the rater, null when the notice did not tell.
  final int? raterId;

  /// Name of the rater.
  final String rater;

  /// When the notice was made, the forum's wall clock.
  final DateTime time;

  /// The points given by kind, "威望" to 10 (negative for a deduction).
  final Map<String, int> scores;
}

/// A rater and what the rater gave in all.
final class RaterTotal {
  /// Constructor.
  const RaterTotal({required this.raterId, required this.rater, required this.count, required this.scores});

  /// Uid of the rater, null when the notices did not tell.
  final int? raterId;

  /// Name of the rater.
  final String rater;

  /// Ratings given.
  final int count;

  /// The points given by kind.
  final Map<String, int> scores;
}

final _scoreRe = RegExp(r'([^\s+\-\d][^\s+\-]*)\s*([+\-]\d+)');

/// The points a rate notice body [html] gives, "威望 +10" to {威望: 10}: what follows "评分" in the text before the
/// quoted reason. Empty when there is none.
///
/// Marked as public for testing.
Map<String, int> rateScoresOf(String html) {
  final body = parseHtmlDocument('<html><body>$html</body></html>').body;
  if (body == null) {
    return const {};
  }
  for (final quote in body.querySelectorAll('div.quote, blockquote')) {
    quote.remove();
  }
  final text = body.innerText.replaceAll(RegExp(r'\s+'), ' ');
  // The last one: a thread title or a name before it may say the word too.
  final at = text.lastIndexOf('评分');
  if (at < 0) {
    return const {};
  }
  final scores = <String, int>{};
  for (final match in _scoreRe.allMatches(text.substring(at + 2))) {
    final kind = match.group(1)!;
    final value = int.tryParse(match.group(2)!.replaceFirst('+', ''));
    if (value != null) {
      scores[kind] = (scores[kind] ?? 0) + value;
    }
  }
  return scores;
}

/// The ratings the user received told by [notices]: the rate notices (a rate track, which is about the user's
/// following of a post, is not one) that name a rater and a score.
List<RateEvent> rateEventsOf(Iterable<NoticeV2> notices) {
  final events = <RateEvent>[];
  for (final notice in notices) {
    if (notice.ignoreType == 'ratetrack') {
      continue;
    }
    final info = NoticeInfo.of(notice);
    final rater = info.author;
    if (info.kind != NoticeKind.rate || rater == null || rater.isEmpty) {
      continue;
    }
    final scores = rateScoresOf(notice.data);
    if (scores.isEmpty) {
      continue;
    }
    final at = DateTime.fromMillisecondsSinceEpoch(notice.timestamp * 1000, isUtc: true).add(const Duration(hours: 8));
    events.add(
      RateEvent(
        raterId: info.authorId,
        rater: rater,
        time: DateTime(at.year, at.month, at.day, at.hour, at.minute),
        scores: scores,
      ),
    );
  }
  return events;
}

/// The raters of [events] with the most ratings first (the points given in all, a deduction taking away, break a
/// tie), at most [limit]. A rater is told by name, which is unique: a notice may lack the uid.
List<RaterTotal> topRatersOf(Iterable<RateEvent> events, {int limit = rateStatsTopCount}) {
  final byRater = <String, RaterTotal>{};
  for (final event in events) {
    final key = event.rater;
    final total = byRater[key];
    final scores = {...?total?.scores};
    event.scores.forEach((kind, value) => scores[kind] = (scores[kind] ?? 0) + value);
    byRater[key] = RaterTotal(
      raterId: total?.raterId ?? event.raterId,
      rater: event.rater,
      count: (total?.count ?? 0) + 1,
      scores: scores,
    );
  }
  int points(RaterTotal e) => e.scores.values.fold(0, (a, b) => a + b);
  final list = byRater.values.toList()
    ..sort((a, b) => a.count != b.count ? b.count.compareTo(a.count) : points(b).compareTo(points(a)));
  return list.take(limit).toList();
}

/// The points given in all by kind.
Map<String, int> scoreTotalsOf(Iterable<RateEvent> events) {
  final totals = <String, int>{};
  for (final event in events) {
    event.scores.forEach((kind, value) => totals[kind] = (totals[kind] ?? 0) + value);
  }
  return totals;
}

/// The ratings received in every one of the [weeks] weeks (seven days each) ending at [today], oldest first.
List<int> weeklyCountsOf(Iterable<RateEvent> events, DateTime today, {int weeks = rateStatsWeeks}) {
  final counts = List<int>.filled(weeks, 0);
  final end = DateTime.utc(today.year, today.month, today.day);
  for (final event in events) {
    final back = end.difference(DateTime.utc(event.time.year, event.time.month, event.time.day)).inDays;
    if (back < 0 || back >= weeks * 7) {
      continue;
    }
    counts[weeks - 1 - back ~/ 7] += 1;
  }
  return counts;
}
