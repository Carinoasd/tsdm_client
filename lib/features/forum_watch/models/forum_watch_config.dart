import 'package:flutter/foundation.dart';
import 'package:tsdm_client/features/blocking/models/thread_filter.dart';

/// Most forums one account has fetched by the check: the forums watched for new threads and the forums the keywords
/// are looked for in, together ([ForumWatchConfig.fetchedFids]). Every forum is one request of each round.
const forumWatchForumMax = 10;

/// Most alert keywords of one account.
const forumWatchKeywordMax = 50;

/// Most characters of one alert keyword (the same as a filter keyword).
const int forumWatchKeywordMaxLength = threadFilterKeywordMaxLength;

/// Most records of forums unwatched kept per account (and in the sync document), the latest ones.
const forumWatchForumRemovalMax = 30;

/// Most records of alert keywords removed kept per account (and in the sync document), the latest ones.
const forumWatchKeywordRemovalMax = 50;

/// How long the record of a forum unwatched or a keyword removed is kept, so the cross-device sync removes it on the
/// other devices too.
const forumWatchRemovalKeptFor = Duration(days: 180);

/// The text an alert keyword matches by: trimmed and lower case, as a filter keyword ([threadFilterKeywordKey]).
String forumWatchKeywordKey(String text) => threadFilterKeywordKey(text);

int _int(Object? v) => v is int ? v : 0;

/// The time of a change made at [now] to something last changed at [before]: later than [before] even when the clock
/// went back, so the change wins on the other devices too.
int forumWatchChangeTime(int now, int before) => now > before ? now : before + 1;

/// [removals] (when, by key) without the records older than [forumWatchRemovalKeptFor] at [now], the latest [max] of
/// them ([forumWatchForumRemovalMax], [forumWatchKeywordRemovalMax]).
Map<K, int> forumWatchRemovalsKept<K extends Comparable<Object>>(Map<K, int> removals, int now, int max) {
  final kept = removals.entries.where((e) => e.value >= now - forumWatchRemovalKeptFor.inMilliseconds).toList()
    ..sort((a, b) {
      final byTime = b.value.compareTo(a.value);
      return byTime != 0 ? byTime : a.key.compareTo(b.key);
    });
  return {for (final e in kept.take(max)) e.key: e.value};
}

Map<K, int> _removalsOf<K extends Object>(Object? json, K? Function(String key) keyOf) {
  final result = <K, int>{};
  if (json case final Map<String, dynamic> map) {
    for (final MapEntry(:key, :value) in map.entries) {
      final k = keyOf(key);
      if (k != null && value is int) {
        result[k] = value;
      }
    }
  }
  return result;
}

/// The entries of the stored list [raw] [read] reads, the first of each [keyOf] kept; anything else left out.
List<T> forumWatchEntriesOf<T extends Object>(Object? raw, T? Function(Object? json) read, Object Function(T e) keyOf) {
  final seen = <Object>{};
  final result = <T>[];
  for (final e in raw is List ? raw : const []) {
    final entry = read(e);
    if (entry != null && seen.add(keyOf(entry))) {
      result.add(entry);
    }
  }
  return result;
}

/// A forum watched for new threads.
@immutable
final class WatchedForum {
  /// Constructor.
  const WatchedForum({required this.fid, required this.name, required this.updated});

  /// Read one entry written by [toJson]; null when it is not one.
  static WatchedForum? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final fid = json['fid'];
    if (fid is! int || fid <= 0) {
      return null;
    }
    return WatchedForum(
      fid: fid,
      name: json['name'] is String ? json['name'] as String : '',
      updated: _int(json['at']),
    );
  }

  /// Forum id.
  final int fid;

  /// Forum name when watched, for display only.
  final String name;

  /// When it was watched (milliseconds since the epoch): the later of two devices' wins in the cross-device sync.
  final int updated;

  /// The entry as stored.
  Map<String, dynamic> toJson() => {'fid': fid, 'name': name, 'at': updated};

  @override
  bool operator ==(Object other) =>
      other is WatchedForum && other.fid == fid && other.name == name && other.updated == updated;

  @override
  int get hashCode => Object.hash(fid, name, updated);
}

/// A keyword: a new thread whose title contains it is announced.
@immutable
final class AlertKeyword {
  /// Constructor.
  const AlertKeyword({required this.text, required this.updated});

