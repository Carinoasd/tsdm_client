import 'package:flutter/foundation.dart' show immutable;
import 'package:tsdm_client/features/member_thread/utils/member_thread_url.dart' show forumUsernameKey;
import 'package:tsdm_client/shared/models/models.dart';

/// Someone a typed `@` in the editor can complete to: an author of the thread being read.
@immutable
final class MentionSuggestion {
  /// Constructor.
  const MentionSuggestion({required this.username, this.uid, this.avatarUrl});

  /// The name, as the floor prints it.
  final String username;

  /// The uid, when the floor carries it.
  final String? uid;

  /// Avatar of the floor's author column, if any.
  final String? avatarUrl;

  @override
  bool operator ==(Object other) =>
      other is MentionSuggestion && other.username == username && other.uid == uid && other.avatarUrl == avatarUrl;

  @override
  int get hashCode => Object.hash(username, uid, avatarUrl);

  @override
  String toString() => 'MentionSuggestion($username, uid=$uid)';
}

/// Name of the author of an anonymous floor, which can not be mentioned.
const _anonymousName = '匿名';

/// The authors of the loaded floors [posts], each once, in the order they first appear.
///
/// Left out: the account in use ([selfUid] or, without it, [selfName]), the authors [hidden] tells to hide (the
/// block list, as the floors themselves are hidden), anonymous floors (named [_anonymousName] without uid) and floors
/// without an author name. Two names the forum counts as the same member ([forumUsernameKey]: the case and the
/// full-width forms of the letters do not matter) are one suggestion, the first floor's spelling.
List<MentionSuggestion> threadMentionSuggestions(
  Iterable<Post> posts, {
  int? selfUid,
  String? selfName,
  bool Function(String? uid)? hidden,
}) {
  final seen = <String>{};
  final self = selfName == null ? null : forumUsernameKey(selfName);
  final suggestions = <MentionSuggestion>[];
  for (final post in posts) {
    final author = post.author;
    final name = author.name.trim();
    final uid = author.uid?.trim();
    final hasUid = uid != null && uid.isNotEmpty;
    if (name.isEmpty || (!hasUid && name == _anonymousName) || (hidden?.call(author.uid) ?? false)) {
      continue;
    }
    final key = forumUsernameKey(name);
    if (key.isEmpty || (selfUid != null && hasUid && uid == '$selfUid') || (self != null && key == self)) {
      continue;
    }
    if (seen.add(key)) {
      suggestions.add(MentionSuggestion(username: name, uid: hasUid ? uid : null, avatarUrl: author.avatarUrl));
    }
  }
  return suggestions;
}

/// The [suggestions] whose name contains [query], compared as the forum compares names ([forumUsernameKey]: the case
/// and the full-width forms of the letters do not matter); all of them for an empty query.
List<MentionSuggestion> filterMentionSuggestions(List<MentionSuggestion> suggestions, String query) {
  final needle = forumUsernameKey(query);
  if (needle.isEmpty) {
    return suggestions;
  }
  return suggestions.where((e) => forumUsernameKey(e.username).contains(needle)).toList();
}

/// Whether [char] is an `@` as typed: the half-width one, or the full-width `＠` a Chinese input method gives.
bool isMentionAt(String char) => char == '@' || char == '\uFF20';

/// The `@` fragment the [caret] of [text] sits in: where the `@` is and what is typed between it and the caret.
///
/// The `@` ([isMentionAt]) must start the text or follow whitespace (`a@b` is an address, as for the typed `@` of
/// the mention picker) and nothing between it and the caret may be whitespace. Null when the caret is not in such a
/// fragment.
({int atOffset, String query})? mentionFragmentAt(String text, int caret) {
  if (caret < 1 || caret > text.length) {
    return null;
  }
  for (var i = caret - 1; i >= 0; i--) {
    final char = text[i];
    if (isMentionAt(char)) {
      if (i > 0 && text[i - 1].trim().isNotEmpty) {
        return null;
      }
      return (atOffset: i, query: text.substring(i + 1, caret));
    }
    if (char.trim().isEmpty) {
      return null;
    }
  }
  return null;
}
