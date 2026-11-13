import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/open_in_app/utils/forum_link_in_text.dart';
import 'package:tsdm_client/features/quick_open/models/quick_open_candidate.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// Most lines of one kind the box lists.
const int quickOpenPerKindLimit = 5;

/// Longest thread id typed: a longer number is not a thread id (`int` safe, and no forum has that many threads).
const int _maxTidDigits = 9;

final _digitsRe = RegExp(r'^\d+$');

/// The page a typed [input] names by itself, null when it is plain text to look up.
///
/// * Digits only are a thread id.
/// * A link of the forum the app can open is that page, also the first one in a longer text ([findForumLinkInText]);
///   any other link is nothing the box can open and falls back to text.
QuickOpenCandidate? parseQuickOpenTarget(String input) {
  final text = input.trim();
  if (text.isEmpty) {
    return null;
  }
  if (_digitsRe.hasMatch(text)) {
    if (text.length > _maxTidDigits) {
      return null;
    }
    final tid = int.parse(text);
    if (tid <= 0) {
      return null;
    }
    return QuickOpenCandidate(
      QuickOpenKind.typedThread,
      text,
      RecognizedRoute(ScreenPaths.threadV1, queryParameters: {'tid': '$tid'}),
    );
  }
  // A link typed or pasted alone (also a relative one), else the first forum link in a longer text: a shared text
  // with the title around the link.
  final whole = text.contains(RegExp(r'\s')) ? null : text.parseUrlToRoute();
  final found = whole == null ? findForumLinkInText(text) : null;
  final route = whole ?? found?.route;
  if (route == null) {
    return null;
  }
  final isThread = route.screenPath == ScreenPaths.threadV1;
  return QuickOpenCandidate(isThread ? QuickOpenKind.typedThread : QuickOpenKind.typedLink, found?.url ?? text, route);
}

/// How well [text] fits [tokens], lower is better, null when it does not fit.
///
/// Every token must be in the text (case insensitive). The text equal to the query is the best, then tokens opening a
/// word, then tokens inside a word; an earlier place is better than a later one.
int? matchScore(String text, List<String> tokens) {
  if (tokens.isEmpty) {
    return null;
  }
  final lower = text.toLowerCase();
  var score = 0;
  for (final token in tokens) {
    final index = lower.indexOf(token);
    if (index < 0) {
      return null;
    }
    final opensWord = index == 0 || !_isWordChar(lower.codeUnitAt(index - 1)) || !_isWordChar(token.codeUnitAt(0));
    score += (opensWord ? 0 : 100) + index;
  }
  return lower == tokens.join(' ') ? 0 : score + 1;
}

/// Whether [unit] is a letter or a digit, so a word goes on through it.
///
/// Chinese has no word boundary: a character after another counts as inside the word, but the punctuation around
/// titles (`【】`, `「」`, the full width space and marks) ends it.
bool _isWordChar(int unit) {
  if (unit <= 0x7f) {
    return (unit >= 0x30 && unit <= 0x39) || (unit >= 0x61 && unit <= 0x7a) || unit == 0x5f;
  }
  final isPunctuation =
      (unit >= 0x2000 && unit <= 0x206f) ||
      (unit >= 0x3000 && unit <= 0x303f) ||
      (unit >= 0xff00 && unit <= 0xff0f) ||
      (unit >= 0xff1a && unit <= 0xff20) ||
      (unit >= 0xff3b && unit <= 0xff40) ||
      (unit >= 0xff5b && unit <= 0xff65);
  return !isPunctuation && unit != 0xa0;
}

/// The lines of the box for the typed [input], first the one Enter opens.
///
/// * What [parseQuickOpenTarget] names comes first.
/// * Then the forums, the threads visited and the users fitting the text, the best fit first; the same fit keeps the
///   kind order (forum, thread, user) and then the order of the source (the threads newest first).
/// * The last line is always the search for the typed text, so Enter never ends nowhere; nothing typed lists nothing.
List<QuickOpenCandidate> buildQuickOpenCandidates(
  String input,
  QuickOpenSources sources, {
  int perKindLimit = quickOpenPerKindLimit,
}) {
  final text = input.trim();
  if (text.isEmpty) {
    return const [];
  }
  final tokens = text.toLowerCase().split(RegExp(r'\s+'));
  final scored = <({int score, int kindOrder, int index, QuickOpenCandidate candidate})>[];

  void collect<T>(
    QuickOpenKind kind,
    int kindOrder,
    List<T> items,
    String Function(T) nameOf,
    QuickOpenCandidate Function(T) build,
  ) {
    final hits = <({int score, int kindOrder, int index, QuickOpenCandidate candidate})>[];
    for (var i = 0; i < items.length; i++) {
      final score = matchScore(nameOf(items[i]), tokens);
      if (score != null) {
        hits.add((score: score, kindOrder: kindOrder, index: i, candidate: build(items[i])));
      }
    }
    hits.sort(_compare);
    scored.addAll(hits.take(perKindLimit));
  }

  collect<QuickOpenForum>(
    QuickOpenKind.forum,
    0,
    sources.forums,
    (e) => e.name,
    (e) => QuickOpenCandidate(
      QuickOpenKind.forum,
      e.name,
      RecognizedRoute(ScreenPaths.forum, pathParameters: {'fid': '${e.fid}'}),
    ),
  );
  collect<QuickOpenThread>(
    QuickOpenKind.thread,
    1,
    sources.threads,
    (e) => e.title,
    (e) => QuickOpenCandidate(
      QuickOpenKind.thread,
      e.title,
      RecognizedRoute(ScreenPaths.threadV1, queryParameters: {'tid': '${e.tid}'}),
    ),
  );
  collect<QuickOpenUser>(
    QuickOpenKind.user,
    2,
    sources.users,
    (e) => e.name,
    (e) => QuickOpenCandidate(
      QuickOpenKind.user,
      e.name,
      RecognizedRoute(ScreenPaths.profile, queryParameters: {'uid': e.uid}),
    ),
  );
  scored.sort(_compare);

  final typed = parseQuickOpenTarget(text);
  return [
    ?typed,
    for (final e in scored) e.candidate,
    QuickOpenCandidate(
      QuickOpenKind.search,
      text,
      RecognizedRoute(ScreenPaths.search, queryParameters: {'keyword': text}),
    ),
  ];
}

int _compare(
  ({int score, int kindOrder, int index, QuickOpenCandidate candidate}) a,
  ({int score, int kindOrder, int index, QuickOpenCandidate candidate}) b,
) {
  final byScore = a.score.compareTo(b.score);
  if (byScore != 0) {
    return byScore;
  }
  final byKind = a.kindOrder.compareTo(b.kindOrder);
  return byKind != 0 ? byKind : a.index.compareTo(b.index);
}
