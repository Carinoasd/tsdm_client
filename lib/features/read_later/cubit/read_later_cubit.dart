import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// A thread an account put aside to read later.
@immutable
final class ReadLaterItem {
  /// Constructor.
  const ReadLaterItem({required this.tid, required this.title, required this.addedAt, this.author, this.forumName});

  /// From a stored row.
  factory ReadLaterItem.fromEntity(ReadLaterEntity e) => ReadLaterItem(
    tid: e.tid,
    title: e.threadTitle,
    author: e.author,
    forumName: e.forumName,
    addedAt: e.addedAt,
  );

  /// Thread id.
  final int tid;

  /// Thread title when it was put aside.
  final String title;

  /// Name of the thread's author, null when not known.
  final String? author;

  /// Name of the forum the thread is in, null when not known.
  final String? forumName;

  /// When the thread was put aside.
  final DateTime addedAt;
}

/// The read later list of the account in use, the latest put aside first.
@immutable
final class ReadLaterState {
  /// Constructor.
  const ReadLaterState({this.uid, this.items = const [], this.loaded = false});

  /// The account, null when none is in use.
  final int? uid;

  /// The list, by time put aside, latest first.
  final List<ReadLaterItem> items;

  /// Whether [items] are read from the stored list of [uid] yet.
  final bool loaded;

  /// Whether thread [tid] is on the list.
  bool contains(int tid) => items.any((e) => e.tid == tid);
}

/// The read later list of the current account, kept on this device (not the forum's favorites).
///
/// Follows the account in use as `RepliedThreadCubit` does; empty while no account is in use. Thread lists and the
/// thread page read it through [isReadLater] and change it through [toggleReadLater]; the thread page takes a thread
/// off with [remove] once read to its last floor.
final class ReadLaterCubit extends Cubit<ReadLaterState> with LoggerMixin {
  /// Constructor.
  ///
  /// With [authenticationRepository] the cubit follows the current account; without it the list of [uid] is
  /// watched (tests).
  ReadLaterCubit({
    required StorageProvider storageProvider,
    AuthenticationRepository? authenticationRepository,
    int? uid,
  }) : _storage = storageProvider,
       super(const ReadLaterState()) {
    if (authenticationRepository == null) {
      _follow(uid);
      return;
    }
    _follow(authenticationRepository.effectiveCurrentUid);
    _authSub = authenticationRepository.status.listen((_) => _follow(authenticationRepository.effectiveCurrentUid));
  }

  final StorageProvider _storage;

  StreamSubscription<void>? _authSub;
  StreamSubscription<List<ReadLaterItem>>? _itemsSub;
  int? _uid;

  void _follow(int? uid) {
    if (uid == _uid && (_itemsSub != null || uid == null)) {
      return;
    }
    _uid = uid;
    unawaited(_itemsSub?.cancel());
    _itemsSub = null;
    if (uid == null) {
      emit(const ReadLaterState());
      return;
    }
    emit(ReadLaterState(uid: uid));
    _itemsSub = _storage.watchReadLater(uid).map((rows) => rows.map(ReadLaterItem.fromEntity).toList()).listen(
      (items) {
        if (!isClosed && _uid == uid) {
          emit(ReadLaterState(uid: uid, items: items, loaded: true));
        }
      },
      onError: (Object e, StackTrace st) => error('failed to watch the read later list: $e', e, st),
    );
  }

  /// Put thread [tid] aside for the account in use; false without one.
  Future<bool> add({required int tid, required String title, String? author, String? forumName}) async {
    final uid = _uid;
    if (uid == null) {
      return false;
    }
    try {
      await _storage.addReadLater(uid: uid, tid: tid, title: title, author: author, forumName: forumName);
      return true;
    } on Object catch (e, st) {
      error('failed to put thread $tid aside: $e', e, st);
      return false;
    }
  }

  /// Take thread [tid] off the list of the account in use.
  Future<void> remove(int tid) async {
    final uid = _uid;
    if (uid == null) {
      return;
    }
    // Gone from the state at once: a swiped away entry must not stay in the tree until the stream delivers.
    final before = state;
    if (before.contains(tid)) {
      emit(ReadLaterState(uid: uid, items: before.items.where((e) => e.tid != tid).toList(), loaded: before.loaded));
    }
    try {
      await _storage.removeReadLater(uid, tid);
    } on Object catch (e, st) {
      error('failed to take thread $tid off the read later list: $e', e, st);
      if (!isClosed && _uid == uid) {
        emit(before);
      }
    }
  }

  /// Empty the list of the account in use.
  Future<void> clear() async {
    final uid = _uid;
    if (uid == null) {
      return;
    }
    final before = state;
    emit(ReadLaterState(uid: uid, loaded: before.loaded));
    try {
      await _storage.clearReadLater(uid);
    } on Object catch (e, st) {
      error('failed to clear the read later list: $e', e, st);
      if (!isClosed && _uid == uid) {
        emit(before);
      }
    }
  }

  @override
  Future<void> close() async {
    await _authSub?.cancel();
    await _itemsSub?.cancel();
    return super.close();
  }
}

/// Whether thread [tid] is on the read later list of the current account.
///
/// Rebuilds the caller when the list changes. False when [tid] is not a thread id or when no [ReadLaterCubit] is above
/// [context] (a widget shown outside the app tree).
bool isReadLater(BuildContext context, String? tid) {
  final id = int.tryParse(tid ?? '');
  if (id == null || context.readOrNull<ReadLaterCubit>() == null) {
    return false;
  }
  return context.select<ReadLaterCubit, bool>((cubit) => cubit.state.contains(id));
}

/// Put thread [tid] on the read later list of the current account, or take it off when it is there.
///
/// Does nothing without an account or a [ReadLaterCubit]. Returns whether the thread is on the list afterwards.
Future<bool> toggleReadLater(
  BuildContext context, {
  required String tid,
  required String title,
  String? author,
  String? forumName,
}) async {
  final id = int.tryParse(tid);
  final cubit = context.readOrNull<ReadLaterCubit>();
  if (id == null || cubit == null) {
    return false;
  }
  if (cubit.state.contains(id)) {
    await cubit.remove(id);
    return false;
  }
  return cubit.add(tid: id, title: title, author: author, forumName: forumName);
}
