import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Most keywords and most forums one account filters (each).
const threadFilterMax = 200;

/// Most characters of one keyword.
const threadFilterKeywordMaxLength = 50;

/// How long the record of a removed keyword or forum is kept, so the removal reaches the other devices.
const threadFilterTombstoneKeptFor = Duration(days: 180);

/// The text a keyword matches by: trimmed and lower case (case is ignored; Simplified and Traditional Chinese are
/// matched as they are, never converted).
String threadFilterKeywordKey(String text) => text.trim().toLowerCase();

int? _milliseconds(Object? at) {
  final ms = at is num ? at.toInt() : 0;
  // DateTime accepts at most 100 million days from the epoch.
  return ms < -8640000000000000 || ms > 8640000000000000 ? null : ms;
}

/// One record of a thread filter: a keyword or a forum, live or removed.
///
/// A removal is kept as a record ([deleted]) with its time, so the cross-device sync carries it to the other devices
/// instead of reading the missing entry as never known.
sealed class ThreadFilterRecord {
  const ThreadFilterRecord({required this.updated, required this.deleted});

  /// When added or removed (milliseconds since the epoch).
  final int updated;

  /// Whether this records a removal.
  final bool deleted;

  /// The id of what this filters: the keyword's [threadFilterKeywordKey] or the forum id.
  String get key;

  /// The item of the sync document.
  Map<String, dynamic> toItem();

  /// Encode as one entry of the settings row.
  String encode();

  /// Whether [other] holds the same content.
  bool sameAs(ThreadFilterRecord other);
}

/// A keyword: threads whose title contains it are hidden.
@immutable
final class BlockedKeyword extends ThreadFilterRecord {
  /// Constructor.
  const BlockedKeyword({required this.text, required super.updated, super.deleted = false});

  /// The record of the sync document item [item] of keyword [key], null when malformed.
  static BlockedKeyword? fromItem(String key, Map<String, dynamic> item) {
    final updated = _milliseconds(item['updated']);
    if (updated == null || key.isEmpty || key != threadFilterKeywordKey(key)) {
      return null;
    }
    if (item['deleted'] == true || item['deleted'] == 1) {
      return BlockedKeyword(text: key, updated: updated, deleted: true);
    }
    final text = item['text'];
    if (text is! String || threadFilterKeywordKey(text) != key) {
      return null;
    }
    return BlockedKeyword(text: text.trim(), updated: updated);
  }

  /// Decode one entry of the settings row, null if malformed.
  static BlockedKeyword? decode(String data) {
    try {
      final m = jsonDecode(data);
      if (m is! Map<String, dynamic>) {
        return null;
      }
      final text = m['text'];
      final updated = _milliseconds(m['at']);
      if (text is! String || threadFilterKeywordKey(text).isEmpty || updated == null) {
        return null;
      }
      return BlockedKeyword(text: text.trim(), updated: updated, deleted: m['deleted'] == true);
    } on FormatException {
      return null;
    }
  }

  /// The keyword as entered (trimmed).
  final String text;

  @override
  String get key => threadFilterKeywordKey(text);

  @override
  Map<String, dynamic> toItem() => deleted ? {'updated': updated, 'deleted': true} : {'updated': updated, 'text': text};

  @override
  String encode() => jsonEncode(<String, Object>{'text': text, 'at': updated, if (deleted) 'deleted': true});

  @override
  bool sameAs(ThreadFilterRecord other) =>
      other is BlockedKeyword && other.text == text && other.updated == updated && other.deleted == deleted;
}

/// A forum: its threads are hidden in the lists of threads of many forums (never in the forum's own page).
@immutable
final class BlockedForum extends ThreadFilterRecord {
  /// Constructor.
  const BlockedForum({required this.fid, required this.name, required super.updated, super.deleted = false});

  /// The record of the sync document item [item] of forum [key], null when malformed.
  static BlockedForum? fromItem(String key, Map<String, dynamic> item) {
    final fid = int.tryParse(key);
    final updated = _milliseconds(item['updated']);
    if (fid == null || fid <= 0 || '$fid' != key || updated == null) {
      return null;
    }
    final name = item['name'];
    return BlockedForum(
      fid: fid,
      name: name is String ? name : '',
      updated: updated,
      deleted: item['deleted'] == true || item['deleted'] == 1,
    );
  }

  /// Decode one entry of the settings row, null if malformed.
  static BlockedForum? decode(String data) {
    try {
      final m = jsonDecode(data);
      if (m is! Map<String, dynamic>) {
        return null;
      }
      final fid = m['fid'];
      final name = m['name'];
      final updated = _milliseconds(m['at']);
      if (fid is! int || fid <= 0 || name is! String || updated == null) {
        return null;
      }
      return BlockedForum(fid: fid, name: name, updated: updated, deleted: m['deleted'] == true);
    } on FormatException {
      return null;
    }
  }

