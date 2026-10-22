import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:dart_bbcode_web_colors/dart_bbcode_web_colors.dart';
import 'package:flutter/material.dart';
import 'package:universal_html/html.dart' as uh;

// What the author of a post styled in its html, and how the app shows it.
//
// A post's look is in its css as much as in its tags: the `style` of an element (`<span style="font-size: 12pt;
// color: #000">`, `<div style="background-color: pink">`), the classes of the forum's style sheet (`.xi1`, `.xg1`…)
// and the post's own `<style>`, which a post written in html carries (`.Red { color: #fff; text-shadow: … }`). The
// app read little of it (the color and a size of `1` to `7` of a `<span>`, the background of a `<span>` and a
// `<font>` when it came first): the posts were flattened to the body text. Here the part of css a post's text can
// show in the app is read: the colors, the background of a block or of a piece of
// text, the size, weight, style and decoration of the text, its shadows (the glow of an activity's headings), the
// alignment and the first line's indent of a block. The rest (the layout of the page, its fonts, its pictures) is
// left to the web page.

/// Size of the text of a post on the web page (`.t_f { font-size: 14px }`), in css pixels: the sizes of a post are
/// shown at the same ratio to the app's body text.
const webPostFontSize = 14.0;

/// The css pixel size of the text of the web page's root (`html`), what `rem` is relative to.
const _webRootFontSize = 16.0;

/// The smallest font size of the author the app shows, in css pixels of the web page: a smaller one could not be read
/// on a phone.
const minWebFontSize = 8.0;

/// The largest font size of the author the app shows, in css pixels of the web page: a larger one does not fit the
/// width of a phone.
const maxWebFontSize = 64.0;

/// A length of css: [value] in css pixels, or in multiples of the font size ([em]).
@immutable
final class CssLength {
  /// A length in css pixels.
  const CssLength.px(this.value) : em = false;

  /// A length in multiples of the font size.
  const CssLength.em(this.value) : em = true;

  /// The length, in pixels or in font sizes.
  final double value;

  /// The length is a multiple of the font size.
  final bool em;

  /// The length in pixels where the font size is [fontSize]; [pixelScale] turns a css pixel into the app's.
  double resolve(double fontSize, {double pixelScale = 1}) => em ? value * fontSize : value * pixelScale;

  @override
  bool operator ==(Object other) => other is CssLength && other.value == value && other.em == em;

  @override
  int get hashCode => Object.hash(value, em);

  @override
  String toString() => em ? '${value}em' : '${value}px';
}

/// A shadow of text (`text-shadow`), its lengths not yet resolved; no [color] is the color of the text.
@immutable
final class CssShadow {
  /// Constructor.
  const CssShadow({required this.dx, required this.dy, required this.blur, this.color});

  /// Horizontal offset.
  final CssLength dx;

  /// Vertical offset.
  final CssLength dy;

  /// Blur radius.
  final CssLength blur;

  /// Color, the text's when null.
  final Color? color;

  /// The shadow where the font size is [fontSize] and the text is [textColor]: offset by at most the font size each
  /// way, blurred by at most the font size. A glow or an outline is that close to its text; a shadow further away
  /// (`0 -100px`) would be drawn over the floor above.
  Shadow resolve(double fontSize, double pixelScale, Color textColor) {
    double bounded(CssLength length, double min) =>
        length.resolve(fontSize, pixelScale: pixelScale).clamp(min, fontSize);
    return Shadow(
      offset: Offset(bounded(dx, -fontSize), bounded(dy, -fontSize)),
      blurRadius: bounded(blur, 0),
      color: color ?? textColor,
    );
  }
}

/// The style the author gave an element, as far as the app shows it. Null fields were not given.
final class AuthorStyle {
  /// Color of the text.
  Color? color;

  /// Background, a single color.
  Color? background;

  /// The background is a picture (`url(…)`, a gradient), which the app does not show: text colored for it may be
  /// unreadable without it.
  bool backgroundPicture = false;

  /// Size of the text, in css pixels of the web page or in multiples of the size around it.
  CssLength? fontSize;

  /// Bold (true) or not (false).
  bool? bold;

  /// Italic (true) or not (false).
  bool? italic;

  /// Underlined.
  bool underline = false;

  /// Struck through.
  bool lineThrough = false;

  /// `text-decoration: none`: a link's own underline is taken off (the decoration of an ancestor stays, as in css).
  bool noDecoration = false;

  /// Alignment of the lines of a block.
  TextAlign? textAlign;

  /// Indent of the first line of a block.
  CssLength? textIndent;

  /// Shadows of the text; empty for `none`.
  List<CssShadow>? textShadows;

  /// Nothing the app shows was given.
  bool get isEmpty =>
      color == null &&
      background == null &&
      !backgroundPicture &&
      fontSize == null &&
      bold == null &&
      italic == null &&
      !underline &&
      !lineThrough &&
      !noDecoration &&
      textAlign == null &&
      textIndent == null &&
      textShadows == null;

  /// Take the declaration of [property] (lower case) with [value]; a value the app cannot show is left out, as a
  /// browser leaves out a value it does not know.
  ///
  /// Left out on purpose: `font-family` (the app has none of the fonts posts name), `line-height` (the line height of
  /// a post's content is the reader's setting, see `PostTypography`; posts give it with what they paste, `30px` from
  /// an editor, `1` on a heading), and the layout of the page (widths, margins, borders, positions).
  void declare(String property, String value) {
    final v = value.trim();
    final lower = v.toLowerCase();
    switch (property) {
      case 'color':
        color = parseCssColor(v) ?? color;
      case 'background-color':
        if (const {'transparent', 'none', 'initial', 'unset'}.contains(lower)) {
          background = null;
        } else if (parseCssColor(v) case final color?) {
          // A transparent one (`rgba(0, 0, 0, 0)`) shows what is behind: none.
          background = color.a < _seenAlpha ? null : color;
        }
      case 'background':
        _declareBackground(lower);
      case 'background-image':
        backgroundPicture = lower != 'none' && lower.isNotEmpty;
      case 'font-size':
        fontSize = parseCssFontSize(lower) ?? fontSize;
      case 'font-weight':
        bold = switch (lower) {
          'bold' || 'bolder' => true,
          'normal' || 'lighter' => false,
          _ => switch (int.tryParse(lower)) {
            final int w when w >= 1 && w <= 1000 => w >= 600,
            _ => bold,
          },
        };
      case 'font-style':
        italic = switch (lower) {
          'italic' || 'oblique' => true,
          'normal' => false,
          _ when lower.startsWith('oblique') => true,
          _ => italic,
        };
      case 'text-decoration' || 'text-decoration-line':
        final words = lower.split(_spaceRe);
        if (words.contains('none')) {
          noDecoration = true;
          underline = false;
          lineThrough = false;
        } else {
          if (words.contains('underline')) {
            underline = true;
          }
          if (words.contains('line-through')) {
            lineThrough = true;
          }
        }
      case 'text-align':
        textAlign = switch (lower) {
          'left' || 'start' || '-webkit-left' => TextAlign.left,
          'center' || '-webkit-center' => TextAlign.center,
          'right' || 'end' || '-webkit-right' => TextAlign.right,
          'justify' => TextAlign.justify,
          _ => textAlign,
        };
      case 'text-indent':
        final indent = parseCssLength(lower);
        if (indent != null && indent.value >= 0) {
          textIndent = indent;
        }
      case 'text-shadow':
        textShadows = parseCssTextShadows(v) ?? textShadows;
    }
  }

