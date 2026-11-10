import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_config.dart';
import 'package:tsdm_client/features/forum_watch/models/forum_watch_state.dart';
import 'package:tsdm_client/features/forum_watch/repository/forum_watch_store.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_check.dart';
import 'package:tsdm_client/features/forum_watch/utils/forum_watch_fetch.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// What the account in use watches and what its check found.
@immutable
final class ForumWatchCubitState {
  /// Constructor.
  const ForumWatchCubitState({
    this.uid,
    this.loaded = false,
    this.config = const ForumWatchConfig(),
    this.alerts = const [],
  });

  /// The account, null when none is in use.
  final int? uid;

  /// Whether [config] and [alerts] were read for [uid] yet.
  final bool loaded;

  /// What the account watches.
  final ForumWatchConfig config;

  /// The threads found, the latest first.
  final List<WatchAlert> alerts;
}

/// The result of a change of what the account watches.
enum ForumWatchChange {
  /// Saved.
  ok,

  /// Nothing to change: the forum or the keyword is there already.
  exists,

  /// The account would fetch more than [forumWatchForumMax] forums, or keep more than [forumWatchKeywordMax]
  /// keywords: nothing was changed.
  limitReached,

  /// No account in use, or another one than the change was started for: nothing was changed.
  noAccount,
}

/// What the account in use watches ([ForumWatchStore]), and the in-app check of it.
///
/// Follows the account in use as `FollowedThreadsCubit` does. While the app runs (all platforms; on iOS only in the
/// foreground) a heartbeat ([forumWatchHeartbeat]) checks when a check is due ([forumWatchTick]); the Android
/// background message service runs the same check, the two share the interval through the settings table.
final class ForumWatchCubit extends Cubit<ForumWatchCubitState> with LoggerMixin {
  /// Constructor.
  ///
  /// [fetchFor] builds the reading of the sources for an account (its own client); [announce] posts the notification
  /// of a batch found for that account and tells whether it did. Without [authenticationRepository] the account [uid]
  /// is followed and nothing is checked (tests).
  ForumWatchCubit({
    required ForumWatchStore store,
    required StorageProvider storage,
    AuthenticationRepository? authenticationRepository,
    Future<ForumWatchFetch> Function(String source) Function(int uid)? fetchFor,
    Future<bool> Function(int uid, ForumWatchBatch batch)? announce,
    int? uid,
    DateTime Function() clock = DateTime.now,
  }) : _store = store,
       _storage = storage,
       _auth = authenticationRepository,
       _fetchFor = fetchFor,
       _announce = announce,
       _clock = clock,
       super(const ForumWatchCubitState()) {
    _changesSub = store.changes.listen((changed) {
      if (changed == _uid) {
        unawaited(_load(changed));
      }
    });
    final auth = authenticationRepository;
    if (auth == null) {
      _follow(uid);
      return;
    }
    _follow(auth.effectiveCurrentUid);
    _authSub = auth.status.listen((_) => _follow(auth.effectiveCurrentUid));
  }

  final ForumWatchStore _store;
  final StorageProvider _storage;
  final AuthenticationRepository? _auth;
  final Future<ForumWatchFetch> Function(String source) Function(int uid)? _fetchFor;
  final Future<bool> Function(int uid, ForumWatchBatch batch)? _announce;
  final DateTime Function() _clock;

  StreamSubscription<void>? _authSub;
  late final StreamSubscription<int> _changesSub;
  Timer? _heartbeat;
  int? _uid;
  var _checking = false;

  void _follow(int? uid) {
    if (uid == _uid && state.uid == uid) {
      return;
    }
    _uid = uid;
    emit(ForumWatchCubitState(uid: uid));
    if (uid != null) {
      unawaited(_load(uid));
    }
  }

  Future<void> _load(int uid) async {
    try {
      final config = await _store.loadConfig(uid);
      final watchState = await _store.loadState(uid);
      if (!isClosed && _uid == uid) {
        emit(ForumWatchCubitState(uid: uid, loaded: true, config: config, alerts: watchState.alerts));
      }
    } on Object catch (e, st) {
      error('failed to load the forum watch: $e', e, st);
    }
  }

  /// Read what the account in use watches again (the background service may have written it).
  Future<void> reload() async {
    if (_uid case final uid?) {
      await _load(uid);
    }
  }

  /// Start the in-app check: a heartbeat every [period], and one right away.
  void start({Duration period = forumWatchHeartbeat}) {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(period, (_) => unawaited(check()));
    unawaited(check());
  }

  /// Check what the account in use watches when it is due; one check at a time.
  Future<void> check() async {
    final uid = _uid;
    final auth = _auth;
    final fetchFor = _fetchFor;
    if (uid == null || auth == null || fetchFor == null || _checking || isClosed) {
      return;
    }
    _checking = true;
    try {
      await forumWatchTick(
        storage: _storage,
        store: _store,
        uid: uid,
        fetch: fetchFor(uid),
        // Without a notification to post the page of the alerts lists them: announced all the same.
        announce: (batch) async => await _announce?.call(uid, batch) ?? true,
        keepGoing: () => !isClosed && auth.effectiveCurrentUid == uid,
        clock: _clock,
      );
    } on Object catch (e, st) {
      error('forum watch check failed: $e', e, st);
    } finally {
      _checking = false;
    }
  }

