import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:rxdart/rxdart.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// A user blocked locally by one account.
final class BlockedUser {
  /// Constructor.
  const BlockedUser({required this.uid, required this.username, required this.blockedAt});

  /// Uid of the blocked user.
  final int uid;

  /// Username when blocked, for display in the management page only.
  ///
  /// Never used to match content: all filtering is done by [uid].
  final String username;

  /// Time of blocking.
  final DateTime blockedAt;

  /// Encode as one entry of the settings row.
  String encode() =>
      jsonEncode(<String, Object>{'uid': uid, 'username': username, 'at': blockedAt.millisecondsSinceEpoch});

  /// Decode one entry of the settings row, null if malformed.
  static BlockedUser? decode(String data) {
    try {
      final m = jsonDecode(data);
      if (m is! Map<String, dynamic>) {
        return null;
      }
      final uid = m['uid'];
      final username = m['username'];
      final at = m['at'];
      if (uid is! int || uid <= 0 || username is! String) {
        return null;
      }
      final milliseconds = at is int ? at : 0;
      // DateTime accepts at most 100 million days from the epoch. Keep damaged entries unreadable and intact.
      if (milliseconds < -8640000000000000 || milliseconds > 8640000000000000) {
        return null;
      }
      return BlockedUser(
        uid: uid,
        username: username,
        blockedAt: DateTime.fromMillisecondsSinceEpoch(milliseconds),
      );
    } on FormatException {
      return null;
    }
  }
}

/// Whether the list of an account is known.
enum UserBlockListStatus {
  /// The list is being read: which users are blocked is not known yet.
  loading,

  /// The list is read.
  ready,

  /// The list could not be read: which users are blocked is not known.
  failed,
}

/// The local block list of one account.
@immutable
final class UserBlockList {
  /// Constructor.
  UserBlockList({
    required this.ownerUid,
    required List<BlockedUser> users,
    List<String> unreadableEntries = const [],
    this.status = UserBlockListStatus.ready,
  }) : users = List.unmodifiable(users),
       unreadableEntries = List.unmodifiable(unreadableEntries),
       uids = Set.unmodifiable(users.map((e) => e.uid));

  /// Empty and known list of [ownerUid].
  const UserBlockList.empty(this.ownerUid)
    : users = const [],
      unreadableEntries = const [],
      uids = const {},
      status = UserBlockListStatus.ready;

  /// List of [ownerUid] that is not known (yet), see [status].
  ///
  /// A null or invalid owner (guest) has nothing to hide and is always known.
  const UserBlockList.unknown(this.ownerUid, {required this.status})
    : assert(status != UserBlockListStatus.ready, 'use UserBlockList.empty'),
      users = const [],
      unreadableEntries = const [],
      uids = const {};

  /// Uid of the account owning this list, null for guest (always empty).
  final int? ownerUid;

  /// Blocked users, latest blocked first.
  final List<BlockedUser> users;

  /// Stored entries this version can not read (written by another version or damaged).
  ///
  /// They are written back unchanged on every change, never dropped silently.
  final List<String> unreadableEntries;

  /// Blocked uids.
  final Set<int> uids;

  /// Whether the list is known.
  final UserBlockListStatus status;

  /// Whether the users in this list are known.
  ///
  /// Guests have nothing to hide and are always known.
  bool get isKnown => status == UserBlockListStatus.ready || ownerUid == null || ownerUid! <= 0;

  /// Whether [uid] is blocked.
  bool isBlocked(int? uid) => uid != null && uids.contains(uid);

  /// Whether content authored by [uid] must not be shown now.
  ///
  /// True for blocked users, and for every identified author while the list of a logged in account is not known:
  /// content is held back instead of being shown for a moment before the list is read. Content without a known
  /// author ([uid] null or not positive) is never hidden.
  bool hides(int? uid) => uid != null && uid > 0 && (isBlocked(uid) || !isKnown);

  /// Same as [hides] with the uid as string (as parsed from html).
  bool hidesString(String? uid) => hides(uid == null ? null : int.tryParse(uid));
}

/// The stored block list could not be read; nothing was changed.
final class UserBlockStorageException implements Exception {
  /// Constructor.
  const UserBlockStorageException(this.cause);

  /// Underlying error.
  final Object cause;

  @override
  String toString() => 'UserBlockStorageException($cause)';
}

/// Result of a block request.
enum UserBlockResult {
  /// Saved.
  ok,

  /// Already blocked, nothing changed.
  alreadyBlocked,

  /// Not blocked, nothing changed (unblock).
  notBlocked,

  /// Users can not block themselves.
  selfBlock,

  /// No account or invalid uid.
  invalid,

  /// The current account changed after the action was started; nothing was changed.
  accountChanged,

  /// The stored list could not be read or written; nothing was changed, or the change is not confirmed.
  storageError,
}

/// Local-only and silent user block.
///
/// Each account owns a separate list keyed by its uid, stored as one row of the settings table named
/// `userBlockList.<ownerUid>` (a json string list, see [BlockedUser.encode]). No request is ever sent to the forum:
/// the blocked user is not notified, forum blacklist, friends and personal messages stay untouched.
///
/// Reads always go to the database so the background service isolate and the sync of all accounts see the same
/// list as the ui without sharing memory.
final class UserBlockRepository with LoggerMixin {
  /// Constructor.
  UserBlockRepository(this._storage);

  final StorageProvider _storage;

  /// Settings row name prefix.
  static const keyPrefix = 'userBlockList.';

  /// Settings row name of [ownerUid].
  static String keyOf(int ownerUid) => '$keyPrefix$ownerUid';

