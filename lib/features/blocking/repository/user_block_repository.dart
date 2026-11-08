import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/features/blocking/models/thread_filter.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

export 'package:tsdm_client/features/blocking/models/thread_filter.dart';

/// A user blocked locally by one account.
final class BlockedUser {
  /// Constructor.
  const BlockedUser({required this.uid, required this.username, required this.blockedAt});

  /// Uid of the blocked user.
  final int uid;

  /// Username when blocked, for display in the management page only.
  ///
  /// Never used to match content: all filtering is done by [uid].
  final String username;

  /// Time of blocking.
  final DateTime blockedAt;

  /// Encode as one entry of the settings row.
  String encode() =>
      jsonEncode(<String, Object>{'uid': uid, 'username': username, 'at': blockedAt.millisecondsSinceEpoch});

  /// Decode one entry of the settings row, null if malformed.
  static BlockedUser? decode(String data) {
    try {
      final m = jsonDecode(data);
      if (m is! Map<String, dynamic>) {
        return null;
      }
      final uid = m['uid'];
      final username = m['username'];
      final at = m['at'];
      if (uid is! int || uid <= 0 || username is! String) {
        return null;
      }
      final milliseconds = at is int ? at : 0;
      // DateTime accepts at most 100 million days from the epoch. Keep damaged entries unreadable and intact.
      if (milliseconds < -8640000000000000 || milliseconds > 8640000000000000) {
        return null;
      }
      return BlockedUser(
        uid: uid,
        username: username,
        blockedAt: DateTime.fromMillisecondsSinceEpoch(milliseconds),
      );
    } on FormatException {
      return null;
    }
  }
}

/// Whether the list of an account is known.
enum UserBlockListStatus {
  /// The list is being read: which users are blocked is not known yet.
  loading,

  /// The list is read.
  ready,

  /// The list could not be read: which users are blocked is not known.
  failed,
}

/// The local block list of one account.
@immutable
final class UserBlockList {
  /// Constructor.
  UserBlockList({
    required this.ownerUid,
    required List<BlockedUser> users,
    List<String> unreadableEntries = const [],
    this.filters = const ThreadFilters.empty(),
    this.status = UserBlockListStatus.ready,
  }) : users = List.unmodifiable(users),
       unreadableEntries = List.unmodifiable(unreadableEntries),
       uids = Set.unmodifiable(users.map((e) => e.uid));

  /// Empty and known list of [ownerUid].
  const UserBlockList.empty(this.ownerUid)
    : users = const [],
      unreadableEntries = const [],
      uids = const {},
      filters = const ThreadFilters.empty(),
      status = UserBlockListStatus.ready;

  /// List of [ownerUid] that is not known (yet), see [status].
  ///
  /// A null or invalid owner (guest) has nothing to hide and is always known.
  const UserBlockList.unknown(this.ownerUid, {required this.status})
    : assert(status != UserBlockListStatus.ready, 'use UserBlockList.empty'),
      users = const [],
      unreadableEntries = const [],
      uids = const {},
      filters = const ThreadFilters.empty();

  /// Uid of the account owning this list, null for guest (always empty).
  final int? ownerUid;

  /// Blocked users, latest blocked first.
  final List<BlockedUser> users;

  /// Stored entries this version can not read (written by another version or damaged).
  ///
  /// They are written back unchanged on every change, never dropped silently.
  final List<String> unreadableEntries;

  /// Blocked uids.
  final Set<int> uids;

  /// The keywords and forums whose threads are hidden in thread lists.
  final ThreadFilters filters;

  /// Whether the list is known.
  final UserBlockListStatus status;

  /// Whether the users in this list are known.
  ///
  /// Guests have nothing to hide and are always known.
  bool get isKnown => status == UserBlockListStatus.ready || ownerUid == null || ownerUid! <= 0;

  /// Whether [uid] is blocked.
  bool isBlocked(int? uid) => uid != null && uids.contains(uid);

  /// Whether content authored by [uid] must not be shown now.
  ///
  /// True for blocked users, and for every identified author while the list of a logged in account is not known:
  /// content is held back instead of being shown for a moment before the list is read. Content without a known
  /// author ([uid] null or not positive) is never hidden.
  bool hides(int? uid) => uid != null && uid > 0 && (isBlocked(uid) || !isKnown);

  /// Same as [hides] with the uid as string (as parsed from html).
  bool hidesString(String? uid) => hides(uid == null ? null : int.tryParse(uid));