  /// The account a change made now is for: [expectedUid] when given (the account bound when a dialog opened), null
  /// when that is not the account in use any more.
  int? _owner(int? expectedUid) {
    final uid = _uid;
    if (uid == null || (expectedUid != null && expectedUid != uid)) {
      return null;
    }
    return uid;
  }

  /// Watch forum [fid] named [name] for new threads. [newestTid] is the newest thread the forum page shows now: the
  /// threads after it are announced, not only the ones after the first check.
  Future<ForumWatchChange> watchForum(int fid, {required String name, int? newestTid, int? expectedUid}) async {
    final uid = _owner(expectedUid);
    if (uid == null) {
      return ForumWatchChange.noAccount;
    }
    var result = ForumWatchChange.ok;
    await _store.updateConfig(
      uid,
      (current) {
        if (current.watches(fid)) {
          result = ForumWatchChange.exists;
          return null;
        }
        final next = current.watching(fid, name: name, now: _clock().millisecondsSinceEpoch);
        if (next.fetchedFids.length > forumWatchForumMax) {
          result = ForumWatchChange.limitReached;
          return null;
        }
        return next;
      },
      marks: {if (newestTid != null && newestTid > 0) forumWatchForumSource(fid): newestTid},
    );
    return result;
  }

  /// Stop watching forum [fid] for new threads.
  Future<ForumWatchChange> unwatchForum(int fid, {int? expectedUid}) async {
    final uid = _owner(expectedUid);
    if (uid == null) {
      return ForumWatchChange.noAccount;
    }
    await _store.updateConfig(
      uid,
      (current) => current.watches(fid) ? current.unwatching(fid, now: _clock().millisecondsSinceEpoch) : null,
    );
    return ForumWatchChange.ok;
  }

  /// Add alert keyword [text].
  Future<ForumWatchChange> addKeyword(String text, {int? expectedUid}) async {
    final uid = _owner(expectedUid);
    final key = forumWatchKeywordKey(text);
    if (uid == null) {
      return ForumWatchChange.noAccount;
    }
    if (key.isEmpty) {
      return ForumWatchChange.exists;
    }
    var result = ForumWatchChange.ok;
    await _store.updateConfig(uid, (current) {
      if (current.keywords.any((k) => k.key == key)) {
        result = ForumWatchChange.exists;
        return null;
      }
      if (current.keywords.length >= forumWatchKeywordMax) {
        result = ForumWatchChange.limitReached;
        return null;
      }
      final next = current.withKeyword(
        text.trim().characters.take(forumWatchKeywordMaxLength).toString(),
        now: _clock().millisecondsSinceEpoch,
      );
      // The first keyword makes the forums of a picked scope fetched.
      if (next.fetchedFids.length > forumWatchForumMax && next.fetchedFids.length > current.fetchedFids.length) {
        result = ForumWatchChange.limitReached;
        return null;
      }
      return next;
    });
    return result;
  }

  /// Remove the alert keyword of [key] ([forumWatchKeywordKey]).
  Future<ForumWatchChange> removeKeyword(String key, {int? expectedUid}) async {
    final uid = _owner(expectedUid);
    if (uid == null) {
      return ForumWatchChange.noAccount;
    }
    await _store.updateConfig(
      uid,
      (current) => current.keywords.any((k) => k.key == key)
          ? current.withoutKeyword(key, now: _clock().millisecondsSinceEpoch)
          : null,
    );
    return ForumWatchChange.ok;
  }

  /// Look for the keywords in [scope] from now on.
  Future<ForumWatchChange> setScope(KeywordScope scope, {int? expectedUid}) async {
    final uid = _owner(expectedUid);
    if (uid == null) {
      return ForumWatchChange.noAccount;
    }
    var result = ForumWatchChange.ok;
    await _store.updateConfig(uid, (current) {
      final count = current.fetchedCountWith(scope: scope);
      if (count > forumWatchForumMax && count > current.fetchedFids.length) {
        result = ForumWatchChange.limitReached;
        return null;
      }
      return current.withScope(scope, now: _clock().millisecondsSinceEpoch);
    });
    return result;
  }

  @override
  Future<void> close() async {
    _heartbeat?.cancel();
    await _authSub?.cancel();
    await _changesSub.cancel();
    return super.close();
  }
}

/// Whether the account in use watches forum [fid] for new threads; false without a [ForumWatchCubit] above
/// [context]. Rebuilds the caller when it changes.
bool isForumWatched(BuildContext context, int? fid) {
  if (fid == null || context.readOrNull<ForumWatchCubit>() == null) {
    return false;
  }
  return context.select<ForumWatchCubit, bool>((cubit) => cubit.state.config.watches(fid));
}