  final _changes = PublishSubject<UserBlockList>();

  /// Serialize all writes in this isolate so two quick taps never lose one update.
  Future<void> _writeQueue = Future.value();

  /// Emits the new list of an account after every change made through this repository.
  Stream<UserBlockList> get changes => _changes.stream;

  /// Load the list of [ownerUid], empty for null or invalid owners.
  ///
  /// Throws [UserBlockStorageException] when the stored row can not be read: callers must not treat that as an
  /// empty list (writing it back would lose the saved one). Entries this version can not decode are kept in
  /// [UserBlockList.unreadableEntries] and written back as they are.
  Future<UserBlockList> load(int? ownerUid) async {
    if (ownerUid == null || ownerUid <= 0) {
      return UserBlockList.empty(ownerUid);
    }
    final List<String> raw;
    try {
      final stored = await _storage.getStringList(keyOf(ownerUid));
      // The row converter returns a lazily cast view: copy it here so an element that is not a string (a row edited
      // by hand or restored from a modified backup) fails this read instead of throwing a TypeError at a caller.
      raw = stored == null ? const [] : List<String>.of(stored);
    } on Object catch (e) {
      error('failed to load user block list: $e');
      throw UserBlockStorageException(e);
    }
    final users = <BlockedUser>[];
    final unreadable = <String>[];
    final seen = <int>{};
    for (final entry in raw) {
      final user = BlockedUser.decode(entry);
      if (user == null) {
        unreadable.add(entry);
      } else if (seen.add(user.uid)) {
        // Deduplicate by uid, keep the first (latest) one.
        users.add(user);
      }
    }
    if (unreadable.isNotEmpty) {
      warning('user block list has ${unreadable.length} unreadable entries, kept as they are');
    }
    return UserBlockList(ownerUid: ownerUid, users: users, unreadableEntries: unreadable);
  }

  /// Blocked uids of [ownerUid].
  ///
  /// Throws [UserBlockStorageException] like [load].
  Future<Set<int>> blockedUidsOf(int? ownerUid) async => (await load(ownerUid)).uids;

  /// Watch the list of [ownerUid]: current value first, then every change.
  ///
  /// Changes are listened to before the first read starts, so a change saved while that read is pending is never
  /// missed: it is emitted instead of the (possibly older) read result. A failed first read is emitted as an error
  /// unless a change arrived meanwhile.
  Stream<UserBlockList> watch(int? ownerUid) {
    if (ownerUid == null || ownerUid <= 0) {
      return Stream.value(UserBlockList.empty(ownerUid));
    }
    late final StreamController<UserBlockList> controller;
    StreamSubscription<UserBlockList>? changesSub;
    controller = StreamController<UserBlockList>(
      onListen: () {
        var loaded = false;
        UserBlockList? pending;
        changesSub = _changes.stream.where((e) => e.ownerUid == ownerUid).listen(
          (list) {
            if (loaded) {
              controller.add(list);
            } else {
              pending = list;
            }
          },
        );
        unawaited(
          load(ownerUid).then(
            (list) {
              loaded = true;
              if (!controller.isClosed) {
                controller.add(pending ?? list);
              }
            },
            onError: (Object e, StackTrace st) {
              loaded = true;
              if (controller.isClosed) {
                return;
              }
              if (pending != null) {
                controller.add(pending!);
              } else {
                controller.addError(e, st);
              }
            },
          ),
        );
      },
      onCancel: () async {
        await changesSub?.cancel();
        await controller.close();
      },
    );
    return controller.stream;
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _writeQueue = _writeQueue.then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<void> _save(UserBlockList list) async {
    final owner = list.ownerUid!;
    if (list.users.isEmpty && list.unreadableEntries.isEmpty) {
      await _storage.deleteKey(keyOf(owner));
    } else {
      await _storage.saveStringList(keyOf(owner), [...list.users.map((e) => e.encode()), ...list.unreadableEntries]);
    }
    _changes.add(list);
  }

  /// Block [uid] for account [ownerUid] locally.
  Future<UserBlockResult> block({
    required int? ownerUid,
    required int uid,
    required String username,
    DateTime? now,
  }) => _serialized(() async {
    if (ownerUid == null || ownerUid <= 0 || uid <= 0) {
      return UserBlockResult.invalid;
    }
    if (ownerUid == uid) {
      return UserBlockResult.selfBlock;
    }
    final list = await load(ownerUid);
    if (list.isBlocked(uid)) {
      return UserBlockResult.alreadyBlocked;
    }
    await _save(
      UserBlockList(
        ownerUid: ownerUid,
        users: [
          BlockedUser(uid: uid, username: username, blockedAt: now ?? DateTime.now()),
          ...list.users,
        ],
        unreadableEntries: list.unreadableEntries,
      ),
    );
    return UserBlockResult.ok;
  });

  /// Remove [uid] from the list of [ownerUid].
  Future<UserBlockResult> unblock({required int? ownerUid, required int uid}) => _serialized(() async {
    if (ownerUid == null || ownerUid <= 0) {
      return UserBlockResult.invalid;
    }
    final list = await load(ownerUid);
    if (!list.isBlocked(uid)) {
      return UserBlockResult.notBlocked;
    }
    await _save(
      UserBlockList(
        ownerUid: ownerUid,
        users: list.users.where((e) => e.uid != uid).toList(),
        unreadableEntries: list.unreadableEntries,
      ),
    );
    return UserBlockResult.ok;
  });

  /// Dispose.
  Future<void> dispose() async {
    await _changes.close();
  }
}
