import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// How Chinese text is shown: as the forum sent it, or converted to one script on screen.
///
/// Only what is shown is converted; the text that is sent to the forum and the data kept are never touched.
enum ChineseDisplayMode {
  /// As received.
  off,

  /// Simplified text shown as Traditional (OpenCC `s2t`).
  traditional,

  /// Traditional text shown as Simplified (OpenCC `t2s`).
  simplified
  ;

  /// The mode saved as [index], [off] when out of range (a backup from a newer version).
  static ChineseDisplayMode fromIndex(int index) => index >= 0 && index < values.length ? values[index] : off;
}

/// Converts between Simplified and Traditional Chinese with the OpenCC dictionaries (`s2t` and `t2s`) by the longest
/// match, the same way OpenCC segments text.
///
/// A dictionary is `source<TAB>target` per line, see `tools/opencc/build_dict.py`.
class ChineseConverter {
  /// Builds the converter of one direction from the text of its dictionary.
  ChineseConverter.parse(String dictionary, {this.cacheLimit = 4096}) {
    final starts = <int>{};
    var longest = 1;
    for (final line in dictionary.split('\n')) {
      final tab = line.indexOf('\t');
      if (tab <= 0) {
        continue;
      }
      final key = line.substring(0, tab);
      _entries[key] = line.substring(tab + 1);
      starts.add(key.codeUnitAt(0));
      if (key.length > longest) {
        longest = key.length;
      }
    }
    _longest = longest;
    _starts = starts;
  }

  /// Most converted strings kept for [convert]; the cache starts over when it is full.
  final int cacheLimit;

  final _entries = <String, String>{};
  final _cache = <String, String>{};
  late final Set<int> _starts;
  late final int _longest;

  /// Number of dictionary entries.
  int get length => _entries.length;

  /// [text] in the script of this converter.
  ///
  /// Text with kana is Japanese and is returned as it is: kanji are shared with Chinese and must not be rewritten.
  String convert(String text) {
    if (text.isEmpty) {
      return text;
    }
    final cached = _cache[text];
    if (cached != null) {
      return cached;
    }
    final converted = _convert(text);
    if (_cache.length >= cacheLimit) {
      _cache.clear();
    }
    _cache[text] = converted;
    return converted;
  }

  String _convert(String text) {
    var first = -1;
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (_isKana(unit)) {
        return text;
      }
      if (first < 0 && _starts.contains(unit)) {
        first = i;
      }
    }
    if (first < 0) {
      return text;
    }
    final out = StringBuffer(text.substring(0, first));
    var i = first;
    while (i < text.length) {
      if (!_starts.contains(text.codeUnitAt(i))) {
        out.writeCharCode(text.codeUnitAt(i));
        i++;
        continue;
      }
      var matched = false;
      for (var n = math.min(_longest, text.length - i); n >= 1; n--) {
        final target = _entries[text.substring(i, i + n)];
        if (target != null) {
          out.write(target);
          i += n;
          matched = true;
          break;
        }
      }
      if (!matched) {
        out.writeCharCode(text.codeUnitAt(i));
        i++;
      }
    }
    return out.toString();
  }

  /// Hiragana, katakana (and their extensions) and half-width katakana.
  static bool _isKana(int unit) =>
      (unit >= 0x3040 && unit <= 0x30FF && unit != 0x30FB) ||
      (unit >= 0x31F0 && unit <= 0x31FF) ||
      (unit >= 0xFF66 && unit <= 0xFF9F);

  /// Number of strings kept for tests.
  @visibleForTesting
  int get cachedCount => _cache.length;
}