  /// Whether a thread titled [title] in forum [fid] is hidden by [filters], see [ThreadFilters.hides].
  bool hidesThread({required String? title, int? fid, bool byForum = true}) =>
      filters.hides(title: title, fid: fid, byForum: byForum);
}

/// The stored block list could not be read; nothing was changed.
final class UserBlockStorageException implements Exception {
  /// Constructor.
  const UserBlockStorageException(this.cause);

  /// Underlying error.
  final Object cause;

  @override
  String toString() => 'UserBlockStorageException($cause)';
}

/// Result of a block request.
enum UserBlockResult {
  /// Saved.
  ok,

  /// Already blocked, nothing changed.
  alreadyBlocked,

  /// Not blocked, nothing changed (unblock).
  notBlocked,

  /// Users can not block themselves.
  selfBlock,

  /// No account or invalid uid.
  invalid,

  /// The current account changed after the action was started; nothing was changed.
  accountChanged,

  /// The stored list could not be read or written; nothing was changed, or the change is not confirmed.
  storageError,

  /// The thread filters hold [threadFilterMax] already; nothing was changed.
  limitReached,
}

/// Local-only and silent user block.
///
/// Each account owns a separate list keyed by its uid, stored as one row of the settings table named
/// `userBlockList.<ownerUid>` (a json string list, see [BlockedUser.encode]). No request is ever sent to the forum:
/// the blocked user is not notified, forum blacklist, friends and personal messages stay untouched.
///
/// Reads always go to the database so the background service isolate and the sync of all accounts see the same
/// list as the ui without sharing memory.
final class UserBlockRepository with LoggerMixin {
  /// Constructor.
  UserBlockRepository(this._storage);

  final StorageProvider _storage;

  /// Settings row name prefix.
  static const keyPrefix = 'userBlockList.';

  /// Settings row name of [ownerUid].
  static String keyOf(int ownerUid) => '$keyPrefix$ownerUid';

  /// Settings row name prefix of the keyword filters ([BlockedKeyword.encode]).
  static const keywordKeyPrefix = 'threadFilterKeywords.';

  /// Settings row name prefix of the forum filters ([BlockedForum.encode]).
  static const forumKeyPrefix = 'threadFilterForums.';

  /// Settings row name of the keyword filters of [ownerUid].
  static String keywordKeyOf(int ownerUid) => '$keywordKeyPrefix$ownerUid';

  /// Settings row name of the forum filters of [ownerUid].
  static String forumKeyOf(int ownerUid) => '$forumKeyPrefix$ownerUid';

  final _changes = PublishSubject<UserBlockList>();

  /// Serialize all writes in this isolate so two quick taps never lose one update.
  Future<void> _writeQueue = Future.value();

  /// Emits the new list of an account after every change made through this repository.
  Stream<UserBlockList> get changes => _changes.stream;

  /// Load the list of [ownerUid], empty for null or invalid owners.
  ///
  /// Throws [UserBlockStorageException] when the stored row can not be read: callers must not treat that as an
  /// empty list (writing it back would lose the saved one). Entries this version can not decode are kept in
  /// [UserBlockList.unreadableEntries] and written back as they are.
  ///
  /// Without [withFilters], the thread filters are not read (left empty): for the callers that only need the users.
  Future<UserBlockList> load(int? ownerUid, {bool withFilters = true}) async {
    if (ownerUid == null || ownerUid <= 0) {
      return UserBlockList.empty(ownerUid);
    }
    final raw = await _readRow(keyOf(ownerUid));
    final users = <BlockedUser>[];
    final unreadable = <String>[];
    final seen = <int>{};
    for (final entry in raw) {
      final user = BlockedUser.decode(entry);
      if (user == null) {
        unreadable.add(entry);
      } else if (seen.add(user.uid)) {
        // Deduplicate by uid, keep the first (latest) one.
        users.add(user);
      }
    }
    if (unreadable.isNotEmpty) {
      warning('user block list has ${unreadable.length} unreadable entries, kept as they are');
    }
    return UserBlockList(
      ownerUid: ownerUid,
      users: users,
      unreadableEntries: unreadable,
      filters: withFilters ? await _loadFilters(ownerUid) : const ThreadFilters.empty(),
    );
  }

  Future<List<String>> _readRow(String key) async {
    try {
      final stored = await _storage.getStringList(key);
      // The row converter returns a lazily cast view: copy it here so an element that is not a string (a row edited
      // by hand or restored from a modified backup) fails this read instead of throwing a TypeError at a caller.
      return stored == null ? const [] : List<String>.of(stored);
    } on Object catch (e) {
      error('failed to load user block list: $e');
      throw UserBlockStorageException(e);
    }
  }

