import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/editor/utils/quick_phrases.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// A visit record of a thread as the sync sees it: the visit and where the reading stopped.
@immutable
final class SyncVisit {
  /// Constructor.
  const SyncVisit({
    required this.tid,
    required this.title,
    required this.fid,
    required this.forumName,
    required this.updated,
    this.page,
    this.pid,
    this.floor,
    this.seenReplies,
  });

  /// The visit of the document item [item] of thread [tid], null when the item lacks what a record needs.
  static SyncVisit? fromItem(int tid, Map<String, dynamic> item) {
    final title = item['title'];
    final fid = item['fid'];
    if (title is! String || fid is! num) {
      return null;
    }
    int? intOf(Object? v) => v is num ? v.toInt() : null;
    return SyncVisit(
      tid: tid,
      title: title,
      fid: fid.toInt(),
      forumName: item['forum'] is String ? item['forum'] as String : '',
      updated: intOf(item['updated']) ?? 0,
      page: intOf(item['page']),
      pid: intOf(item['pid']),
      floor: intOf(item['floor']),
      seenReplies: intOf(item['seen']),
    );
  }

  /// Thread id.
  final int tid;

  /// Thread title.
  final String title;

  /// Forum id.
  final int fid;

  /// Forum name.
  final String forumName;

  /// The visit time (milliseconds since the epoch), the item's `updated`.
  final int updated;

  /// Where the reading stopped: the page.
  final int? page;

  /// Where the reading stopped: the post id.
  final int? pid;

  /// Where the reading stopped: the floor.
  final int? floor;

  /// The replies the thread had when read.
  final int? seenReplies;

  /// The document item.
  Map<String, dynamic> toItem() => {
    'updated': updated,
    'title': title,
    'fid': fid,
    'forum': forumName,
    'page': ?page,
    'pid': ?pid,
    'floor': ?floor,
    'seen': ?seenReplies,
  };

  @override
  bool operator ==(Object other) =>
      other is SyncVisit &&
      other.tid == tid &&
      other.title == title &&
      other.fid == fid &&
      other.forumName == forumName &&
      other.updated == updated &&
      other.page == page &&
      other.pid == pid &&
      other.floor == floor &&
      other.seenReplies == seenReplies;

  @override
  int get hashCode => Object.hash(tid, title, fid, forumName, updated, page, pid, floor, seenReplies);
}

/// A blocked user as the sync sees it.
@immutable
final class SyncBlock {
  /// Constructor.
  const SyncBlock({required this.uid, required this.username, required this.updated});

  /// The block of the document item [item] of user [uid].
  factory SyncBlock.fromItem(int uid, Map<String, dynamic> item) => SyncBlock(
    uid: uid,
    username: item['username'] is String ? item['username'] as String : '',
    updated: item['updated'] is num ? (item['updated'] as num).toInt() : 0,
  );

  /// The blocked user.
  final int uid;

  /// The name shown for the user.
  final String username;

  /// When the user was blocked (milliseconds since the epoch), the item's `updated`.
  final int updated;

  /// The document item.
  Map<String, dynamic> toItem() => {'updated': updated, 'username': username};

  @override
  bool operator ==(Object other) =>
      other is SyncBlock && other.uid == uid && other.username == username && other.updated == updated;

  @override
  int get hashCode => Object.hash(uid, username, updated);
}

/// What the sync was last told by the forum about an account: the document the forum holds and its `updated`.
typedef SyncLastSynced = ({String document, int updated});

/// What the sync reads and writes on this device.
abstract interface class SyncLocalStore {
  /// The visit records of account [uid].
  Future<List<SyncVisit>> visits(int uid);

  /// Keep [visit] as a visit record of account [uid] (added or replaced, its progress with it).
  Future<void> saveVisit(int uid, SyncVisit visit);

  /// Remove the visit record of thread [tid] of account [uid].
  Future<void> deleteVisit(int uid, int tid);

  /// The quick phrases (of the device, not of one account).
  Future<List<String>> phrases();

  /// Replace the quick phrases.
  Future<void> savePhrases(List<String> phrases);

  /// When the quick phrases last changed (milliseconds), null when never noted.
  Future<int?> phrasesUpdated();

  /// Note when the quick phrases last changed.
  Future<void> savePhrasesUpdated(int updated);

  /// The users account [uid] blocks.
  Future<List<SyncBlock>> blocks(int uid);

  /// Replace the users account [uid] blocks.
  Future<void> saveBlocks(int uid, List<SyncBlock> blocks);

  /// The document the forum held for account [uid] when it was last read or written, null before the first sync.
  Future<SyncLastSynced?> lastSynced(int uid);

  /// Keep [document] as what the forum holds for account [uid], written at [updated] (forum seconds).
  Future<void> saveLastSynced(int uid, String document, int updated);
}

/// [SyncLocalStore] on the app's storage: the visit records, the settings, the block lists.
final class StorageSyncLocalStore implements SyncLocalStore {
  /// Constructor.
  const StorageSyncLocalStore({
    required StorageProvider storage,
    required SettingsRepository settings,
    required UserBlockRepository blocks,
    required AuthenticationRepository authentication,
  }) : _storage = storage,
       _settings = settings,
       _blocks = blocks,
       _authentication = authentication;

  final StorageProvider _storage;
  final SettingsRepository _settings;
  final UserBlockRepository _blocks;
  final AuthenticationRepository _authentication;

  /// The settings row of when the quick phrases last changed.
  static const phrasesUpdatedKey = 'sync.phrasesUpdated';

  /// The settings row of the document the forum held for an account.
  static String lastDocumentKeyOf(int uid) => 'sync.lastDocument.$uid';

  /// The settings row of the `updated` of the document the forum held for an account.
  static String lastUpdatedKeyOf(int uid) => 'sync.lastUpdated.$uid';

