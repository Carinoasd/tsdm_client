import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';
import 'dart:isolate';
import 'dart:math';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/local_notice/direct_reply.dart';
import 'package:tsdm_client/features/local_notice/keys.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// The text of a reply typed in a notification that was not sent, kept the moment it fails.
///
/// The reply is sent in the notification plugin's own isolate (`direct_reply_entry.dart`), which may not write the
/// drafts of the app: the app's [LocalDraftStore] keeps the drafts it read in memory and would write over a file
/// changed behind it. So the failing isolate only *adds* a file of its own here, one per failure (`<id>.json` in
/// `draft_inbox` of the app's support directory, written to a temporary file renamed in place), and the app's isolate
/// moves each into the drafts ([collect]) when it starts, when it comes back to the front, when the failing isolate
/// tells it ([portName]) and when the notification of the failure is tapped. Nothing is read and written back by two
/// isolates: the failing one never reads, the app's one is the only one to delete.
///
/// A file moved into the drafts leaves a mark (`<id>.done`, empty) for [keepFor]: the notification of the failure
/// carries the id ([LocalNoticeTarget.draftEvent]), and a tap on it after its text was moved does not keep it again
/// (the user may have changed, sent or deleted the draft since).
///
/// The file is `{"v": 1, "id": …, "uid": …, "tid": …, "pid": …, "peer": …, "text": …, "ms": bool, "at": <ms>}`: the
/// account the notification was about, the floor (`tid` and `pid`) or the conversation (`peer`), what was typed,
/// whether it may have been sent after all, and when it failed. At most [maxPending] wait, the oldest go first; one
/// older than [keepFor] is dropped; a file that does not parse is deleted.
final class DirectReplyDraftInbox {
  /// Constructor: the files in [directory] (`draft_inbox` in the app's support directory by default).
  DirectReplyDraftInbox({Future<Directory> Function()? directory, DateTime Function()? now, Random? random})
    : _directory = directory ?? _defaultDirectory,
      _now = now ?? DateTime.now,
      _random = random ?? Random();

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}draft_inbox');

  final Future<Directory> Function() _directory;
  final DateTime Function() _now;
  final Random _random;

  /// Version of the files.
  static const formatVersion = 1;

  /// How many failures wait at most.
  static const maxPending = 50;

  /// How long a failure waits, and how long the mark of one moved into the drafts is kept.
  static const keepFor = Duration(days: 30);

  /// Name of the port of the app's isolate ([watchDirectReplyDrafts]) the failing isolate wakes after a write.
  static const portName = 'tsdm_client.directReplyDraftInbox';

  static final _idPattern = RegExp(r'^[1-9]\d{0,11}-\d{1,16}-[0-9a-f]{8}$');

  /// Whether [id] may name a file here: a payload is read from an intent, nothing else reaches the file system.
  static bool validId(String id) => _idPattern.hasMatch(id);

  File _file(Directory dir, String name) => File('${dir.path}${Platform.pathSeparator}$name');

  /// Keep [text], typed for [target] by account [uid], as a failure waiting for the app (the failing isolate). Returns
  /// its id, null when it could not be written (the notification of the failure then carries the text alone, kept
  /// at its tap as before).
  Future<String?> put({
    required int uid,
    required LocalNoticeTarget target,
    required String text,
    bool maybeSent = false,
  }) async {
    final tid = target.tid;
    final pid = target.pid;
    final peer = target.peerUid;
    if (uid <= 0 || text.trim().isEmpty || !((tid != null && pid != null) || peer != null)) {
      return null;
    }
    try {
      final at = _now();
      final id = '$uid-${at.millisecondsSinceEpoch}-${_random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}';
      final dir = await _directory();
      await dir.create(recursive: true);
      final file = _file(dir, '$id.json');
      final temp = _file(dir, '$id.json.tmp');
      await temp.writeAsString(
        jsonEncode({
          'v': formatVersion,
          'id': id,
          'uid': uid,
          if (tid != null && pid != null) ...{'tid': tid, 'pid': pid} else 'peer': peer,
          'text': text,
          'ms': maybeSent,
          'at': at.millisecondsSinceEpoch,
        }),
        flush: true,
      );
      await temp.rename(file.path);
      return id;
    } on Object catch (e) {
      _warn('direct reply: the text was not kept for the app: $e');
      return null;
    }
  }

  /// Whether the failure [id] was moved into the drafts already (or dropped for an account no longer on this device).
  Future<bool> handled(String id) async {
    if (!validId(id)) {
      return false;
    }
    try {
      return _file(await _directory(), '$id.done').existsSync();
    } on Object catch (e) {
      _warn('direct reply: inbox not read: $e');
      return false;
    }
  }

  /// Mark the failure [id] as kept ([handled]): its text was kept from the payload of a tap while its file could not be
  /// moved, the next [collect] deletes the file instead of moving it once more (a draft sent or deleted since would
  /// come back). Never throws.
  Future<void> markHandled(String id) async {
    if (!validId(id)) {
      return;
    }
    try {
      final dir = await _directory();
      if (dir.existsSync()) {
        await _file(dir, '$id.done').writeAsString('', flush: true);
      }
    } on Object catch (e) {
      _warn('direct reply: inbox not marked: $e');
    }
  }

  /// Move every failure waiting into [store] (the app's isolate, one call at a time: [collectDirectReplyDrafts]), the
  /// oldest first, and return the ids moved. [accounts] are the accounts on this device (null: not known, every
  /// failure is kept): a failure of another account is dropped. A file that does not parse, of another version, too
  /// old or past [maxPending] is deleted. Never throws.
  Future<List<String>> collect(LocalDraftStore store, {Future<Set<int>?> Function()? accounts}) async {
    final moved = <String>[];
    try {
      final dir = await _directory();
      if (!dir.existsSync()) {
        return moved;
      }
      final now = _now();
      final oldest = now.subtract(keepFor);
      final pending = <_Pending>[];
      final done = <String>{};
      final files = await dir.list().where((e) => e is File).cast<File>().toList();
      for (final file in files) {
        final name = file.uri.pathSegments.last;
        if (name.endsWith('.done')) {
          done.add(name.substring(0, name.length - 5));
        }
      }
      for (final file in files) {
        final name = file.uri.pathSegments.last;
        try {
          if (name.endsWith('.done')) {
            if (file.statSync().modified.isBefore(oldest)) {
              await file.delete();
            }
            continue;
          }
          if (name.endsWith('.tmp')) {
            // Being written now, or left by an isolate killed while writing.
            if (file.statSync().modified.isBefore(now.subtract(const Duration(days: 1)))) {
              await file.delete();
            }
            continue;
          }
          if (!name.endsWith('.json')) {
            continue;
          }
          final id = name.substring(0, name.length - 5);
          if (done.contains(id)) {
            // Moved already, the app stopped before deleting it.
            await file.delete();
            continue;
          }
          final item = validId(id) ? _Pending.parse(id, await file.readAsString()) : null;
          if (item == null) {
            _warn('direct reply: inbox file not read, deleted');
            await file.delete();
            continue;
          }
          if (item.at.isBefore(oldest)) {
            await file.delete();
            continue;
          }
          pending.add(item..file = file);
        } on Object catch (e) {
          _warn('direct reply: inbox file skipped: $e');
        }
      }
      pending.sort((a, b) => a.at.compareTo(b.at));
      while (pending.length > maxPending) {
        final drop = pending.removeAt(0);
        await _deleteQuietly(drop.file);
      }
      if (pending.isEmpty) {
        return moved;
      }
      final Set<int>? onDevice;
      try {
        onDevice = await accounts?.call();
      } on Object catch (e) {
        _warn('direct reply: accounts not read, inbox left for later: $e');
        return moved;
      }
      for (final item in pending) {
        try {
          if (onDevice == null || onDevice.contains(item.uid)) {
            await keepFailedReplyDraft(
              store,
              item.uid,
              tid: item.tid,
              pid: item.pid,
              peer: item.peer,
              text: item.text,
              at: item.at,
              maybeSent: item.maybeSent,
            );
            moved.add(item.id);
          }
          // The mark first: a failure marked and not deleted is not moved twice.
          await _file(dir, '${item.id}.done').writeAsString('', flush: true);
          await item.file.delete();
        } on Object catch (e) {
          _warn('direct reply: inbox item not moved, left for later: $e');
        }
      }
    } on Object catch (e) {
      _warn('direct reply: inbox not read: $e');
    }
    return moved;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } on Object {
      // Gone already.
    }
  }
}

