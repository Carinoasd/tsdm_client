import 'dart:async';
import 'dart:convert';

import 'package:tsdm_client/features/forum_watch/models/forum_watch_config.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_state.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_sync.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// What each account watches ([ForumWatchConfig]) and what the check of it knows ([ForumWatchState]), kept on this
/// device in the settings table: two JSON objects per account ([StorageProvider.forumWatchKey],
/// [StorageProvider.forumWatchStateKey]), removed with the account.
///
/// The app and the Android background message service (an isolate of its own on the same database) both write them:
/// the app when the account watches a forum or changes its keywords, a check when it read a source. Every change is
/// one read-modify-write under the database's write lock ([StorageProvider.exclusively]), so a forum unwatched while a
/// check runs stays unwatched and its mark goes with it ([updateConfig]).
final class ForumWatchStore with LoggerMixin {
  /// Constructor.
  ForumWatchStore(this._storage);

  final StorageProvider _storage;

  /// The app's store, null when none is registered (the service isolate, tests of other features): the cross-device
  /// sync leaves what is watched alone then.
  static ForumWatchStore? get app => getIt.isRegistered<ForumWatchStore>() ? getIt.get<ForumWatchStore>() : null;

  final _changes = StreamController<int>.broadcast();
  final _configChanges = StreamController<int>.broadcast();

  /// Accounts whose config or state changed through this store, by uid; what another isolate wrote is only seen by
  /// [loadConfig] and [loadState].
  Stream<int> get changes => _changes.stream;

  /// Accounts whose config changed through this store (never for a change of the check's state alone): what the
  /// cross-device sync writes after.
  Stream<int> get configChanges => _configChanges.stream;

  /// What account [uid] watches.
  Future<ForumWatchConfig> loadConfig(int uid) async =>
      ForumWatchConfig.fromJson(_decode(await _storage.getString(StorageProvider.forumWatchKey(uid))));

  /// What the check of account [uid] knows.
  Future<ForumWatchState> loadState(int uid) async =>
      ForumWatchState.fromJson(_decode(await _storage.getString(StorageProvider.forumWatchStateKey(uid))));

  /// Change what account [uid] watches to what [change] makes of it (null: nothing to change), with [marks] the marks
  /// the change sets (a forum watched from its page starts from the threads shown there).
  ///
  /// The marks of the sources the check no longer reads go with the change: a source read again later starts over.
  /// Returns the config as stored.
  Future<ForumWatchConfig> updateConfig(
    int uid,
    ForumWatchConfig? Function(ForumWatchConfig current) change, {
    Map<String, int> marks = const {},
  }) async {
    final result = await _storage.exclusively(() async {
      final current = await loadConfig(uid);
      final next = change(current);
      if (next == null || next == current) {
        return (changed: false, config: current);
      }
      await _write(StorageProvider.forumWatchKey(uid), next.isBlank ? null : next);
      final state = await loadState(uid);
      var nextState = state.onlyMarks(next.sources);
      for (final MapEntry(:key, :value) in marks.entries) {
        if (next.sources.contains(key) && !nextState.marks.containsKey(key)) {
          nextState = nextState.withMark(key, value);
        }
      }
      if (nextState != state) {
        await _writeState(uid, nextState);
      }
      return (changed: true, config: next);
    });
    if (result.changed && !_changes.isClosed) {
      _changes.add(uid);
      _configChanges.add(uid);
    }
    return result.config;
  }

  /// Take the sections of the sync document in for account [uid] ([forumWatchWithSynced]): the items of
  /// `watch_forums` ([forums]) and `watch_keywords` ([keywords]) and the item of `watch_scope` ([scope]). A forum or
  /// a source that comes with them starts without a mark: its first reading announces nothing.
  Future<void> applySynced(
    int uid, {
    required Map<String, Map<String, dynamic>> forums,
    required Map<String, Map<String, dynamic>> keywords,
    required Map<String, dynamic>? scope,
    DateTime? now,
  }) async {
    await updateConfig(
      uid,
      (current) => forumWatchWithSynced(
        current,
        forums: forums,
        keywords: keywords,
        scope: scope,
        now: (now ?? DateTime.now()).millisecondsSinceEpoch,
      ),
    );
  }

  /// Change what the check of account [uid] knows to what [change] makes of it, given what the account watches now
  /// (null: nothing to change). Returns the state as stored.
  Future<ForumWatchState> updateState(
    int uid,
    ForumWatchState? Function(ForumWatchConfig config, ForumWatchState current) change,
  ) async {
    final result = await _storage.exclusively(() async {
      final current = await loadState(uid);
      final next = change(await loadConfig(uid), current);
      if (next == null || next == current) {
        return (changed: false, state: current);
      }
      await _writeState(uid, next);
      return (changed: true, state: next);
    });
    if (result.changed && !_changes.isClosed) {
      _changes.add(uid);
    }
    return result.state;
  }

  /// Close the change streams.
  Future<void> dispose() async {
    await _changes.close();
    await _configChanges.close();
  }

  Future<void> _writeState(int uid, ForumWatchState state) => _write(
    StorageProvider.forumWatchStateKey(uid),
    state.marks.isEmpty && state.alerts.isEmpty ? null : state,
  );

  Future<void> _write(String key, Object? value) async {
    if (value == null) {
      await _storage.deleteKey(key);
      return;
    }
    await _storage.saveString(key, jsonEncode(value));
  }

  Object? _decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return null;
    }
    try {
      return jsonDecode(raw);
    } on FormatException catch (e) {
      warning('forum watch row not readable, starting over: $e');
      return null;
    }
  }
}
