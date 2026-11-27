import 'dart:async';

import 'package:tsdm_client/utils/chinese_display/chinese_converter.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';

/// Matching typed words against texts the device already has (the lists kept on it, the quick open box): nothing is
/// asked from the forum.
///
/// Texts are compared folded ([foldForSearch]): in lower case and in simplified Chinese, so "收藏" typed either way
/// finds a title written either way, whatever the display setting is.

final _whitespace = RegExp(r'\s+');

/// [text] as it is compared: lower case, traditional characters as their simplified ones.
///
/// The characters are folded once the dictionary is loaded ([ensureSearchFolding]); until then only the case is.
String foldForSearch(String text) => ChineseDisplay.instance.convert(ChineseDisplayMode.simplified, text).toLowerCase();

/// Load the dictionary [foldForSearch] folds the characters with; a search opened calls it without waiting (the
/// first letters typed are compared by case alone when it is not there yet). Never throws: without it the search
/// still works on the text as written.
Future<void> ensureSearchFolding() async {
  try {
    await ChineseDisplay.instance.load(ChineseDisplayMode.simplified);
  } on Object catch (_) {
    // The asset could not be read: compared as written.
  }
}

/// The words of [query], folded; empty when nothing is typed.
List<String> searchTokens(String query) => foldForSearch(query).split(_whitespace).where((e) => e.isNotEmpty).toList();

/// Whether every one of [tokens] ([searchTokens]) is in one of [fields]; each word may be in another field. True for
/// no tokens: nothing typed filters nothing.
bool matchesSearch(List<String> tokens, Iterable<String?> fields) {
  if (tokens.isEmpty) {
    return true;
  }
  final folded = [
    for (final field in fields)
      if (field != null && field.isNotEmpty) foldForSearch(field),
  ];
  return tokens.every((token) => folded.any((field) => field.contains(token)));
}