  /// `background`: its color, and whether it shows a picture.
  void _declareBackground(String value) {
    if (value == 'none' || value == 'transparent' || value == 'initial' || value == 'unset') {
      background = null;
      backgroundPicture = false;
      return;
    }
    backgroundPicture = value.contains('url(') || value.contains('gradient(') || value.contains('image(');
    Color? color;
    for (final token in _splitTopLevel(value, ' ')) {
      if (token.contains('url(') || token.contains('gradient(')) {
        continue;
      }
      color = parseCssColor(token);
      if (color != null) {
        break;
      }
    }
    background = color == null || color.a < _seenAlpha ? null : color;
  }
}

final _spaceRe = RegExp(r'\s+');

/// A background less opaque than this is not seen: transparent.
const _seenAlpha = 0.05;

/// [text] split at each [separator] outside of parentheses and quotes, each piece trimmed, empty ones left out.
List<String> _splitTopLevel(String text, String separator) {
  final parts = <String>[];
  var depth = 0;
  String? quote;
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (quote != null) {
      if (c == quote) {
        quote = null;
      }
      continue;
    }
    if (c == '"' || c == "'") {
      quote = c;
    } else if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth = math.max(0, depth - 1);
    } else if (depth == 0 && (separator == ' ' ? _isSpace(c) : c == separator)) {
      parts.add(text.substring(start, i));
      start = i + 1;
    }
  }
  parts.add(text.substring(start));
  return [
    for (final p in parts)
      if (p.trim().isNotEmpty) p.trim(),
  ];
}

bool _isSpace(String c) => c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f';

/*                Values                      */

final _hexRe = RegExp(r'^[0-9a-f]+$');
final _functionRe = RegExp(r'^(rgba?|hsla?)\((.*)\)$');

/// The color of a css color [value]: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()`, `hsl()`, `hsla()`
/// and the color names; `transparent` is a color without alpha. Null for anything else (`inherit`, `currentColor`,
/// a gradient…).
Color? parseCssColor(String value) {
  final v = value.trim().toLowerCase();
  if (v.isEmpty || v.length > 64) {
    return null;
  }
  if (v == 'transparent') {
    return const Color(0x00000000);
  }
  if (v.startsWith('#')) {
    final hex = v.substring(1);
    if (!_hexRe.hasMatch(hex)) {
      return null;
    }
    String twice(String s) => s.split('').map((e) => '$e$e').join();
    final rgba = switch (hex.length) {
      3 => '${twice(hex)}ff',
      4 => twice(hex),
      6 => '${hex}ff',
      8 => hex,
      _ => null,
    };
    if (rgba == null) {
      return null;
    }
    final n = int.parse(rgba, radix: 16);
    return Color.fromARGB(n & 0xFF, (n >> 24) & 0xFF, (n >> 16) & 0xFF, (n >> 8) & 0xFF);
  }
  final function = _functionRe.firstMatch(v);
  if (function != null) {
    return _parseColorFunction(function.group(1)!, function.group(2)!);
  }
  final named = WebColors.fromString(v);
  return named.isValid ? Color(named.colorValue) : null;
}

/// The color of a color attribute [value] (`<font color="…">`, `bgcolor`), read as a browser reads it (the rules for
/// parsing a legacy color value): a color name, or hexadecimal digits, `#` or not, of any length, what is not a digit
/// taken as `0`. `#8ac9b` (a digit short) is `#8ac9b0`, `#ff00` is `#ff0000`, `8b0000` is dark red. Before, a value of
/// five digits was read as `#08ac9b` (another color) and one of four was no color at all.
Color? parseLegacyColor(String? value) {
  final v = value?.trim();
  if (v == null || v.isEmpty || v.toLowerCase() == 'transparent') {
    return null;
  }
  final named = WebColors.fromString(v);
  if (named.isValid) {
    return Color(named.colorValue);
  }
  if (v.length == 4 && v.startsWith('#') && _hexRe.hasMatch(v.substring(1).toLowerCase())) {
    return parseCssColor(v);
  }
  var digits = v.length > 128 ? v.substring(0, 128) : v;
  if (digits.startsWith('#')) {
    digits = digits.substring(1);
  }
  digits = digits.replaceAll(_notHexRe, '0');
  final missing = digits.isEmpty ? 3 : (3 - digits.length % 3) % 3;
  digits = digits.padRight(digits.length + missing, '0');
  final length = digits.length ~/ 3;
  var parts = [for (var i = 0; i < 3; i++) digits.substring(i * length, (i + 1) * length)];
  if (length > 8) {
    parts = [for (final p in parts) p.substring(p.length - 8)];
  }
  while (parts.first.length > 2 && parts.every((p) => p.startsWith('0'))) {
    parts = [for (final p in parts) p.substring(1)];
  }
  if (parts.first.length > 2) {
    parts = [for (final p in parts) p.substring(0, 2)];
  }
  final channels = [for (final p in parts) int.parse(p, radix: 16)];
  return Color.fromARGB(255, channels[0], channels[1], channels[2]);
}

final _notHexRe = RegExp('[^0-9a-fA-F]');