  /// Read one entry written by [toJson]; null when it is not one.
  static AlertKeyword? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return null;
    }
    final text = json['text'];
    if (text is! String || forumWatchKeywordKey(text).isEmpty) {
      return null;
    }
    return AlertKeyword(text: text.trim(), updated: _int(json['at']));
  }

  /// The keyword as entered (trimmed).
  final String text;

  /// When it was added (milliseconds since the epoch): the later of two devices' wins in the cross-device sync.
  final int updated;

  /// What it matches by ([forumWatchKeywordKey]).
  String get key => forumWatchKeywordKey(text);

  /// The entry as stored.
  Map<String, dynamic> toJson() => {'text': text, 'at': updated};

  @override
  bool operator ==(Object other) => other is AlertKeyword && other.text == text && other.updated == updated;

  @override
  int get hashCode => Object.hash(text, updated);
}

/// Where the keywords are looked for: by default ([custom] false) in the forums watched for new threads and the list
/// of the latest threads (`forum.php?mod=guide&view=newthread`); otherwise in the list of the latest threads when
/// [latest] and in the forums [forums].
@immutable
final class KeywordScope {
  /// Constructor.
  const KeywordScope({this.custom = false, this.latest = true, this.forums = const [], this.updated = 0});

  /// Read what [toJson] wrote; the default for anything else.
  factory KeywordScope.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const KeywordScope();
    }
    return KeywordScope(
      custom: json['custom'] == true,
      latest: json['latest'] != false,
      forums: forumWatchEntriesOf(json['forums'], WatchedForum.fromJson, (f) => f.fid),
      updated: _int(json['at']),
    );
  }

  /// Whether the scope is picked ([latest], [forums]) instead of the default.
  final bool custom;

  /// Whether the list of the latest threads is looked in, when [custom].
  final bool latest;

  /// The forums looked in, when [custom].
  final List<WatchedForum> forums;

  /// When the scope was last changed on a device (milliseconds since the epoch), 0 for one never changed: the later
  /// of two devices' wins in the cross-device sync, whole.
  final int updated;

  /// Whether [other] looks in the same places, whenever either was changed.
  bool sameChoiceAs(KeywordScope other) =>
      other.custom == custom &&
      other.latest == latest &&
      listEquals([for (final f in other.forums) f.fid], [for (final f in forums) f.fid]);

  /// The scope as stored.
  Map<String, dynamic> toJson() => {
    'custom': custom,
    'latest': latest,
    'forums': [for (final f in forums) f.toJson()],
    if (updated != 0) 'at': updated,
  };

  /// A copy with the fields given.
  KeywordScope copyWith({bool? custom, bool? latest, List<WatchedForum>? forums, int? updated}) => KeywordScope(
    custom: custom ?? this.custom,
    latest: latest ?? this.latest,
    forums: forums ?? this.forums,
    updated: updated ?? this.updated,
  );

  @override
  bool operator ==(Object other) =>
      other is KeywordScope &&
      other.custom == custom &&
      other.latest == latest &&
      other.updated == updated &&
      listEquals(other.forums, forums);

  @override
  int get hashCode => Object.hash(custom, latest, updated, Object.hashAll(forums));
}

/// The source of the list of the latest threads in [ForumWatchConfig.sources] and in the marks of the check.
const forumWatchLatestSource = 'latest';

/// The source of forum [fid] in [ForumWatchConfig.sources] and in the marks of the check.
String forumWatchForumSource(int fid) => 'f$fid';

/// The forum id of [source], null for the list of the latest threads (or anything else).
int? forumWatchFidOfSource(String source) {
  if (!source.startsWith('f')) {
    return null;
  }
  final fid = int.tryParse(source.substring(1));
  return fid != null && fid > 0 ? fid : null;
}

/// What account watches: the forums whose new threads are announced, the keywords announced in the new threads and
/// where they are looked for. Kept per account on this device (`ForumWatchStore`), and the same on its other devices
/// through the cross-device sync (`forum_watch_sync.dart`): for that, a forum unwatched and a keyword removed leave a
/// record of when ([removedForums], [removedKeywords]).
@immutable
final class ForumWatchConfig {
  /// Constructor.
  const ForumWatchConfig({
    this.forums = const [],
    this.keywords = const [],
    this.scope = const KeywordScope(),
    this.removedForums = const {},
    this.removedKeywords = const {},
  });

