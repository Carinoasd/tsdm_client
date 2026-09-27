import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' show Either, left, right;
import 'package:rxdart/rxdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/cubit/website_blocklist_cubit.dart';
import 'package:tsdm_client/features/blocking/models/website_blocklist.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/repository/website_blocklist_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Website blacklist state (#126): everything is bound to one account and one generation; account changes clear it
/// and drop late answers and open confirmations (also A → B → A); the same account's auth refresh and the replay of
/// the current status change nothing; duplicate taps and racing lookups send nothing twice; import only adds to the
/// app's local list and keeps every existing entry. Synthetic accounts, no network.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);

/// Authentication whose status replays the current value to each new listener, like the app's.
final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser) : _status = BehaviorSubject.seeded(AuthStatusAuthed(currentUser!));

  @override
  UserLoginInfo? currentUser;

  final BehaviorSubject<AuthStatus> _status;

  @override
  Stream<AuthStatus> get status => _status.stream;

  void switchTo(UserLoginInfo? user) {
    currentUser = user;
    _status.add(user == null ? const AuthStatusNotAuthed() : AuthStatusAuthed(user));
  }

  /// A login check of the same account.
  void refresh() => _status.add(AuthStatusAuthed(currentUser!));

  Future<void> close() => _status.close();
}

/// Forum answered by the test through completers.
final class _Repo extends WebsiteBlocklistRepository {
  final lists = <(int, Completer<Either<WebsiteBlocklistError, WebsiteBlocklist>>)>[];
  final lookups = <(int, int, Completer<Either<WebsiteBlocklistError, WebsiteBlocklistLookup>>)>[];
  final adds = <(int, int, Completer<WebsiteBlocklistWrite>)>[];
  final removes = <(int, int, Completer<WebsiteBlocklistWrite>)>[];

  /// Validity checks handed to the writes, in call order.
  final checks = <WebsiteBlocklistStillCurrent?>[];

  @override
  Future<Either<WebsiteBlocklistError, WebsiteBlocklist>> fetchList(NetClientProvider client, {required int uid}) {
    final c = Completer<Either<WebsiteBlocklistError, WebsiteBlocklist>>();
    lists.add((uid, c));
    return c.future;
  }

  @override
  Future<Either<WebsiteBlocklistError, WebsiteBlocklistLookup>> lookup(
    NetClientProvider client, {
    required int uid,
    required int target,
  }) {
    final c = Completer<Either<WebsiteBlocklistError, WebsiteBlocklistLookup>>();
    lookups.add((uid, target, c));
    return c.future;
  }

  @override
  Future<WebsiteBlocklistWrite> add(
    NetClientProvider client, {
    required int uid,
    required int target,
    String? expectedName,
    WebsiteBlocklistStillCurrent? stillCurrent,
  }) {
    final c = Completer<WebsiteBlocklistWrite>();
    adds.add((uid, target, c));
    checks.add(stillCurrent);
    return c.future;
  }

  @override
  Future<WebsiteBlocklistWrite> remove(
    NetClientProvider client, {
    required int uid,
    required int target,
    WebsiteBlocklistStillCurrent? stillCurrent,
  }) {
    final c = Completer<WebsiteBlocklistWrite>();
    removes.add((uid, target, c));
    checks.add(stillCurrent);
    return c.future;
  }
}

/// Storage whose block list rows can not be read or written while the flags are set.
final class _FlakyStorage extends StorageProvider {
  _FlakyStorage(AppDatabase db) : super(db, {}, {});

  bool failReads = false;
  bool failWrites = false;

  @override
  Future<List<String>?> getStringList(String key) async {
    if (failReads && key.startsWith(UserBlockRepository.keyPrefix)) {
      throw StateError('database is locked');
    }
    return super.getStringList(key);
  }

  @override
  Future<void> saveStringList(String key, List<String> value) async {
    if (failWrites && key.startsWith(UserBlockRepository.keyPrefix)) {
      throw StateError('disk full');
    }
    return super.saveStringList(key, value);
  }
}

final class _Offline implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

NetClientProvider _client(UserLoginInfo _) =>
    NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _Offline(), cookie: CookieProvider.buildEmpty());