  @override
  Future<List<SyncVisit>> visits(int uid) async {
    final rows = await _storage.fetchThreadVisitHistoryByUid(uid).run();
    return switch (rows) {
      Right(:final value) => [
        for (final row in value)
          SyncVisit(
            tid: row.tid,
            title: row.threadTitle,
            fid: row.fid,
            forumName: row.forumName,
            updated: row.visitTime.millisecondsSinceEpoch,
            page: row.lastPage,
            pid: row.lastPid,
            floor: row.lastFloor,
            seenReplies: row.seenReplies,
          ),
      ],
      Left(:final value) => throw value,
    };
  }

  @override
  Future<void> saveVisit(int uid, SyncVisit visit) async {
    // The record names the account: the one in use when verified, else the one the global cookie names.
    final user = _authentication.currentUser;
    final cookieUser = getIt.get<CookieProvider>().userLoginInfo;
    final username = user?.uid == uid ? user?.username : (cookieUser.uid == uid ? cookieUser.username : null);
    await _storage.updateThreadVisitHistory(
      uid: uid,
      tid: visit.tid,
      fid: visit.fid,
      username: username ?? '',
      threadTitle: visit.title,
      forumName: visit.forumName,
      visitTime: DateTime.fromMillisecondsSinceEpoch(visit.updated),
    );
    await _storage.updateThreadVisitProgress(
      uid: uid,
      tid: visit.tid,
      page: visit.page,
      pid: visit.pid,
      floor: visit.floor,
      seenReplies: visit.seenReplies,
      visitTime: DateTime.fromMillisecondsSinceEpoch(visit.updated),
    );
  }

  @override
  Future<void> deleteVisit(int uid, int tid) => _storage.deleteThreadVisitHistory(uid: uid, tid: tid);

  @override
  Future<List<String>> phrases() async => decodeQuickPhrases(_settings.currentSettings.editorQuickPhrases);

  @override
  Future<void> savePhrases(List<String> phrases) =>
      _settings.setValue(SettingsKeys.editorQuickPhrases, phrases.isEmpty ? '' : encodeQuickPhrases(phrases));

  @override
  Future<int?> phrasesUpdated() => _storage.getInt(phrasesUpdatedKey);

  @override
  Future<void> savePhrasesUpdated(int updated) => _storage.saveInt(phrasesUpdatedKey, updated);

  @override
  Future<List<SyncBlock>> blocks(int uid) async => [
    for (final user in (await _blocks.load(uid)).users)
      SyncBlock(uid: user.uid, username: user.username, updated: user.blockedAt.millisecondsSinceEpoch),
  ];

  @override
  Future<void> saveBlocks(int uid, List<SyncBlock> blocks) async {
    await _blocks.replaceAll(
      ownerUid: uid,
      users: [
        for (final b in blocks)
          BlockedUser(uid: b.uid, username: b.username, blockedAt: DateTime.fromMillisecondsSinceEpoch(b.updated)),
      ],
    );
  }

  @override
  Future<SyncLastSynced?> lastSynced(int uid) async {
    final document = await _storage.getString(lastDocumentKeyOf(uid));
    if (document == null) {
      return null;
    }
    return (document: document, updated: await _storage.getInt(lastUpdatedKeyOf(uid)) ?? 0);
  }

  @override
  Future<void> saveLastSynced(int uid, String document, int updated) async {
    await _storage.saveString(lastDocumentKeyOf(uid), document);
    await _storage.saveInt(lastUpdatedKeyOf(uid), updated);
  }
}

/// A [SyncLocalStore] in memory (tests).
final class MemorySyncLocalStore implements SyncLocalStore {
  /// The visit records by account and thread.
  final visitsByUid = <int, Map<int, SyncVisit>>{};

  /// The quick phrases.
  List<String> phraseList = [];

  /// When the quick phrases last changed.
  int? phrasesUpdatedAt;

  /// The block lists by account.
  final blocksByUid = <int, List<SyncBlock>>{};

  /// What the forum held, by account.
  final lastByUid = <int, SyncLastSynced>{};

  /// Every write, in order (`saveVisit 3`, `deleteVisit 3`, `savePhrases`, `saveBlocks`), for the tests.
  final writes = <String>[];

  @override
  Future<List<SyncVisit>> visits(int uid) async => (visitsByUid[uid] ?? const {}).values.toList();

  @override
  Future<void> saveVisit(int uid, SyncVisit visit) async {
    (visitsByUid[uid] ??= {})[visit.tid] = visit;
    writes.add('saveVisit ${visit.tid}');
  }

  @override
  Future<void> deleteVisit(int uid, int tid) async {
    visitsByUid[uid]?.remove(tid);
    writes.add('deleteVisit $tid');
  }

  @override
  Future<List<String>> phrases() async => List.of(phraseList);

  @override
  Future<void> savePhrases(List<String> phrases) async {
    phraseList = List.of(phrases);
    writes.add('savePhrases');
  }

  @override
  Future<int?> phrasesUpdated() async => phrasesUpdatedAt;

  @override
  Future<void> savePhrasesUpdated(int updated) async => phrasesUpdatedAt = updated;

  @override
  Future<List<SyncBlock>> blocks(int uid) async => List.of(blocksByUid[uid] ?? const []);

  @override
  Future<void> saveBlocks(int uid, List<SyncBlock> blocks) async {
    blocksByUid[uid] = List.of(blocks);
    writes.add('saveBlocks');
  }

  @override
  Future<SyncLastSynced?> lastSynced(int uid) async => lastByUid[uid];

  @override
  Future<void> saveLastSynced(int uid, String document, int updated) async =>
      lastByUid[uid] = (document: document, updated: updated);
}