Color? _parseColorFunction(String name, String arguments) {
  // `rgb(1, 2, 3)`, `rgba(1, 2, 3, .5)`, `rgb(1 2 3 / 50%)`.
  final slash = arguments.split('/');
  if (slash.length > 2) {
    return null;
  }
  final parts = slash.first.contains(',') ? slash.first.split(',') : slash.first.trim().split(_spaceRe);
  final args = [for (final p in parts) p.trim()];
  if (slash.length == 2) {
    args.add(slash[1].trim());
  }
  if (args.length < 3 || args.length > 4 || args.any((e) => e.isEmpty)) {
    return null;
  }
  final alpha = args.length == 4 ? _parseFraction(args[3]) : 1.0;
  if (alpha == null) {
    return null;
  }
  if (name.startsWith('rgb')) {
    final channels = <int>[];
    for (final a in args.take(3)) {
      final double? c;
      if (a.endsWith('%')) {
        final p = double.tryParse(a.substring(0, a.length - 1));
        c = p == null ? null : p * 2.55;
      } else {
        c = double.tryParse(a);
      }
      if (c == null || !c.isFinite) {
        return null;
      }
      channels.add(c.clamp(0, 255).round());
    }
    return Color.fromARGB((alpha * 255).round(), channels[0], channels[1], channels[2]);
  }
  final hue = _parseHue(args[0]);
  final saturation = _parsePercent(args[1]);
  final lightness = _parsePercent(args[2]);
  if (hue == null || saturation == null || lightness == null) {
    return null;
  }
  if (!hue.isFinite || !saturation.isFinite || !lightness.isFinite) {
    return null;
  }
  return HSLColor.fromAHSL(alpha, hue % 360, saturation.clamp(0, 1), lightness.clamp(0, 1)).toColor();
}

/// A number from 0 to 1, or a percentage.
double? _parseFraction(String value) {
  final double? n;
  if (value.endsWith('%')) {
    final p = double.tryParse(value.substring(0, value.length - 1));
    n = p == null ? null : p / 100;
  } else {
    n = double.tryParse(value);
  }
  // `1e400` is infinity, `NaN` no number: none of them is an alpha.
  return n == null || !n.isFinite ? null : n.clamp(0, 1);
}

double? _parsePercent(String value) {
  final p = double.tryParse(value.endsWith('%') ? value.substring(0, value.length - 1) : value);
  return p == null ? null : p / 100;
}

/// A hue in degrees.
double? _parseHue(String value) {
  for (final (unit, toDegrees) in const [('deg', 1.0), ('grad', 0.9), ('rad', 180 / math.pi), ('turn', 360.0)]) {
    if (value.endsWith(unit)) {
      final n = double.tryParse(value.substring(0, value.length - unit.length));
      return n == null ? null : n * toDegrees;
    }
  }
  return double.tryParse(value);
}

final _lengthRe = RegExp(r'^(-?(?:\d+\.?\d*|\.\d+))(px|pt|em|rem|pc|in|cm|mm|q)?$');

/// The css length [value] (`12px`, `9pt`, `2em`, `0`); null for a percentage, a unit relative to the page (`vw`) or
/// an expression (`calc()`), which do not apply to a post's text.
CssLength? parseCssLength(String value) {
  final m = _lengthRe.firstMatch(value.trim().toLowerCase());
  if (m == null) {
    return null;
  }
  final n = double.parse(m.group(1)!);
  if (!n.isFinite) {
    // Hundreds of digits: infinity.
    return null;
  }
  return switch (m.group(2)) {
    null => n == 0 ? const CssLength.px(0) : null,
    'px' => CssLength.px(n),
    'pt' => CssLength.px(n * 4 / 3),
    'pc' => CssLength.px(n * 16),
    'in' => CssLength.px(n * 96),
    'cm' => CssLength.px(n * 96 / 2.54),
    'mm' => CssLength.px(n * 96 / 25.4),
    'q' => CssLength.px(n * 96 / 101.6),
    'em' => CssLength.em(n),
    'rem' => CssLength.px(n * _webRootFontSize),
    _ => null,
  };
}

/// The css pixel sizes of the font size keywords, as a browser has them (the sizes of `<font size="1">` to `"7"` too,
/// see `FontSize`).
const _fontSizeKeywords = {
  'xx-small': 9.0,
  'x-small': 10.0,
  'small': 13.0,
  'medium': 16.0,
  'large': 18.0,
  'x-large': 24.0,
  'xx-large': 32.0,
  'xxx-large': 48.0,
};

/// The css font size [value] (lower case): a length, a percentage of the size around it, a keyword.
CssLength? parseCssFontSize(String value) {
  final keyword = _fontSizeKeywords[value];
  if (keyword != null) {
    return CssLength.px(keyword);
  }
  if (value == 'larger') {
    return const CssLength.em(1.2);
  }
  if (value == 'smaller') {
    return const CssLength.em(5 / 6);
  }
  if (value.endsWith('%')) {
    final p = double.tryParse(value.substring(0, value.length - 1));
    return p == null || p < 0 ? null : CssLength.em(p / 100);
  }
  final length = parseCssLength(value);
  return length == null || length.value < 0 ? null : length;
}

/// Most shadows of a text taken: a shadow is drawn for every glyph, a long list of them on a long text is slow.
const _maxShadows = 6;

final _shadowTokenRe = RegExp(r'(?:rgba?|hsla?)\([^)]*\)|#[0-9a-fA-F]+|-?(?:\d+\.?\d*|\.\d+)[a-zA-Z%]*|[a-zA-Z-]+');

/// The shadows of css `text-shadow` [value]: empty for `none`, null when one of them cannot be read.
List<CssShadow>? parseCssTextShadows(String value) {
  final v = value.trim();
  if (v.toLowerCase() == 'none') {
    return const [];
  }
  final shadows = <CssShadow>[];
  for (final part in _splitTopLevel(v, ',')) {
    Color? color;
    final lengths = <CssLength>[];
    for (final m in _shadowTokenRe.allMatches(part)) {
      final token = m.group(0)!;
      final length = parseCssLength(token);
      if (length != null) {
        lengths.add(length);
        continue;
      }
      final c = parseCssColor(token);
      if (c == null || color != null) {
        return null;
      }
      color = c;
    }
    if (lengths.length < 2 || lengths.length > 4) {
      return null;
    }
    if (shadows.length < _maxShadows) {
      shadows.add(
        CssShadow(
          dx: lengths[0],
          dy: lengths[1],
          blur: lengths.length > 2 ? lengths[2] : const CssLength.px(0),
          color: color,
        ),
      );
    }
  }
  return shadows;
}

/*                Declarations and style sheets                      */

/// A declaration of css: `property: value`, maybe `!important`.
@immutable
final class CssDeclaration {
  /// Constructor.
  const CssDeclaration(this.property, this.value, {this.important = false});

  /// The property, in lower case.
  final String property;

  /// The value.
  final String value;

  /// Declared `!important`.
  final bool important;
}

/// Most characters of a block of declarations read (an inline `style`).
const _maxDeclarationsLength = 4096;

/// Most declarations read from a block.
const _maxDeclarations = 64;