  /// The thread filters of [ownerUid]: one record per key (the latest), entries this version can not decode kept.
  Future<ThreadFilters> _loadFilters(int ownerUid) async {
    (List<T>, List<String>) decodeAll<T extends ThreadFilterRecord>(List<String> raw, T? Function(String) decode) {
      final byKey = <String, T>{};
      final unreadable = <String>[];
      for (final entry in raw) {
        final record = decode(entry);
        if (record == null) {
          unreadable.add(entry);
        } else if (byKey[record.key] case final kept when kept == null || kept.updated < record.updated) {
          byKey[record.key] = record;
        }
      }
      return (byKey.values.toList(), unreadable);
    }

    final (keywords, badKeywords) = decodeAll(await _readRow(keywordKeyOf(ownerUid)), BlockedKeyword.decode);
    final (forums, badForums) = decodeAll(await _readRow(forumKeyOf(ownerUid)), BlockedForum.decode);
    return ThreadFilters(
      keywordRecords: keywords,
      forumRecords: forums,
      unreadableKeywordEntries: badKeywords,
      unreadableForumEntries: badForums,
    );
  }

  /// Blocked uids of [ownerUid].
  ///
  /// Throws [UserBlockStorageException] like [load].
  Future<Set<int>> blockedUidsOf(int? ownerUid) async => (await load(ownerUid, withFilters: false)).uids;