  /// Read what [toJson] wrote; nothing watched for anything else. Duplicates are dropped, the first kept.
  factory ForumWatchConfig.fromJson(Object? json) {
    if (json is! Map<String, dynamic>) {
      return const ForumWatchConfig();
    }
    return ForumWatchConfig(
      forums: forumWatchEntriesOf(json['forums'], WatchedForum.fromJson, (f) => f.fid),
      keywords: forumWatchEntriesOf(json['keywords'], AlertKeyword.fromJson, (k) => k.key),
      scope: KeywordScope.fromJson(json['scope']),
      removedForums: _removalsOf(json['gone_forums'], (key) {
        final fid = int.tryParse(key);
        return fid != null && fid > 0 ? fid : null;
      }),
      removedKeywords: _removalsOf(
        json['gone_keywords'],
        (key) => key.isNotEmpty && forumWatchKeywordKey(key) == key ? key : null,
      ),
    );
  }

  /// The forums watched for new threads, the one watched last first.
  final List<WatchedForum> forums;

  /// The alert keywords, the one added last first.
  final List<AlertKeyword> keywords;

  /// Where the keywords are looked for.
  final KeywordScope scope;

  /// The forums unwatched on a device, by forum id: when (milliseconds since the epoch). Kept for the cross-device
  /// sync ([forumWatchRemovalsKept]).
  final Map<int, int> removedForums;

  /// The keywords removed on a device, by key ([forumWatchKeywordKey]): when (milliseconds since the epoch).
  final Map<String, int> removedKeywords;

  /// Nothing watched.
  bool get isEmpty => forums.isEmpty && keywords.isEmpty;

  /// Nothing to keep: nothing watched, the scope never changed, no record of a removal.
  bool get isBlank => isEmpty && scope == const KeywordScope() && removedForums.isEmpty && removedKeywords.isEmpty;

  /// Ids of the forums watched for new threads.
  Set<int> get watchedFids => {for (final f in forums) f.fid};

  /// Whether forum [fid] is watched for new threads.
  bool watches(int fid) => forums.any((f) => f.fid == fid);

  /// Ids of the forums the keywords are looked in: the scope's own, or the forums watched by default. None without a
  /// keyword.
  Set<int> get keywordFids => keywords.isEmpty
      ? const {}
      : scope.custom
      ? {for (final f in scope.forums) f.fid}
      : watchedFids;

  /// Whether the list of the latest threads is looked in for the keywords.
  bool get keywordsInLatest => keywords.isNotEmpty && (!scope.custom || scope.latest);

  /// Ids of every forum the check fetches: the forums watched and the forums of the keywords.
  Set<int> get fetchedFids => {...watchedFids, ...keywordFids};

  /// Every source a round of the check fetches, in order: the forums ([forumWatchForumSource]; at most
  /// [forumWatchForumMax], the forums watched first), then the list of the latest threads when the keywords look in
  /// it ([forumWatchLatestSource]).
  List<String> get sources => [
    for (final fid in fetchedFids.take(forumWatchForumMax)) forumWatchForumSource(fid),
    if (keywordsInLatest) forumWatchLatestSource,
  ];

  /// The name of forum [fid] as kept, empty when not known.
  String nameOf(int fid) {
    for (final f in [...forums, ...scope.forums]) {
      if (f.fid == fid && f.name.isNotEmpty) {
        return f.name;
      }
    }
    return '';
  }

  /// How many forums the check would fetch with [forums] watched and the keyword scope [scope] (the current ones when
  /// not given): what [forumWatchForumMax] limits.
  int fetchedCountWith({List<WatchedForum>? forums, KeywordScope? scope}) => ForumWatchConfig(
    forums: forums ?? this.forums,
    keywords: keywords,
    scope: scope ?? this.scope,
  ).fetchedFids.length;

  /// The keywords of [keywords] whose text [title] contains (case ignored), in the order of [keywords].
  List<AlertKeyword> keywordsIn(String title) {
    final lower = title.toLowerCase();
    return [
      for (final k in keywords)
        if (k.key.isNotEmpty && lower.contains(k.key)) k,
    ];
  }