/// Most characters of a value taken, its `var()` resolved: a longer one is left out. A custom property may hold
/// others, each many times (`--v2: var(--v1) var(--v1)…`): resolved without a bound, a few lines of css grew to
/// gigabytes.
const _maxValueLength = 1024;

final _importantRe = RegExp(r'!\s*important\s*$', caseSensitive: false);
final _varRe = RegExp(r'var\(\s*(--[\w-]+)\s*(?:,([^()]*))?\)');

/// The declarations of a css block [text] (`color: red; font-size: 12px`), the custom properties (`--ink: #333`)
/// among them. A `var()` in a value is taken from [variables]; a value with one that is not there is left out.
List<CssDeclaration> parseCssDeclarations(String text, {Map<String, String> variables = const {}}) {
  final declarations = <CssDeclaration>[];
  final source = text.length > _maxDeclarationsLength ? text.substring(0, _maxDeclarationsLength) : text;
  for (final part in _splitTopLevel(source, ';')) {
    if (declarations.length >= _maxDeclarations) {
      break;
    }
    final colon = part.indexOf(':');
    if (colon <= 0) {
      continue;
    }
    final property = part.substring(0, colon).trim().toLowerCase();
    var value = part.substring(colon + 1).trim();
    final important = _importantRe.hasMatch(value);
    if (important) {
      value = value.replaceFirst(_importantRe, '').trim();
    }
    if (!property.startsWith('--')) {
      final resolved = _resolveVariables(value, variables);
      if (resolved == null) {
        continue;
      }
      value = resolved;
    }
    if (property.isEmpty || value.isEmpty || value.length > _maxValueLength) {
      continue;
    }
    declarations.add(CssDeclaration(property, value, important: important));
  }
  return declarations;
}

/// [value] with its `var()` taken from [variables], null when one is not there and has no fallback, or when it grows
/// longer than [_maxValueLength].
String? _resolveVariables(String value, Map<String, String> variables) {
  var v = value;
  for (var depth = 0; depth < 4 && v.contains('var('); depth++) {
    var missing = false;
    var added = 0;
    final next = v.replaceAllMapped(_varRe, (m) {
      if (missing || added > _maxValueLength) {
        return '';
      }
      final resolved = variables[m.group(1)!] ?? m.group(2)?.trim();
      if (resolved == null) {
        missing = true;
        return '';
      }
      added += resolved.length;
      return added > _maxValueLength ? '' : resolved;
    });
    if (missing || added > _maxValueLength || next.length > _maxValueLength) {
      return null;
    }
    v = next;
  }
  return v.contains('var(') ? null : v;
}

/// One part of a selector: a tag, an id, classes (`div`, `.Red`, `#tsdm`, `span.big`).
@immutable
final class _Compound {
  _Compound({this.tag, this.id, this.classes = const []})
    : _keys = [?tag, if (id != null) '#$id', for (final c in classes) '.$c'];

  final String? tag;
  final String? id;
  final List<String> classes;

  /// What an element has to have to match, as [AuthorStyler] keys an element: its tag, `#` its id, `.` each class.
  final List<String> _keys;

  /// The key an element is looked up by for this compound: its id, else its first class, else its tag.
  String get key => id != null ? '#$id' : (classes.isNotEmpty ? '.${classes.first}' : tag!);

  /// Specificity as css counts it: ids, classes, tags.
  int get specificity => (id == null ? 0 : 10000) + classes.length * 100 + (tag == null ? 0 : 1);

  /// Whether an element with [keys] (see [AuthorStyler]) matches.
  bool matchesKeys(uh.Element element, Set<String> keys) {
    for (final k in _keys) {
      if (!keys.contains(k)) {
        return false;
      }
    }
    return true;
  }

  static final _re = RegExp(r'^([a-zA-Z][a-zA-Z0-9-]*)?((?:[.#][-_a-zA-Z0-9\u00a0-\uffff]+)*)$');
  static final _partRe = RegExp(r'[.#][-_a-zA-Z0-9\u00a0-\uffff]+');

  static _Compound? parse(String text) {
    final m = _re.firstMatch(text);
    if (m == null || text.isEmpty) {
      return null;
    }
    String? id;
    final classes = <String>[];
    for (final part in _partRe.allMatches(m.group(2) ?? '')) {
      final s = part.group(0)!;
      if (s.startsWith('#')) {
        if (id != null) {
          return null;
        }
        id = s.substring(1);
      } else {
        classes.add(s.substring(1));
      }
    }
    final tag = m.group(1)?.toLowerCase();
    if (tag == null && id == null && classes.isEmpty) {
      return null;
    }
    return _Compound(tag: tag, id: id, classes: classes);
  }
}

/// A selector the app understands: [compounds] separated by white space (descendants, `.box .card span`), the last
/// one the [subject].
@immutable
final class _Selector {
  const _Selector(this.compounds);

  /// The compounds, from the outermost ancestor to the subject.
  final List<_Compound> compounds;

  _Compound get subject => compounds.last;

  /// The ancestor compounds, nearest first.
  Iterable<_Compound> get ancestors => compounds.reversed.skip(1);

  int get specificity => compounds.fold(0, (sum, c) => sum + c.specificity);

  /// Most compounds of a selector the app takes: the subject and three ancestors.
  static const maxCompounds = 4;

  /// Most ancestors looked at to match the ancestors of a selector.
  static const maxDepth = 64;

  /// Whether [element], whose subject compound already matches, has the ancestors of the selector, nearest first,
  /// each the nearest one above the one before (the descendant combinator matches the nearest ancestor greedily).
  bool matchesAncestors(uh.Element element, uh.Element root, AuthorStyler styler) {
    var node = element.parent;
    var depth = 0;
    for (final compound in ancestors) {
      var found = false;
      while (node != null && depth < maxDepth) {
        final current = node;
        node = identical(current, root) ? null : current.parent;
        depth++;
        if (compound.matchesKeys(current, styler._keysOf(current))) {
          found = true;
          break;
        }
      }
      if (!found) {
        return false;
      }
    }
    return true;
  }

  /// The selector [text], null when it is not one the app understands: a child, sibling or attribute selector, a
  /// pseudo class, `*`, more than [maxCompounds] compounds.
  static _Selector? parse(String text) {
    final t = text.trim();
    if (t.isEmpty || t.length > 200 || t.contains(_unsupportedRe)) {
      return null;
    }
    final parts = t.split(_spaceRe);
    if (parts.length > maxCompounds) {
      return null;
    }
    final compounds = <_Compound>[];
    for (final part in parts) {
      final compound = _Compound.parse(part);
      if (compound == null) {
        return null;
      }
      compounds.add(compound);
    }
    return _Selector(compounds);
  }

