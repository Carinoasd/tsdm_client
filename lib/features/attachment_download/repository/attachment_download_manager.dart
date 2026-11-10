import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:tsdm_client/features/attachment_download/models/attachment_download.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_store.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_fetcher.dart';
import 'package:tsdm_client/features/attachment_download/utils/attachment_protocol.dart';
import 'package:tsdm_client/features/attachment_download/utils/download_location.dart';
import 'package:tsdm_client/features/audio_player/utils/audio_attachment.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/logger.dart';

/// How long the download address the forum gives after taking the credits (`…&ck=…`) is reused: the forum takes it
/// for an hour.
const Duration attachmentResolvedUrlValidFor = Duration(minutes: 55);

/// The most redirects of one download followed.
const _maxHops = 4;

/// The most of a message page read to find the forum's words.
const int _maxPageBytes = 512 * 1024;

/// The attachment downloads of the accounts: started from a post, listed by the downloads page, kept by the
/// [AttachmentDownloadStore] (one list per account).
///
/// A download goes `queued` → `running` → `completed`, `failed` or `cancelled`; a failed or cancelled one can be
/// [retry]ed. At most [maxRunning] run at once. The file is fetched into a part file next to where it goes and renamed
/// when the forum handed the file out ([isFileDisposition]); a message page (no permission, the price not paid, the
/// link expired) fails the download with the forum's words, the purchase kept for the price ([AttachmentDownload.
/// purchaseUrl]). A download that costs credits takes them once, as the website does ([isAttachCreditUrl]), and a
/// retry within [attachmentResolvedUrlValidFor] reuses what was paid for.
///
/// Downloads left running when the app went away are failed when their account is loaded again.
final class AttachmentDownloadManager extends ChangeNotifier with LoggerMixin {
  /// Constructor.
  AttachmentDownloadManager({
    AttachmentFetcher? fetcher,
    AttachmentDownloadStore? store,
    Future<Directory> Function()? directory,
    Future<Directory> Function()? partDirectory,
    DateTime Function()? now,
    this.maxRunning = 2,
    this.progressInterval = const Duration(milliseconds: 200),
  }) : _fetcher = fetcher ?? const NetAttachmentFetcher(),
       _store = store ?? AttachmentDownloadStore(),
       _directory = directory ?? attachmentDownloadDirectory,
       _partDirectory = partDirectory ?? attachmentPartDirectory,
       _now = now ?? DateTime.now;

  /// The app's manager, null when none is registered (tests of other features).
  static AttachmentDownloadManager? get app =>
      getIt.isRegistered<AttachmentDownloadManager>() ? getIt.get<AttachmentDownloadManager>() : null;

  /// How many downloads run at once.
  final int maxRunning;

  /// How often the progress of a running download is told.
  final Duration progressInterval;

  final AttachmentFetcher _fetcher;
  final AttachmentDownloadStore _store;
  final Future<Directory> Function() _directory;
  final Future<Directory> Function() _partDirectory;
  final DateTime Function() _now;

  final _items = <int, List<AttachmentDownload>>{};
  final _loading = <int, Future<List<AttachmentDownload>>>{};
  final _tokens = <String, CancelToken>{};
  var _seq = 0;

  /// How many times each account was forgotten ([forget]): a read started before is not kept.
  final _generations = <int, int>{};

  /// When each download was queued last (an increasing number): the queue goes in this order, a retried one last.
  final _queuedAt = <String, int>{};
  var _queueSeq = 0;

  /// Paths of files being moved into place: two downloads of the same name finishing at once get two names.
  final _reserved = <String>{};

  /// How many running downloads use each part folder (by its path), from before they make sure it is there until their
  /// part file is moved into place or deleted: the folder is only removed when none does ([_releasePartFolder]).
  final _partFolderUsers = <String, int>{};

  /// The downloads of account [uid], the newest first; empty until [load]ed.
  List<AttachmentDownload> itemsOf(int uid) => List.unmodifiable(_items[uid] ?? const <AttachmentDownload>[]);

