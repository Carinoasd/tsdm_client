import 'dart:io';

import 'package:dio/dio.dart';
import 'package:tsdm_client/extensions/date_time.dart';

/// The server clock carried by a forum answer, from its `Date` header. Null when the header is missing or unreadable.
///
/// Notification times are stamped by the forum's clock, so the lower bound of the next fetch has to come from the
/// same clock, not from the device (GitHub #71).
DateTime? serverTimeOf(Headers headers) {
  final raw = headers.value('date');
  if (raw == null || raw.isEmpty) {
    return null;
  }
  try {
    return HttpDate.parse(raw);
  } on Exception {
    return null;
  }
}

/// The inclusive lower bound to store after a notification fetch that started at [startedAt] (device clock) and got
/// [serverTime] back from the forum.
///
/// With a server time: that clock truncated to the minute, minus one minute. The `Date` header is written after the
/// pages were rendered, so a message created while they rendered can still carry the previous minute; the margin
/// keeps it inside the next window, and the copies fetched twice are reconciled against storage like today.
/// Without one: the device clock at the start of the fetch, truncated to the minute, as before. A device clock ahead
/// of the forum then still moves the bound past messages the forum has not stamped yet, which is the case #71 is
/// about, so the header is preferred whenever it is there.
DateTime nextFetchBound({required DateTime startedAt, DateTime? serverTime}) {
  if (serverTime == null) {
    return startedAt.truncateToMinute();
  }
  return serverTime.toLocal().truncateToMinute().subtract(const Duration(minutes: 1));
}

/// The earliest of [times], ignoring nulls; null when none is known.
DateTime? earliestOf(Iterable<DateTime?> times) {
  DateTime? earliest;
  for (final time in times) {
    if (time != null && (earliest == null || time.isBefore(earliest))) {
      earliest = time;
    }
  }
  return earliest;
}
