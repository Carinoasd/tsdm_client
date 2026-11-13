import 'dart:io';

/// Log file.
final class HistoricalLog {
  /// Constructor.
  const HistoricalLog(this.time, this.file, {this.background = false});

  /// Time of the log, in days.
  final DateTime time;

  /// File entity to the log file.
  final File file;

  /// Written by the Android background message service (`tsdm_client_bg_<day>.log`), not by the app itself.
  final bool background;

  /// The day and the writer of a log file named [fileName]: `tsdm_client_<yyyyMMdd>.log` for the app's own,
  /// `tsdm_client_bg_<yyyyMMdd>.log` for the Android background message service's; null for any other file.
  static ({DateTime day, bool background})? parseFileName(String fileName) {
    final m = _nameRe.firstMatch(fileName);
    if (m == null) {
      return null;
    }
    final year = int.parse(m.namedGroup('year')!);
    final month = int.parse(m.namedGroup('month')!);
    final day = int.parse(m.namedGroup('day')!);
    final time = DateTime(year, month, day);
    if (time.month != month || time.day != day) {
      // Not a date (`20261399`): DateTime would roll it over into another day.
      return null;
    }
    return (day: time, background: m.namedGroup('bg') != null);
  }

  static final _nameRe = RegExp(r'^tsdm_client_(?<bg>bg_)?(?<year>\d\d\d\d)(?<month>\d\d)(?<day>\d\d)\.log$');
}
