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
///              "<uid>": {"updated": ms, "deleted": true}}}
/// ```
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
  static const itemSections = ['visits', 'blocks'];

  /// The sections this version reads as one item each.
  static const singleSections = ['phrases'];

  /// The items of section [name] (`visits`, `blocks`) by key, empty when the section is missing or not an object.
  /// Items that are not objects are left out.
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

  /// The one item of section [name] (`phrases`), null when missing or not an object.
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
    final progress = progressUpdatedOf(a) > progressUpdatedOf(b) ? a : b;
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
