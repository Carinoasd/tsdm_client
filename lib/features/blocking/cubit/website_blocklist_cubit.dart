import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/models/website_blocklist.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/repository/website_blocklist_repository.dart';
import 'package:tsdm_client/features/blocking/widgets/notice_ignore_actions.dart' show BoundClientFactory;
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// Whether the website blacklist is known.
enum WebsiteBlocklistStatus {
  /// Not loaded yet: nothing is known, the list is not "empty".
  initial,

  /// Being read.
  loading,

  /// Read.
  ready,

  /// Could not be read: see [WebsiteBlocklistState.error].
  failed,
}

/// State of the member lookup.
enum WebsiteLookupStatus {
  /// No lookup.
  none,

  /// Being looked up.
  loading,

  /// Member found: see [WebsiteBlocklistState.lookup].
  found,

  /// Not found or failed: see [WebsiteBlocklistState.lookupError].
  failed,
}

/// Website blacklist of one account, one generation of it.
@immutable
final class WebsiteBlocklistState {
  /// Constructor.
  const WebsiteBlocklistState({
    required this.owner,
    required this.generation,
    this.status = WebsiteBlocklistStatus.initial,
    this.list,
    this.error,
    this.lookupStatus = WebsiteLookupStatus.none,
    this.lookup,
    this.lookupError,
    this.writing = false,
    this.importing = const {},
  });

  /// Account everything here belongs to; null when logged out.
  final int? owner;

  /// Changes on every account change: confirmations taken for another generation are dropped.
  final int generation;

  /// Whether [list] is known.
  final WebsiteBlocklistStatus status;

  /// Last list read for [owner]; kept after a failed reload, never shown for another account.
  final WebsiteBlocklist? list;

  /// Why the last read or write failed.
  final WebsiteBlocklistError? error;

  /// Lookup state.
  final WebsiteLookupStatus lookupStatus;

  /// Member found by the last lookup.
  final WebsiteBlocklistLookup? lookup;

  /// Why the last lookup failed.
  final WebsiteBlocklistError? lookupError;

  /// An add or a remove is being sent: no other write may start.
  final bool writing;

  /// Uids being imported into the local list.
  final Set<int> importing;

  /// Copy with changes; nullable fields are replaced through a getter so they can be cleared.
  WebsiteBlocklistState copyWith({
    WebsiteBlocklistStatus? status,
    ValueGetter<WebsiteBlocklist?>? list,
    ValueGetter<WebsiteBlocklistError?>? error,
    WebsiteLookupStatus? lookupStatus,
    ValueGetter<WebsiteBlocklistLookup?>? lookup,
    ValueGetter<WebsiteBlocklistError?>? lookupError,
    bool? writing,
    Set<int>? importing,
  }) => WebsiteBlocklistState(
    owner: owner,
    generation: generation,
    status: status ?? this.status,
    list: list == null ? this.list : list(),
    error: error == null ? this.error : error(),
    lookupStatus: lookupStatus ?? this.lookupStatus,
    lookup: lookup == null ? this.lookup : lookup(),
    lookupError: lookupError == null ? this.lookupError : lookupError(),
    writing: writing ?? this.writing,
    importing: importing ?? this.importing,
  );
}

/// Outcome of a user action, for the message shown after it.
enum WebsiteBlocklistActionResult {
  /// Done and confirmed.
  done,

  /// Nothing to do, nothing was sent.
  alreadyApplied,

  /// Failed: see the state's error (or the lookup error).
  failed,

  /// Another write, a load during a write (or a write during a load), or the same import is running; nothing was
  /// started.
  busy,

  /// The account or the page generation changed; nothing was sent for it, any late answer was dropped.
  stale,

  /// The account changed after the write was sent: it may have reached the forum, its result is not known here.
  staleUnconfirmed,

  /// The input is not a uid or a profile link.
  invalidInput,

  /// The account itself.
  selfTarget,

  /// The list is not complete or the local list is not known: import refused.
  importUnavailable,
}

