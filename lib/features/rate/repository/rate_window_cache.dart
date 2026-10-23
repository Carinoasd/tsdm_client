import 'package:tsdm_client/features/rate/models/models.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';

/// The rate window of a thread, kept from one rate to the next.
///
/// Rating several floors of a thread in a row (a thread owner rewarding every participant) opened the rate window of
/// each floor over the network first, a spinner before every form. The window only differs by the post: the form
/// hash, the scores with their ranges, the default reasons and the author notice setting are those of the thread and
/// the account; today's remaining scores change with every rate. So the last window of the thread is kept here, the
/// next rate page shows it at once with its post id and loads the real one behind it.
///
/// Kept per account and thread, for [maxAge]: the form hash of a session changes rarely and the forum refuses a stale
/// one with a message the page shows, after which the window is loaded again anyway.
abstract final class RateWindowCache {
  /// How long a kept window is used.
  static const maxAge = Duration(minutes: 30);

  static final _windows = <String, ({RateWindowInfo info, DateTime time})>{};

  static String? _key(String tid) {
    final uid = getIt.isRegistered<SettingsRepository>() ? getIt.get<SettingsRepository>().currentSettings.loginUid : 0;
    return uid > 0 ? '$uid/$tid' : null;
  }

  /// The thread id in a rate action url (`forum.php?mod=misc&action=rate&tid=…&pid=…`), null when it has none.
  static String? tidOf(String rateAction) => Uri.tryParse(rateAction)?.queryParameters['tid'];

  /// The window kept for thread [tid] of the current account, null when there is none or it is too old.
  static RateWindowInfo? get(String tid, {DateTime? now}) {
    final key = _key(tid);
    final kept = key == null ? null : _windows[key];
    if (kept == null) {
      return null;
    }
    if ((now ?? DateTime.now()).difference(kept.time) > maxAge) {
      _windows.remove(key);
      return null;
    }
    return kept.info;
  }

  /// Keep [info] as the window of its thread for the current account.
  static void put(RateWindowInfo info, {DateTime? now}) {
    final key = _key(info.tid);
    final time = now ?? DateTime.now();
    _windows.removeWhere((_, kept) => time.difference(kept.time) > maxAge);
    if (key != null) {
      _windows[key] = (info: info, time: time);
    }
  }

  /// The kept window [info] as the window of post [pid] of the same thread: the post id, and the `#pid` anchor of
  /// the referer the forum sends the browser back to; in the served fields of a window of the forum's app API too.
  static RateWindowInfo forPost(RateWindowInfo info, String pid) {
    final referer = info.referer.replaceFirst('#pid${info.pid}', '#pid$pid');
    final fields = info.submitFields;
    return info.copyWith(
      pid: pid,
      referer: referer,
      submitFields: fields == null
          ? null
          : {
              ...fields,
              if (fields.containsKey('pid')) 'pid': pid,
              if (fields.containsKey('referer')) 'referer': referer,
            },
    );
  }

  /// The window [info] after a rate just accepted: [rated] (score id to value, as sent) is taken off today's
  /// remaining scores, so the form shows what is left without waiting for the forum. The real window replaces it
  /// when it arrives.
  static RateWindowInfo rated(RateWindowInfo info, Map<String, String> rated) {
    final scores = info.scoreList.map((score) {
      final value = int.tryParse(rated[score.id] ?? '');
      final remaining = int.tryParse(score.remaining.trim());
      if (value == null || remaining == null) {
        return score;
      }
      return score.copyWith(remaining: '${remaining - value.abs()}');
    }).toList();
    return info.copyWith(scoreList: scores);
  }

  /// Keep the window of a rate just accepted, see [rated].
  static void putRated(RateWindowInfo info, Map<String, String> sent, {DateTime? now}) =>
      put(rated(info, sent), now: now);

  /// Forget every window (tests, or after the account changed).
  static void clear() => _windows.clear();
}
