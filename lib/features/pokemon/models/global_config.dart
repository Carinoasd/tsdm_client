/// Global configuration of the pokemon plugin (`config/global_config`).
///
/// Values come from the `pm_config` table and are typed by their `data_type` column on the server side. Parsing is
/// deliberately tolerant because historic rows may store a boolean as the string `'1'`/`'0'` or an empty string.
final class GlobalConfig {
  /// Constructor.
  const GlobalConfig({
    required this.isOpen,
    required this.version,
    required this.annTitle,
    required this.annUrl,
    required this.medicalPrice,
    required this.isEnableCatch,
    required this.isEnableBuyPokemon,
  });

  /// Build an instance from the `data` object of the `config/global_config` response.
  factory GlobalConfig.fromJson(Map<String, dynamic> json) => GlobalConfig(
    isOpen: _asBool(json['is_open']),
    version: _asString(json['version']),
    annTitle: _asString(json['ann_title']),
    annUrl: _asString(json['ann_url']),
    medicalPrice: _asInt(json['medical_price']),
    isEnableCatch: _asBool(json['is_enable_catch']),
    isEnableBuyPokemon: _asBool(json['is_enable_buy_pokemon']),
  );

  /// Whether the plugin is open.
  final bool isOpen;

  /// Plugin version string.
  final String version;

  /// Announcement title.
  final String annTitle;

  /// Announcement url.
  final String annUrl;

  /// Price of healing at the pokemon center.
  final int medicalPrice;

  /// Whether catching wild pokemon is enabled.
  final bool isEnableCatch;

  /// Whether buying pokemon is enabled.
  final bool isEnableBuyPokemon;

  static String _asString(Object? v) {
    if (v == null) return '';
    return v.toString();
  }

  static int _asInt(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim()) ?? 0;
    return 0;
  }

  static bool _asBool(Object? v) {
    if (v is bool) return v;
    if (v is int || v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      return s == '1' || s == 'true' || s == 'yes' || s == 'on';
    }
    return false;
  }
}
