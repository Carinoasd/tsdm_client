import 'dart:convert';

import 'package:flutter/widgets.dart' show StringCharacters;

/// Longest quick phrase, in characters (grapheme clusters, the unit a `TextField`'s `maxLength` counts: an emoji is one).
const quickPhraseMaxLength = 2000;

/// Most quick phrases kept.
const quickPhraseMaxCount = 100;

/// The quick phrases saved in [raw] (`SettingsKeys.editorQuickPhrases`), in order.
///
/// A JSON list of strings. Anything else (an empty value, damaged JSON, entries that are not text or are blank) reads
/// as no phrases for that part; a phrase over [quickPhraseMaxLength] characters is cut (between characters, never inside
/// one) and the list stops at [quickPhraseMaxCount].
List<String> decodeQuickPhrases(String raw) {
  if (raw.isEmpty) {
    return const [];
  }
  try {
    final json = jsonDecode(raw);
    if (json is! List) {
      return const [];
    }
    return [
      for (final e in json)
        if (e is String && e.trim().isNotEmpty) _cut(e),
    ].take(quickPhraseMaxCount).toList();
  } on FormatException {
    return const [];
  }
}

/// [phrase] cut to [quickPhraseMaxLength] characters: the same unit as the field that takes it, so what the field let
/// through is read back whole and a surrogate pair is never split.
String _cut(String phrase) {
  // A string has at least as many code units as characters: a short one is kept without counting.
  if (phrase.length <= quickPhraseMaxLength) {
    return phrase;
  }
  final characters = phrase.characters;
  return characters.length > quickPhraseMaxLength ? characters.take(quickPhraseMaxLength).toString() : phrase;
}

/// [phrases] as the value to save, see [decodeQuickPhrases].
String encodeQuickPhrases(List<String> phrases) => jsonEncode(phrases);
