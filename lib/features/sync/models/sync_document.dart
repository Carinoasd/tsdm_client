import 'dart:convert';

import 'package:flutter/foundation.dart';

/// The schema of the documents this version writes.
const syncSchema = 1;

/// Most bytes a document may take: the plugin's limit (`max_bytes` of its `sync` answers, 64 KB), with room for the
/// form encoding.
const syncDocumentMaxBytes = 60000;

/// Most live visit records a document carries: the latest ones, by their time.
const syncVisitsMax = 400;

/// Most records of deleted visits a document carries, the latest first.
const syncVisitTombstonesMax = 400;

/// How long a record of a deletion (a visit removed, a user unblocked) is kept in the document before it is dropped.
const syncTombstoneKeptFor = Duration(days: 180);

/// Most quick phrases (the editor's own limit).
const syncPhrasesMax = 100;

/// Most fast rate templates a document carries.
const syncRateTemplatesMax = 100;

/// Most live local drafts a document carries: the latest ones, by their time.
const syncDraftsMax = 30;

/// Most records of deleted local drafts a document carries, the latest first.
const syncDraftTombstonesMax = 200;

/// Most bytes one draft item may take; a larger one goes without its editor document (`delta`), and stays on its
/// device when that is not enough.
const int syncDraftMaxBytes = 8 * 1024;

/// Most bytes the drafts of a document take together, so the reading progress keeps the rest of the room.
const int syncDraftsMaxBytes = 16 * 1024;

/// Most live floor bookmarks a document carries: the latest ones, by their time.
const syncBookmarksMax = 100;

/// Most records of removed floor bookmarks a document carries, the latest first.
const syncBookmarkTombstonesMax = 100;

/// Most bytes the floor bookmarks of a document take together (two fifths of it at most): with the drafts, the
/// reading progress keeps a third of the room. A bookmark with a Chinese excerpt and title takes about 400 bytes, 700
/// with a long note: some 35 to 60 of the latest go with the sync, the older ones stay on their device.
const int syncBookmarksMaxBytes = 24 * 1024;

/// What one account keeps on the forum for its devices (plugin 3.4.0, `sync`): a JSON object the plugin stores as it
/// is. This version reads and writes `schema` 1:
///
/// ```json
/// {"schema": 1,
///  "visits":  {"<tid>": {"updated": ms, "title": "…", "fid": 7, "forum": "…",
///                        "progress_updated": ms, "page": 3, "pid": 1, "floor": 27, "seen": 9},
///              "<tid>": {"updated": ms, "deleted": true}},
///  "phrases": {"updated": ms, "items": ["…"]},
///  "blocks":  {"<uid>": {"updated": ms, "username": "…"},
///              "<uid>": {"updated": ms, "deleted": true}},
///  "rate_templates": {"updated": ms, "items": [{"name": "…", "ww": 0, "tsb": 0, "xc": 0, "tr": 0, "fh": 0,
///                                               "jl": 0, "special": 0, "special2": 0}]},
///  "settings": {"updated": ms, "values": {"<settings name>": value}},
///  "drafts":  {"<draft key>": {"updated": ms, "body": "…", "delta": "…", "subject": "…", "fid": "…", "tid": "…",
///                              "replyAction": "…", "hint": "…", "quote": false, "title": "…", "typeId": "…",
///                              "maybeSent": true},
///              "<draft key>": {"updated": ms, "deleted": true}},
///  "bookmarks": {"<tid>:<pid>": {"updated": ms, "tid": 1, "pid": 2, "floor": 27, "page": 2, "note": "…",
///                                "excerpt": "…", "title": "…"},
///                "<tid>:<pid>": {"updated": ms, "deleted": true}}}
/// ```
///
/// `rate_templates` and `settings` are one item each, like `phrases`: the later `updated` wins, whole (the values of
/// settings the later one does not hold are kept from the other). `settings`
/// holds the reading and display settings of `syncedSettings` by their stored name (a theme index, a text scale, a
/// switch), never one tied to the device. `drafts` holds the local drafts of the account by their key
/// (`reply:<tid>`, `floor:<tid>:<pid>`, `thread:<fid>`, `edit:<pid>`, a backup with `~<stamp>`; never a private
/// message, `pm:<uid>`, which stays on its device): the latest [syncDraftsMax] within [syncDraftsMaxBytes], none over
/// [syncDraftMaxBytes]. `bookmarks` holds the floor bookmarks of the account (`FloorBookmark`): the latest
/// [syncBookmarksMax] within [syncBookmarksMaxBytes]. Each of the four can be left out of
/// the sync on a device (its section is then neither read nor written there).
///
/// Every item carries `updated`, the device clock (milliseconds since the epoch) of its last change; a deletion is an
/// item with `deleted: true` and the time of the deletion, so a thread visit removed or a user unblocked on one device
/// is removed on the others too. Two documents merge item by item ([SyncDocument.merge]): the later `updated` wins,
/// whole item (its unknown fields with it). A visit is two halves: the visit (`updated`: title, forum) and the
/// reading progress (`progress_updated`: page, pid, floor, seen), each taken from the side that wrote it later, so
/// opening a thread on a device that has not read as far does not undo the progress of another. Fields and items
/// this version does not know are kept as they are and written back.
@immutable
final class SyncDocument {
  /// Constructor.
  const SyncDocument(this.raw);