  static final _unsupportedRe = RegExp(r'[>+~:\[\]*()|\\@]');
}

/// A rule of a style sheet: a selector and its declarations, where it is in the sheets.
@immutable
final class _Rule {
  const _Rule(this.selector, this.declarations, this.order);

  final _Selector selector;
  final List<CssDeclaration> declarations;
  final int order;
}

/// Most characters of style sheets read from one piece of html; the rest is left out.
const int maxStyleSheetLength = 64 * 1024;

/// Most rules taken from the style sheets of one piece of html.
const _maxRules = 1024;

/// Most custom properties (`--name`) taken.
const _maxVariables = 256;

/// The forum's style sheet, the part that styles the classes posts use (`common.css` of the forum's theme): what a
/// post written with them looks like on the web page. The app's own look stays for the rest (quotes, code blocks).
const _forumStyleSheet = '''
.xi1, .onerror { color: #F26C4F }
.xi2, .xi2 a, .xi3 a { color: #369 }
.xg1, .xg1 a { color: #999 !important }
.xg1 .xi2 { color: #369 !important }
.xg2 { color: #666 }
.xw0 { font-weight: 400 }
.xw1 { font-weight: 700 }
.xs0 { font-size: 0.83em }
.xs1 { font-size: 12px !important }
.xs2 { font-size: 14px !important }
.xs3 { font-size: 16px !important }
.xst { font-size: 14px }
''';

/// The part of the forum's style sheet for the content of a post (`.t_f`, `.pcb` in `forum_viewthread.css`): text in
/// a cell of a table is at the size of the post's text, not at the size of a `<font>` around the table (`.t_f td`);
/// the headings are a little larger than the text (`.pcb h1`) or as large (`h3 { font-size: 1em }`); `<em>` is gray;
/// the link under a player of `[media]` (`如果无法播放，请点击此处在新窗口打开`) is small, gray, centered.
const _postStyleSheet = '''
td { font-size: 14px }
h1, h2 { font-size: 1.17em }
h3, h4, h5, h6 { font-size: 1em }
em { color: #666 }
.media_tips { text-align: center }
.media_tips a { font-size: 12px !important; color: #999 !important; text-decoration: none !important }
''';

/// Longest a piece of html's style sheets are read for; a style sheet that takes longer is left out.
const _parseBudget = Duration(milliseconds: 100);

/// Longest the rules of a piece of html's style sheets are matched for, all its elements together; past it, only the
/// `style` of each element is read.
const _matchBudget = Duration(milliseconds: 250);

/// The style sheets a piece of html is shown with: the forum's ([_forumStyleSheet], [_postStyleSheet] for a post's
/// content) and its own `<style>` elements, read once.
final class AuthorStyleSheets {
  AuthorStyleSheets._(this._rules, this._variables) {
    for (final rule in _rules) {
      final selector = rule.selector;
      final key = selector.subject.key;
      final nearest = selector.ancestors.firstOrNull;
      if (nearest == null) {
        (_plain[key] ??= []).add(rule);
      } else {
        ((_nested[key] ??= {})[nearest.key] ??= []).add(rule);
      }
    }
  }

  /// The style sheets of the html under [root]: the forum's, [postContent] the content of a post, and those of the
  /// `<style>` elements in it.
  ///
  /// What cannot be read is left out, as a browser does: an at-rule (`@media`, `@keyframes`), a selector the app does
  /// not understand, a property it does not show. The style sheets are read up to [maxStyleSheetLength] characters and
  /// for at most [_parseBudget]; a style sheet that cannot be read in that, or at all, is left out entirely: the html
  /// is shown with the forum's.
  factory AuthorStyleSheets.of(uh.Element root, {required bool postContent}) {
    final forum = postContent ? _forumPost : _forum;
    try {
      final styles = root.querySelectorAll('style');
      if (styles.isEmpty) {
        return forum;
      }
      final buffer = StringBuffer(_forumStyleSheet);
      if (postContent) {
        buffer.write(_postStyleSheet);
      }
      var length = 0;
      for (final style in styles) {
        final text = style.text ?? '';
        if (length + text.length > maxStyleSheetLength) {
          buffer.write(text.substring(0, maxStyleSheetLength - length));
          break;
        }
        buffer
          ..write('\n')
          ..write(text);
        length += text.length;
      }
      return AuthorStyleSheets.parse(buffer.toString(), budget: _parseBudget) ?? forum;
    } on Object {
      return forum;
    }
  }

  /// The rules of the style sheet [css]; null when reading it takes longer than [budget].
  static AuthorStyleSheets? parse(String css, {Duration? budget}) {
    final clock = Stopwatch()..start();
    bool late() => budget != null && clock.elapsed > budget;
    final blocks = _blocks(_withoutComments(css));
    // Custom properties first: a value may use one declared after it. The scope of a custom property is not kept
    // (the last declaration of a name wins): posts declare theirs once, on the block around everything.
    final variables = <String, String>{};
    final parsed = <(String, List<CssDeclaration>)>[];
    for (final (_, body) in blocks) {
      if (late()) {
        return null;
      }
      for (final d in parseCssDeclarations(body)) {
        if (d.property.startsWith('--') && variables.length < _maxVariables && d.value.length <= _maxValueLength) {
          variables[d.property] = d.value;
        }
      }
    }
    // Variables made of variables; one longer than a value can be once resolved is left out.
    for (final key in variables.keys.toList()) {
      final resolved = _resolveVariables(variables[key]!, variables);
      if (resolved == null || resolved.length > _maxValueLength) {
        variables.remove(key);
      } else {
        variables[key] = resolved;
      }
    }
    for (final (prelude, body) in blocks) {
      if (late()) {
        return null;
      }
      final declarations = parseCssDeclarations(
        body,
        variables: variables,
      ).where((e) => !e.property.startsWith('--')).where((e) => _shownProperties.contains(e.property)).toList();
      if (declarations.isNotEmpty) {
        parsed.add((prelude, declarations));
      }
    }
    final rules = <_Rule>[];
    var order = 0;
    for (final (prelude, declarations) in parsed) {
      for (final text in prelude.split(',').take(32)) {
        final selector = _Selector.parse(text);
        if (selector != null && rules.length < _maxRules) {
          rules.add(_Rule(selector, declarations, order++));
        }
      }
    }
    return late() ? null : AuthorStyleSheets._(rules, variables);
  }

  /// No rules: the html has no style sheet of its own, and is not given the forum's.
  static final empty = AuthorStyleSheets._(const [], const {});