  /// Watch the list of [ownerUid]: current value first, then every change.
  ///
  /// Changes are listened to before the first read starts, so a change saved while that read is pending is never
  /// missed: it is emitted instead of the (possibly older) read result. A failed first read is emitted as an error
  /// unless a change arrived meanwhile.
  Stream<UserBlockList> watch(int? ownerUid) {
    if (ownerUid == null || ownerUid <= 0) {
      return Stream.value(UserBlockList.empty(ownerUid));
    }
    late final StreamController<UserBlockList> controller;
    StreamSubscription<UserBlockList>? changesSub;
    controller = StreamController<UserBlockList>(
      onListen: () {
        var loaded = false;
        UserBlockList? pending;
        changesSub = _changes.stream.where((e) => e.ownerUid == ownerUid).listen(
          (list) {
            if (loaded) {
              controller.add(list);
            } else {
              pending = list;
            }
          },
        );
        unawaited(
          load(ownerUid).then(
            (list) {
              loaded = true;
              if (!controller.isClosed) {
                controller.add(pending ?? list);
              }
            },
            onError: (Object e, StackTrace st) {
              loaded = true;
              if (controller.isClosed) {
                return;
              }
              if (pending != null) {
                controller.add(pending!);
              } else {
                controller.addError(e, st);
              }
            },
          ),
        );
      },
      onCancel: () async {
        await changesSub?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Write [list]: the users when [users], the thread filters when [filters].
  Future<void> _save(UserBlockList list, {bool users = true, bool filters = false}) async {
    final owner = list.ownerUid!;
    Future<void> write(String key, List<String> entries) =>
        entries.isEmpty ? _storage.deleteKey(key) : _storage.saveStringList(key, entries);
    if (users) {
      await write(keyOf(owner), [...list.users.map((e) => e.encode()), ...list.unreadableEntries]);
    }
    if (filters) {
      final f = list.filters;
      await write(keywordKeyOf(owner), [
        ...f.keywordRecords.map((e) => e.encode()),
        ...f.unreadableKeywordEntries,
      ]);
      await write(forumKeyOf(owner), [...f.forumRecords.map((e) => e.encode()), ...f.unreadableForumEntries]);
    }
    _changes.add(list);
  }

  UserBlockList _withFilters(UserBlockList list, ThreadFilters filters) => UserBlockList(
    ownerUid: list.ownerUid,
    users: list.users,
    unreadableEntries: list.unreadableEntries,
    filters: filters,
  );

  /// [records] without the removals older than [threadFilterTombstoneKeptFor] at [now].
  static List<T> _pruned<T extends ThreadFilterRecord>(Iterable<T> records, int now) => [
    for (final r in records)
      if (!r.deleted || r.updated >= now - threadFilterTombstoneKeptFor.inMilliseconds) r,
  ];

  /// [records] within [threadFilterMax] in use: the latest added are kept, the others dropped without a record of a
  /// removal (two devices' filters merged over the limit; the sync document keeps the same latest ones).
  static List<T> _capped<T extends ThreadFilterRecord>(List<T> records) {
    final live = records.where((e) => !e.deleted).toList();
    if (live.length <= threadFilterMax) {
      return records;
    }
    live.sort(compareThreadFilterRecords);
    final dropped = live.skip(threadFilterMax).toSet();
    return records.where((e) => !dropped.contains(e)).toList();
  }

  ThreadFilters _filtersWith(
    ThreadFilters base, {
    required int now,
    Iterable<BlockedKeyword>? keywords,
    Iterable<BlockedForum>? forums,
  }) => ThreadFilters(
    keywordRecords: _capped(_pruned(keywords ?? base.keywordRecords, now)),
    forumRecords: _capped(_pruned(forums ?? base.forumRecords, now)),
    unreadableKeywordEntries: base.unreadableKeywordEntries,
    unreadableForumEntries: base.unreadableForumEntries,
  );

  /// Hide the threads whose title contains [text] (case ignored) for account [ownerUid].
  Future<UserBlockResult> addKeyword({required int? ownerUid, required String text, DateTime? now}) => _serialized(
    () async {
      final keyword = text.trim();
      if (ownerUid == null ||
          ownerUid <= 0 ||
          keyword.isEmpty ||
          keyword.characters.length > threadFilterKeywordMaxLength) {
        return UserBlockResult.invalid;
      }
      final list = await load(ownerUid);
      final key = threadFilterKeywordKey(keyword);
      if (list.filters.hasKeyword(key)) {
        return UserBlockResult.alreadyBlocked;
      }
      if (list.filters.keywords.length >= threadFilterMax) {
        return UserBlockResult.limitReached;
      }
      final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
      final records = [
        BlockedKeyword(text: keyword, updated: at),
        ...list.filters.keywordRecords.where((e) => e.key != key),
      ];
      await _save(
        _withFilters(list, _filtersWith(list.filters, keywords: records, now: at)),
        users: false,
        filters: true,
      );
      return UserBlockResult.ok;
    },
  );

  /// Stop hiding the threads of the keyword of [key] ([threadFilterKeywordKey]) for account [ownerUid].
  Future<UserBlockResult> removeKeyword({required int? ownerUid, required String key, DateTime? now}) =>
      _serialized(() async {
        if (ownerUid == null || ownerUid <= 0) {
          return UserBlockResult.invalid;
        }
        final list = await load(ownerUid);
        if (!list.filters.hasKeyword(key)) {
          return UserBlockResult.notBlocked;
        }
        final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
        final records = [
          for (final r in list.filters.keywordRecords)
            r.key == key ? BlockedKeyword(text: r.text, updated: at, deleted: true) : r,
        ];
        await _save(
          _withFilters(list, _filtersWith(list.filters, keywords: records, now: at)),
          users: false,
          filters: true,
        );
        return UserBlockResult.ok;
      });

  /// Change the forums whose threads are hidden in the lists of many forums for account [ownerUid]: hide the forums
  /// of [add] (id to name), stop hiding those of [remove]. Applied to the list as stored now, so a forum another
  /// device added meanwhile (or one removed a moment before) is left as it is.
  Future<UserBlockResult> changeForums({
    required int? ownerUid,
    Map<int, String> add = const {},
    Set<int> remove = const {},
    DateTime? now,
  }) => _serialized(() async {
    if (ownerUid == null || ownerUid <= 0) {
      return UserBlockResult.invalid;
    }
    final list = await load(ownerUid);
    final current = list.filters.forumIds;
    final adding = {
      for (final MapEntry(:key, :value) in add.entries)
        if (key > 0 && !current.contains(key) && !remove.contains(key)) key: value,
    };
    final removing = remove.where(current.contains).toSet();
    if (adding.isEmpty && removing.isEmpty) {
      return UserBlockResult.alreadyBlocked;
    }
    if (current.length - removing.length + adding.length > threadFilterMax) {
      return UserBlockResult.limitReached;
    }
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final known = {for (final r in list.filters.forumRecords) r.fid};
    final records = <BlockedForum>[
      for (final r in list.filters.forumRecords)
        if (removing.contains(r.fid))
          BlockedForum(fid: r.fid, name: r.name, updated: at, deleted: true)
        else if (adding.containsKey(r.fid))
          BlockedForum(fid: r.fid, name: adding[r.fid]!, updated: at)
        else
          r,
      for (final MapEntry(:key, :value) in adding.entries)
        if (!known.contains(key)) BlockedForum(fid: key, name: value, updated: at),
    ];
    await _save(
      _withFilters(list, _filtersWith(list.filters, forums: records, now: at)),
      users: false,
      filters: true,
    );
    return UserBlockResult.ok;
  });

  /// Take the thread filter records of the cross-device sync, [keywords] and [forums] (removals included): per key,
  /// the later record wins, this device's own on the same time (a change made here while the sync was on its way is
  /// never undone). Nothing is written when nothing changes.
  ///
  /// The document merge (`SyncDocument.merge`) keeps the forum's item on the same time instead, on purpose: records of
  /// one time are the same change either way, and the next run converges on it.
  Future<UserBlockResult> applySyncedFilters({
    required int? ownerUid,
    required List<BlockedKeyword> keywords,
    required List<BlockedForum> forums,
    DateTime? now,
  }) => _serialized(() async {
    if (ownerUid == null || ownerUid <= 0) {
      return UserBlockResult.invalid;
    }
    final list = await load(ownerUid);
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    // Removals too old to keep are not taken: they would be dropped right after, a change of nothing.
    final merged = list.filters.mergedWith(keywords: _pruned(keywords, at), forums: _pruned(forums, at));
    final next = merged == null ? null : _filtersWith(merged, now: at);
    // Compared after the cap: a record the cap drops again is no change (no write, no sync run started by it).
    if (next == null || next.sameRecordsAs(list.filters)) {
      return UserBlockResult.ok;
    }
    await _save(
      _withFilters(list, next),
      users: false,
      filters: true,
    );
    return UserBlockResult.ok;
  });

  /// Block [uid] for account [ownerUid] locally.
  Future<UserBlockResult> block({
    required int? ownerUid,
    required int uid,
    required String username,
    DateTime? now,
  }) => _serialized(() async {
    if (ownerUid == null || ownerUid <= 0 || uid <= 0) {
      return UserBlockResult.invalid;
    }
    if (ownerUid == uid) {
      return UserBlockResult.selfBlock;
    }
    final list = await load(ownerUid);
    if (list.isBlocked(uid)) {
      return UserBlockResult.alreadyBlocked;
    }
    await _save(
      UserBlockList(
        ownerUid: ownerUid,
        users: [
          BlockedUser(uid: uid, username: username, blockedAt: now ?? DateTime.now()),
          ...list.users,
        ],
        unreadableEntries: list.unreadableEntries,
        filters: list.filters,
      ),
    );
    return UserBlockResult.ok;
  });

  /// Remove [uid] from the list of [ownerUid].
  Future<UserBlockResult> unblock({required int? ownerUid, required int uid}) => _serialized(() async {
    if (ownerUid == null || ownerUid <= 0) {
      return UserBlockResult.invalid;
    }
    final list = await load(ownerUid);
    if (!list.isBlocked(uid)) {
      return UserBlockResult.notBlocked;
    }
    await _save(
      UserBlockList(
        ownerUid: ownerUid,
        users: list.users.where((e) => e.uid != uid).toList(),
        unreadableEntries: list.unreadableEntries,
        filters: list.filters,
      ),
    );
    return UserBlockResult.ok;
  });

  /// Replace the list of [ownerUid] with [users] (the cross-device sync applying the merged list); entries this
  /// version can not read are kept. Nothing is written when the list is the same already.
  Future<UserBlockResult> replaceAll({required int? ownerUid, required List<BlockedUser> users}) =>
      _serialized(() async {
        if (ownerUid == null || ownerUid <= 0) {
          return UserBlockResult.invalid;
        }
        final list = await load(ownerUid);
        final next = <BlockedUser>[];
        final seen = <int>{};
        for (final user in users) {
          if (user.uid > 0 && user.uid != ownerUid && seen.add(user.uid)) {
            next.add(user);
          }
        }
        next.sort((a, b) => b.blockedAt.compareTo(a.blockedAt));
        final same =
            next.length == list.users.length &&
            Iterable<int>.generate(next.length).every(
              (i) =>
                  next[i].uid == list.users[i].uid &&
                  next[i].username == list.users[i].username &&
                  next[i].blockedAt == list.users[i].blockedAt,
            );
        if (same) {
          return UserBlockResult.ok;
        }
        await _save(
          UserBlockList(
            ownerUid: ownerUid,
            users: next,
            unreadableEntries: list.unreadableEntries,
            filters: list.filters,
          ),
        );
        return UserBlockResult.ok;
      });

  /// Dispose.
  Future<void> dispose() async {
    await _changes.close();
  }
}
