import 'dart:convert';

/// Longest quick phrase, in characters.
const quickPhraseMaxLength = 2000;

/// Most quick phrases kept.
const quickPhraseMaxCount = 100;

/// The quick phrases saved in [raw] (`SettingsKeys.editorQuickPhrases`), in order.
///
/// A JSON list of strings. Anything else (an empty value, damaged JSON, entries that are not text or are blank) reads
/// as no phrases for that part; a phrase over [quickPhraseMaxLength] characters is cut and the list stops at
/// [quickPhraseMaxCount].
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
        if (e is String && e.trim().isNotEmpty)
          e.length > quickPhraseMaxLength ? e.substring(0, quickPhraseMaxLength) : e,
    ].take(quickPhraseMaxCount).toList();
  } on FormatException {
    return const [];
  }
}

/// [phrases] as the value to save, see [decodeQuickPhrases].
String encodeQuickPhrases(List<String> phrases) => jsonEncode(phrases);