  /// The forum's style sheet, read once: html without a `<style>` of its own.
  static final AuthorStyleSheets _forum = AuthorStyleSheets.parse(_forumStyleSheet)!;

  /// The forum's style sheet for the content of a post, read once.
  static final AuthorStyleSheets _forumPost = AuthorStyleSheets.parse('$_forumStyleSheet$_postStyleSheet')!;

  /// [css] without its comments, read once from the start: a comment not closed runs to the end.
  static String _withoutComments(String css) {
    final buffer = StringBuffer();
    var i = 0;
    while (i < css.length) {
      final open = css.indexOf('/*', i);
      if (open < 0) {
        buffer.write(css.substring(i));
        break;
      }
      buffer
        ..write(css.substring(i, open))
        ..write(' ');
      final close = css.indexOf('*/', open + 2);
      if (close < 0) {
        break;
      }
      i = close + 2;
    }
    return buffer.toString();
  }

  /// The properties the app shows (see [AuthorStyle.declare]); the others are not kept.
  static const _shownProperties = {
    'color',
    'background-color',
    'background',
    'background-image',
    'font-size',
    'font-weight',
    'font-style',
    'text-decoration',
    'text-decoration-line',
    'text-align',
    'text-indent',
    'text-shadow',
  };

  /// The rule blocks of [css] (no comments): the selectors and the declarations of each, at-rules left out.
  static List<(String, String)> _blocks(String css) {
    final blocks = <(String, String)>[];
    var i = 0;
    while (i < css.length && blocks.length < _maxRules) {
      final open = css.indexOf('{', i);
      if (open < 0) {
        break;
      }
      var prelude = css.substring(i, open);
      // A statement at-rule before the block (`@import url(…);`, `@charset`) ends at its semicolon.
      final semicolon = prelude.lastIndexOf(';');
      if (semicolon >= 0) {
        prelude = prelude.substring(semicolon + 1);
      }
      // The end of the block, nested blocks (of an at-rule) skipped.
      var depth = 1;
      var j = open + 1;
      var nested = false;
      while (j < css.length && depth > 0) {
        final c = css.codeUnitAt(j);
        if (c == 0x7B) {
          depth++;
          nested = true;
        } else if (c == 0x7D) {
          depth--;
        }
        j++;
      }
      final body = css.substring(open + 1, depth == 0 ? j - 1 : j);
      if (!nested && !prelude.trim().startsWith('@')) {
        blocks.add((prelude.trim(), body));
      }
      i = j;
    }
    return blocks;
  }

  final List<_Rule> _rules;
  final Map<String, String> _variables;

  /// Rules of one compound, by the key of their subject ([_Compound.key]).
  final Map<String, List<_Rule>> _plain = {};

  /// Rules with ancestors, by the key of their subject, then by the key of their nearest ancestor.
  final Map<String, Map<String, List<_Rule>>> _nested = {};

  /// How the style sheets are matched to the elements under [root] in one go: with what is kept of the elements
  /// between them, within one budget.
  AuthorStyler styler(uh.Element root) => AuthorStyler._(this, root);
}

/// The style sheets matched to the elements of one piece of html, see [styleOf].
///
/// Each element's keys (its tag, `#` its id, `.` each class) are read once, so are the keys of its ancestors: a rule
/// with ancestors is only tried where the key of its nearest ancestor is above the element, and its ancestors are
/// only looked for then. Before, every rule with an ancestor walked up from every element, the classes read again at
/// each level: a thousand rules on a long floor took seconds. All the matching of the html together takes at most
/// [_matchBudget]; past it, the rules are not matched any more, only the `style` of each element is read.
final class AuthorStyler {
  AuthorStyler._(this._sheets, this._root);

  final AuthorStyleSheets _sheets;
  final uh.Element _root;
  final _keys = Map<uh.Element, Set<String>>.identity();
  final _clock = Stopwatch();

  /// The keys of [element]: its tag, `#` its id, `.` each class.
  Set<String> _keysOf(uh.Element element) => _keys.putIfAbsent(element, () {
    final keys = <String>{element.localName};
    final id = element.id;
    if (id.isNotEmpty) {
      keys.add('#$id');
    }
    for (final c in (element.attributes['class'] ?? '').split(_spaceRe)) {
      if (c.isNotEmpty) {
        keys.add('.$c');
      }
    }
    return keys;
  });

  /// The keys of the ancestors of [element] up to the root, at most [_Selector.maxDepth] of them.
  Set<String> _ancestorKeysOf(uh.Element element) {
    final keys = <String>{};
    var node = element.parent;
    for (var depth = 0; node != null && depth < _Selector.maxDepth; depth++) {
      keys.addAll(_keysOf(node));
      node = identical(node, _root) ? null : node.parent;
    }
    return keys;
  }

  /// The style the author gave [element], null when none: the rules matching it in the order of the cascade (by
  /// specificity, then by place), then its own `style`; the declarations marked `!important` last, in the same order.
  /// The presentational attributes (`<font color>`, `align`, `bgcolor`) are taken before this by the html renderer,
  /// as a browser takes them before the style sheets.
  AuthorStyle? styleOf(uh.Element element) {
    final inline = element.attributes['style'];
    final matched = <_Rule>[];
    if (_sheets._rules.isNotEmpty && _clock.elapsed < _matchBudget) {
      _clock.start();
      try {
        final keys = _keysOf(element);
        Set<String>? ancestorKeys;
        for (final key in keys) {
          for (final rule in _sheets._plain[key] ?? const <_Rule>[]) {
            if (rule.selector.subject.matchesKeys(element, keys)) {
              matched.add(rule);
            }
          }
          final nested = _sheets._nested[key];
          if (nested == null) {
            continue;
          }
          ancestorKeys ??= _ancestorKeysOf(element);
          // The smaller of the two sides is walked.
          final candidates = nested.length <= ancestorKeys.length
              ? [
                  for (final MapEntry(key: k, value: rules) in nested.entries)
                    if (ancestorKeys.contains(k)) ...rules,
                ]
              : [for (final k in ancestorKeys) ...?nested[k]];
          for (final rule in candidates) {
            final selector = rule.selector;
            if (selector.subject.matchesKeys(element, keys) &&
                selector.ancestors.every((c) => c._keys.every(ancestorKeys!.contains)) &&
                selector.matchesAncestors(element, _root, this)) {
              matched.add(rule);
            }
          }
        }
      } finally {
        _clock.stop();
      }
    }
    if (matched.isEmpty && (inline == null || inline.trim().isEmpty)) {
      return null;
    }
    // A rule is kept under one key only, and its subject has that key once: it is found once.
    matched.sort((a, b) {
      final bySpecificity = a.selector.specificity.compareTo(b.selector.specificity);
      return bySpecificity != 0 ? bySpecificity : a.order.compareTo(b.order);
    });
    final own = inline == null ? const <CssDeclaration>[] : parseCssDeclarations(inline, variables: _sheets._variables);
    final style = AuthorStyle();
    for (final important in [false, true]) {
      for (final rule in matched) {
        for (final d in rule.declarations) {
          if (d.important == important) {
            style.declare(d.property, d.value);
          }
        }
      }
      for (final d in own) {
        if (d.important == important) {
          style.declare(d.property, d.value);
        }
      }
    }
    return style.isEmpty ? null : style;
  }
}