final class _Pending {
  _Pending(this.id, this.uid, this.tid, this.pid, this.peer, this.text, this.at, {required this.maybeSent});

  static _Pending? parse(String id, String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map<String, dynamic> || json['v'] != DirectReplyDraftInbox.formatVersion || json['id'] != id) {
        return null;
      }
      final uid = json['uid'];
      final text = json['text'];
      final at = json['at'];
      int? positive(Object? v) => v is int && v > 0 ? v : null;
      final tid = positive(json['tid']);
      final pid = positive(json['pid']);
      final peer = positive(json['peer']);
      if (uid is! int ||
          uid <= 0 ||
          !id.startsWith('$uid-') ||
          text is! String ||
          text.trim().isEmpty ||
          at is! int ||
          !((tid != null && pid != null) || peer != null)) {
        return null;
      }
      final floor = tid != null && pid != null;
      return _Pending(
        id,
        uid,
        floor ? tid : null,
        floor ? pid : null,
        floor ? null : peer,
        text,
        DateTime.fromMillisecondsSinceEpoch(at),
        maybeSent: json['ms'] == true,
      );
    } on Object {
      return null;
    }
  }

  final String id;
  final int uid;
  final int? tid;
  final int? pid;
  final int? peer;
  final String text;
  final DateTime at;
  final bool maybeSent;
  late final File file;
}