  /// The download [id] of account [uid], null when there is none.
  AttachmentDownload? find(int uid, String id) => _items[uid]?.where((e) => e.id == id).firstOrNull;

  /// Read the downloads of account [uid] (once); those left running are failed.
  Future<List<AttachmentDownload>> load(int uid) async {
    if (_items[uid] case final items?) {
      return items;
    }
    final generation = _generations[uid] ?? 0;
    return _loading[uid] ??= () async {
      final read = await _store.load(uid);
      if (generation != (_generations[uid] ?? 0)) {
        // Forgotten while read.
        return const <AttachmentDownload>[];
      }
      final interrupted = read.where((e) => e.status.active).toList();
      final items = [
        for (final e in read) e.status.active ? e.copyWith(status: AttachmentDownloadStatus.failed, received: 0) : e,
      ];
      // Started while it was read.
      final started = _items[uid] ?? const <AttachmentDownload>[];
      _items[uid] = [...started, ...items.where((e) => !started.any((s) => s.id == e.id))];
      unawaited(_loading.remove(uid));
      if (interrupted.isNotEmpty) {
        for (final e in interrupted) {
          await _deletePart(e);
        }
        await _save(uid);
      }
      notifyListeners();
      return _items[uid]!;
    }();
  }

  /// Download the attachment at [url] for account [uid]. The same attachment (by its id, the address changes with each
  /// page) running or saved already (its file still there) is not downloaded again: that download is returned. One
  /// that failed, was cancelled or whose file is gone starts again from [url], keeping the paid address
  /// ([AttachmentDownload.resolvedUrl]) so the credits of the download are not taken twice.
  ///
  /// [filename] and [size] are what the post shows of it; [tid] and [threadTitle] the thread it is in.
  Future<AttachmentDownload> start({
    required int uid,
    required String url,
    required String filename,
    int? size,
    String? tid,
    String? threadTitle,
  }) async {
    await load(uid);
    // Forgotten while read: a list of its own again.
    final items = _items[uid] ??= [];
    final aid = aidOfAttachmentUrl(url);
    bool same(AttachmentDownload e) => e.url == url || (aid != null && aidOfAttachmentUrl(e.url) == aid);
    bool kept(AttachmentDownload e) =>
        e.status.active ||
        (e.status == AttachmentDownloadStatus.completed && e.path != null && File(e.path!).existsSync());
    if (items.where((e) => same(e) && kept(e)).firstOrNull case final existing?) {
      return existing;
    }
    final stopped = items.where(same).firstOrNull;
    if (stopped != null) {
      final again = stopped.copyWith(
        url: url,
        status: AttachmentDownloadStatus.queued,
        received: 0,
        clearTotal: true,
        clearMessage: true,
        clearFinishedAt: true,
        clearPath: true,
      );
      items
        ..removeWhere((e) => e.id == stopped.id)
        ..insert(0, again);
      _queuedAt.remove(again.id);
      await _save(uid);
      notifyListeners();
      _queue();
      return again;
    }
    final now = _now();
    final item = AttachmentDownload(
      id: '${now.microsecondsSinceEpoch}-${_seq++}',
      uid: uid,
      url: url,
      filename: filename,
      createdAt: now,
      size: size,
      tid: tid ?? tidOfAttachmentUrl(url),
      threadTitle: threadTitle,
    );
    items.insert(0, item);
    _trim(uid);
    await _save(uid);
    notifyListeners();
    _queue();
    return item;
  }

  /// Stop the download [id] of account [uid].
  Future<void> cancel(int uid, String id) async {
    final item = find(uid, id);
    if (item == null || !item.status.active) {
      return;
    }
    final token = _tokens[id];
    if (token != null) {
      // The run sees it and stops.
      token.cancel('cancelled');
      return;
    }
    _queuedAt.remove(id);
    _replace(item.copyWith(status: AttachmentDownloadStatus.cancelled, finishedAt: _now(), received: 0));
    await _save(uid);
    notifyListeners();
  }

