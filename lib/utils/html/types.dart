/// Font size of `<font size="…">` (`[size=1]` to `[size=7]`).
///
/// The sizes a browser gives them, in css pixels: the post's text is 14 on the web page (`.t_f`), `[size=2]` is 13,
/// `[size=3]` 16. The app shows them at the same ratio to its body text ([value] at a body text of 14). Before, they
/// were a pixel larger each (`[size=2]` was the body text itself, `[size=3]` 17), measured once on another forum
/// style.
enum FontSize {
  /// "1": x-small, 10px.
  size1,

  /// "2": small, 13px.
  size2,

  /// "3": medium, 16px.
  size3,

  /// "4": large, 18px.
  size4,

  /// "5": x-large, 24px.
  size5,

  /// "6": xx-large, 32px.
  size6,

  /// "7": xxx-large, 48px.
  size7,

  /// Not support size.
  notSupport
  ;

  /// The size of `<font size="[size]">` as a browser reads it: a number from 1 to 7 (a larger or smaller one taken
  /// as 7 or 1), or one relative to 3 (`+1` is 4, `-1` is 2); not a size when it does not start with a number.
  factory FontSize.fromString(String? size) {
    if (size == null) {
      return FontSize.notSupport;
    }
    final m = _sizeRe.firstMatch(size.trim());
    if (m == null) {
      return FontSize.notSupport;
    }
    final n = int.tryParse(m.group(2)!.length > 3 ? '999' : m.group(2)!) ?? 7;
    final value = switch (m.group(1)) {
      '+' => 3 + n,
      '-' => 3 - n,
      _ => n,
    };
    return FontSize.values[value.clamp(1, 7) - 1];
  }

  static final _sizeRe = RegExp(r'^([+-]?)(\d+)');

  /// The font size, in css pixels of the web page: the app's at a body text of 14 (see [FontSize]).
  double value() {
    return switch (this) {
      FontSize.size1 => 10.0,
      FontSize.size2 => 13.0,
      FontSize.size3 => 16.0,
      FontSize.size4 => 18.0,
      FontSize.size5 => 24.0,
      FontSize.size6 => 32.0,
      FontSize.size7 => 48.0,
      FontSize.notSupport => 16.0, // A browser's default.
    };
  }

  /// Is the font size valid.
  bool get isValid => this != FontSize.notSupport;

  /// Is the font size invalid.
  bool get isNotValid => !isValid;
}