/// Keep [text], a reply typed in a notification at [at] that was not sent, as the local draft of account [uid] for the
/// floor [pid] of thread [tid], or the conversation with [peer], and return once it is written.
///
/// The convention of the drafts: one draft per target, the newer text in front. The same text there already is left
/// alone (marked maybe sent when this one is). Another text there already is moved aside (`backupAt`, listed, never
/// lost) when it is older than [at]; when it is newer (typed in the app after the reply failed), [text] is the one kept
/// aside. Nothing without a target.
Future<void> keepFailedReplyDraft(
  LocalDraftStore store,
  int uid, {
  required int? tid,
  required int? pid,
  required int? peer,
  required String text,
  required DateTime at,
  bool maybeSent = false,
}) async {
  final LocalDraftKey key;
  if (tid != null && pid != null) {
    key = LocalDraftKey.floorReply('$tid', '$pid');
  } else if (peer != null) {
    key = LocalDraftKey.message('$peer');
  } else {
    return;
  }
  final existing = await store.load(uid, key);
  final draft = LocalDraft(
    key: key,
    body: text,
    updatedAt: at,
    tid: tid == null ? null : '$tid',
    replyAction: tid != null && pid != null ? directReplyActionUrl(tid: tid, pid: pid) : null,
    maybeSent: maybeSent,
  );
  if (existing == null) {
    store.save(uid, draft);
  } else if (existing.body == text) {
    if (maybeSent && !existing.maybeSent) {
      store.markMaybeSent(uid, key);
    }
  } else if (existing.updatedAt.isAfter(at)) {
    store.save(uid, draft.withKey(key.backupAt(at.millisecondsSinceEpoch)));
  } else {
    store
      ..save(uid, existing.withKey(key.backupAt(existing.updatedAt.millisecondsSinceEpoch)))
      ..save(uid, draft);
  }
  // Every read and write of the store runs in one queue: this read returns once the writes above are done.
  await store.load(uid, key);
}

/// Log [message] without ever throwing: in the failing isolate the log may be what could not be set up (`talker` is
/// then not set), and the notification telling the reply was not sent must still be posted.
void _warn(String message, {bool info = false}) {
  try {
    if (info) {
      talker.info(message);
    } else {
      talker.warning(message);
    }
  } on Object {
    debugPrint(message);
  }
}

/// The end of the queue of [collectDirectReplyDrafts]: one at a time in the app's isolate.
Future<void> _collecting = Future<void>.value();

