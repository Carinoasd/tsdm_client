import 'dart:async';
import 'dart:convert';
import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Something holding text not written to the store yet (the autosaver of an editor): told to write it now when the app
/// goes to the background, where it may be closed without notice.
// An interface the autosavers implement, not a callback: the store keeps them in a set.
// ignore: one_member_abstracts
abstract interface class DraftFlusher {
  /// Write what is held now.
  void flush();
}

/// The drafts the editors did not send, kept on this device: one file per account (`drafts/<uid>.json` in the app's
/// support directory), never shown to another account.
///
/// Why files and not the database: the drafts are written every few seconds while typing, are read by one page at a
/// time and belong to one account each; a file per account keeps them out of the schema of the database (no migration,
/// nothing to sync with the background service), and forgetting an account is deleting its file. They live in the
/// support directory, not the cache: the system never clears it on its own.
///
/// Every read and write runs in one queue, in the order asked, so a read sees every write asked before it. A write
/// goes into a temporary file renamed over the old one: a crash leaves the previous file, never half of one. At most
/// [maxDrafts] drafts are kept for an account, the oldest go first; a file of another [formatVersion] or that does not
/// parse is no draft (and is replaced at the next write).
final class LocalDraftStore with LoggerMixin {
  /// Constructor.
  ///
  /// The files live in [directory] (`drafts` in the app's support directory by default).
  LocalDraftStore({Future<Directory> Function()? directory, this.maxDrafts = defaultMaxDrafts})
    : _files = _DirectoryDraftFiles(directory ?? _defaultDirectory);

  /// A store keeping its files in memory (tests of the pages using it: no file work between the frames).
  @visibleForTesting
  LocalDraftStore.memory({this.maxDrafts = defaultMaxDrafts}) : _files = _MemoryDraftFiles();