WebsiteBlocklist _list(int owner, Map<int, String> rows, {bool complete = true}) => WebsiteBlocklist(
  ownerUid: owner,
  rows: [for (final e in rows.entries) WebsiteBlockedUser(uid: e.key, username: e.value, removable: true)],
  quota: WebsiteBlocklistQuota(used: rows.length, limit: 10),
  complete: complete,
);

/// Let streams, timers of zero and database work run.
Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 30));

void main() {
  late AppDatabase db;
  late _FlakyStorage storage;
  late UserBlockRepository blocks;
  late _Auth auth;
  late _Repo repo;
  late UserBlockCubit local;
  late WebsiteBlocklistCubit cubit;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = _FlakyStorage(db);
    blocks = UserBlockRepository(storage);
    auth = _Auth(_alice);
    repo = _Repo();
    local = UserBlockCubit(
      repository: blocks,
      currentUid: () => auth.currentUser?.uid,
      authStatus: auth.status,
      retryDelays: const [],
    );
    cubit = WebsiteBlocklistCubit(auth: auth, localBlocks: local, repository: repo, clientFactory: _client);
    await _settle();
  });

  tearDown(() async {
    await cubit.close();
    await local.close();
    await auth.close();
    await blocks.dispose();
    await db.close();
  });

  Future<void> loadWith(WebsiteBlocklist list) async {
    final pending = cubit.load();
    repo.lists.last.$2.complete(right(list));
    expect(await pending, WebsiteBlocklistActionResult.done);
  }

  group('account binding', () {
    test('the list is never empty before the forum answered, and a failure is kept apart from empty', () async {
      expect(cubit.state.status, WebsiteBlocklistStatus.initial);
      expect(cubit.state.list, isNull);
      final pending = cubit.load();
      expect(cubit.state.status, WebsiteBlocklistStatus.loading);
      repo.lists.single.$2.complete(left(const WebsiteBlocklistError(WebsiteBlocklistFailure.notLoggedIn)));
      expect(await pending, WebsiteBlocklistActionResult.failed);
      expect(cubit.state.status, WebsiteBlocklistStatus.failed);
      expect(cubit.state.list, isNull);
      expect(cubit.state.error?.failure, WebsiteBlocklistFailure.notLoggedIn);
    });

    test('a real switch clears rows, lookup and names; a late answer of the old account is dropped', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}));
      final lookup = cubit.lookup('2003');
      repo.lookups.single.$3.complete(
        right(const WebsiteBlocklistLookup(uid: 2003, username: 'Charlie', alreadyListed: false, canAdd: true)),
      );
      await lookup;
      expect(cubit.state.lookup?.username, 'Charlie');

      final lateLoad = cubit.load();
      auth.switchTo(_bob);
      await _settle();
      expect(cubit.state.owner, _bob.uid);
      expect(cubit.state.list, isNull);
      expect(cubit.state.lookup, isNull);
      expect(cubit.state.status, WebsiteBlocklistStatus.initial);

      repo.lists.last.$2.complete(right(_list(_alice.uid!, {2002: 'Bravo'})));
      expect(await lateLoad, WebsiteBlocklistActionResult.stale);
      expect(cubit.state.list, isNull, reason: "Alice's list is never shown for Bob");
    });

    test('the replayed status and a refresh of the same account change nothing', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}));
      final generation = cubit.state.generation;
      auth.refresh();
      // A new listener gets the current status again.
      final sub = auth.status.listen((_) {});
      await _settle();
      await sub.cancel();
      expect(cubit.state.generation, generation);
      expect(cubit.state.list?.contains(2001), isTrue);
    });

    test('a confirmation taken for A is dropped after A → B → A', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}));
      final generation = cubit.state.generation;
      final row = cubit.state.list!.rows.single;
      auth
        ..switchTo(_bob)
        ..switchTo(_alice);
      await _settle();
      expect(cubit.state.owner, _alice.uid);
      expect(await cubit.remove(row, generation: generation), WebsiteBlocklistActionResult.stale);
      expect(repo.removes, isEmpty);
      const found = WebsiteBlocklistLookup(uid: 2003, username: 'Charlie', alreadyListed: false, canAdd: true);
      expect(await cubit.add(found, generation: generation), WebsiteBlocklistActionResult.stale);
      expect(repo.adds, isEmpty);
    });

    test('a write answered after a switch is dropped and never shown for the other account', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}));
      final pending = cubit.remove(cubit.state.list!.rows.single, generation: cubit.state.generation);
      expect(repo.removes.single.$1, _alice.uid);
      auth.switchTo(_bob);
      await _settle();
      repo.removes.single.$3.complete(WebsiteBlocklistWrite.success(list: _list(_alice.uid!, {})));
      // It was sent: the result is unknown here, not "nothing was sent".
      expect(await pending, WebsiteBlocklistActionResult.staleUnconfirmed);
      expect(cubit.state.list, isNull);
      expect(cubit.state.writing, isFalse);
    });

    test('a write that expired before sending reports that nothing was sent', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}));
      final pending = cubit.remove(cubit.state.list!.rows.single, generation: cubit.state.generation);
      auth.switchTo(_bob);
      await _settle();
      repo.removes.single.$3.complete(
        const WebsiteBlocklistWrite.failed(WebsiteBlocklistError(WebsiteBlocklistFailure.accountMismatch)),
      );
      expect(await pending, WebsiteBlocklistActionResult.stale);
    });

    test('the validity check handed to a write fails after A → B → A, before and after the write returns', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}));
      final pending = cubit.remove(cubit.state.list!.rows.single, generation: cubit.state.generation);
      final check = repo.checks.single!;
      expect(check(), isTrue);
      auth
        ..switchTo(_bob)
        ..switchTo(_alice);
      await _settle();
      expect(cubit.state.owner, _alice.uid);
      expect(check(), isFalse, reason: 'same account again, but not the generation the user confirmed in');
      repo.removes.single.$3.complete(
        const WebsiteBlocklistWrite.failed(WebsiteBlocklistError(WebsiteBlocklistFailure.accountMismatch)),
      );
      expect(await pending, WebsiteBlocklistActionResult.stale);
      expect(cubit.state.list, isNull);
    });
  });

  group('reads and writes never overlap', () {
    test('no write starts while the list is read, and no read while a write runs', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}));
      final row = cubit.state.list!.rows.single;
      final load = cubit.load();
      expect(await cubit.remove(row, generation: cubit.state.generation), WebsiteBlocklistActionResult.busy);
      expect(repo.removes, isEmpty);
      repo.lists.last.$2.complete(right(_list(_alice.uid!, {2001: 'Alpha'})));
      expect(await load, WebsiteBlocklistActionResult.done);

      final write = cubit.remove(row, generation: cubit.state.generation);
      expect(await cubit.load(), WebsiteBlocklistActionResult.busy);
      expect(await cubit.lookup('2003'), WebsiteBlocklistActionResult.busy);
      expect(repo.lookups, isEmpty);
      repo.removes.single.$3.complete(WebsiteBlocklistWrite.success(list: _list(_alice.uid!, {})));
      expect(await write, WebsiteBlocklistActionResult.done);
      expect(cubit.state.list!.rows, isEmpty);
    });

    test('a lookup pending when a write starts never shows its older answer', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}));
      final lookup = cubit.lookup('2001');
      final write = cubit.remove(cubit.state.list!.rows.single, generation: cubit.state.generation);
      expect(cubit.state.lookupStatus, WebsiteLookupStatus.none);
      repo.removes.single.$3.complete(WebsiteBlocklistWrite.success(list: _list(_alice.uid!, {})));
      expect(await write, WebsiteBlocklistActionResult.done);
      repo.lookups.single.$3.complete(
        right(const WebsiteBlocklistLookup(uid: 2001, username: 'Alpha', alreadyListed: true, canAdd: false)),
      );
      expect(await lookup, WebsiteBlocklistActionResult.stale);
      expect(cubit.state.lookup, isNull, reason: '"already listed" describes the list before the removal');
    });
  });

  group('duplicates and races', () {
    test('a second write while one is sent sends nothing', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha', 2002: 'Bravo'}));
      final generation = cubit.state.generation;
      final first = cubit.remove(cubit.state.list!.rows.first, generation: generation);
      expect(cubit.state.writing, isTrue);
      expect(
        await cubit.remove(cubit.state.list!.rows.first, generation: generation),
        WebsiteBlocklistActionResult.busy,
      );
      expect(
        await cubit.remove(cubit.state.list!.rows.last, generation: generation),
        WebsiteBlocklistActionResult.busy,
      );
      expect(await cubit.load(), WebsiteBlocklistActionResult.busy);
      expect(repo.removes, hasLength(1));
      expect(repo.lists, hasLength(1));
      repo.removes.single.$3.complete(WebsiteBlocklistWrite.success(list: _list(_alice.uid!, {2002: 'Bravo'})));
      expect(await first, WebsiteBlocklistActionResult.done);
      expect(cubit.state.writing, isFalse);
      expect(cubit.state.list!.rows.map((e) => e.uid), [2002]);
    });

    test('a failed write keeps the list it read and its error; nothing is retried', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}));
      final pending = cubit.remove(cubit.state.list!.rows.single, generation: cubit.state.generation);
      repo.removes.single.$3.complete(
        WebsiteBlocklistWrite.failed(
          const WebsiteBlocklistError(WebsiteBlocklistFailure.unknownAfterSubmit),
          list: _list(_alice.uid!, {2001: 'Alpha'}),
        ),
      );
      expect(await pending, WebsiteBlocklistActionResult.failed);
      expect(cubit.state.error?.failure, WebsiteBlocklistFailure.unknownAfterSubmit);
      expect(cubit.state.list!.contains(2001), isTrue);
      expect(repo.removes, hasLength(1));
    });

    test('only the latest lookup is shown; a lookup never writes', () async {
      final first = cubit.lookup('2003');
      final second = cubit.lookup('https://www.tsdm39.com/home.php?mod=space&uid=2004');
      expect(repo.lookups.map((e) => e.$2), [2003, 2004]);
      repo.lookups.last.$3.complete(
        right(const WebsiteBlocklistLookup(uid: 2004, username: 'Delta', alreadyListed: false, canAdd: true)),
      );
      expect(await second, WebsiteBlocklistActionResult.done);
      repo.lookups.first.$3.complete(
        right(const WebsiteBlocklistLookup(uid: 2003, username: 'Charlie', alreadyListed: false, canAdd: true)),
      );
      expect(await first, WebsiteBlocklistActionResult.stale);
      expect(cubit.state.lookup?.uid, 2004);
      expect(repo.adds, isEmpty);
    });

    test('bad input and the account itself are refused before any request', () async {
      expect(await cubit.lookup('abc'), WebsiteBlocklistActionResult.invalidInput);
      expect(
        await cubit.lookup('https://example.com/home.php?mod=space&uid=2003'),
        WebsiteBlocklistActionResult.invalidInput,
      );
      expect(await cubit.lookup('${_alice.uid}'), WebsiteBlocklistActionResult.selfTarget);
      expect(repo.lookups, isEmpty);
    });

    const charlie = WebsiteBlocklistLookup(uid: 2003, username: 'Charlie', alreadyListed: false, canAdd: true);

    test('refused input drops the previous result', () async {
      for (final input in ['abc', '${_alice.uid}']) {
        final lookup = cubit.lookup('2003');
        repo.lookups.last.$3.complete(right(charlie));
        await lookup;
        expect(cubit.state.lookup?.uid, 2003);
        await cubit.lookup(input);
        expect(cubit.state.lookup, isNull, reason: input);
        expect(cubit.state.lookupStatus, WebsiteLookupStatus.none, reason: input);
      }
    });

    test('changed input drops the result and the answer of a pending lookup', () async {
      final lookup = cubit.lookup('2003');
      // The user edits the input while the forum answers.
      cubit.clearLookup();
      repo.lookups.single.$3.complete(right(charlie));
      expect(await lookup, WebsiteBlocklistActionResult.stale);
      expect(cubit.state.lookup, isNull);
      expect(cubit.state.lookupStatus, WebsiteLookupStatus.none);
    });
  });

  group('import into the local list', () {
    test('adds only the chosen user and keeps every existing and unreadable local entry', () async {
      await storage.saveStringList(UserBlockRepository.keyOf(_alice.uid!), [
        BlockedUser(uid: 3001, username: 'Local', blockedAt: DateTime(2026)).encode(),
        '{"damaged": true}',
      ]);
      await local.reload();
      await _settle();
      await loadWith(_list(_alice.uid!, {2001: 'Alpha', 2002: 'Bravo'}));

      final row = cubit.state.list!.rowOf(2001)!;
      final (result, localResult) = await cubit.importRow(row, generation: cubit.state.generation);
      expect((result, localResult), (WebsiteBlocklistActionResult.done, UserBlockResult.ok));
      await _settle();

      final stored = await blocks.load(_alice.uid);
      expect(stored.uids, {2001, 3001}, reason: 'Bravo was not chosen, the local entry stays');
      expect(stored.unreadableEntries, ['{"damaged": true}']);
      expect(stored.users.firstWhere((e) => e.uid == 2001).username, 'Alpha');
      expect(local.state.isBlocked(2001), isTrue, reason: 'the app-wide cubit is the one that changed');

      final again = await cubit.importRow(row, generation: cubit.state.generation);
      expect(again.$1, WebsiteBlocklistActionResult.alreadyApplied);
      expect((await blocks.load(_alice.uid)).users, hasLength(2));
    });

    test('an incomplete website list or an unknown local list can not be imported from', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}, complete: false));
      final row = cubit.state.list!.rows.single;
      expect(
        (await cubit.importRow(row, generation: cubit.state.generation)).$1,
        WebsiteBlocklistActionResult.importUnavailable,
      );

      // A local list that could never be read is unknown, not empty.
      storage.failReads = true;
      final unreadable = UserBlockCubit(
        repository: blocks,
        currentUid: () => auth.currentUser?.uid,
        authStatus: auth.status,
        retryDelays: const [],
      );
      final other = WebsiteBlocklistCubit(
        auth: auth,
        localBlocks: unreadable,
        repository: repo,
        clientFactory: _client,
      );
      addTearDown(() async {
        await other.close();
        await unreadable.close();
      });
      await _settle();
      expect(unreadable.state.status, UserBlockListStatus.failed);
      final pending = other.load();
      repo.lists.last.$2.complete(right(_list(_alice.uid!, {2001: 'Alpha'})));
      await pending;
      expect(
        (await other.importRow(other.state.list!.rows.single, generation: other.state.generation)).$1,
        WebsiteBlocklistActionResult.importUnavailable,
      );
      storage.failReads = false;
      expect((await blocks.load(_alice.uid)).users, isEmpty);
    });

    test('a failed local save is reported and changes nothing', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}));
      storage.failWrites = true;
      final (result, localResult) = await cubit.importRow(
        cubit.state.list!.rows.single,
        generation: cubit.state.generation,
      );
      expect((result, localResult), (WebsiteBlocklistActionResult.failed, UserBlockResult.storageError));
      expect(cubit.state.importing, isEmpty);
      storage.failWrites = false;
      expect((await blocks.load(_alice.uid)).users, isEmpty);
    });

    test('an import uses the row of the list current now, not the row tapped before a reload', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}));
      final tapped = cubit.state.list!.rows.single;
      await loadWith(_list(_alice.uid!, {2001: 'Alpha Renamed'}));
      final (result, _) = await cubit.importRow(tapped, generation: cubit.state.generation);
      expect(result, WebsiteBlocklistActionResult.done);
      await _settle();
      expect((await blocks.load(_alice.uid)).users.single.username, 'Alpha Renamed');

      await loadWith(_list(_alice.uid!, {}));
      expect(
        (await cubit.importRow(
          const WebsiteBlockedUser(uid: 2002, username: 'Gone', removable: true),
          generation: cubit.state.generation,
        )).$1,
        WebsiteBlocklistActionResult.stale,
        reason: 'a user no longer on the list is not imported',
      );
    });

    test('a second tap on the same import while it is saved does nothing', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}));
      final row = cubit.state.list!.rows.single;
      final generation = cubit.state.generation;
      final first = cubit.importRow(row, generation: generation);
      final second = await cubit.importRow(row, generation: generation);
      expect(second.$1, WebsiteBlocklistActionResult.busy);
      expect((await first).$1, WebsiteBlocklistActionResult.done);
      expect((await blocks.load(_alice.uid)).users, hasLength(1));
    });

    test('an import for A is dropped after A → B → A and never writes into B', () async {
      await loadWith(_list(_alice.uid!, {2001: 'Alpha'}));
      final row = cubit.state.list!.rows.single;
      final generation = cubit.state.generation;
      auth.switchTo(_bob);
      await _settle();
      expect((await cubit.importRow(row, generation: generation)).$1, WebsiteBlocklistActionResult.stale);
      auth.switchTo(_alice);
      await _settle();
      expect((await cubit.importRow(row, generation: generation)).$1, WebsiteBlocklistActionResult.stale);
      expect((await blocks.load(_alice.uid)).users, isEmpty);
      expect((await blocks.load(_bob.uid)).users, isEmpty);
    });
  });
}