  /// Start the failed or cancelled download [id] of account [uid] again.
  Future<void> retry(int uid, String id) async {
    final item = find(uid, id);
    if (item == null || item.status.active || item.status == AttachmentDownloadStatus.completed) {
      return;
    }
    _replace(
      item.copyWith(
        status: AttachmentDownloadStatus.queued,
        received: 0,
        clearTotal: true,
        clearMessage: true,
        clearFinishedAt: true,
      ),
    );
    await _save(uid);
    notifyListeners();
    _queue();
  }

  /// Remove the download [id] of account [uid] from the list; its file too with [deleteFile].
  Future<void> remove(int uid, String id, {bool deleteFile = true}) async {
    final item = find(uid, id);
    if (item == null) {
      return;
    }
    _tokens.remove(id)?.cancel('removed');
    _queuedAt.remove(id);
    _items[uid]!.removeWhere((e) => e.id == id);
    await _save(uid);
    notifyListeners();
    await _deletePart(item);
    final path = item.path;
    if (deleteFile && path != null) {
      try {
        final file = File(path);
        if (file.existsSync()) {
          await file.delete();
        }
      } on FileSystemException catch (e) {
        warning('failed to delete downloaded attachment: $e');
      }
    }
  }

  /// Account [uid] was removed from this device: its downloads stop and are forgotten (the files stay).
  void forget(int uid) {
    _generations[uid] = (_generations[uid] ?? 0) + 1;
    unawaited(_loading.remove(uid));
    for (final e in _items.remove(uid) ?? const <AttachmentDownload>[]) {
      _tokens.remove(e.id)?.cancel('forgotten');
    }
    _store.forget(uid);
    notifyListeners();
  }

  void _replace(AttachmentDownload item) {
    final items = _items[item.uid];
    if (items == null) {
      return;
    }
    final index = items.indexWhere((e) => e.id == item.id);
    if (index >= 0) {
      items[index] = item;
    }
  }

  Future<void> _save(int uid) => _store.save(uid, _items[uid] ?? const []);

  /// Keep at most [AttachmentDownloadStore.maxItems] downloads of account [uid]: the oldest finished ones leave the list
  /// (their files stay where they were saved).
  void _trim(int uid) {
    final items = _items[uid];
    if (items == null) {
      return;
    }
    for (var i = items.length - 1; i >= 0 && items.length > AttachmentDownloadStore.maxItems; i--) {
      if (!items[i].status.active) {
        items.removeAt(i);
      }
    }
  }

  /// Put the downloads just queued at the end of the queue and start what can run.
  void _queue() {
    for (final items in _items.values) {
      // The list is the newest first.
      for (final e in items.reversed) {
        if (e.status == AttachmentDownloadStatus.queued && !_queuedAt.containsKey(e.id)) {
          _queuedAt[e.id] = _queueSeq++;
        }
      }
    }
    _pump();
  }

  /// Start the queued downloads of every account while fewer than [maxRunning] run, the oldest asked first.
  void _pump() {
    var running = _tokens.length;
    final queued = [
      for (final items in _items.values)
        ...items.where((e) => e.status == AttachmentDownloadStatus.queued && !_tokens.containsKey(e.id)),
    ]..sort((a, b) => (_queuedAt[a.id] ?? -1).compareTo(_queuedAt[b.id] ?? -1));
    for (final item in queued) {
      if (running >= maxRunning) {
        break;
      }
      running++;
      final token = CancelToken();
      _tokens[item.id] = token;
      unawaited(_run(item, token));
    }
  }

  // The part files live in their own folder on the volume of the downloads, see `attachmentPartDirectory`.
  String _partPath(Directory dir, AttachmentDownload item) => p.join(dir.path, '${item.id}.part');

  Future<void> _deletePart(AttachmentDownload item) async {
    try {
      final part = File(_partPath(await _partDirectory(), item));
      if (part.existsSync()) {
        await part.delete();
      }
    } on Object catch (e) {
      warning('failed to delete the part file of a download: $e');
    }
  }

