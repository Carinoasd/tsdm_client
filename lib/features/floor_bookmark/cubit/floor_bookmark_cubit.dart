import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/floor_bookmark/models/floor_bookmark.dart';
import 'package:tsdm_client/features/floor_bookmark/repository/floor_bookmark_store.dart';
import 'package:tsdm_client/utils/logger.dart';

/// The floor bookmarks of the account in use.
@immutable
final class FloorBookmarkState {
  /// Constructor.
  const FloorBookmarkState({this.uid, this.items = const [], this.loaded = false});

  /// The account, null when none is in use.
  final int? uid;

  /// The live bookmarks, the latest changed first.
  final List<FloorBookmark> items;

  /// Whether [items] are read from the store yet.
  final bool loaded;

  /// The bookmark of floor [pid] of thread [tid], null when it has none.
  FloorBookmark? of({required int tid, required int pid}) {
    final key = FloorBookmark.keyOf(tid: tid, pid: pid);
    for (final item in items) {
      if (item.key == key) {
        return item;
      }
    }
    return null;
  }

  /// The bookmarks of thread [tid], by floor.
  List<FloorBookmark> ofThread(int tid) =>
      items.where((e) => e.tid == tid).toList()..sort((a, b) => (a.floor ?? 0).compareTo(b.floor ?? 0));
}

/// The floor bookmarks of the account in use, kept on this device ([FloorBookmarkStore]) and carried by the
/// cross-device sync. Follows the account in use; empty while none is.
final class FloorBookmarkCubit extends Cubit<FloorBookmarkState> with LoggerMixin {
  /// Constructor.
  ///
  /// With [authenticationRepository] the cubit follows the current account; without it the bookmarks of [uid] are
  /// read (tests).
  FloorBookmarkCubit({required FloorBookmarkStore store, AuthenticationRepository? authenticationRepository, int? uid})
    : _store = store,
      super(const FloorBookmarkState()) {
    _changesSub = store.changes.listen((changed) {
      if (changed == _uid) {
        unawaited(_reload(changed));
      }
    });
    if (authenticationRepository == null) {
      _follow(uid);
      return;
    }
    _follow(authenticationRepository.effectiveCurrentUid);
    _authSub = authenticationRepository.status.listen((_) => _follow(authenticationRepository.effectiveCurrentUid));
  }

  final FloorBookmarkStore _store;
  StreamSubscription<void>? _authSub;
  StreamSubscription<int>? _changesSub;
  int? _uid;

  void _follow(int? uid) {
    if (uid == _uid && (state.loaded || uid == null)) {
      return;
    }
    _uid = uid;
    if (uid == null) {
      emit(const FloorBookmarkState());
      return;
    }
    emit(FloorBookmarkState(uid: uid));
    unawaited(_reload(uid));
  }

  Future<void> _reload(int uid) async {
    try {
      final items = await _store.list(uid);
      if (!isClosed && _uid == uid) {
        emit(FloorBookmarkState(uid: uid, items: items, loaded: true));
      }
    } on Object catch (e, st) {
      error('failed to read the floor bookmarks: $e', e, st);
    }
  }

  /// Mark floor [pid] of thread [tid] for the account in use, or change its note; false without an account.
  Future<bool> put({
    required int tid,
    required int pid,
    int? floor,
    int? page,
    String note = '',
    String excerpt = '',
    String threadTitle = '',
  }) async {
    final uid = _uid;
    if (uid == null) {
      return false;
    }
    try {
      await _store.put(
        uid,
        tid: tid,
        pid: pid,
        floor: floor,
        page: page,
        note: note,
        excerpt: excerpt,
        threadTitle: threadTitle,
      );
      return true;
    } on Object catch (e, st) {
      error('failed to bookmark floor $pid: $e', e, st);
      return false;
    }
  }

  /// Remove the bookmark under [key] of the account in use.
  Future<void> remove(String key) async {
    final uid = _uid;
    if (uid == null) {
      return;
    }
    // Gone from the state at once.
    final before = state;
    emit(FloorBookmarkState(uid: uid, items: before.items.where((e) => e.key != key).toList(), loaded: before.loaded));
    try {
      await _store.remove(uid, key);
    } on Object catch (e, st) {
      error('failed to remove the floor bookmark $key: $e', e, st);
      if (!isClosed && _uid == uid) {
        emit(before);
      }
    }
  }

  @override
  Future<void> close() async {
    await _authSub?.cancel();
    await _changesSub?.cancel();
    return super.close();
  }
}

/// The bookmark of floor [pid] of thread [tid] of the current account, rebuilding the caller when it changes; null
/// when it has none, the ids are not known or no [FloorBookmarkCubit] is above [context].
FloorBookmark? floorBookmarkOf(BuildContext context, {required String? tid, required String? pid}) {
  final t = int.tryParse(tid ?? '');
  final p = int.tryParse(pid ?? '');
  if (t == null || p == null || context.readOrNull<FloorBookmarkCubit>() == null) {
    return null;
  }
  return context.select<FloorBookmarkCubit, FloorBookmark?>((cubit) => cubit.state.of(tid: t, pid: p));
}
