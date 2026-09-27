import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' show Either, left, right;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/models/website_blocklist.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/repository/website_blocklist_repository.dart';
import 'package:tsdm_client/features/blocking/view/user_block_page.dart';
import 'package:tsdm_client/features/blocking/view/website_blocklist_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Website blacklist page (#126): explicit load, lookup before add, confirmations bound to the account, per-row
/// import into the local list with accurate labels, browser fallback, and a readable layout with large text. All data
/// is synthetic; no network.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);

final class _Auth extends Fake implements AuthenticationRepository {
  _Auth(this.currentUser);

  @override
  UserLoginInfo? currentUser;

  final _controller = StreamController<AuthStatus>.broadcast(sync: true);

  @override
  Stream<AuthStatus> get status => _controller.stream;

  void switchTo(UserLoginInfo? user) {
    currentUser = user;
    _controller.add(user == null ? const AuthStatusNotAuthed() : AuthStatusAuthed(user));
  }

  Future<void> close() => _controller.close();
}

/// A forum answering at once from [listed]; writes wait for [writeGate] when set.
final class _Repo extends WebsiteBlocklistRepository {
  _Repo(this.listed);

  final Map<int, String> listed;
  final members = {2003: 'Charlie', 2004: 'Delta'};
  bool complete = true;
  WebsiteBlocklistError? listError;
  Completer<void>? writeGate;
  Completer<void>? lookupGate;
  final calls = <String>[];

  WebsiteBlocklist _list(int uid) => WebsiteBlocklist(
    ownerUid: uid,
    rows: [for (final e in listed.entries) WebsiteBlockedUser(uid: e.key, username: e.value, removable: true)],
    quota: WebsiteBlocklistQuota(used: listed.length, limit: 12),
    complete: complete,
  );

  @override
  Future<Either<WebsiteBlocklistError, WebsiteBlocklist>> fetchList(
    NetClientProvider client, {
    required int uid,
  }) async {
    calls.add('list:$uid');
    return listError != null ? left(listError!) : right(_list(uid));
  }

  @override
  Future<Either<WebsiteBlocklistError, WebsiteBlocklistLookup>> lookup(
    NetClientProvider client, {
    required int uid,
    required int target,
  }) async {
    calls.add('lookup:$target');
    await lookupGate?.future;
    final name = members[target];
    if (name == null) {
      return left(const WebsiteBlocklistError(WebsiteBlocklistFailure.notFound));
    }
    final listedNow = listed.containsKey(target);
    return right(WebsiteBlocklistLookup(uid: target, username: name, alreadyListed: listedNow, canAdd: !listedNow));
  }

  @override
  Future<WebsiteBlocklistWrite> add(
    NetClientProvider client, {
    required int uid,
    required int target,
    String? expectedName,
    WebsiteBlocklistStillCurrent? stillCurrent,
  }) async {
    calls.add('add:$target');
    await writeGate?.future;
    listed[target] = members[target]!;
    return WebsiteBlocklistWrite.success(list: _list(uid));
  }

  @override
  Future<WebsiteBlocklistWrite> remove(
    NetClientProvider client, {
    required int uid,
    required int target,
    WebsiteBlocklistStillCurrent? stillCurrent,
  }) async {
    calls.add('remove:$target');
    await writeGate?.future;
    listed.remove(target);
    return WebsiteBlocklistWrite.success(list: _list(uid));
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

void main() {
  late AppDatabase db;
  late UserBlockRepository blocks;
  late _Auth auth;
  late _Repo repo;
  late List<Uri> opened;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    blocks = UserBlockRepository(StorageProvider(db, {}, {}));
    auth = _Auth(_alice);
    repo = _Repo({2001: 'Alpha', 2002: 'Bravo'});
    opened = [];
  });

