import 'dart:convert';
import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Kinds of answers [SavedAnswerStore] keeps.
enum SavedAnswerKind {
  /// The homepage (`forum.php`) in the JSON mode of the forum's app API (plugin 2.3.0, `schema: 5`).
  homepage,

  /// The guide index page (`forum.php?mod=guide&view=index`, plugin 2.4.0, `schema: 7`).
  guide,
}

/// An answer read back by [SavedAnswerStore.load], and when it was saved.
typedef SavedAnswer = ({Map<String, dynamic> answer, DateTime savedAt});

/// The last answer of each kind ([SavedAnswerKind]) of the forum's app API, kept as a file per account (and one for the
/// guest) so the next start shows at once what the homepage showed last, while the page is asked again
/// (stale-while-revalidate).
///
/// An answer is only ever handed back to the account it was served to: it is stored under the uid the answer itself
/// names (`uid`, 0 for a guest), never under one the caller passes, and read back only when that uid is the uid asked
/// for. An answer older than [maxAge] (or from the future: the clock went back), of another [formatVersion] or that
/// does not parse is no answer, and its file goes. The files of an account go when it is removed from the device or its
/// session is known dead ([forget]).
///
/// Writes run one after another in the background, each into a temporary file renamed over the old one, so a read
/// never sees half a file; a failed write is logged and dropped.
final class SavedAnswerStore with LoggerMixin {
  /// Constructor.
  ///
  /// The files live in [directory] (`saved_answers` in the app's cache directory by default); [now] is the clock.
  SavedAnswerStore({Future<Directory> Function()? directory, DateTime Function()? now, this.maxAge = defaultMaxAge})
    : _directory = directory ?? _defaultDirectory,
      _now = now ?? DateTime.now;

  /// The app's store, null when none is registered (tests of other features): nothing is saved or read then.
  static SavedAnswerStore? get app => getIt.isRegistered<SavedAnswerStore>() ? getIt.get<SavedAnswerStore>() : null;

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getApplicationCacheDirectory()).path}${Platform.pathSeparator}saved_answers');

  /// Version of the files and of what the app reads from the answers in them: a file of another version is not read.
  static const formatVersion = 1;

  /// How old a saved answer may be by default to be shown.
  static const defaultMaxAge = Duration(days: 1);

  /// How far in the future a saved time may be: a little clock adjustment, not a clock that went back by days.
  static const _futureSlack = Duration(minutes: 5);

  /// How old a saved answer may be to be shown.
  final Duration maxAge;

  final Future<Directory> Function() _directory;
  final DateTime Function() _now;

  Future<void> _writes = Future<void>.value();

  /// Completes once every write handed over so far is done.
  @visibleForTesting
  Future<void> get pendingWrites => _writes;

  static int _uidOf(int? uid) => uid != null && uid > 0 ? uid : 0;

  static int? _answerUid(Map<String, dynamic> answer) {
    final uid = answer['uid'];
    final value = uid is int ? uid : int.tryParse('$uid');
    return value == null || value < 0 ? null : value;
  }

  Future<File> _fileOf(SavedAnswerKind kind, int uid) async {
    final dir = await _directory();
    return File('${dir.path}${Platform.pathSeparator}${kind.name}_$uid.json');
  }

  void _queue(String what, Future<void> Function() write) {
    _writes = _writes.then((_) async {
      try {
        await write();
      } on Object catch (e, st) {
        warning('saved answers: failed to $what: $e');
        handleRaw(e, st);
      }
    });
  }

  /// Fields of an answer that belong to the session it was served in, never kept on disk: its form hash, the
  /// forum's daily login request and today's daily red packet. A saved page shows none of them.
  static const sessionFields = {'formhash', 'checknewpm', 'red_packet'};

  /// How many times the answers of each account were forgotten ([forget]): what was read for an account before
  /// ([forgetCountOf] changed since) is stale.
  final _forgotten = <int, int>{};

  /// How many times the answers of the account [uid] were forgotten, see [_forgotten].
  int forgetCountOf(int? uid) => _forgotten[_uidOf(uid)] ?? 0;

  /// Keep [answer] of [kind] as the last one served to the account it names, replacing the one saved before, without
  /// its [sessionFields].
  ///
  /// Nothing is kept for an answer that names no account (no `uid`).
  void save(SavedAnswerKind kind, Map<String, dynamic> answer) {
    final kept = Map.of(answer)..removeWhere((key, _) => sessionFields.contains(key));
    final uid = _answerUid(kept);
    if (uid == null) {
      warning('saved answers: ${kind.name} answer names no account, not saved');
      return;
    }
    final savedAt = _now();
    _queue('save ${kind.name}', () async {
      final file = await _fileOf(kind, uid);
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({
          'v': formatVersion,
          'kind': kind.name,
          'uid': uid,
          'savedAt': savedAt.millisecondsSinceEpoch,
          'answer': kept,
        }),
        flush: true,
      );
      await temp.rename(file.path);
    });
  }

  /// The answer of [kind] saved for the account [uid] (null or 0 for the guest), null when there is none, it is too
  /// old, it is of another format, or it was served to another account.
  Future<SavedAnswer?> load(SavedAnswerKind kind, {required int? uid}) async {
    final id = _uidOf(uid);
    // A write handed over before is what is read back.
    await _writes;
    final File file;
    try {
      file = await _fileOf(kind, id);
      if (!file.existsSync()) {
        return null;
      }
    } on Object catch (e) {
      warning('saved answers: no directory for ${kind.name}: $e');
      return null;
    }
    String? dropped;
    try {
      final saved = jsonDecode(await file.readAsString());
      final now = _now();
      if (saved is! Map<String, dynamic> || saved['v'] != formatVersion || saved['kind'] != kind.name) {
        dropped = 'another format';
      } else if (saved['uid'] != id) {
        dropped = 'another account';
      } else if (saved['savedAt'] is! int) {
        dropped = 'no time';
      } else {
        final savedAt = DateTime.fromMillisecondsSinceEpoch(saved['savedAt'] as int);
        final answer = saved['answer'];
        if (now.difference(savedAt) > maxAge || savedAt.difference(now) > _futureSlack) {
          dropped = 'saved at $savedAt';
        } else if (answer is! Map<String, dynamic> || _answerUid(answer) != id) {
          dropped = 'answer of another account';
        } else {
          return (answer: answer, savedAt: savedAt);
        }
      }
    } on Object catch (e) {
      dropped = 'unreadable: $e';
    }
    debug('saved answers: ${kind.name} not used ($dropped)');
    _queue('drop ${kind.name}', () async {
      if (file.existsSync()) {
        await file.delete();
      }
    });
    return null;
  }

  /// Delete every answer saved for the account [uid]: removed from the device, or its session is dead.
  void forget(int uid) {
    if (uid <= 0) {
      return;
    }
    _forgotten[uid] = (_forgotten[uid] ?? 0) + 1;
    _queue('forget account', () async {
      for (final kind in SavedAnswerKind.values) {
        final file = await _fileOf(kind, uid);
        if (file.existsSync()) {
          await file.delete();
        }
      }
    });
  }
}