/// Website blacklist page state: list, lookup, add, remove and import into the local block list.
///
/// Everything belongs to the account current when it was read ([WebsiteBlocklistState.owner]). On a real account
/// change the state is cleared (rows, lookup, names) and the generation increases; answers and confirmations of an
/// older generation are dropped, also after switching back (A → B → A). Auth events of the same account (a login
/// refresh, the replay of the current status to a new listener) change nothing.
///
/// Writes are only started by explicit user actions, one at a time and never while the list is being read, and use
/// one client bound to the account. The repository checks the write's account and generation again right before
/// sending, so a confirmation that expired while its fresh form was read sends nothing. A write drops any pending
/// lookup, and no lookup starts during a write, so a page read before the change never replaces the list or lookup
/// read after it.
///
/// Import only adds to the local list through the app's [UserBlockCubit]; nothing is ever uploaded or removed.
final class WebsiteBlocklistCubit extends Cubit<WebsiteBlocklistState> with LoggerMixin {
  /// Constructor.
  WebsiteBlocklistCubit({
    required AuthenticationRepository auth,
    required UserBlockCubit localBlocks,
    this.repository = const WebsiteBlocklistRepository(),
    BoundClientFactory? clientFactory,
  }) : _auth = auth,
       _local = localBlocks,
       _clientFactory = clientFactory,
       super(WebsiteBlocklistState(owner: _uidOf(auth), generation: 0)) {
    _authSub = auth.status.listen((status) {
      // The account each event names, not the current one when it is delivered: a quick A → B → A still counts as
      // two changes.
      switch (status) {
        case AuthStatusAuthed(:final userInfo):
          _followOwner(userInfo.uid);
        case AuthStatusNotAuthed():
          _followOwner(null);
        case AuthStatusLoading() || AuthStatusUnknown():
          break;
      }
    });
  }

  /// Forum access, replaceable in tests.
  final WebsiteBlocklistRepository repository;

  final AuthenticationRepository _auth;
  final UserBlockCubit _local;
  final BoundClientFactory? _clientFactory;
  late final StreamSubscription<Object?> _authSub;

  /// Increases on every lookup: only the latest one is shown.
  int _lookupSeq = 0;

  static int? _uidOf(AuthenticationRepository auth) {
    final uid = auth.currentUser?.uid;
    return uid != null && uid > 0 ? uid : null;
  }

  int? get _current => _uidOf(_auth);

  /// Follow the current account, see [_followOwner].
  void _follow() => _followOwner(_current);

  /// Start a new generation for [uid] unless it already owns the state.
  void _followOwner(int? uid) {
    final valid = uid != null && uid > 0 ? uid : null;
    if (isClosed || valid == state.owner) {
      return;
    }
    _lookupSeq++;
    // Nothing of the previous account is kept: rows, lookup, names and pending flags.
    emit(WebsiteBlocklistState(owner: valid, generation: state.generation + 1));
  }

  /// Whether an answer started in [generation] for [owner] may still be shown.
  bool _valid(int generation, int owner) =>
      !isClosed && generation == state.generation && owner == state.owner && _current == owner;

  /// Client bound to the current account, null when logged out or when it is not the owner of the state.
  (int, NetClientProvider)? _bind() {
    final user = _auth.currentUser;
    final uid = user?.uid;
    if (user == null || uid == null || uid <= 0 || uid != state.owner) {
      return null;
    }
    return (uid, (_clientFactory ?? _defaultClient)(user));
  }

  static NetClientProvider _defaultClient(UserLoginInfo user) => NetClientProvider.build(userLoginInfo: user);