  /// This config with forum [fid] named [name] watched at [now] (milliseconds), first of the forums: later than the
  /// record of its last unwatching, which goes.
  ForumWatchConfig watching(int fid, {required String name, required int now}) => copyWith(
    forums: [
      WatchedForum(fid: fid, name: name, updated: forumWatchChangeTime(now, removedForums[fid] ?? 0)),
      ...forums.where((f) => f.fid != fid),
    ],
    removedForums: {
      for (final e in removedForums.entries)
        if (e.key != fid) e.key: e.value,
    },
  );

  /// This config with forum [fid] unwatched at [now] (milliseconds), leaving a record of when.
  ForumWatchConfig unwatching(int fid, {required int now}) {
    final was = forums.where((f) => f.fid == fid).firstOrNull;
    if (was == null) {
      return this;
    }
    return copyWith(
      forums: [...forums.where((f) => f.fid != fid)],
      removedForums: forumWatchRemovalsKept(
        {...removedForums, fid: forumWatchChangeTime(now, was.updated)},
        now,
        forumWatchForumRemovalMax,
      ),
    );
  }

  /// This config with the alert keyword [text] added at [now] (milliseconds), first of the keywords: later than the
  /// record of its last removal, which goes.
  ForumWatchConfig withKeyword(String text, {required int now}) {
    final key = forumWatchKeywordKey(text);
    return copyWith(
      keywords: [
        AlertKeyword(text: text.trim(), updated: forumWatchChangeTime(now, removedKeywords[key] ?? 0)),
        ...keywords.where((k) => k.key != key),
      ],
      removedKeywords: {
        for (final e in removedKeywords.entries)
          if (e.key != key) e.key: e.value,
      },
    );
  }

  /// This config with the alert keyword of [key] removed at [now] (milliseconds), leaving a record of when.
  ForumWatchConfig withoutKeyword(String key, {required int now}) {
    final was = keywords.where((k) => k.key == key).firstOrNull;
    if (was == null) {
      return this;
    }
    return copyWith(
      keywords: [...keywords.where((k) => k.key != key)],
      removedKeywords: forumWatchRemovalsKept(
        {...removedKeywords, key: forumWatchChangeTime(now, was.updated)},
        now,
        forumWatchKeywordRemovalMax,
      ),
    );
  }

  /// This config with the keywords looked for in [next] from [now] (milliseconds) on; itself when [next] looks in the
  /// same places.
  ForumWatchConfig withScope(KeywordScope next, {required int now}) => next.sameChoiceAs(scope)
      ? this
      : copyWith(scope: next.copyWith(updated: forumWatchChangeTime(now, scope.updated)));

  /// The config as stored.
  Map<String, dynamic> toJson() => {
    'forums': [for (final f in forums) f.toJson()],
    'keywords': [for (final k in keywords) k.toJson()],
    'scope': scope.toJson(),
    if (removedForums.isNotEmpty) 'gone_forums': {for (final e in removedForums.entries) '${e.key}': e.value},
    if (removedKeywords.isNotEmpty) 'gone_keywords': removedKeywords,
  };

  /// A copy with the fields given.
  ForumWatchConfig copyWith({
    List<WatchedForum>? forums,
    List<AlertKeyword>? keywords,
    KeywordScope? scope,
    Map<int, int>? removedForums,
    Map<String, int>? removedKeywords,
  }) => ForumWatchConfig(
    forums: forums ?? this.forums,
    keywords: keywords ?? this.keywords,
    scope: scope ?? this.scope,
    removedForums: removedForums ?? this.removedForums,
    removedKeywords: removedKeywords ?? this.removedKeywords,
  );

  @override
  bool operator ==(Object other) =>
      other is ForumWatchConfig &&
      listEquals(other.forums, forums) &&
      listEquals(other.keywords, keywords) &&
      other.scope == scope &&
      mapEquals(other.removedForums, removedForums) &&
      mapEquals(other.removedKeywords, removedKeywords);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(forums),
    Object.hashAll(keywords),
    scope,
    Object.hashAllUnordered(removedForums.entries.map((e) => Object.hash(e.key, e.value))),
    Object.hashAllUnordered(removedKeywords.entries.map((e) => Object.hash(e.key, e.value))),
  );
}
