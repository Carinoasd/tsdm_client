/// What the cross-device sync carries of [ForumWatchConfig]: three sections of the sync document (`SyncDocument`).
///
/// * `watch_forums`: the forums watched for new threads by forum id, `{"updated": ms, "name": "…"}`, a forum unwatched
///   as `{"updated": ms, "deleted": true}`;
/// * `watch_keywords`: the alert keywords by key ([forumWatchKeywordKey]), `{"updated": ms, "text": "…"}`, a keyword
///   removed as `{"updated": ms, "deleted": true}`;
/// * `watch_scope`: where the keywords are looked for, one item `{"updated": ms, "custom": false, "latest": true,
///   "forums": [{"fid": 1, "name": "…"}]}`, left out while the scope was never changed on a device.
///
/// What a device's check knows (`ForumWatchState`: the newest thread seen per source, the threads announced, the time
/// of the last check) never goes with them. A forum or a source that arrives from another device has no mark here:
/// its first reading sets the mark and announces nothing.
library;

import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:tsdm_client/features/forum_watch/models/forum_watch_config.dart';

/// Name of the section of the forums watched.
const forumWatchForumsSection = 'watch_forums';

/// Name of the section of the alert keywords.
const forumWatchKeywordsSection = 'watch_keywords';

/// Name of the section of the keyword scope.
const forumWatchScopeSection = 'watch_scope';

Map<String, dynamic> _removed(int at) => {'updated': at, 'deleted': true};

/// The time (milliseconds) of the document item [item], null when it has none.
int? _updatedOf(Map<String, dynamic> item) => switch (item['updated']) {
  final num n when n.isFinite => n.toInt(),
  _ => null,
};

bool _deleted(Map<String, dynamic> item) => item['deleted'] == true || item['deleted'] == 1;

/// The order the latest watched forums and keywords are kept by, the same on every device and in the sync document:
/// the later first, then by key.
int compareForumWatchRecords((String key, int updated) a, (String key, int updated) b) {
  final byTime = b.$2.compareTo(a.$2);
  return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
}

/// The items of `watch_forums` [config] stands for: the forums watched and the records of the ones unwatched.
Map<String, Map<String, dynamic>> forumWatchForumItems(ForumWatchConfig config) => {
  for (final e in config.removedForums.entries) '${e.key}': _removed(e.value),
  for (final f in config.forums) '${f.fid}': {'updated': f.updated, 'name': f.name},
};

/// The items of `watch_keywords` [config] stands for: the alert keywords and the records of the ones removed.
Map<String, Map<String, dynamic>> forumWatchKeywordItems(ForumWatchConfig config) => {
  for (final e in config.removedKeywords.entries) e.key: _removed(e.value),
  for (final k in config.keywords) k.key: {'updated': k.updated, 'text': k.text},
};

/// The item of `watch_scope` [config] stands for, null while its scope was never changed.
Map<String, dynamic>? forumWatchScopeItem(ForumWatchConfig config) => config.scope.updated == 0
    ? null
    : {
        'updated': config.scope.updated,
        'custom': config.scope.custom,
        'latest': config.scope.latest,
        'forums': [
          for (final f in config.scope.forums) {'fid': f.fid, 'name': f.name},
        ],
      };

/// The scope of the `watch_scope` item [item], null when it is not one (no time).
KeywordScope? _scopeOf(Map<String, dynamic> item) {
  final updated = _updatedOf(item);
  if (updated == null || updated <= 0) {
    return null;
  }
  return KeywordScope(
    custom: item['custom'] == true,
    latest: item['latest'] != false,
    forums: forumWatchEntriesOf(
      item['forums'],
      (json) => WatchedForum.fromJson(json is Map<String, dynamic> ? {...json, 'at': updated} : json),
      (f) => f.fid,
    ).take(forumWatchForumMax).toList(),
    updated: updated,
  );
}

/// Whether the scopes [a] and [b] read the same in the document: the same choice and the same names of the forums.
bool _sameScopeItem(KeywordScope a, KeywordScope b) =>
    a.custom == b.custom &&
    a.latest == b.latest &&
    a.forums.length == b.forums.length &&
    [for (final (i, f) in a.forums.indexed) f.fid == b.forums[i].fid && f.name == b.forums[i].name].every((e) => e);