  /// Forum id.
  final int fid;

  /// Forum name when picked, for display only.
  final String name;

  @override
  String get key => '$fid';

  @override
  Map<String, dynamic> toItem() => deleted ? {'updated': updated, 'deleted': true} : {'updated': updated, 'name': name};

  @override
  String encode() =>
      jsonEncode(<String, Object>{'fid': fid, 'name': name, 'at': updated, if (deleted) 'deleted': true});

  @override
  bool sameAs(ThreadFilterRecord other) =>
      other is BlockedForum &&
      other.fid == fid &&
      other.name == name &&
      other.updated == updated &&
      other.deleted == deleted;
}

/// The keyword and forum filters of thread lists of one account.
@immutable
final class ThreadFilters {
  /// Constructor.
  ///
  /// [keywordRecords] and [forumRecords] hold the removals too, one record per key.
  ThreadFilters({
    List<BlockedKeyword> keywordRecords = const [],
    List<BlockedForum> forumRecords = const [],
    List<String> unreadableKeywordEntries = const [],
    List<String> unreadableForumEntries = const [],
  }) : keywordRecords = List.unmodifiable(keywordRecords),
       forumRecords = List.unmodifiable(forumRecords),
       unreadableKeywordEntries = List.unmodifiable(unreadableKeywordEntries),
       unreadableForumEntries = List.unmodifiable(unreadableForumEntries),
       keywords = List.unmodifiable(_live(keywordRecords)),
       forums = List.unmodifiable(_live(forumRecords)),
       keywordKeys = List.unmodifiable({for (final k in keywordRecords.where((e) => !e.deleted)) k.key}),
       forumIds = Set.unmodifiable({for (final f in forumRecords.where((e) => !e.deleted)) f.fid});

  /// No filter.
  const ThreadFilters.empty()
    : keywordRecords = const [],
      forumRecords = const [],
      unreadableKeywordEntries = const [],
      unreadableForumEntries = const [],
      keywords = const [],
      forums = const [],
      keywordKeys = const [],
      forumIds = const {};

  static List<T> _live<T extends ThreadFilterRecord>(List<T> records) =>
      records.where((e) => !e.deleted).toList()..sort((a, b) => b.updated.compareTo(a.updated));

  /// Every keyword record, removals included.
  final List<BlockedKeyword> keywordRecords;

  /// Every forum record, removals included.
  final List<BlockedForum> forumRecords;

  /// Stored keyword entries this version can not read, written back unchanged.
  final List<String> unreadableKeywordEntries;

  /// Stored forum entries this version can not read, written back unchanged.
  final List<String> unreadableForumEntries;

  /// The keywords in use, latest added first.
  final List<BlockedKeyword> keywords;

  /// The forums in use, latest added first.
  final List<BlockedForum> forums;

  /// [threadFilterKeywordKey] of the keywords in use.
  final List<String> keywordKeys;

  /// Ids of the forums in use.
  final Set<int> forumIds;

  /// These filters with the records [keywords] and [forums] taken in (the cross-device sync's, removals included):
  /// per key the later record wins, this one's own on the same time. Null when nothing changes.
  ThreadFilters? mergedWith({required List<BlockedKeyword> keywords, required List<BlockedForum> forums}) {
    (List<T>, bool) merge<T extends ThreadFilterRecord>(List<T> mine, List<T> theirs) {
      final byKey = {for (final r in mine) r.key: r};
      var changed = false;
      for (final r in theirs) {
        final local = byKey[r.key];
        if (local == null || (local.updated < r.updated && !local.sameAs(r))) {
          byKey[r.key] = r;
          changed = true;
        }
      }
      return (byKey.values.toList(), changed);
    }

    final (nextKeywords, keywordsChanged) = merge(keywordRecords, keywords);
    final (nextForums, forumsChanged) = merge(forumRecords, forums);
    if (!keywordsChanged && !forumsChanged) {
      return null;
    }
    return ThreadFilters(
      keywordRecords: nextKeywords,
      forumRecords: nextForums,
      unreadableKeywordEntries: unreadableKeywordEntries,
      unreadableForumEntries: unreadableForumEntries,
    );
  }

  /// Whether nothing is filtered.
  bool get isEmpty => keywordKeys.isEmpty && forumIds.isEmpty;

  /// Whether the keyword of [key] is in use.
  bool hasKeyword(String key) => keywordKeys.contains(key);

  /// Whether a thread titled [title] in forum [fid] is hidden: its title contains a keyword (case ignored), or, when
  /// [byForum] (a list of threads of many forums), its forum is filtered.
  bool hides({required String? title, int? fid, bool byForum = true}) {
    if (byForum && fid != null && forumIds.contains(fid)) {
      return true;
    }
    if (title == null || keywordKeys.isEmpty) {
      return false;
    }
    final lower = title.toLowerCase();
    return keywordKeys.any(lower.contains);
  }
}