  Future<void> _run(AttachmentDownload queued, CancelToken token) async {
    final uid = queued.uid;
    var item = queued.copyWith(status: AttachmentDownloadStatus.running, received: 0, clearTotal: true);
    _replace(item);
    await _save(uid);
    notifyListeners();
    File? part;
    Directory? partDir;
    try {
      partDir = await _partDirectory();
      // Counted before the folder is asked for (nothing awaited in between): a download finishing meanwhile leaves it.
      _partFolderUsers[partDir.path] = (_partFolderUsers[partDir.path] ?? 0) + 1;
      await partDir.create(recursive: true);
      part = File(_partPath(partDir, item));
      item = await _fetch(item, part, token);
      if (find(uid, item.id) == null) {
        // Removed meanwhile: nothing is kept.
        item = item.copyWith(status: AttachmentDownloadStatus.cancelled);
      }
      if (item.status == AttachmentDownloadStatus.completed) {
        final dir = await _directory();
        await dir.create(recursive: true);
        final target = uniqueFileIn(
          dir,
          safeDownloadFileName(item.filename, fallback: 'attachment-${item.id}'),
          taken: _reserved,
        );
        _reserved.add(target.path);
        try {
          await _move(part, target);
        } finally {
          _reserved.remove(target.path);
        }
        item = item.copyWith(path: target.path, filename: p.basename(target.path));
      }
    } on DioException catch (e) {
      item = item.copyWith(
        status: CancelToken.isCancel(e) ? AttachmentDownloadStatus.cancelled : AttachmentDownloadStatus.failed,
        received: 0,
      );
    } on AttachmentFetchException catch (e) {
      warning('failed to download attachment ${item.id}: $e');
      item = item.copyWith(status: AttachmentDownloadStatus.failed, received: 0);
    } on Object catch (e, st) {
      warning('failed to download attachment ${item.id}: $e');
      handleRaw(e, st);
      item = item.copyWith(status: AttachmentDownloadStatus.failed, received: 0);
    } finally {
      _tokens.remove(item.id);
      _queuedAt.remove(item.id);
    }
    try {
      if (item.status != AttachmentDownloadStatus.completed && part != null && part.existsSync()) {
        await part.delete();
      }
    } on FileSystemException {
      // Left for the next load.
    } finally {
      if (partDir != null) {
        _releasePartFolder(partDir);
      }
    }
    // Removed or forgotten meanwhile.
    if (find(uid, item.id) != null) {
      _replace(item.copyWith(finishedAt: _now()));
      await _save(uid);
      notifyListeners();
    }
    _queue();
  }

  /// A download is done with the part folder [dir]: once no running download uses it and nothing is in it, it is
  /// deleted (no empty folder left in the user's downloads folder).
  ///
  /// Looked at and deleted in one go, nothing awaited: a download that starts later asks for the folder after this, and
  /// one that started earlier is counted in [_partFolderUsers]. Deleted across an `await`, the folder could go between
  /// another download making sure it is there and writing its part file into it, failing that download.
  void _releasePartFolder(Directory dir) {
    final users = (_partFolderUsers[dir.path] ?? 0) - 1;
    if (users > 0) {
      _partFolderUsers[dir.path] = users;
      return;
    }
    _partFolderUsers.remove(dir.path);
    try {
      if (dir.existsSync() && dir.listSync().isEmpty) {
        dir.deleteSync();
      }
    } on FileSystemException {
      // Something else was put there, or it is gone already.
    }
  }

  /// Move [part] to [target]: a rename, a copy when they are on different volumes (a copy cut short leaves nothing).
  static Future<void> _move(File part, File target) async {
    try {
      await part.rename(target.path);
    } on FileSystemException {
      try {
        await part.copy(target.path);
      } on Object {
        if (target.existsSync()) {
          await target.delete();
        }
        rethrow;
      }
      await part.delete();
    }
  }