  /// Read the list of the current account.
  Future<WebsiteBlocklistActionResult> load() async {
    _follow();
    if (state.status == WebsiteBlocklistStatus.loading || state.writing) {
      return WebsiteBlocklistActionResult.busy;
    }
    final bound = _bind();
    if (bound == null) {
      return WebsiteBlocklistActionResult.stale;
    }
    final (uid, client) = bound;
    final generation = state.generation;
    emit(state.copyWith(status: WebsiteBlocklistStatus.loading, error: () => null));
    final result = await repository.fetchList(client, uid: uid);
    if (!_valid(generation, uid)) {
      return WebsiteBlocklistActionResult.stale;
    }
    switch (result) {
      case Left(:final value):
        emit(state.copyWith(status: WebsiteBlocklistStatus.failed, error: () => value));
        return WebsiteBlocklistActionResult.failed;
      case Right(:final value):
        emit(state.copyWith(status: WebsiteBlocklistStatus.ready, list: () => value, error: () => null));
        return WebsiteBlocklistActionResult.done;
    }
  }

  /// Look up the member typed in [input] (uid or profile link). Read-only: nothing is ever sent from here.
  ///
  /// Any previous result is dropped first, also when [input] is refused, so a result never stays next to other input.
  Future<WebsiteBlocklistActionResult> lookup(String input) async {
    _follow();
    if (state.writing) {
      return WebsiteBlocklistActionResult.busy;
    }
    clearLookup();
    final target = parseWebsiteBlocklistTarget(input);
    if (target == null) {
      return WebsiteBlocklistActionResult.invalidInput;
    }
    final bound = _bind();
    if (bound == null) {
      return WebsiteBlocklistActionResult.stale;
    }
    final (uid, client) = bound;
    if (target == uid) {
      return WebsiteBlocklistActionResult.selfTarget;
    }
    final seq = ++_lookupSeq;
    final generation = state.generation;
    emit(
      state.copyWith(lookupStatus: WebsiteLookupStatus.loading, lookup: () => null, lookupError: () => null),
    );
    final result = await repository.lookup(client, uid: uid, target: target);
    if (!_valid(generation, uid) || seq != _lookupSeq) {
      return WebsiteBlocklistActionResult.stale;
    }
    switch (result) {
      case Left(:final value):
        emit(state.copyWith(lookupStatus: WebsiteLookupStatus.failed, lookupError: () => value));
        return WebsiteBlocklistActionResult.failed;
      case Right(:final value):
        emit(state.copyWith(lookupStatus: WebsiteLookupStatus.found, lookup: () => value));
        return WebsiteBlocklistActionResult.done;
    }
  }

  /// Clear the lookup result and drop the answer of any pending lookup (the input changed).
  void clearLookup() {
    _lookupSeq++;
    if (isClosed || (state.lookupStatus == WebsiteLookupStatus.none && state.lookup == null)) {
      return;
    }
    emit(state.copyWith(lookupStatus: WebsiteLookupStatus.none, lookup: () => null, lookupError: () => null));
  }

  /// Add the member of [found] after the user confirmed it in [generation].
  Future<WebsiteBlocklistActionResult> add(WebsiteBlocklistLookup found, {required int generation}) => _write(
    generation,
    (client, uid, stillCurrent) => repository.add(
      client,
      uid: uid,
      target: found.uid,
      expectedName: found.username,
      stillCurrent: stillCurrent,
    ),
  );

  /// Remove [row] after the user confirmed it in [generation].
  Future<WebsiteBlocklistActionResult> remove(WebsiteBlockedUser row, {required int generation}) => _write(
    generation,
    (client, uid, stillCurrent) => repository.remove(client, uid: uid, target: row.uid, stillCurrent: stillCurrent),
  );

