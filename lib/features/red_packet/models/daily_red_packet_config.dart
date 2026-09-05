part of 'models.dart';

/// The daily red packet (每日紅包) offered by the forum's `hongbao` plugin.
///
/// Embedded in the footer of every page while the current user has not claimed it today:
/// `hongbaoDailyInit({"entry":2,"dateflag":"20260906","from":"系統 每日紅包","bless":"...","unit":"天使币"})`.
@MappableClass()
final class DailyRedPacketConfig with DailyRedPacketConfigMappable {
  /// Constructor.
  const DailyRedPacketConfig({
    required this.entry,
    required this.dateFlag,
    required this.from,
    required this.bless,
    required this.unit,
  });

  /// Build from the config object passed to `hongbaoDailyInit`.
  factory DailyRedPacketConfig.fromServerJson(Map<String, dynamic> json) => DailyRedPacketConfig(
    entry: _jsonInt(json['entry']) ?? 2,
    dateFlag: '${json['dateflag'] ?? ''}',
    from: '${json['from'] ?? ''}',
    bless: '${json['bless'] ?? ''}',
    unit: '${json['unit'] ?? ''}',
  );

  /// How the web page shows the entry: 1 opens automatically, 2 shows a floating button.
  final int entry;

  /// Day of the packet, `YYYYMMDD`.
  final String dateFlag;

  /// Sender text, e.g. "系統 每日紅包".
  final String from;

  /// Blessing text.
  final String bless;

  /// Currency unit, e.g. "天使币".
  final String unit;
}