/// [config] with the sections of the sync document taken in at [now] (milliseconds): the items of `watch_forums`
/// ([forums]) and of `watch_keywords` ([keywords]), and the item of `watch_scope` ([scope]). Null when nothing changes.
///
/// Per forum and per keyword the later `updated` wins, the document's on the same time (as the merge of two documents
/// keeps the forum's item then, so the devices end with the same): one the document holds is watched (or added)
/// here, one it records as removed is removed here unless it was watched (or added) again later. One the document
/// does not hold stays as it is, and so does one whose item this version does not read (not a forum id, a keyword
/// that is not the key of its text or longer than a keyword may be). The scope is taken whole when the document's is
/// later, or as late and another one (another choice, or another name of a forum).
///
/// The forums and the keywords are then the latest first, at most [forumWatchForumMax] and [forumWatchKeywordMax] of
/// them, and the forums the check fetches ([ForumWatchConfig.fetchedFids]: the watched ones and the ones of a picked
/// scope, the limit the page holds a change to) at most [forumWatchForumMax]: over it the forums watched longest ago
/// go, so the scope's are still looked in. What goes is dropped without a record: not removed on the other devices,
/// and watched here again by a later sync once there is room (the keywords gone, a smaller scope).
ForumWatchConfig? forumWatchWithSynced(
  ForumWatchConfig config, {
  required Map<String, Map<String, dynamic>> forums,
  required Map<String, Map<String, dynamic>> keywords,
  required Map<String, dynamic>? scope,
  required int now,
}) {
  var changed = false;

  // One list: [live] by key with the time of each, [removed] the records, [read] the entry of a document item.
  (Map<K, T>, Map<K, int>) take<K extends Comparable<Object>, T extends Object>({
    required Map<K, T> live,
    required Map<K, int> removed,
    required int Function(T entry) updatedOf,
    required Map<String, Map<String, dynamic>> items,
    required K? Function(String key) keyOf,
    required T? Function(K key, Map<String, dynamic> item, int updated) read,
    required int max,
    required int removedMax,
  }) {
    final nextLive = {...live};
    final nextRemoved = {...removed};
    for (final MapEntry(key: name, value: item) in items.entries) {
      final key = keyOf(name);
      final updated = _updatedOf(item);
      if (key == null || updated == null) {
        continue;
      }
      final mine = nextLive[key];
      final mineAt = mine != null ? updatedOf(mine) : nextRemoved[key];
      if (mineAt != null && mineAt > updated) {
        continue;
      }
      if (_deleted(item)) {
        // A removal of what this device does not hold changes nothing.
        if (mine != null) {
          nextLive.remove(key);
          nextRemoved[key] = updated;
          changed = true;
        }
        continue;
      }
      final entry = read(key, item, updated);
      if (entry == null || entry == mine) {
        continue;
      }
      nextLive[key] = entry;
      nextRemoved.remove(key);
      changed = true;
    }
    final latest = nextLive.entries.toList()
      ..sort((a, b) => compareForumWatchRecords(('${a.key}', updatedOf(a.value)), ('${b.key}', updatedOf(b.value))));
    return (
      {for (final e in latest.take(max)) e.key: e.value},
      forumWatchRemovalsKept(nextRemoved, now, removedMax),
    );
  }

  final (nextForums, removedForums) = take<int, WatchedForum>(
    live: {for (final f in config.forums) f.fid: f},
    removed: config.removedForums,
    updatedOf: (f) => f.updated,
    items: forums,
    keyOf: (key) {
      final fid = int.tryParse(key);
      return fid != null && fid > 0 && '$fid' == key ? fid : null;
    },
    read: (fid, item, updated) =>
        WatchedForum(fid: fid, name: item['name'] is String ? item['name'] as String : '', updated: updated),
    max: forumWatchForumMax,
    removedMax: forumWatchForumRemovalMax,
  );
  final (nextKeywords, removedKeywords) = take<String, AlertKeyword>(
    live: {for (final k in config.keywords) k.key: k},
    removed: config.removedKeywords,
    updatedOf: (k) => k.updated,
    items: keywords,
    keyOf: (key) => key.isNotEmpty && forumWatchKeywordKey(key) == key ? key : null,
    read: (key, item, updated) {
      final text = item['text'];
      return text is String &&
              forumWatchKeywordKey(text) == key &&
              text.trim().characters.length <= forumWatchKeywordMaxLength
          ? AlertKeyword(text: text.trim(), updated: updated)
          : null;
    },
    max: forumWatchKeywordMax,
    removedMax: forumWatchKeywordRemovalMax,
  );
  var nextScope = config.scope;
  if (scope != null) {
    final theirs = _scopeOf(scope);
    if (theirs != null &&
        (theirs.updated > config.scope.updated ||
            (theirs.updated == config.scope.updated && !_sameScopeItem(theirs, config.scope)))) {
      nextScope = theirs;
      changed = true;
    }
  }
  if (!changed) {
    return null;
  }
  var next = ForumWatchConfig(
    forums: nextForums.values.toList(),
    keywords: nextKeywords.values.toList(),
    scope: nextScope,
    removedForums: removedForums,
    removedKeywords: removedKeywords,
  );
  // Two devices' forums together may be more than a round fetches (the watched ones and the ones of a picked scope):
  // the forums watched longest ago go, never one the keywords look in too (it would be fetched all the same).
  while (next.fetchedFids.length > forumWatchForumMax) {
    final scoped = next.keywordFids;
    final oldest = next.forums.lastIndexWhere((f) => !scoped.contains(f.fid));
    if (oldest < 0) {
      break;
    }
    next = next.copyWith(forums: [...next.forums]..removeAt(oldest));
  }
  return next == config ? null : next;
}
