import 'package:flutter/material.dart';

/// The words searched for in the content of the posts under it (the search of a thread): the munched text marks
/// every place they are found in, on [background] in [foreground].
///
/// Only a post's content is marked (`PostTypographyScope.postContent`), and only text that holds the whole of a
/// match in one piece: a word split by the markup inside it (a color on half of it) is found by the search, not marked.
///
/// The marks are part of the munched content, which is kept across builds (`MunchedHtml`) and munched again when the
/// [identity] changes: every hit of a search is marked in the same colors, so the floors are not munched again when
/// the current hit moves from one to another.
class SearchHighlightScope extends InheritedWidget {
  /// Constructor.
  const SearchHighlightScope({
    required this.pattern,
    required this.background,
    required this.foreground,
    required super.child,
    super.key,
  });

  /// What is marked; null marks nothing (the scope stays, so the floors under it keep their widgets when a search
  /// starts or ends).
  final RegExp? pattern;

  /// Color behind the marked text.
  final Color background;

  /// Color of the marked text.
  final Color foreground;

  /// The scope [context] is in, null when none or it marks nothing.
  static SearchHighlightScope? maybeOf(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<SearchHighlightScope>();
    return scope?.pattern == null ? null : scope;
  }

  /// What makes the marks of this scope: munched content made under another one is made again.
  (String, Color, Color)? get identity => switch (pattern) {
    final pattern? => (pattern.pattern, background, foreground),
    null => null,
  };

  /// [spans] with the matches of [pattern] in their text cut out into spans of their own, on [background]; spans with
  /// children or without text stay as they are.
  List<InlineSpan> mark(List<InlineSpan> spans) {
    if (pattern == null) {
      return spans;
    }
    List<InlineSpan>? marked;
    for (final (index, span) in spans.indexed) {
      final parts = span is TextSpan && span.children == null ? _markText(span) : null;
      if (parts == null) {
        marked?.add(span);
        continue;
      }
      (marked ??= spans.sublist(0, index)).addAll(parts);
    }
    return marked ?? spans;
  }

  List<InlineSpan>? _markText(TextSpan span) {
    final text = span.text;
    if (text == null || text.isEmpty) {
      return null;
    }
    final matches = pattern!.allMatches(text).where((e) => e.end > e.start).toList();
    if (matches.isEmpty) {
      return null;
    }
    final markedStyle = (span.style ?? const TextStyle()).copyWith(backgroundColor: background, color: foreground);
    final parts = <InlineSpan>[];
    var last = 0;
    for (final match in matches) {
      if (match.start > last) {
        parts.add(TextSpan(text: text.substring(last, match.start), style: span.style, recognizer: span.recognizer));
      }
      parts.add(
        TextSpan(text: text.substring(match.start, match.end), style: markedStyle, recognizer: span.recognizer),
      );
      last = match.end;
    }
    if (last < text.length) {
      parts.add(TextSpan(text: text.substring(last), style: span.style, recognizer: span.recognizer));
    }
    return parts;
  }

  @override
  bool updateShouldNotify(SearchHighlightScope oldWidget) => identity != oldWidget.identity;
}
