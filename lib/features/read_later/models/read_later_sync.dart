import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/sync/models/sync_removals.dart';

/// The section of the sync document holding the read later list of the account: one item per thread, by its id.
///
/// ```json
/// "read_later": {"<tid>": {"updated": ms, "title": "…", "author": "…", "forum": "…"},
///                "<tid>": {"updated": ms, "deleted": true}}
/// ```
///
/// `updated` is when the thread was put aside (the stored time, whole seconds) or when it was taken off (a record of
/// the removal, kept on the device as [syncRemovalsOf] reads them). Item by item the later wins: a thread taken off on one device is taken off the
/// others unless one put it aside again after that.
const readLaterSection = 'read_later';

/// A thread on the read later list as the sync sees it.
@immutable
final class ReadLaterSyncEntry {
  /// Constructor.
  const ReadLaterSyncEntry({required this.tid, required this.title, required this.addedAt, this.author, this.forum});

  /// The entry of the document item [item] of thread [key], null when it is not one (no title, a removal).
  static ReadLaterSyncEntry? fromItem(String key, Map<String, dynamic> item) {
    final tid = int.tryParse(key);
    final title = item['title'];
    final updated = item['updated'];
    if (tid == null || tid <= 0 || title is! String || updated is! num || item['deleted'] == true) {
      return null;
    }
    String? text(Object? v) => v is String && v.isNotEmpty ? v : null;
    return ReadLaterSyncEntry(
      tid: tid,
      title: title,
      addedAt: updated.toInt(),
      author: text(item['author']),
      forum: text(item['forum']),
    );
  }

  /// Thread id.
  final int tid;

  /// Thread title when it was put aside.
  final String title;

  /// When it was put aside, milliseconds (whole seconds: the time is stored in seconds).
  final int addedAt;

  /// Name of the author, null when not known.
  final String? author;

  /// Name of the forum, null when not known.
  final String? forum;

  /// The document item.
  Map<String, dynamic> toItem() => {'updated': addedAt, 'title': title, 'author': ?author, 'forum': ?forum};

  @override
  bool operator ==(Object other) =>
      other is ReadLaterSyncEntry &&
      other.tid == tid &&
      other.title == title &&
      other.addedAt == addedAt &&
      other.author == author &&
      other.forum == forum;

  @override
  int get hashCode => Object.hash(tid, title, addedAt, author, forum);
}

/// The items of [readLaterSection] a device holds: its [entries], and the records of the threads it took off
/// ([removed]) that it does not hold.
Map<String, Map<String, dynamic>> readLaterSyncItems(List<ReadLaterSyncEntry> entries, Map<int, int> removed) =>
    syncItemsWithRemovals({for (final e in entries) e.tid: e.toItem()}, removed);

/// What taking the [items] of [readLaterSection] in changes on a device holding [entries] and the records [removed]:
/// the entries to save (put aside, or a newer copy of one) and the threads to take off, each with its time. An item
/// changes the device only when it is later than what the device has (the stored time is in whole seconds: an item
/// within the same second is the same); a removal of a thread the device does not hold changes nothing.
({List<ReadLaterSyncEntry> save, Map<int, int> remove}) readLaterSyncChanges(
  List<ReadLaterSyncEntry> entries,
  Map<int, int> removed,
  Map<String, Map<String, dynamic>> items,
) {
  final byTid = {for (final e in entries) e.tid: e};
  final save = <ReadLaterSyncEntry>[];
  final remove = <int, int>{};
  for (final MapEntry(:key, value: item) in items.entries) {
    final tid = int.tryParse(key);
    final at = item['updated'];
    if (tid == null || at is! num) {
      continue;
    }
    final mine = byTid[tid];
    if (item['deleted'] == true || item['deleted'] == 1) {
      if (mine != null && mine.addedAt <= at.toInt()) {
        remove[tid] = at.toInt();
      }
      continue;
    }
    final entry = ReadLaterSyncEntry.fromItem(key, item);
    if (entry == null) {
      continue;
    }
    final seconds = entry.addedAt - entry.addedAt % 1000;
    final localAt = mine?.addedAt ?? removed[tid] ?? -1;
    if (localAt < seconds) {
      save.add(entry);
    }
  }
  return (save: save, remove: remove);
}