  /// An empty document.
  const SyncDocument.empty() : raw = const {'schema': syncSchema};

  /// The document [text] holds, an empty one for null, blank or damaged text, or a JSON value that is not an object.
  /// A `schema` newer than [syncSchema] is kept as it is ([schema]: the caller leaves such a document alone); an
  /// older or missing one reads as this version's.
  factory SyncDocument.parse(String? text) {
    if (text == null || text.trim().isEmpty) {
      return const SyncDocument.empty();
    }
    try {
      final json = jsonDecode(text);
      if (json is Map<String, dynamic>) {
        final schema = json['schema'];
        return SyncDocument({...json, 'schema': schema is num && schema > syncSchema ? schema.toInt() : syncSchema});
      }
    } on FormatException {
      // Damaged: nothing is read from it.
    }
    return const SyncDocument.empty();
  }

  /// Merge [local] with [remote]: the later `updated` wins per item, whole item; ties keep the forum's item ([remote]:
  /// nothing to send back then). Fields neither side knows are kept, the forum's over this device's; sections this
  /// version does not read are taken from the forum when it has them, from this device otherwise.
  factory SyncDocument.merge(SyncDocument local, SyncDocument remote) {
    final result = <String, dynamic>{...local.raw, ...remote.raw, 'schema': syncSchema};
    for (final section in itemSections) {
      final mine = local.items(section);
      final theirs = remote.items(section);
      if (mine.isEmpty && theirs.isEmpty) {
        continue;
      }
      final merged = <String, Map<String, dynamic>>{};
      for (final key in {...theirs.keys, ...mine.keys}) {
        final a = mine[key];
        final b = theirs[key];
        merged[key] = switch ((a, b)) {
          (final a?, null) => a,
          (null, final b?) => b,
          (final a?, final b?) => section == 'visits' ? mergeVisit(a, b) : (updatedOf(a) > updatedOf(b) ? a : b),
          _ => const {},
        };
      }
      result[section] = merged;
    }
    for (final section in singleSections) {
      final a = local.single(section);
      final b = remote.single(section);
      final winner = switch ((a, b)) {
        (final a?, null) => a,
        (null, final b?) => b,
        (final a?, final b?) when section == 'settings' => mergeSettings(a, b),
        (final a?, final b?) => updatedOf(a) > updatedOf(b) ? a : b,
        _ => null,
      };
      if (winner != null) {
        result[section] = winner;
      }
    }
    return SyncDocument(result);
  }

  /// The document as read, `schema` included.
  final Map<String, dynamic> raw;

  /// The `schema` of the document ([syncSchema] for this version's).
  int get schema => switch (raw['schema']) {
    final num n => n.toInt(),
    _ => syncSchema,
  };

  /// Whether the document was written by a newer app version than this one reads: it is left alone.
  bool get newerThanKnown => schema > syncSchema;

  /// The item sections this version reads: a map of items keyed by the id of what they describe.
  static const itemSections = ['visits', 'blocks', 'drafts', 'bookmarks'];

  /// The sections this version reads as one item each.
  static const singleSections = ['phrases', 'rate_templates', 'settings'];

  /// The items of section [name] (`visits`, `blocks`, `drafts`, `bookmarks`) by key, empty when the section is missing
  /// or not an object. Items that are not objects are left out.
  Map<String, Map<String, dynamic>> items(String name) {
    final section = raw[name];
    if (section is! Map) {
      return const {};
    }
    return {
      for (final MapEntry(:key, :value) in section.entries)
        if (key is String && value is Map<String, dynamic>) key: value,
    };
  }

  /// The one item of section [name] (`phrases`, `rate_templates`, `settings`), null when missing or not an object.
  Map<String, dynamic>? single(String name) {
    final section = raw[name];
    return section is Map<String, dynamic> ? section : null;
  }

  /// The document as the text sent to the forum (keys in a fixed order, so equal documents give equal text).
  String encode() => jsonEncode(_sorted(raw));

  /// The bytes [encode] takes.
  int get encodedLength => utf8.encode(encode()).length;

  /// Whether [other] holds the same content.
  bool sameAs(SyncDocument other) => encode() == other.encode();