/*                Colors in the theme                      */

/// How the colors an author gave a post are shown in a [ThemeData]: as given in a light theme, where the web page is
/// light too; in a dark theme, the backgrounds dark in their own hue and the text readable on what it is on.
///
/// The dark theme follows the forum's own (its `tsdm_theme`), which follows what Dark Reader and Chrome's automatic
/// dark theme settled on: the hue of a color is kept, never inverted, and only a text that does not read on its
/// background (WCAG AA, a contrast of 4.5:1) is lightened, to the least lightness that reads, the most chroma the
/// colors of a screen hold there. Text of the color of its background is hidden on purpose (an answer kept for later,
/// "你知道太多了"): it stays hidden. Before, every author color was inverted in a dark theme (a yellow became olive, a
/// light background a dark one in another hue) whether it read or not, and backgrounds were inverted to whatever came
/// out.
final class AuthorColors {
  /// The colors in [theme].
  AuthorColors(ThemeData theme)
    : dark = theme.brightness == Brightness.dark,
      surface = theme.cardTheme.color ?? theme.colorScheme.surfaceContainerLow;

  /// The theme is dark.
  final bool dark;

  /// The surface a post's text is on: its card.
  final Color surface;

  final _inks = <(int, int), Color>{};
  final _backgrounds = <int, Color>{};

  /// The color text of [color] is shown in [on] a background of the author (null: on the post's surface).
  /// [pictureBehind]: the author put the text on a picture, which the app does not show (on [on] under the picture);
  /// a text that cannot be seen at all without it (white on a dark picture) is made readable, in a light theme too.
  Color text(Color color, {Color? on, bool pictureBehind = false}) {
    if (color.a < _seenAlpha) {
      // `color: transparent`: hidden on purpose.
      return color;
    }
    if (!dark) {
      // As the author gave it, as the web page shows it; but on a picture the app does not show, a text that could
      // not be seen at all on the surface (white on a dark picture) is made readable.
      if (pictureBehind) {
        final behind = on == null ? surface : (background(on) ?? surface);
        if (contrastRatio(opaque(color), behind) < _unseenContrast) {
          return _inks.putIfAbsent((color.toARGB32(), behind.toARGB32()), () => readableInk(color, behind));
        }
      }
      return color;
    }
    // Without a background of the author, the text is on the white of the web page: white text there is hidden on
    // purpose (反白, an answer to select), as it is in a block the author painted white. Not on a picture, which
    // the white text was meant to be read on.
    final behind = opaque(on ?? _pageWhite);
    if (!pictureBehind && isCamouflaged(opaque(color), behind)) {
      // Hidden in the color of its background: hidden in the dark one too.
      return background(color) ?? surface;
    }
    final shownBehind = on == null ? surface : (background(behind) ?? surface);
    return _inks.putIfAbsent((color.toARGB32(), shownBehind.toARGB32()), () => readableInk(color, shownBehind));
  }

  /// The color text of [color] is shown in on a background of the author [on] it was not given in (the theme's text
  /// color, a color given around the block): readable on the background as it is painted ([readableInk]), in a light
  /// theme too, never hidden. Null when the background is not painted (see [background]).
  ///
  /// Before, the background was shown and the color was not changed: the theme's dark text on a dark block of a post
  /// whose own text color the app could not read (`.card .label { color: #d6bec8 }`) could not be seen at all.
  Color? onBackground(Color color, Color on) {
    final shown = background(on);
    if (shown == null) {
      return null;
    }
    return _inks.putIfAbsent((color.toARGB32(), shown.toARGB32()), () => readableInk(color, shown));
  }

  /// The color a background of [color] is painted in, null when it is not painted: transparent, or the white of the
  /// web page's own background (`background: white`, `#fefefe` pasted from another page), which shows nothing there.
  Color? background(Color color) {
    if (color.a < _seenAlpha) {
      return null;
    }
    final c = opaque(color);
    if (_isPageWhite(c)) {
      return null;
    }
    if (!dark) {
      return c;
    }
    return _backgrounds.putIfAbsent(c.toARGB32(), () => darkBackground(c));
  }

  static bool _isPageWhite(Color c) =>
      (c.r * 255).round() >= 248 && (c.g * 255).round() >= 248 && (c.b * 255).round() >= 248;
}

/// Text this close to the surface cannot be seen at all: see [AuthorColors.text].
const _unseenContrast = 1.5;

/// Text and background this close are hidden text, not unreadable text: see [AuthorColors].
const camouflageContrast = 1.15;

/// The white of the web page, what text without a background of the author is on.
const _pageWhite = Color(0xFFFFFFFF);

/// Whether text in [color] on [background] is hidden on purpose: as light as its background
/// ([camouflageContrast]) and of the same color: next to it in OKLab, or both grays. Red on a gray of its lightness,
/// orange on silver, are as light but seen: they are made readable, not hidden.
bool isCamouflaged(Color color, Color background) {
  if (contrastRatio(color, background) > camouflageContrast) {
    return false;
  }
  final (l1, a1, b1) = _toOklab(color);
  final (l2, a2, b2) = _toOklab(background);
  final distance = math.sqrt(math.pow(l1 - l2, 2) + math.pow(a1 - a2, 2) + math.pow(b1 - b2, 2));
  final gray1 = math.sqrt(a1 * a1 + b1 * b1) < _grayChroma;
  final gray2 = math.sqrt(a2 * a2 + b2 * b2) < _grayChroma;
  return distance < _sameColorDistance || (gray1 && gray2);
}

/// Colors closer than this in OKLab are the same color to the eye.
const _sameColorDistance = 0.05;

/// A color of less chroma than this (OKLab) is a gray.
const _grayChroma = 0.04;

/// [color] over the white of the web page: its alpha taken out.
Color opaque(Color color) {
  if (color.a >= 1) {
    return color;
  }
  final a = color.a;
  return Color.from(alpha: 1, red: color.r * a + (1 - a), green: color.g * a + (1 - a), blue: color.b * a + (1 - a));
}