  tearDown(() async {
    await blocks.dispose();
    await auth.close();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, {Widget? page, double textScale = 1}) async {
    final local = UserBlockCubit(
      repository: blocks,
      currentUid: () => auth.currentUser?.uid,
      authStatus: auth.status,
      retryDelays: const [],
    );
    addTearDown(local.close);
    await tester.pumpWidget(
      TranslationProvider(
        child: RepositoryProvider<AuthenticationRepository>.value(
          value: auth,
          child: BlocProvider<UserBlockCubit>.value(
            value: local,
            child: MaterialApp(
              scaffoldMessengerKey: snackbarKey,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
                child: child!,
              ),
              home:
                  page ??
                  WebsiteBlocklistPage(
                    repository: repo,
                    clientFactory: _client,
                    openBrowser: (uri) async {
                      opened.add(uri);
                      return true;
                    },
                  ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    await reveal(tester, find.text(text));
    await tester.tap(find.text(text).first);
    await settle(tester);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await reveal(tester, find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
  }

  testWidgets('nothing is shown as empty before an explicit load; rows are labelled against the local list', (
    tester,
  ) async {
    await tester.runAsync(() => blocks.block(ownerUid: _alice.uid, uid: 2002, username: 'Bravo'));
    await tester.runAsync(() => blocks.block(ownerUid: _alice.uid, uid: 3001, username: 'Local'));
    await pump(tester);
    expect(find.text(w.notLoaded), findsOneWidget);
    expect(find.text(w.empty), findsNothing);
    expect(repo.calls, isEmpty, reason: 'opening the page reads nothing');

    await tapText(tester, w.load);
    expect(repo.calls, ['list:${_alice.uid}']);
    // In page order: the list view builds its children lazily.
    await reveal(tester, find.text(w.count(count: '2')));
    expect(find.text(w.count(count: '2')), findsOneWidget);
    expect(find.text(w.quotaUsed(used: '2', limit: '12')), findsOneWidget);
    await reveal(tester, find.text(w.localOnly(count: '1')));
    expect(find.text(w.localOnly(count: '1')), findsOneWidget);
    await reveal(tester, find.text('UID 2001 · ${w.stateWebsiteOnly}'));
    expect(find.text('UID 2001 · ${w.stateWebsiteOnly}'), findsOneWidget);
    await reveal(tester, find.byKey(const ValueKey('website-import-2001')));
    expect(find.byKey(const ValueKey('website-import-2001')), findsOneWidget);
    await reveal(tester, find.text('UID 2002 · ${w.stateBoth}'));
    expect(find.text('UID 2002 · ${w.stateBoth}'), findsOneWidget);
    await reveal(tester, find.byKey(const ValueKey('website-remove-2002')));
    expect(find.byKey(const ValueKey('website-import-2002')), findsNothing, reason: 'already blocked here');
  });

  testWidgets('a failed load is not empty and offers retry and the website', (tester) async {
    repo.listError = const WebsiteBlocklistError(WebsiteBlocklistFailure.unsupported);
    await pump(tester);
    await tapText(tester, w.load);
    expect(find.text(w.failure.unsupported), findsOneWidget);
    expect(find.text(w.empty), findsNothing);
    expect(find.text(tr.general.retry), findsOneWidget);
    await tapText(tester, w.openInBrowser);
    expect(opened.single.queryParameters['id'], 'blockuser:spacecp');
  });

  testWidgets('lookup shows the member first; add is sent once after the confirmation', (tester) async {
    await pump(tester);
    await tapText(tester, w.load);
    await tester.enterText(find.byKey(const ValueKey('website-lookup-input')), '2003');
    await tapText(tester, w.lookup);
    expect(find.text(w.lookupResult(name: 'Charlie', uid: '2003')), findsOneWidget);
    expect(repo.calls.where((e) => e.startsWith('add')), isEmpty, reason: 'a lookup never adds');

    // Cancelled: nothing sent.
    await tapKey(tester, 'website-add');
    expect(find.text(w.addConfirmTitle(name: 'Charlie')), findsOneWidget);
    await tester.tap(find.text(tr.general.cancel));
    await settle(tester);
    expect(repo.calls.where((e) => e.startsWith('add')), isEmpty);

    await tapKey(tester, 'website-add');
    await tester.tap(find.text(tr.general.ok));
    await settle(tester);
    expect(repo.calls.where((e) => e.startsWith('add')), ['add:2003']);
    expect(find.text(w.added(name: 'Charlie')), findsOneWidget);
    expect(find.byKey(const ValueKey('website-lookup-result')), findsNothing, reason: 'the lookup is outdated');
    await reveal(tester, find.byKey(const ValueKey('website-row-2003')));
    expect(find.byKey(const ValueKey('website-row-2003')), findsOneWidget);
  });

  testWidgets('bad input is explained and nothing is requested', (tester) async {
    await pump(tester);
    await tester.enterText(
      find.byKey(const ValueKey('website-lookup-input')),
      'https://example.com/space-uid-2003.html',
    );
    await tapText(tester, w.lookup);
    expect(find.text(w.invalidInput), findsOneWidget);
    // The next message replaces the previous one at once instead of queueing behind it.
    await tester.enterText(find.byKey(const ValueKey('website-lookup-input')), '${_alice.uid}');
    await tapText(tester, w.lookup);
    expect(find.text(w.selfTarget), findsOneWidget);
    expect(find.text(w.invalidInput), findsNothing);
    expect(repo.calls, isEmpty);
  });

  testWidgets('editing the input hides the result and drops the answer of a pending lookup', (tester) async {
    await pump(tester);
    final input = find.byKey(const ValueKey('website-lookup-input'));
    await tester.enterText(input, '2003');
    await tapText(tester, w.lookup);
    expect(find.byKey(const ValueKey('website-add')), findsOneWidget);
    await tester.enterText(input, '2004');
    await settle(tester);
    expect(find.byKey(const ValueKey('website-lookup-result')), findsNothing);
    expect(find.byKey(const ValueKey('website-add')), findsNothing);

    // A slow answer for the old input never shows up next to the new one.
    repo.lookupGate = Completer<void>();
    await tapText(tester, w.lookup);
    await tester.enterText(input, '2003');
    await settle(tester);
    repo.lookupGate!.complete();
    await settle(tester);
    expect(repo.calls.where((e) => e.startsWith('lookup')), ['lookup:2003', 'lookup:2004']);
    expect(find.byKey(const ValueKey('website-lookup-result')), findsNothing);
    expect(find.byKey(const ValueKey('website-add')), findsNothing);

    // Refused input drops a shown result too.
    repo.lookupGate = null;
    await tapText(tester, w.lookup);
    expect(find.text(w.lookupResult(name: 'Charlie', uid: '2003')), findsOneWidget);
    await tester.enterText(input, 'abc');
    await tapText(tester, w.lookup);
    expect(find.byKey(const ValueKey('website-lookup-result')), findsNothing);
    expect(repo.calls.where((e) => e.startsWith('add')), isEmpty);
  });

  testWidgets('remove asks first; while it is sent the buttons are disabled', (tester) async {
    await pump(tester);
    await tapText(tester, w.load);
    repo.writeGate = Completer<void>();
    await tapKey(tester, 'website-remove-2001');
    expect(find.text(w.removeConfirmTitle(name: 'Alpha')), findsOneWidget);
    await tester.tap(find.text(tr.general.ok));
    await settle(tester);
    expect(repo.calls.where((e) => e.startsWith('remove')), ['remove:2001']);
    final other = tester.widget<TextButton>(find.byKey(const ValueKey('website-remove-2002')));
    expect(other.onPressed, isNull);

    repo.writeGate!.complete();
    await settle(tester);
    expect(find.text(w.removed(name: 'Alpha')), findsOneWidget);
    expect(find.byKey(const ValueKey('website-row-2001')), findsNothing);
    expect(repo.calls.where((e) => e.startsWith('remove')), hasLength(1));
  });

  testWidgets('an account switch closes the open confirmation; nothing is sent and the rows are cleared', (
    tester,
  ) async {
    await pump(tester);
    await tapText(tester, w.load);
    await tapKey(tester, 'website-remove-2001');
    expect(find.text(w.removeConfirmTitle(name: 'Alpha')), findsOneWidget);
    auth.switchTo(_bob);
    await settle(tester);
    expect(find.text(w.removeConfirmTitle(name: 'Alpha')), findsNothing, reason: "the old account's target is gone");
    expect(find.text(tr.general.ok), findsNothing);
    expect(find.text('Alpha'), findsNothing);
    expect(repo.calls.where((e) => e.startsWith('remove')), isEmpty);
    expect(find.byKey(const ValueKey('website-row-2001')), findsNothing, reason: "Alice's rows are not Bob's");
    expect(find.text(w.notLoaded), findsOneWidget);

    // The page still works for the new account.
    await tapText(tester, w.load);
    expect(repo.calls.last, 'list:${_bob.uid}');
  });

  testWidgets("an account switch removes this page's message naming the old account's user", (tester) async {
    await pump(tester);
    await tapText(tester, w.load);
    await tapKey(tester, 'website-remove-2001');
    await tester.tap(find.text(tr.general.ok));
    await settle(tester);
    expect(find.text(w.removed(name: 'Alpha')), findsOneWidget);
    auth.switchTo(_bob);
    await settle(tester);
    expect(find.text(w.removed(name: 'Alpha')), findsNothing);
  });

  for (final confirm in [false, true]) {
    testWidgets('account switch clears target during dialog exit (confirm=$confirm)', (tester) async {
      await pump(tester);
      await tapText(tester, w.load);
      repo.writeGate = Completer<void>();
      await tapKey(tester, 'website-remove-2001');
      await tester.tap(find.text(confirm ? tr.general.ok : tr.general.cancel));
      await tester.pump(const Duration(milliseconds: 20));
      auth.switchTo(_bob);
      await tester.pump();
      expect(find.text(w.removeConfirmTitle(name: 'Alpha')), findsNothing);
      repo.writeGate!.complete();
      await settle(tester);
      expect(repo.calls.where((e) => e.startsWith('remove')), hasLength(confirm ? 1 : 0));
      expect(find.text(w.removed(name: 'Alpha')), findsNothing);
    });
  }

  testWidgets('an account switch while the write is sent says the result is unconfirmed, not "nothing sent"', (
    tester,
  ) async {
    await pump(tester);
    await tapText(tester, w.load);
    repo.writeGate = Completer<void>();
    await tapKey(tester, 'website-remove-2001');
    await tester.tap(find.text(tr.general.ok));
    await settle(tester);
    expect(repo.calls.where((e) => e.startsWith('remove')), ['remove:2001']);
    auth.switchTo(_bob);
    await settle(tester);
    repo.writeGate!.complete();
    await settle(tester);
    expect(find.text(w.staleUnconfirmed), findsOneWidget);
    expect(find.text(w.stale), findsNothing);
    expect(find.text(w.removed(name: 'Alpha')), findsNothing);
    expect(repo.calls.where((e) => e.startsWith('remove')), hasLength(1), reason: 'never retried');
  });

  testWidgets('import copies one user into the local list and keeps the others', (tester) async {
    await tester.runAsync(() => blocks.block(ownerUid: _alice.uid, uid: 3001, username: 'Local'));
    await pump(tester);
    await tapText(tester, w.load);
    await tapKey(tester, 'website-import-2001');
    expect(find.text(w.imported(name: 'Alpha')), findsOneWidget);
    expect(find.text('UID 2001 · ${w.stateBoth}'), findsOneWidget);
    expect(find.byKey(const ValueKey('website-import-2001')), findsNothing);
    final stored = await tester.runAsync(() => blocks.load(_alice.uid));
    expect(stored!.uids, {2001, 3001});
    expect(repo.calls.where((e) => !e.startsWith('list')), isEmpty, reason: 'import never writes to the forum');
  });

  testWidgets('an incomplete website list offers no import and says why', (tester) async {
    repo.complete = false;
    await pump(tester);
    await tapText(tester, w.load);
    expect(find.text(w.incomplete), findsOneWidget);
    expect(find.text(w.countPartial(count: '2')), findsOneWidget, reason: 'the rows read are not the total');
    expect(find.text(w.count(count: '2')), findsNothing);
    expect(find.byKey(const ValueKey('website-import-2001')), findsNothing);
    expect(find.text(w.localOnly(count: '0')), findsNothing, reason: 'local-only is unknown against a partial list');
  });

  testWidgets('no rows on an incomplete list is not called empty', (tester) async {
    repo
      ..listed.clear()
      ..complete = false;
    await pump(tester);
    await tapText(tester, w.load);
    expect(find.text(w.incomplete), findsOneWidget);
    expect(find.text(w.empty), findsNothing);
    expect(find.text(w.countPartial(count: '0')), findsOneWidget);

    repo.complete = true;
    await tapText(tester, w.reload);
    await reveal(tester, find.text(w.empty));
    expect(find.text(w.empty), findsOneWidget);
    expect(find.text(w.count(count: '0')), findsOneWidget);
  });

  for (final (name, size) in [('phone', const Size(360, 740)), ('desktop', const Size(1280, 800))]) {
    testWidgets('large text stays readable on $name', (tester) async {
      tester.view
        ..physicalSize = size
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pump(tester, textScale: 2);
      await tapText(tester, w.load);
      expect(tester.takeException(), isNull);
      for (final key in ['website-row-2001', 'website-remove-2001', 'website-row-2002', 'website-remove-2002']) {
        await reveal(tester, find.byKey(ValueKey(key)));
        expect(find.byKey(ValueKey(key)).hitTestable(), findsOneWidget, reason: key);
        expect(tester.takeException(), isNull, reason: key);
      }
      await tapKey(tester, 'website-remove-2002');
      expect(find.text(w.removeConfirmTitle(name: 'Bravo')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the blocking page links the website blacklist and keeps the local list and notice rules', (
    tester,
  ) async {
    await pump(tester, page: UserBlockPage(clientFactory: _client));
    expect(find.byKey(const ValueKey('website-blocklist-entry')), findsOneWidget);
    expect(find.text(w.entry), findsOneWidget);
    expect(find.text(tr.userBlock.serverRules.title), findsWidgets);
    expect(find.text(tr.userBlock.empty), findsOneWidget);
  });
}

Translations get tr => LocaleSettings.instance.currentTranslations;

/// Strings of the page, read when used (the locale is set in `setUpAll`).
TranslationsUserBlockWebsiteEn get w => tr.userBlock.website;

/// The page's own vertical list (the lookup input has a horizontal scrollable of its own).
Finder get _pageScrollable => find.byWidgetPredicate((e) => e is Scrollable && e.axis == Axis.vertical).first;

/// Bring [finder] on screen and finish scrolling before tapping. These actions start from an idle page; the
/// separate [settle] helper handles pending request spinners after a tap.
Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(finder, 120, scrollable: _pageScrollable);
  }
  await tester.ensureVisible(finder.first);
  await tester.pumpAndSettle();
}

/// Let database work and futures finish outside the fake zone, then build the frames it caused.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 20));
  }
}