  /// Fetch [start] into [part], following the forum: redirects, the page taking the credits, a message page.
  Future<AttachmentDownload> _fetch(AttachmentDownload start, File part, CancelToken token) async {
    var item = start;
    final paid =
        item.resolvedUrl != null &&
        item.resolvedAt != null &&
        _now().difference(item.resolvedAt!) < attachmentResolvedUrlValidFor;
    var url = paid ? item.resolvedUrl! : item.url;
    var lastTold = DateTime.fromMillisecondsSinceEpoch(0);
    for (var hop = 0; hop < _maxHops; hop++) {
      final answer = await _fetcher.fetch(
        url,
        part.path,
        uid: item.uid,
        cancelToken: token,
        onProgress: (received, total) {
          final now = DateTime.now();
          final current = find(item.uid, item.id);
          if (current == null || now.difference(lastTold) < progressInterval) {
            return;
          }
          lastTold = now;
          _replace(current.copyWith(received: received, total: total));
          notifyListeners();
        },
      );
      if (token.isCancelled) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: url),
          reason: 'cancelled',
        );
      }
      final base = Uri.parse(url);
      if (answer.status >= 300 && answer.status < 400) {
        final location = answer.location;
        if (location == null || location.isEmpty) {
          return item.copyWith(status: AttachmentDownloadStatus.failed);
        }
        final next = '${base.resolve(location)}';
        if (isAttachPayUrl(next)) {
          return item.copyWith(status: AttachmentDownloadStatus.failed, purchaseUrl: next);
        }
        if (isAttachCreditUrl(next)) {
          // Loading the page takes the credits; it links to the download for an hour. Not cancelled halfway on
          // purpose: once asked for, the credits are taken, and its link is kept for a retry.
          final page = await _fetcher.fetchPage(next, uid: item.uid);
          final said = forumAnswerOf(page, base: Uri.parse(next));
          final link = said?.link;
          if (said == null || link == null || !isAttachmentDownloadUrl(link)) {
            return item.copyWith(status: AttachmentDownloadStatus.failed, message: said?.message);
          }
          item = item.copyWith(notice: said.message, resolvedUrl: link, resolvedAt: _now());
          _replace(item);
          await _save(item.uid);
          notifyListeners();
          url = link;
          continue;
        }
        url = next;
        continue;
      }
      final length = part.existsSync() ? part.lengthSync() : 0;
      if (isFileDisposition(answer.disposition)) {
        return item.copyWith(
          status: AttachmentDownloadStatus.completed,
          filename: filenameOfContentDisposition(answer.disposition) ?? item.filename,
          received: length,
          total: length,
        );
      }
      final said = await _answerIn(part, base);
      if (said != null) {
        final link = said.link;
        return item.copyWith(
          status: AttachmentDownloadStatus.failed,
          message: said.message,
          purchaseUrl: link != null && isAttachPayUrl(link) ? link : null,
        );
      }
      if (await _looksLikePage(part)) {
        return item.copyWith(status: AttachmentDownloadStatus.failed);
      }
      // A file served without its name (a storage the forum redirected to).
      return item.copyWith(status: AttachmentDownloadStatus.completed, received: length, total: length);
    }
    return item.copyWith(status: AttachmentDownloadStatus.failed);
  }

  static Future<String> _head(File file, int max) async {
    final raf = await file.open();
    try {
      final bytes = await raf.read(max);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await raf.close();
    }
  }

  static Future<ForumAnswer?> _answerIn(File part, Uri base) async {
    if (!part.existsSync() || part.lengthSync() > _maxPageBytes) {
      return null;
    }
    return forumAnswerOf(await _head(part, _maxPageBytes), base: base);
  }

  static Future<bool> _looksLikePage(File part) async {
    if (!part.existsSync()) {
      return true;
    }
    final head = (await _head(part, 512)).trimLeft().toLowerCase();
    return head.startsWith('<!doctype html') || head.startsWith('<html') || head.startsWith('<?xml');
  }
}