  Future<WebsiteBlocklistActionResult> _write(
    int generation,
    Future<WebsiteBlocklistWrite> Function(NetClientProvider client, int uid, bool Function() stillCurrent) send,
  ) async {
    _follow();
    if (generation != state.generation) {
      return WebsiteBlocklistActionResult.stale;
    }
    // Checked and set before the first await: a second tap never sends a second write, and a list read that started
    // before the write can never land after it.
    if (state.writing || state.status == WebsiteBlocklistStatus.loading) {
      return WebsiteBlocklistActionResult.busy;
    }
    final bound = _bind();
    if (bound == null) {
      return WebsiteBlocklistActionResult.stale;
    }
    final (uid, client) = bound;
    // A lookup describes the list before this change: dropped now, also its pending answer.
    _lookupSeq++;
    emit(
      state.copyWith(
        writing: true,
        error: () => null,
        lookupStatus: WebsiteLookupStatus.none,
        lookup: () => null,
        lookupError: () => null,
      ),
    );
    final WebsiteBlocklistWrite result;
    try {
      // Checked by the repository right before sending, after its fresh form read.
      result = await send(client, uid, () => _valid(generation, uid));
    } finally {
      if (_valid(generation, uid)) {
        emit(state.copyWith(writing: false));
      }
    }
    if (!_valid(generation, uid)) {
      return result.sent ? WebsiteBlocklistActionResult.staleUnconfirmed : WebsiteBlocklistActionResult.stale;
    }
    final list = result.list;
    emit(
      state.copyWith(
        status: list != null ? WebsiteBlocklistStatus.ready : null,
        list: list != null ? () => list : null,
        error: () => result.error,
        // A lookup describes the list before this change: cleared once anything was sent.
        lookupStatus: WebsiteLookupStatus.none,
        lookup: () => null,
        lookupError: () => null,
      ),
    );
    if (!result.isSuccess) {
      return WebsiteBlocklistActionResult.failed;
    }
    return result.alreadyApplied ? WebsiteBlocklistActionResult.alreadyApplied : WebsiteBlocklistActionResult.done;
  }

  /// Why [row] can not be imported now, null when it can.
  ///
  /// Only from a complete list of the current account and generation, while the local list of the same account is
  /// known.
  WebsiteBlocklistActionResult? importBlocker(WebsiteBlockedUser row) {
    final list = state.list;
    if (state.owner == null || list == null || list.ownerUid != state.owner || !list.contains(row.uid)) {
      return WebsiteBlocklistActionResult.stale;
    }
    final local = _local.state;
    if (!list.complete || local.ownerUid != state.owner || local.status != UserBlockListStatus.ready) {
      return WebsiteBlocklistActionResult.importUnavailable;
    }
    return null;
  }

  /// Copy the user of [tapped] into the local block list of the current account; only adds, keeps every existing
  /// local entry.
  ///
  /// The row is taken from the list current now, not from [tapped]: a reload while the tap was pending may have
  /// changed the name, or removed the user.
  Future<(WebsiteBlocklistActionResult, UserBlockResult?)> importRow(
    WebsiteBlockedUser tapped, {
    required int generation,
  }) async {
    _follow();
    if (generation != state.generation) {
      return (WebsiteBlocklistActionResult.stale, null);
    }
    if (importBlocker(tapped) case final blocker?) {
      return (blocker, null);
    }
    final row = state.list!.rowOf(tapped.uid)!;
    if (state.importing.contains(row.uid)) {
      return (WebsiteBlocklistActionResult.busy, null);
    }
    final owner = state.owner!;
    if (_local.state.isBlocked(row.uid)) {
      return (WebsiteBlocklistActionResult.alreadyApplied, UserBlockResult.alreadyBlocked);
    }
    emit(state.copyWith(importing: {...state.importing, row.uid}));
    final result = await _local.block(uid: row.uid, username: row.displayName, expectedOwner: owner);
    if (!_valid(generation, owner)) {
      return (WebsiteBlocklistActionResult.stale, result);
    }
    emit(state.copyWith(importing: {...state.importing}..remove(row.uid)));
    return switch (result) {
      UserBlockResult.ok => (WebsiteBlocklistActionResult.done, result),
      UserBlockResult.alreadyBlocked => (WebsiteBlocklistActionResult.alreadyApplied, result),
      UserBlockResult.accountChanged => (WebsiteBlocklistActionResult.stale, result),
      _ => (WebsiteBlocklistActionResult.failed, result),
    };
  }

  @override
  Future<void> close() async {
    await _authSub.cancel();
    return super.close();
  }
}