  /// This document with section [name] replaced by [items] (removed when empty: a device without any is the same as
  /// a forum without the section).
  SyncDocument withItems(String name, Map<String, Map<String, dynamic>> items) {
    final next = {...raw};
    if (items.isEmpty) {
      next.remove(name);
    } else {
      next[name] = items;
    }
    return SyncDocument(next);
  }

  /// This document with the single section [name] replaced by [item] (removed when null).
  SyncDocument withSingle(String name, Map<String, dynamic>? item) {
    final next = {...raw};
    if (item == null) {
      next.remove(name);
    } else {
      next[name] = item;
    }
    return SyncDocument(next);
  }

  /// The `updated` of [item] (milliseconds), 0 when missing or not a number.
  static int updatedOf(Map<String, dynamic> item) => switch (item['updated']) {
    final num n => n.toInt(),
    _ => 0,
  };

  /// The `progress_updated` of a visit [item] (milliseconds), 0 when missing or not a number.
  static int progressUpdatedOf(Map<String, dynamic> item) => switch (item['progress_updated']) {
    final num n => n.toInt(),
    _ => 0,
  };

  /// The fields of a visit item that belong to its reading progress.
  static const progressFields = ['progress_updated', 'page', 'pid', 'floor', 'seen'];

  /// Whether a visit [item] carries a reading progress.
  static bool hasProgress(Map<String, dynamic> item) =>
      item['page'] != null || item['pid'] != null || item['floor'] != null;

  /// Merge two visit items [a] (this device's) and [b] (the forum's) of the same thread: the visit (`updated`) and
  /// the progress (`progress_updated`) each from the side that wrote it later, ties to [b]. A deletion wins when it is
  /// later than both times of the live item, else the live item wins (visited again after the deletion).
  static Map<String, dynamic> mergeVisit(Map<String, dynamic> a, Map<String, dynamic> b) {
    if (isDeleted(a) || isDeleted(b)) {
      if (isDeleted(a) && isDeleted(b)) {
        return updatedOf(a) > updatedOf(b) ? a : b;
      }
      final (stone, live) = isDeleted(a) ? (a, b) : (b, a);
      final liveAt = updatedOf(live) > progressUpdatedOf(live) ? updatedOf(live) : progressUpdatedOf(live);
      final stoneAt = updatedOf(stone);
      // Ties to the forum's item.
      return stoneAt > liveAt || (stoneAt == liveAt && identical(stone, b)) ? stone : live;
    }
    final visit = updatedOf(a) > updatedOf(b) ? a : b;
    // The same progress time on both (0: a progress kept before it was timed, or none): the side that has a
    // progress, the forum's when both have.
    final progress = switch (progressUpdatedOf(a).compareTo(progressUpdatedOf(b))) {
      > 0 => a,
      < 0 => b,
      _ => hasProgress(b) || !hasProgress(a) ? b : a,
    };
    if (identical(visit, progress)) {
      return visit;
    }
    return {
      for (final MapEntry(:key, :value) in visit.entries)
        if (!progressFields.contains(key)) key: value,
      for (final field in progressFields)
        if (progress.containsKey(field)) field: progress[field],
    };
  }

  /// Merge two `settings` items [a] (this device's) and [b] (the forum's): the later one wins, ties to [b], and the
  /// values of settings it does not hold (a setting the app version that wrote it does not carry) are taken from the
  /// other, so a device of an older version does not drop the settings of a newer one.
  static Map<String, dynamic> mergeSettings(Map<String, dynamic> a, Map<String, dynamic> b) {
    final (winner, loser) = updatedOf(a) > updatedOf(b) ? (a, b) : (b, a);
    Map<String, dynamic> valuesOf(Map<String, dynamic> item) =>
        item['values'] is Map<String, dynamic> ? item['values'] as Map<String, dynamic> : const {};
    final values = {...valuesOf(loser), ...valuesOf(winner)};
    return values.length == valuesOf(winner).length ? winner : {...winner, 'values': values};
  }

  /// Whether [item] records a deletion.
  static bool isDeleted(Map<String, dynamic> item) => item['deleted'] == true || item['deleted'] == 1;

  /// A record of a deletion at [at].
  static Map<String, dynamic> tombstone(int at) => {'updated': at, 'deleted': true};

  @override
  bool operator ==(Object other) => other is SyncDocument && other.sameAs(this);

  @override
  int get hashCode => encode().hashCode;

  @override
  String toString() => 'SyncDocument(${encode()})';
}

/// [value] with the keys of every object sorted, so the text of equal documents is equal.
Object? _sorted(Object? value) => switch (value) {
  final Map<dynamic, dynamic> map => {
    for (final e in map.entries.toList()..sort((a, b) => '${a.key}'.compareTo('${b.key}')))
      '${e.key}': _sorted(e.value),
  },
  final List<dynamic> list => list.map(_sorted).toList(),
  _ => value,
};
