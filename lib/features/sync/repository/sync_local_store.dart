import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/editor/utils/quick_phrases.dart';
import 'package:tsdm_client/features/floor_bookmark/models/floor_bookmark.dart';
import 'package:tsdm_client/features/floor_bookmark/repository/floor_bookmark_store.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
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
    this.progressUpdated = 0,
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
      progressUpdated: intOf(item['progress_updated']) ?? 0,
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

  /// The visit time (milliseconds since the epoch), the item's `updated`: the time of the title and forum fields.
  final int updated;

  /// When the progress fields were written (milliseconds), the item's `progress_updated`; 0 when not known (a
  /// progress kept before schema 18).
  final int progressUpdated;

  /// Where the reading stopped: the page.
  final int? page;

  /// Where the reading stopped: the post id.
  final int? pid;

  /// Where the reading stopped: the floor.
  final int? floor;

  /// The replies the thread had when read.
  final int? seenReplies;

  /// Whether a reading progress is kept (the same test as `SyncDocument.hasProgress` on the item).
  bool get hasProgress => page != null || pid != null || floor != null;

  /// The document item.
  Map<String, dynamic> toItem() => {
    'updated': updated,
    'title': title,
    'fid': fid,
    'forum': forumName,
    'progress_updated': progressUpdated,
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
      other.progressUpdated == progressUpdated &&
      other.page == page &&
      other.pid == pid &&
      other.floor == floor &&
      other.seenReplies == seenReplies;

  @override
  int get hashCode => Object.hash(tid, title, fid, forumName, updated, progressUpdated, page, pid, floor, seenReplies);
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

/// The document item of the fast rate template [template] (an item of the `rate_templates` list).
Map<String, dynamic> rateTemplateToItem(FastRateTemplateModel template) => {
  'name': template.name,
  'ww': template.ww,
  'tsb': template.tsb,
  'xc': template.xc,
  'tr': template.tr,
  'fh': template.fh,
  'jl': template.jl,
  'special': template.special,
  'special2': template.special2,
};

/// The fast rate template of the document item [item], null when it is not one (no name, a value not a number).
FastRateTemplateModel? rateTemplateFromItem(Object? item) {
  if (item is! Map) {
    return null;
  }
  final name = item['name'];
  if (name is! String || name.trim().isEmpty) {
    return null;
  }
  int? intOf(String field) => switch (item[field]) {
    final num n when n.isFinite => n.toInt(),
    null => 0,
    _ => null,
  };
  final values = [
    for (final f in const ['ww', 'tsb', 'xc', 'tr', 'fh', 'jl', 'special', 'special2']) intOf(f),
  ];
  if (values.contains(null)) {
    return null;
  }
  return FastRateTemplateModel(
    name: name,
    ww: values[0]!,
    tsb: values[1]!,
    xc: values[2]!,
    tr: values[3]!,
    fh: values[4]!,
    jl: values[5]!,
    special: values[6]!,
    special2: values[7]!,
  );
}

/// The fields of a draft item this version reads; others are kept as they are.
const syncDraftFields = {
  'updated',
  'deleted',
  'body',
  'delta',
  'subject',
  'fid',
  'tid',
  'replyAction',
  'hint',
  'quote',
  'title',
  'typeId',
  'maybeSent',
};

/// The document item of [draft]: its fields as the draft file has them, the time as `updated`.
Map<String, dynamic> draftToItem(LocalDraft draft) => {
  'updated': draft.updatedAt.millisecondsSinceEpoch,
  for (final MapEntry(:key, :value) in draft.toJson().entries)
    if (key != 'updatedAt') key: value,
};

/// The draft of the document item [item] under [key], null when either is not one this version reads.
LocalDraft? draftFromItem(String key, Map<String, dynamic> item) {
  final draftKey = LocalDraftKey.parse(key);
  if (draftKey == null) {
    return null;
  }
  return LocalDraft.fromJson(draftKey, {...item, 'updatedAt': item['updated']});
}

/// What the sync was last told by the forum about an account: the document the forum holds and its `updated`.
typedef SyncLastSynced = ({String document, int updated});

/// What the sync reads and writes on this device.
abstract interface class SyncLocalStore {
  /// The visit records of account [uid].
  Future<List<SyncVisit>> visits(int uid);

  /// Keep the visit of [visit] (title, forum, time) as a record of account [uid], added or replaced; the progress
  /// columns of a record that exists stay.
  Future<void> saveVisit(int uid, SyncVisit visit);

  /// Keep the progress of [visit] (page, pid, floor, seen replies, when written) on the record of account [uid];
  /// nothing when the visit is not recorded.
  Future<void> saveProgress(int uid, SyncVisit visit);

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

  /// The fast rate templates (of the device, not of one account), in their order.
  Future<List<FastRateTemplateModel>> rateTemplates();

  /// Replace the fast rate templates.
  Future<void> saveRateTemplates(List<FastRateTemplateModel> templates);

  /// When the fast rate templates last changed (milliseconds), null when never noted.
  Future<int?> rateTemplatesUpdated();

  /// Note when the fast rate templates last changed.
  Future<void> saveRateTemplatesUpdated(int updated);

  /// The values of the synced settings (of the device), by stored name ([syncedSettingsValues]).
  Future<Map<String, Object>> settingsValues();

  /// Apply the document's settings [values] ([syncedSettingsChanges]), at once.
  Future<void> applySettingsValues(Map<String, dynamic> values);

  /// When the synced settings last changed (milliseconds), null when never noted.
  Future<int?> settingsUpdated();

  /// Note when the synced settings last changed.
  Future<void> saveSettingsUpdated(int updated);

  /// The local drafts of account [uid], null when they can not be read (they are left alone then). When the drafts of
  /// the account were lost on this device (their file set aside), [draftsSeen] is forgotten first: nothing this device
  /// held reads as deleted.
  Future<List<LocalDraft>?> drafts(int uid);

  /// Keep the drafts [save] and delete those of [delete] of account [uid].
  Future<void> applyDrafts(int uid, {required List<LocalDraft> save, required List<LocalDraftKey> delete});

  /// The keys of the drafts of account [uid] this device held (or knew deleted) after its last sync of them, null
  /// before the first: a key of them this device no longer holds was deleted here.
  Future<Set<String>?> draftsSeen(int uid);

  /// Keep [keys] as the [draftsSeen] of account [uid].
  Future<void> saveDraftsSeen(int uid, Set<String> keys);

  /// The floor bookmarks of account [uid], the records of removed ones included; null when they can not be kept on
  /// this device (left alone then).
  Future<List<FloorBookmark>?> bookmarks(int uid);

  /// Keep [save] (bookmarks and records of removed ones) for account [uid], each where it is later than this device's.
  Future<void> applyBookmarks(int uid, List<FloorBookmark> save);

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

  /// The settings row of when the fast rate templates last changed.
  static const rateTemplatesUpdatedKey = 'sync.rateTemplatesUpdated';

  /// The settings row of when the synced settings last changed.
  static const settingsUpdatedKey = 'sync.settingsUpdated';

  /// The settings row of the drafts an account held after its last sync of them.
  static String draftsSeenKeyOf(int uid) => 'sync.draftsSeen.$uid';

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
            progressUpdated: row.progressUpdated?.millisecondsSinceEpoch ?? 0,
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
  }

  @override
  Future<void> saveProgress(int uid, SyncVisit visit) => _storage.updateThreadVisitProgress(
    uid: uid,
    tid: visit.tid,
    page: visit.page,
    pid: visit.pid,
    floor: visit.floor,
    seenReplies: visit.seenReplies,
    progressUpdated: visit.progressUpdated > 0 ? DateTime.fromMillisecondsSinceEpoch(visit.progressUpdated) : null,
  );

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
  Future<List<FastRateTemplateModel>> rateTemplates() async => switch (await _storage.getAllFastRateTemplate().run()) {
    Right(:final value) => value,
    Left(:final value) => throw value,
  };

  @override
  Future<void> saveRateTemplates(List<FastRateTemplateModel> templates) async {
    if (await _storage.replaceAllFastRateTemplates(templates).run() case Left(:final value)) {
      throw value;
    }
  }

  @override
  Future<int?> rateTemplatesUpdated() => _storage.getInt(rateTemplatesUpdatedKey);

  @override
  Future<void> saveRateTemplatesUpdated(int updated) => _storage.saveInt(rateTemplatesUpdatedKey, updated);

  @override
  Future<Map<String, Object>> settingsValues() async => syncedSettingsValues(_settings.currentSettings);

  @override
  Future<void> applySettingsValues(Map<String, dynamic> values) async {
    final changes = syncedSettingsChanges(values, _settings.currentSettings);
    if (changes.isNotEmpty) {
      await _settings.setMixedValues(changes);
    }
  }

  @override
  Future<int?> settingsUpdated() => _storage.getInt(settingsUpdatedKey);

  @override
  Future<void> saveSettingsUpdated(int updated) => _storage.saveInt(settingsUpdatedKey, updated);

  @override
  Future<List<LocalDraft>?> drafts(int uid) async {
    final store = LocalDraftStore.app;
    if (store == null) {
      return null;
    }
    final drafts = await store.listForSync(uid);
    if (store.takeSetAside(uid)) {
      await _storage.deleteKey(draftsSeenKeyOf(uid));
    }
    return drafts;
  }

  @override
  Future<void> applyDrafts(int uid, {required List<LocalDraft> save, required List<LocalDraftKey> delete}) async =>
      LocalDraftStore.app?.applySynced(uid, save: save, delete: delete);

  @override
  Future<Set<String>?> draftsSeen(int uid) async => (await _storage.getStringList(draftsSeenKeyOf(uid)))?.toSet();

  @override
  Future<void> saveDraftsSeen(int uid, Set<String> keys) =>
      _storage.saveStringList(draftsSeenKeyOf(uid), keys.toList());

  @override
  Future<List<FloorBookmark>?> bookmarks(int uid) async => FloorBookmarkStore.app?.items(uid);

  @override
  Future<void> applyBookmarks(int uid, List<FloorBookmark> save) async =>
      FloorBookmarkStore.app?.applySynced(uid, save);

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

  /// The fast rate templates.
  List<FastRateTemplateModel> templateList = [];

  /// When the fast rate templates last changed.
  int? templatesUpdatedAt;

  /// The values of the synced settings, by stored name.
  Map<String, Object> settingsMap = syncedSettingsDefaults();

  /// When the synced settings last changed.
  int? settingsUpdatedAt;

  /// The drafts by account and key; an account missing reads as none, [draftsUnreadable] as unreadable.
  final draftsByUid = <int, Map<String, LocalDraft>>{};

  /// Accounts whose drafts can not be read.
  final draftsUnreadable = <int>{};

  /// Accounts whose drafts were lost (their file set aside): read as none, [draftsSeen] forgotten.
  final draftsSetAside = <int>{};

  /// Called after each read of the drafts (the tests change the drafts in the middle of a run).
  void Function(int uid)? afterDraftsRead;

  /// The [draftsSeen] by account.
  final draftsSeenByUid = <int, Set<String>>{};

  /// The floor bookmarks by account and key, the records of removed ones included.
  final bookmarksByUid = <int, Map<String, FloorBookmark>>{};

  /// Every write, in order (`saveVisit 3`, `deleteVisit 3`, `savePhrases`, `saveBlocks`), for the tests.
  final writes = <String>[];

  @override
  Future<List<SyncVisit>> visits(int uid) async => (visitsByUid[uid] ?? const {}).values.toList();

  @override
  Future<void> saveVisit(int uid, SyncVisit visit) async {
    final old = (visitsByUid[uid] ??= {})[visit.tid];
    visitsByUid[uid]![visit.tid] = old == null
        ? SyncVisit(
            tid: visit.tid,
            title: visit.title,
            fid: visit.fid,
            forumName: visit.forumName,
            updated: visit.updated,
          )
        : SyncVisit(
            tid: visit.tid,
            title: visit.title,
            fid: visit.fid,
            forumName: visit.forumName,
            updated: visit.updated,
            progressUpdated: old.progressUpdated,
            page: old.page,
            pid: old.pid,
            floor: old.floor,
            seenReplies: old.seenReplies,
          );
    writes.add('saveVisit ${visit.tid}');
  }

  @override
  Future<void> saveProgress(int uid, SyncVisit visit) async {
    final old = visitsByUid[uid]?[visit.tid];
    if (old == null) {
      return;
    }
    visitsByUid[uid]![visit.tid] = SyncVisit(
      tid: old.tid,
      title: old.title,
      fid: old.fid,
      forumName: old.forumName,
      updated: old.updated,
      progressUpdated: visit.progressUpdated,
      page: visit.page,
      pid: visit.pid,
      floor: visit.floor,
      seenReplies: visit.seenReplies,
    );
    writes.add('saveProgress ${visit.tid}');
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
  Future<List<FastRateTemplateModel>> rateTemplates() async => List.of(templateList);

  @override
  Future<void> saveRateTemplates(List<FastRateTemplateModel> templates) async {
    templateList = List.of(templates);
    writes.add('saveRateTemplates');
  }

  @override
  Future<int?> rateTemplatesUpdated() async => templatesUpdatedAt;

  @override
  Future<void> saveRateTemplatesUpdated(int updated) async => templatesUpdatedAt = updated;

  @override
  Future<Map<String, Object>> settingsValues() async => Map.of(settingsMap);

  @override
  Future<void> applySettingsValues(Map<String, dynamic> values) async {
    final next = syncedSettingsApplied(settingsMap, values);
    if (!mapEquals(next, settingsMap)) {
      settingsMap = next;
      writes.add('applySettings');
    }
  }

  @override
  Future<int?> settingsUpdated() async => settingsUpdatedAt;

  @override
  Future<void> saveSettingsUpdated(int updated) async => settingsUpdatedAt = updated;

  @override
  Future<List<LocalDraft>?> drafts(int uid) async {
    if (draftsUnreadable.contains(uid)) {
      return null;
    }
    if (draftsSetAside.remove(uid)) {
      draftsByUid.remove(uid);
      draftsSeenByUid.remove(uid);
    }
    final drafts = (draftsByUid[uid] ?? const {}).values.toList();
    afterDraftsRead?.call(uid);
    return drafts;
  }

  @override
  Future<void> applyDrafts(int uid, {required List<LocalDraft> save, required List<LocalDraftKey> delete}) async {
    final drafts = draftsByUid[uid] ??= {};
    for (final key in delete) {
      drafts.remove(key.value);
      writes.add('deleteDraft ${key.value}');
    }
    for (final draft in save) {
      drafts[draft.key.value] = draft;
      writes.add('saveDraft ${draft.key.value}');
    }
  }

  @override
  Future<Set<String>?> draftsSeen(int uid) async => draftsSeenByUid[uid];

  @override
  Future<void> saveDraftsSeen(int uid, Set<String> keys) async => draftsSeenByUid[uid] = Set.of(keys);

  @override
  Future<List<FloorBookmark>?> bookmarks(int uid) async => (bookmarksByUid[uid] ?? const {}).values.toList();

  @override
  Future<void> applyBookmarks(int uid, List<FloorBookmark> save) async {
    final items = bookmarksByUid[uid] ??= {};
    for (final bookmark in save) {
      if ((items[bookmark.key]?.updated ?? -1) < bookmark.updated) {
        items[bookmark.key] = bookmark;
        writes.add('saveBookmark ${bookmark.key}');
      }
    }
  }

  @override
  Future<SyncLastSynced?> lastSynced(int uid) async => lastByUid[uid];

  @override
  Future<void> saveLastSynced(int uid, String document, int updated) async =>
      lastByUid[uid] = (document: document, updated: updated);
}