/// Relative luminance of [color], as WCAG has it.
double relativeLuminance(Color color) {
  double channel(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b);
}

/// Contrast ratio of [a] and [b], as WCAG has it: 1 to 21.
double contrastRatio(Color a, Color b) {
  final x = relativeLuminance(a);
  final y = relativeLuminance(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

/// Contrast a text needs on its background to be read: WCAG AA for body text.
const readableContrast = 4.5;

/// [color] if text in it reads on [background], else the color of its hue of the least change of lightness that
/// reads ([readableContrast]), with the most chroma the screen shows at that lightness: lighter on a dark
/// background, darker on a light one. A gray when no color of the hue reads.
Color readableInk(Color color, Color background) {
  final c = opaque(color);
  if (contrastRatio(c, background) >= readableContrast) {
    return c;
  }
  final lightSurface = relativeLuminance(background) > 0.28;
  final (_, a, b) = _toOklab(c);
  final chroma = math.sqrt(a * a + b * b);
  final hue = math.atan2(b, a);
  const darkLadder = [0.75, 0.82, 0.88, 0.94, 1.0];
  const lightLadder = [0.42, 0.34, 0.26, 0.16, 0.06];
  for (final level in lightSurface ? lightLadder : darkLadder) {
    final limit = math.min(chroma, _gamutChroma(level, hue));
    final candidate = _fromOklab(level, limit * math.cos(hue), limit * math.sin(hue));
    if (contrastRatio(candidate, background) >= readableContrast) {
      return candidate;
    }
  }
  return lightSurface ? const Color(0xFF181818) : const Color(0xFFECECEC);
}

/// Lightness (OKLab) a background is kept at or under in a dark theme: a darker one already is a dark background.
const _darkBackgroundLightness = 0.40;

/// Lightness (OKLab) of the background of the lightest color (white) in a dark theme: a little lighter than the dark
/// surface of a card, still seen as a block.
const _darkestBackgroundLightness = 0.26;

/// The background of [color] in a dark theme: its hue, dark. A dark color stays; a lighter one gets darker the
/// lighter it is (pink, wheat and silver, the backgrounds of posts, are the lightest and get the darkest), with the
/// chroma the screen shows at that lightness.
Color darkBackground(Color color) {
  final c = opaque(color);
  final (l, a, b) = _toOklab(c);
  if (l <= _darkBackgroundLightness) {
    return c;
  }
  final level =
      _darkBackgroundLightness -
      (_darkBackgroundLightness - _darkestBackgroundLightness) *
          (l - _darkBackgroundLightness) /
          (1 - _darkBackgroundLightness);
  final chroma = math.sqrt(a * a + b * b);
  final hue = math.atan2(b, a);
  final limit = math.min(chroma, _gamutChroma(level, hue));
  return _fromOklab(level, limit * math.cos(hue), limit * math.sin(hue));
}

double _linear(double c) => c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

double _gamma(double c) {
  final v = c.clamp(0.0, 1.0);
  return v <= 0.0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - 0.055;
}

double _cbrt(double x) => x < 0 ? -math.pow(-x, 1 / 3).toDouble() : math.pow(x, 1 / 3).toDouble();

(double, double, double) _toOklab(Color color) {
  final r = _linear(color.r);
  final g = _linear(color.g);
  final b = _linear(color.b);
  final l = _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
  final m = _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
  final s = _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
  return (
    0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
    1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
    0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s,
  );
}

(double, double, double) _oklabToLinear(double l, double a, double b) {
  final l1 = l + 0.3963377774 * a + 0.2158037573 * b;
  final m1 = l - 0.1055613458 * a - 0.0638541728 * b;
  final s1 = l - 0.0894841775 * a - 1.2914855480 * b;
  final l3 = l1 * l1 * l1;
  final m3 = m1 * m1 * m1;
  final s3 = s1 * s1 * s1;
  return (
    4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3,
    -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3,
    -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3,
  );
}

Color _fromOklab(double l, double a, double b) {
  final (r, g, bl) = _oklabToLinear(l, a, b);
  return Color.from(alpha: 1, red: _gamma(r), green: _gamma(g), blue: _gamma(bl));
}

/// The most chroma a color of [hue] at lightness [level] has on a screen (sRGB).
double _gamutChroma(double level, double hue) {
  bool inGamut(double chroma) {
    final (r, g, b) = _oklabToLinear(level, chroma * math.cos(hue), chroma * math.sin(hue));
    const lo = -0.0005;
    const hi = 1.0005;
    return r >= lo && r <= hi && g >= lo && g <= hi && b >= lo && b <= hi;
  }

  var low = 0.0;
  var high = 0.4;
  for (var step = 0; step < 22; step++) {
    final mid = (low + high) / 2;
    if (inGamut(mid)) {
      low = mid;
    } else {
      high = mid;
    }
  }
  return low;
}

/// The area html munched from a post paints in ([ClipRect.clipper]): its own box and [overflow] around it, for what a
/// glyph, a glow or the shadow of a card in it draws past its edge. A post card has more space than that around its
/// content: nothing the content paints reaches another floor. Before, a shadow of the author's text (`text-shadow: 0
/// -100px`) was drawn over the floor above.
class PostContentClipper extends CustomClipper<Rect> {
  /// Constructor.
  const PostContentClipper();

  /// How far past its box the content paints.
  static const overflow = 8.0;

  @override
  Rect getClip(Size size) => (Offset.zero & size).inflate(overflow);

  @override
  bool shouldReclip(PostContentClipper oldClipper) => false;
}

/// A block of a post with the background its author gave it (`<div style="background-color: pink">`,
/// `<table bgcolor="wheat">`): [child] on [color], [padding] around it as the web page's block has.
class PostBlockBackground extends StatelessWidget {
  /// Constructor.
  const PostBlockBackground({required this.color, required this.child, this.padding = defaultPadding, super.key});

  /// Space around the content of a block.
  static const defaultPadding = EdgeInsets.symmetric(horizontal: 8, vertical: 6);

  /// Space around the content of a block in another block with a background: blocks nested several times kept
  /// narrowing the text by 16 each.
  static const nestedPadding = EdgeInsets.symmetric(horizontal: 3, vertical: 4);

  /// The background, as shown in the theme (see [AuthorColors.background]).
  final Color color;

  /// Space around [child].
  final EdgeInsetsGeometry padding;

  /// The content.
  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: color, borderRadius: const BorderRadius.all(Radius.circular(4))),
    child: Padding(padding: padding, child: child),
  );
}
