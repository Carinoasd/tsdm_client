/// A number as an axis label: whole up to 9999, then "1.2k", "3.4M".
String compactNumber(num value) {
  final abs = value.abs();
  String trimmed(double v) => v.toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '');
  if (abs >= 1000000) {
    return '${value < 0 ? '-' : ''}${trimmed(abs / 1000000)}M';
  }
  if (abs >= 10000) {
    return '${value < 0 ? '-' : ''}${trimmed(abs / 1000)}k';
  }
  return value.round().toString();
}

/// A signed number for a tooltip: "+12", "-3", "0".
String signedNumber(num value) {
  final n = value.round();
  return n > 0 ? '+$n' : '$n';
}

/// The month and day of [day], "11/8".
String shortDate(DateTime day) => '${day.month}/${day.day}';