/// Move the failed direct replies waiting ([DirectReplyDraftInbox]) into the app's drafts, once every collect asked
/// before is done. Defaults: the app's inbox, its draft store and the accounts saved on this device. Nothing without a
/// store. Never throws.
Future<List<String>> collectDirectReplyDrafts({
  DirectReplyDraftInbox? inbox,
  LocalDraftStore? store,
  Future<Set<int>?> Function()? accounts,
}) {
  final drafts = store ?? LocalDraftStore.app;
  if (drafts == null) {
    return Future.value(const []);
  }
  final done = Completer<List<String>>();
  _collecting = _collecting.then((_) async {
    try {
      final moved = await (inbox ?? DirectReplyDraftInbox()).collect(drafts, accounts: accounts ?? _savedAccounts);
      if (moved.isNotEmpty) {
        _warn('direct reply: ${moved.length} unsent text(s) kept as drafts', info: true);
      }
      done.complete(moved);
    } on Object catch (e, st) {
      _warn('direct reply: collecting the unsent texts failed: $e\n$st');
      done.complete(const []);
    }
  });
  return done.future;
}

Future<Set<int>?> _savedAccounts() async {
  if (!getIt.isRegistered<StorageProvider>()) {
    return null;
  }
  return (await getIt.get<StorageProvider>().getAllUsers()).map((e) => e.uid).nonNulls.toSet();
}

/// Keep the text of the reply of a tap on the notification telling it was not sent ([LocalNoticeTarget.draft]) as the
/// draft of account [uid]: the failure waiting under [LocalNoticeTarget.draftEvent] when there is one (moved with the
/// others), nothing when it was moved already, the text of the payload otherwise (the failure could not be kept, a
/// notification of an older version).
Future<void> keepDirectReplyDraftOfTap(
  int uid,
  LocalNoticeTarget target, {
  DirectReplyDraftInbox? inbox,
  LocalDraftStore? store,
  Future<Set<int>?> Function()? accounts,
  DateTime? now,
}) async {
  if (target.draft == null) {
    return;
  }
  final event = target.draftEvent;
  final DirectReplyDraftInbox? box;
  if (event != null && DirectReplyDraftInbox.validId(event) && event.startsWith('$uid-')) {
    box = inbox ?? DirectReplyDraftInbox();
    await collectDirectReplyDrafts(inbox: box, store: store, accounts: accounts);
    if (await box.handled(event)) {
      return;
    }
  } else {
    box = null;
  }
  final drafts = store ?? LocalDraftStore.app;
  if (drafts == null) {
    return;
  }
  await keepFailedReplyDraft(
    drafts,
    uid,
    tid: target.tid,
    pid: target.pid,
    peer: target.peerUid,
    text: target.draft!,
    at: now ?? DateTime.now(),
    maybeSent: target.maybeSent,
  );
  // Its file, if it is still there (it could not be moved now), is not moved again later. Outside the queue of the
  // collects on purpose: one moving the same file meanwhile keeps the same text, which [keepFailedReplyDraft] leaves
  // alone; changing that rule needs this marked inside the queue.
  await box?.markHandled(event!);
}

/// Wake the app's isolate ([watchDirectReplyDrafts]) after a failure was kept: the app in front sees no resume. Nothing
/// when it does not run.
void tellAppOfDirectReplyDraft(String id) {
  try {
    IsolateNameServer.lookupPortByName(DirectReplyDraftInbox.portName)?.send(id);
  } on Object catch (e) {
    _warn('direct reply: the app was not told of the kept text: $e');
  }
}

ReceivePort? _port;
AppLifecycleListener? _lifecycle;

/// In the app's isolate (the home page, once): move the failed direct replies into the drafts now, whenever the app
/// comes back to the front, and whenever the failing isolate tells one was kept. Calling it again does nothing.
void watchDirectReplyDrafts() {
  if (_lifecycle != null) {
    return;
  }
  _lifecycle = AppLifecycleListener(onResume: () => unawaited(collectDirectReplyDrafts()));
  try {
    final port = ReceivePort('direct reply drafts');
    IsolateNameServer.removePortNameMapping(DirectReplyDraftInbox.portName);
    IsolateNameServer.registerPortWithName(port.sendPort, DirectReplyDraftInbox.portName);
    port.listen((_) => unawaited(collectDirectReplyDrafts()));
    _port = port;
  } on Object catch (e) {
    _warn('direct reply: no port for the kept texts, collected at resume only: $e');
  }
  unawaited(collectDirectReplyDrafts());
}

/// Undo [watchDirectReplyDrafts] (tests).
@visibleForTesting
void unwatchDirectReplyDrafts() {
  _lifecycle?.dispose();
  _lifecycle = null;
  if (_port != null) {
    IsolateNameServer.removePortNameMapping(DirectReplyDraftInbox.portName);
    _port!.close();
    _port = null;
  }
}