  /// The app's store, null when none is registered (tests of other features): nothing is kept then.
  static LocalDraftStore? get app => getIt.isRegistered<LocalDraftStore>() ? getIt.get<LocalDraftStore>() : null;

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}drafts');

  /// Version of the files.
  static const formatVersion = 1;

  /// How many drafts an account keeps by default.
  static const defaultMaxDrafts = 100;

  /// How many drafts an account keeps: the oldest go when there are more.
  final int maxDrafts;

  final _DraftFiles _files;

  /// The drafts of each account read so far, by key.
  final _accounts = <int, Map<String, LocalDraft>>{};

  /// Accounts removed from the device ([forget]): a late write of an editor still open is refused, until the account
  /// reads its drafts again (it logged in again).
  final _forgotten = <int>{};

  /// A draft the list asked the editor of its target to offer next ([preferNext]), by account.
  final _preferred = <int, LocalDraftKey>{};

  /// Let the next editor of the target of [key] for [uid] offer that very draft (a draft kept aside, opened from the
  /// list) instead of the newest one of the target.
  void preferNext(int uid, LocalDraftKey key) => _preferred[uid] = key;

  /// The draft asked for by [preferNext] when [test] accepts its target, taken (asked once).
  LocalDraftKey? takePreferred(int uid, bool Function(LocalDraftKey key) test) {
    final key = _preferred[uid];
    if (key == null || !test(key.target)) {
      return null;
    }
    _preferred.remove(uid);
    return key;
  }

  /// The end of the queue, null before the first read or write (made then, in the zone of its caller).
  Future<void>? _queue;

  final _changes = StreamController<int>.broadcast();

  /// The account whose drafts changed, after every write.
  Stream<int> get changes => _changes.stream;

  /// Completes once every read and write asked so far is done.
  @visibleForTesting
  Future<void> get pendingWrites => _queue ?? Future<void>.value();

  final _flushers = <DraftFlusher>{};
  AppLifecycleListener? _lifecycle;

  /// Let [flusher] write what it holds when the app goes to the background, until [unregister]ed.
  void register(DraftFlusher flusher) {
    _flushers.add(flusher);
    _lifecycle ??= AppLifecycleListener(onHide: flushAll, onPause: flushAll, onDetach: flushAll);
  }

  /// Undo [register].
  void unregister(DraftFlusher flusher) => _flushers.remove(flusher);

  /// Ask every registered flusher to write what it holds now.
  void flushAll() {
    for (final flusher in List.of(_flushers)) {
      try {
        flusher.flush();
      } on Object catch (e, st) {
        handleRaw(e, st);
      }
    }
  }

  /// Run [op] after everything asked before, its error logged (the value is then [fallback]).
  Future<T> _run<T>(String what, T fallback, Future<T> Function() op) {
    final done = Completer<T>();
    _queue = (_queue ?? Future<void>.value()).then((_) async {
      try {
        done.complete(await op());
      } on Object catch (e, st) {
        warning('local drafts: failed to $what: $e');
        handleRaw(e, st);
        done.complete(fallback);
      }
    });
    return done.future;
  }

  /// The drafts of [uid], read from its file the first time.
  Future<Map<String, LocalDraft>> _draftsOf(int uid) async {
    if (_accounts[uid] case final drafts?) {
      return drafts;
    }
    final drafts = <String, LocalDraft>{};
    final text = await _files.read(uid);
    if (text != null) {
      try {
        final saved = jsonDecode(text);
        if (saved is Map<String, dynamic> &&
            saved['v'] == formatVersion &&
            saved['uid'] == uid &&
            saved['drafts'] is Map<String, dynamic>) {
          for (final MapEntry(:key, :value) in (saved['drafts'] as Map<String, dynamic>).entries) {
            final draftKey = LocalDraftKey.parse(key);
            final draft = draftKey == null ? null : LocalDraft.fromJson(draftKey, value);
            if (draft != null) {
              drafts[key] = draft;
            }
          }
        } else {
          warning('local drafts: file of uid $uid not read (another format or account)');
          await _files.keepAside(uid);
        }
      } on Object catch (e) {
        warning('local drafts: file of uid $uid unreadable: $e');
        // Kept beside, not written over by the next draft.
        await _files.keepAside(uid);
      }
    }
    return _accounts[uid] = drafts;
  }

  /// Write the drafts of [uid] to its file (delete it when there are none) and tell [changes].
  Future<void> _write(int uid, Map<String, LocalDraft> drafts) async {
    if (drafts.isEmpty) {
      await _files.delete(uid);
    } else {
      await _files.write(
        uid,
        jsonEncode({
          'v': formatVersion,
          'uid': uid,
          'drafts': {for (final MapEntry(:key, :value) in drafts.entries) key: value.toJson()},
        }),
      );
    }
    _changes.add(uid);
  }

  static bool _valid(int uid) => uid > 0;

  bool _writable(int uid) => _valid(uid) && !_forgotten.contains(uid);

  /// The draft of [uid] for [key], null when there is none.
  Future<LocalDraft?> load(int uid, LocalDraftKey key) async {
    if (!_valid(uid)) {
      return null;
    }
    _forgotten.remove(uid);
    return _run('read', null, () async => (await _draftsOf(uid))[key.value]);
  }

  /// Every draft of [uid], the newest first.
  Future<List<LocalDraft>> list(int uid) async {
    if (!_valid(uid)) {
      return const [];
    }
    _forgotten.remove(uid);
    return _run(
      'list',
      const [],
      () async => (await _draftsOf(uid)).values.toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt)),
    );
  }

  /// Keep [draft] as the draft of [uid] for its key, replacing the one there.
  void save(int uid, LocalDraft draft) {
    if (!_writable(uid)) {
      return;
    }
    unawaited(
      _run('save ${draft.key.value}', null, () async {
        final drafts = await _draftsOf(uid);
        drafts[draft.key.value] = draft;
        if (drafts.length > maxDrafts) {
          final oldest = drafts.values.toList()..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
          for (final drop in oldest.take(drafts.length - maxDrafts)) {
            if (drop.key != draft.key) {
              drafts.remove(drop.key.value);
            }
          }
        }
        await _write(uid, drafts);
      }),
    );
  }

  /// Delete the draft of [uid] for [key].
  void delete(int uid, LocalDraftKey key) {
    if (!_writable(uid)) {
      return;
    }
    unawaited(
      _run('delete ${key.value}', null, () async {
        final drafts = await _draftsOf(uid);
        if (drafts.remove(key.value) != null) {
          await _write(uid, drafts);
        }
      }),
    );
  }

  /// Mark the draft of [uid] for [key] as maybe sent ([LocalDraft.maybeSent]): sending it failed after the request
  /// left.
  void markMaybeSent(int uid, LocalDraftKey key) {
    if (!_writable(uid)) {
      return;
    }
    unawaited(
      _run('mark ${key.value}', null, () async {
        final drafts = await _draftsOf(uid);
        final draft = drafts[key.value];
        if (draft != null && !draft.maybeSent) {
          drafts[key.value] = draft.copyWith(maybeSent: true);
          await _write(uid, drafts);
        }
      }),
    );
  }

  /// Delete every draft of [uid].
  void deleteAll(int uid) {
    if (!_writable(uid)) {
      return;
    }
    unawaited(
      _run('delete all', null, () async {
        final drafts = await _draftsOf(uid);
        drafts.clear();
        await _write(uid, drafts);
      }),
    );
  }

  /// Delete the file of [uid]: the account was removed from this device.
  void forget(int uid) {
    if (!_valid(uid)) {
      return;
    }
    _forgotten.add(uid);
    _preferred.remove(uid);
    unawaited(
      _run('forget account', null, () async {
        _accounts.remove(uid);
        await _files.delete(uid);
        _changes.add(uid);
      }),
    );
  }

  /// Release the lifecycle listener (tests).
  @visibleForTesting
  Future<void> dispose() async {
    _lifecycle?.dispose();
    _lifecycle = null;
    _flushers.clear();
    await _queue;
    await _changes.close();
  }
}

/// Where the file of each account is kept.
abstract interface class _DraftFiles {
  Future<String?> read(int uid);

  Future<void> write(int uid, String text);

  Future<void> delete(int uid);

  /// Keep the file of [uid] aside (`.bad`): it could not be read.
  Future<void> keepAside(int uid);
}

/// `<uid>.json` in a directory, each write into a temporary file renamed over the old one.
final class _DirectoryDraftFiles implements _DraftFiles {
  _DirectoryDraftFiles(this._directory);

  final Future<Directory> Function() _directory;

  Future<File> _fileOf(int uid) async {
    final dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}$uid.json');
  }

  @override
  Future<String?> read(int uid) async {
    final file = await _fileOf(uid);
    return file.existsSync() ? file.readAsString() : null;
  }

  @override
  Future<void> write(int uid, String text) async {
    final file = await _fileOf(uid);
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(text, flush: true);
    await temp.rename(file.path);
  }

  @override
  Future<void> delete(int uid) async {
    final file = await _fileOf(uid);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  @override
  Future<void> keepAside(int uid) async {
    final file = await _fileOf(uid);
    if (file.existsSync()) {
      await file.rename('${file.path}.bad');
    }
  }
}

/// The files in memory.
final class _MemoryDraftFiles implements _DraftFiles {
  final _files = <int, String>{};

  @override
  Future<String?> read(int uid) async => _files[uid];

  @override
  Future<void> write(int uid, String text) async => _files[uid] = text;

  @override
  Future<void> delete(int uid) async => _files.remove(uid);

  @override
  Future<void> keepAside(int uid) async => _files.remove(uid);
}
