import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/thread_follow/models/followed_thread.dart';
import 'package:tsdm_client/features/thread_follow/repository/followed_thread_store.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_check.dart';
import 'package:tsdm_client/features/thread_follow/utils/followed_thread_fetch.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// The threads the account in use follows.
@immutable
final class FollowedThreadsState {
  /// Constructor.
  const FollowedThreadsState({this.uid, this.threads = const [], this.loaded = false});

  /// The account, null when none is in use.
  final int? uid;

  /// Whether [threads] were read for [uid] yet.
  final bool loaded;

  /// The threads followed, the one followed last first.
  final List<FollowedThread> threads;

  /// The entry of thread [tid], null when it is not followed.
  FollowedThread? of(int tid) {
    for (final e in threads) {
      if (e.tid == tid) {
        return e;
      }
    }
    return null;
  }
}

/// The threads the account in use follows ([FollowedThreadStore]), and the in-app check of their new replies.
///
/// Follows the account in use as `ReadingProgressCubit` does. While the app runs (all platforms; on iOS only in the
/// foreground) a heartbeat ([followedThreadHeartbeat]) checks the threads of the account in use when a check is due
/// ([followedThreadsTick]); the Android background message service runs the same check, the two share the interval
/// through the settings table. What the service stored is read again on every heartbeat and with [reload].
final class FollowedThreadsCubit extends Cubit<FollowedThreadsState> with LoggerMixin {
  /// Constructor.
  ///
  /// [fetchFor] builds the check of one thread for an account (its own client); [announce] posts the notification of
  /// a thread with new replies, for that account, and tells whether it did; [onRead] takes back the notification of a
  /// thread read (its new replies are no news any more). Without [authenticationRepository] the list of [uid] is followed
  /// and nothing is checked (tests).
  FollowedThreadsCubit({
    required FollowedThreadStore store,
    required StorageProvider storage,
    AuthenticationRepository? authenticationRepository,
    Future<FollowedThreadFetch> Function(int tid) Function(int uid)? fetchFor,
    Future<bool> Function(int uid, FollowedThread thread)? announce,
    void Function(int tid)? onRead,
    int? uid,
  }) : _store = store,
       _onRead = onRead,
       _storage = storage,
       _auth = authenticationRepository,
       _fetchFor = fetchFor,
       _announce = announce,
       super(const FollowedThreadsState()) {
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

  final FollowedThreadStore _store;
  final StorageProvider _storage;
  final AuthenticationRepository? _auth;
  final Future<FollowedThreadFetch> Function(int tid) Function(int uid)? _fetchFor;
  final Future<bool> Function(int uid, FollowedThread thread)? _announce;
  final void Function(int tid)? _onRead;

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
    emit(FollowedThreadsState(uid: uid));
    if (uid != null) {
      unawaited(_load(uid));
    }
  }

  Future<void> _load(int uid) async {
    try {
      final threads = await _store.load(uid);
      if (!isClosed && _uid == uid) {
        emit(FollowedThreadsState(uid: uid, threads: threads, loaded: true));
      }
    } on Object catch (e, st) {
      error('failed to load the followed threads: $e', e, st);
    }
  }

  /// Read the list of the account in use again (the background service may have written it).
  Future<void> reload() async {
    if (_uid case final uid?) {
      await _load(uid);
    }
  }

  /// Start the in-app check: a heartbeat every [period], and one right away.
  void start({Duration period = followedThreadHeartbeat}) {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(period, (_) => unawaited(check()));
    unawaited(check());
  }

  /// Check the threads of the account in use when it is due; one check at a time.
  Future<void> check() async {
    final uid = _uid;
    final auth = _auth;
    final fetchFor = _fetchFor;
    if (uid == null || auth == null || fetchFor == null || _checking || isClosed) {
      return;
    }
    _checking = true;
    try {
      await followedThreadsTick(
        storage: _storage,
        store: _store,
        uid: uid,
        fetch: fetchFor(uid),
        // Without a notification to post the list shows the new replies: announced all the same.
        announce: (thread) async => await _announce?.call(uid, thread) ?? true,
        keepGoing: () => !isClosed && auth.effectiveCurrentUid == uid,
      );
    } on Object catch (e, st) {
      error('followed threads check failed: $e', e, st);
    } finally {
      _checking = false;
    }
    await reload();
  }

  /// Follow thread [tid] for the account in use; false without one.
  Future<bool> follow({required int tid, required String title, required int replies, DateTime? lastReplyAt}) async {
    final uid = _uid;
    if (uid == null) {
      return false;
    }
    await _store.follow(uid, tid: tid, title: title, replies: replies, lastReplyAt: lastReplyAt);
    return true;
  }

  /// Stop following thread [tid] for the account in use.
  Future<void> unfollow(int tid) async {
    if (_uid case final uid?) {
      await _store.unfollow(uid, tid);
    }
  }

  /// Put [thread] back in the list of the account in use as it was (undo of [unfollow]).
  ///
  /// [index] is where it was in the list.
  Future<void> restore(FollowedThread thread, {int? index}) async {
    if (_uid case final uid?) {
      await _store.update(uid, thread.tid, (current) => current ?? thread, insertAt: index);
    }
  }

  /// Account [uid] read thread [tid] (it had [replies]): its new replies are cleared. Nothing for a thread not
  /// followed.
  Future<void> markRead({
    required int uid,
    required int tid,
    int? replies,
    String? title,
    DateTime? lastReplyAt,
  }) async {
    if (uid == state.uid && state.loaded) {
      final known = state.of(tid);
      // Not followed, or nothing to clear: no write (the thread page tells every page it loads).
      if (known == null ||
          (!known.notified &&
              known.newReplies == 0 &&
              (replies == null || replies == known.seenReplies) &&
              (title == null || title.isEmpty || title == known.title))) {
        return;
      }
    }
    try {
      // Told by the entry seen under the store's lock: the background service may have announced it just now.
      var hadNews = false;
      await _store.update(uid, tid, (current) {
        hadNews = current != null && (current.notified || current.newReplies > 0);
        return current?.read(replies: replies, title: title, lastReplyAt: lastReplyAt);
      });
      if (hadNews) {
        _onRead?.call(tid);
      }
    } on Object catch (e, st) {
      error('failed to mark followed thread $tid read: $e', e, st);
    }
  }

  @override
  Future<void> close() async {
    _heartbeat?.cancel();
    await _authSub?.cancel();
    await _changesSub.cancel();
    return super.close();
  }
}

/// The entry of thread [tid] the account in use follows; null when it does not follow it, when [tid] is not a thread id
/// or when no [FollowedThreadsCubit] is above [context]. Rebuilds the caller when the entry changes.
FollowedThread? followedThreadOf(BuildContext context, String? tid) {
  final id = int.tryParse(tid ?? '');
  if (id == null || context.readOrNull<FollowedThreadsCubit>() == null) {
    return null;
  }
  return context.select<FollowedThreadsCubit, FollowedThread?>((cubit) => cubit.state.of(id));
}
