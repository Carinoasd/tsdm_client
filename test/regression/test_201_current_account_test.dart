import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rxdart/rxdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/homepage/widgets/user_operation_dialog.dart';
import 'package:tsdm_client/features/multi_user/cubit/current_account_cubit.dart';
import 'package:tsdm_client/features/multi_user/widgets/current_account_avatar.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/heroes.dart';

/// GitHub #184: users with several accounts replied with the wrong one, only the homepage showed the avatar. Pages now
/// show the account in use (`CurrentAccountCubit` and its widgets) once more than one account is saved; with a single
/// account nothing changes.
const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);

const _buttonKey = ValueKey<String>('current_account_avatar_button');
const _chipKey = ValueKey<String>('current_account_chip');

/// The check page as served to a logged-in account.
String _loggedPage(UserLoginInfo user) =>
    '<div id="inner_stat"><strong><a href="home.php?uid=${user.uid}">${user.username}</a></strong></div>';

Map<String, String> _cookieOf(UserLoginInfo user) => {
  '.domains': '{"${user.username}":1}',
  'Ystv_2132_auth': user.username!.toLowerCase(),
};

/// Answers every request with [body].
final class _FixedAdapter implements HttpClientAdapter {
  _FixedAdapter(this.body);

  final String body;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    body,
    200,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=utf-8'],
    },
  );

  @override
  void close({bool force = false}) {}
}

/// Never answers: avatars are not loaded in these tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Saved accounts that are only users: the cubit only counts them.
List<UserLoginInfo> _accounts(int n) => [for (var i = 0; i < n; i++) UserLoginInfo(username: 'U$i', uid: 2000 + i)];

/// The cubit fed by controllers, with the account in use in [current] (re-read on every auth event, like the app's
/// `() => auth.currentUser`).
final class _Harness {
  _Harness({UserLoginInfo? user = _alice}) : current = user {
    cubit = CurrentAccountCubit(currentUser: () => current, authStatus: auth.stream, accounts: accounts.stream);
  }

  UserLoginInfo? current;
  final auth = StreamController<AuthStatus>.broadcast();
  final accounts = StreamController<List<UserLoginInfo>>.broadcast();
  late final CurrentAccountCubit cubit;

  Future<void> dispose() async {
    await cubit.close();
    await auth.close();
    await accounts.close();
  }
}

/// Polls [condition] until it holds; drift streams answer on a later event loop turn.
Future<void> _until(bool Function() condition, {String? reason}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting${reason == null ? '' : ': $reason'}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  group('CurrentAccountState', () {
    test('shows the account only when logged in with a username and more than one account saved', () {
      expect(const CurrentAccountState().showsAccount, isFalse);
      expect(const CurrentAccountState(user: _alice).showsAccount, isFalse);
      expect(const CurrentAccountState(user: _alice, accountCount: 1).showsAccount, isFalse);
      expect(const CurrentAccountState(user: _alice, accountCount: 2).showsAccount, isTrue);
      expect(const CurrentAccountState(accountCount: 2).showsAccount, isFalse, reason: 'logged out');
      expect(
        const CurrentAccountState(user: UserLoginInfo(username: '', uid: 1000), accountCount: 2).showsAccount,
        isFalse,
        reason: 'empty username',
      );
      expect(
        const CurrentAccountState(user: UserLoginInfo(username: null, uid: 1000), accountCount: 2).showsAccount,
        isFalse,
        reason: 'no username',
      );
    });

    test('username and avatar url follow the user', () {
      const state = CurrentAccountState(user: _alice, accountCount: 2);
      expect(state.username, 'Alice');
      expect(state.avatarUrl, avatarUrlOfUid('1000'));
      expect(state.avatarUrl, endsWith('/data/avatar/000/00/10/00_avatar_middle.jpg'));
      expect(const CurrentAccountState().username, '');
      expect(const CurrentAccountState().avatarUrl, isNull);
      expect(
        const CurrentAccountState(user: UserLoginInfo(username: 'X', uid: null)).avatarUrl,
        isNull,
        reason: 'no uid',
      );
    });

    test('equal by uid, username and count', () {
      expect(
        const CurrentAccountState(user: _alice, accountCount: 2),
        const CurrentAccountState(user: UserLoginInfo(username: 'Alice', uid: 1000), accountCount: 2),
      );
      expect(
        const CurrentAccountState(user: _alice, accountCount: 2).hashCode,
        const CurrentAccountState(user: UserLoginInfo(username: 'Alice', uid: 1000), accountCount: 2).hashCode,
      );
      expect(
        const CurrentAccountState(user: _alice, accountCount: 2) ==
            const CurrentAccountState(user: _bob, accountCount: 2),
        isFalse,
      );
      expect(
        const CurrentAccountState(user: _alice, accountCount: 2) ==
            const CurrentAccountState(user: UserLoginInfo(username: 'Alice2', uid: 1000), accountCount: 2),
        isFalse,
        reason: 'renamed account',
      );
      expect(
        const CurrentAccountState(user: _alice, accountCount: 2) == const CurrentAccountState(user: _alice),
        isFalse,
      );
    });
  });

  group('CurrentAccountCubit', () {
    late _Harness h;

    tearDown(() async => h.dispose());

    test('starts with the current user and no saved account', () {
      h = _Harness();
      expect(h.cubit.state.user, _alice);
      expect(h.cubit.state.accountCount, 0);
      expect(h.cubit.state.showsAccount, isFalse);
    });

    test('starts logged out when there is no current user', () {
      h = _Harness(user: null);
      expect(h.cubit.state.user, isNull);
      expect(h.cubit.state.username, '');
      expect(h.cubit.state.showsAccount, isFalse);
    });

    test('shows the account only once a second account is saved', () async {
      h = _Harness();
      h.accounts.add(const []);
      await pumpEventQueue();
      expect(h.cubit.state.accountCount, 0);
      expect(h.cubit.state.showsAccount, isFalse);

      h.accounts.add(_accounts(1));
      await pumpEventQueue();
      expect(h.cubit.state.accountCount, 1);
      expect(h.cubit.state.showsAccount, isFalse, reason: 'a single account: nothing to confuse');

      h.accounts.add(_accounts(2));
      await pumpEventQueue();
      expect(h.cubit.state.accountCount, 2);
      expect(h.cubit.state.showsAccount, isTrue);
      expect(h.cubit.state.username, 'Alice');
    });

    test('hides the account when logged out, even with two saved accounts', () async {
      h = _Harness(user: null);
      h.accounts.add(_accounts(2));
      await pumpEventQueue();
      expect(h.cubit.state.accountCount, 2);
      expect(h.cubit.state.showsAccount, isFalse);
    });

    test('hides the account when the username is empty', () async {
      h = _Harness(user: const UserLoginInfo(username: '', uid: 1000));
      h.accounts.add(_accounts(2));
      await pumpEventQueue();
      expect(h.cubit.state.showsAccount, isFalse);
    });

    test('follows a switch of account on the next auth event, the avatar follows the uid', () async {
      h = _Harness();
      h.accounts.add(_accounts(2));
      await pumpEventQueue();
      expect(h.cubit.state.avatarUrl, avatarUrlOfUid('1000'));

      final seen = <CurrentAccountState>[];
      final sub = h.cubit.stream.listen(seen.add);
      addTearDown(sub.cancel);

      // The repository sets the user before announcing it.
      h.current = _bob;
      h.auth.add(const AuthStatusAuthed(_bob));
      await pumpEventQueue();
      expect(h.cubit.state.user, _bob);
      expect(h.cubit.state.username, 'Bob');
      expect(h.cubit.state.accountCount, 2, reason: 'the count is kept across auth events');
      expect(h.cubit.state.showsAccount, isTrue);
      expect(h.cubit.state.avatarUrl, avatarUrlOfUid('1001'));
      expect(h.cubit.state.avatarUrl, isNot(avatarUrlOfUid('1000')));

      // An auth event that changes nothing does not rebuild the pages.
      h.auth.add(const AuthStatusAuthed(_bob));
      await pumpEventQueue();
      expect(seen, hasLength(1));

      // Logging out hides it again.
      h.current = null;
      h.auth.add(const AuthStatusNotAuthed());
      await pumpEventQueue();
      expect(h.cubit.state.user, isNull);
      expect(h.cubit.state.showsAccount, isFalse);
      expect(h.cubit.state.accountCount, 2);
      expect(seen, hasLength(2));
    });

    test('an accounts event re-reads the current user too', () async {
      h = _Harness()..current = _bob;
      h.accounts.add(_accounts(2));
      await pumpEventQueue();
      expect(h.cubit.state.user, _bob);
    });

    test('hides the account when the saved accounts shrink from 2 to 1', () async {
      h = _Harness();
      h.accounts.add(_accounts(2));
      await pumpEventQueue();
      expect(h.cubit.state.showsAccount, isTrue);

      h.accounts.add(_accounts(1));
      await pumpEventQueue();
      expect(h.cubit.state.accountCount, 1);
      expect(h.cubit.state.showsAccount, isFalse);
      expect(h.cubit.state.user, _alice, reason: 'still logged in');
    });

    test('close cancels both subscriptions; later events are ignored', () async {
      h = _Harness();
      h.accounts.add(_accounts(2));
      await pumpEventQueue();
      expect(h.auth.hasListener, isTrue);
      expect(h.accounts.hasListener, isTrue);
      final before = h.cubit.state;

      await h.cubit.close();
      expect(h.cubit.isClosed, isTrue);
      expect(h.auth.hasListener, isFalse);
      expect(h.accounts.hasListener, isFalse);

      // Nothing listens any more: no emit after close, no StateError.
      h.current = _bob;
      h.auth.add(const AuthStatusAuthed(_bob));
      h.accounts.add(_accounts(5));
      await pumpEventQueue();
      expect(h.cubit.state, before);
    });

    test('an event already queued when close starts does not emit after close', () async {
      // A single-subscription source delivers the queued event even while the cancel is pending.
      final auth = StreamController<AuthStatus>();
      final accounts = StreamController<List<UserLoginInfo>>();
      final cubit = CurrentAccountCubit(
        currentUser: () => _alice,
        authStatus: auth.stream,
        accounts: accounts.stream,
      );
      auth.add(const AuthStatusAuthed(_alice));
      accounts.add(_accounts(2));
      await cubit.close();
      await pumpEventQueue();
      expect(cubit.isClosed, isTrue);
      await auth.close();
      await accounts.close();
    });

    test('works on the replaying auth stream of the repository (BehaviorSubject.asBroadcastStream)', () async {
      // `AuthenticationRepository.status` is `BehaviorSubject.asBroadcastStream()`: a new subscriber gets the last
      // event again. That replay only re-reads the user, it changes nothing.
      final subject = BehaviorSubject<AuthStatus>.seeded(const AuthStatusAuthed(_alice));
      addTearDown(subject.close);
      final accounts = StreamController<List<UserLoginInfo>>.broadcast();
      addTearDown(accounts.close);
      UserLoginInfo? current = _alice;
      final cubit = CurrentAccountCubit(
        currentUser: () => current,
        authStatus: subject.asBroadcastStream(),
        accounts: accounts.stream,
      );
      final seen = <CurrentAccountState>[];
      final sub = cubit.stream.listen(seen.add);
      await pumpEventQueue();
      // Bloc lets the first emit through even when equal, so the replay may repeat the initial state once.
      expect(seen.length, lessThanOrEqualTo(1));
      expect(seen, everyElement(const CurrentAccountState(user: _alice)), reason: 'the replay changes nothing');

      accounts.add(_accounts(2));
      await pumpEventQueue();
      current = _bob;
      subject.add(const AuthStatusAuthed(_bob));
      await pumpEventQueue();
      expect(cubit.state.user, _bob);
      expect(cubit.state.showsAccount, isTrue);

      await sub.cancel();
      await cubit.close();
      subject.add(const AuthStatusNotAuthed());
      await pumpEventQueue();
      expect(cubit.state.user, _bob, reason: 'closed');
    });
  });

  group('with the real StorageProvider and AuthenticationRepository', () {
    setUp(TsdmAppApi.markUnavailable);

    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
      await settings.init();
    });

    tearDown(() async {
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    test('saving the cookies of two accounts counts 2, deleting one counts 1', () async {
      final cubit = CurrentAccountCubit(
        currentUser: () => _alice,
        authStatus: const Stream.empty(),
        accounts: storage.allUsersStream(),
      );
      addTearDown(cubit.close);

      // The empty table is announced as well.
      await _until(() => cubit.state.accountCount == 0 && !cubit.state.showsAccount);

      await storage.saveCookie(username: 'Alice', uid: 1000, cookie: _cookieOf(_alice));
      await _until(() => cubit.state.accountCount == 1, reason: 'one account');
      expect(cubit.state.showsAccount, isFalse);

      // A cookie without the auth entry is not a saved account.
      await storage.saveCookie(username: 'Bob', uid: 1001, cookie: {'.domains': '{"Bob":1}'});
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cubit.state.accountCount, 1);

      await storage.saveCookie(username: 'Bob', uid: 1001, cookie: _cookieOf(_bob));
      await _until(() => cubit.state.accountCount == 2, reason: 'two accounts');
      expect(cubit.state.showsAccount, isTrue);
      expect(cubit.state.username, 'Alice');

      // Saving the cookie again (a Set-Cookie) keeps the count.
      await storage.saveCookie(username: 'Bob', uid: 1001, cookie: {'Ystv_2132_saltkey': 'x'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(cubit.state.accountCount, 2);

      expect(await storage.deleteCookiesByUids([1001]), 1);
      await _until(() => cubit.state.accountCount == 1, reason: 'one account left');
      expect(cubit.state.showsAccount, isFalse);
    });

    test('wired like the app: switching account shows the new one, forgetting it hides the chip', () async {
      for (final u in [_alice, _bob]) {
        await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: _cookieOf(u));
      }
      await settings.setValue<int>(SettingsKeys.loginUid, 1000);
      await settings.setValue<String>(SettingsKeys.loginUsername, 'Alice');
      getIt.registerSingleton<CookieProvider>(CookieProvider(_alice, _cookieOf(_alice)));

      final auth = AuthenticationRepository(
        user: _alice,
        clientFactory: (cookie) => NetClientProvider.buildNoCookie(
          dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _FixedAdapter(_loggedPage(_bob)),
          cookie: cookie,
        ),
      );
      addTearDown(auth.dispose);
      // Same arguments as lib/app.dart.
      final cubit = CurrentAccountCubit(
        currentUser: () => auth.effectiveCurrentUser,
        authStatus: auth.status,
        accounts: getIt.get<StorageProvider>().allUsersStream(),
      );
      addTearDown(cubit.close);

      await _until(() => cubit.state.accountCount == 2);
      expect(cubit.state.user?.uid, 1000);
      expect(cubit.state.showsAccount, isTrue);
      expect(cubit.state.avatarUrl, avatarUrlOfUid('1000'));

      final switched = await auth.switchUser(_bob).run();
      expect(switched.isRight(), isTrue, reason: '$switched');
      await _until(() => cubit.state.user?.uid == 1001, reason: 'switched to Bob');
      expect(cubit.state.username, 'Bob');
      expect(cubit.state.avatarUrl, avatarUrlOfUid('1001'));
      expect(cubit.state.accountCount, 2);
      expect(cubit.state.showsAccount, isTrue);

      // Removing the account in use signs this device out and drops its row.
      final forgot = await auth.forgetCurrentUser().run();
      expect(forgot.isRight(), isTrue, reason: '$forgot');
      await _until(() => cubit.state.user == null && cubit.state.accountCount == 1, reason: 'Bob forgotten');
      expect(cubit.state.showsAccount, isFalse);
    });
    test('an offline start, before the session is verified, still names the account the cookie belongs to', () async {
      for (final u in [_alice, _bob]) {
        await storage.saveCookie(username: u.username!, uid: u.uid!, cookie: _cookieOf(u));
      }
      await settings.setValue<int>(SettingsKeys.loginUid, 1000);
      await settings.setValue<String>(SettingsKeys.loginUsername, 'Alice');
      getIt.registerSingleton<CookieProvider>(CookieProvider(_alice, _cookieOf(_alice)));
      final auth = AuthenticationRepository();
      addTearDown(auth.dispose);
      expect(auth.currentUser, isNull, reason: 'nothing verified the session yet');
      expect(auth.effectiveCurrentUser?.uid, 1000);
      expect(auth.effectiveCurrentUser?.username, 'Alice');

      // Only the settings name the account (the cookie provider is empty).
      await getIt.unregister<CookieProvider>();
      getIt.registerSingleton<CookieProvider>(CookieProvider.buildEmpty());
      expect(auth.effectiveCurrentUser?.uid, 1000);

      // No account in use at all.
      await settings.setValue<int>(SettingsKeys.loginUid, 0);
      await settings.setValue<String>(SettingsKeys.loginUsername, '');
      expect(auth.effectiveCurrentUser, isNull);
    });
  });

  group('widgets', () {
    late AppDatabase db;
    late StorageProvider storage;
    late SettingsRepository settings;
    late _Harness h;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
      await settings.init();
      getIt.registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    });

    tearDown(() async {
      await getIt.get<ImageCacheProvider>().dispose();
      await getIt.reset();
      await settings.dispose();
      await db.close();
    });

    /// An app bar with the button and a body with the chip, like a page and an editor.
    Widget page() => Scaffold(
      appBar: AppBar(title: const Text('page'), actions: const [CurrentAccountAvatarButton()]),
      body: const Center(child: CurrentAccountChip()),
    );

    Future<void> pump(WidgetTester tester, {bool provided = true}) async {
      // Built inside the test zone so the controllers deliver on the tester's pumps.
      h = _Harness();
      final app = MaterialApp(home: page());
      addTearDown(h.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: provided ? BlocProvider<CurrentAccountCubit>.value(value: h.cubit, child: app) : app,
        ),
      );
      await tester.pump();
    }

    /// The event reaches the cubit on one pump and the rebuilt widgets on the next.
    Future<void> settle(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
    }

    Future<void> setAccounts(WidgetTester tester, int n) async {
      h.accounts.add(_accounts(n));
      await settle(tester);
    }

    void expectHidden(WidgetTester tester) {
      expect(find.byKey(_buttonKey), findsNothing);
      expect(find.byKey(_chipKey), findsNothing);
      expect(find.byType(HeroUserAvatar), findsNothing);
      expect(find.byType(IconButton), findsNothing);
      expect(find.text('Alice'), findsNothing);
      expect(tester.takeException(), isNull);
    }

    testWidgets('nothing without a provided cubit', (tester) async {
      await pump(tester, provided: false);
      expect(find.text('page'), findsOneWidget);
      expectHidden(tester);
    });

    testWidgets('nothing with no or a single saved account', (tester) async {
      await pump(tester);
      expectHidden(tester);
      await setAccounts(tester, 1);
      expect(h.cubit.state.accountCount, 1);
      expectHidden(tester);
    });

    testWidgets('nothing when logged out with two accounts', (tester) async {
      await pump(tester);
      await setAccounts(tester, 2);
      h.current = null;
      h.auth.add(const AuthStatusNotAuthed());
      await settle(tester);
      expectHidden(tester);
      // Let the avatar load started while Alice was shown fail.
      await tester.pumpAndSettle();
    });

    testWidgets('two accounts: the button names the account in its tooltip, the chip shows the name', (tester) async {
      await pump(tester);
      await setAccounts(tester, 2);

      final button = find.byKey(_buttonKey);
      expect(button, findsOneWidget);
      final tooltip = tester.widget<IconButton>(button).tooltip;
      expect(tooltip, contains('Alice'));
      expect(tooltip, 'Current account: Alice');
      expect(find.byTooltip('Current account: Alice'), findsOneWidget);

      final chip = find.byKey(_chipKey);
      expect(chip, findsOneWidget);
      expect(find.descendant(of: chip, matching: find.text('Alice')), findsOneWidget);
      expect(tester.widget<Tooltip>(chip).message, 'Posting as Alice');

      final avatars = tester.widgetList<HeroUserAvatar>(find.byType(HeroUserAvatar)).toList();
      expect(avatars, hasLength(2));
      expect(avatars.map((e) => e.username), everyElement('Alice'));
      expect(avatars.map((e) => e.avatarUrl), everyElement(avatarUrlOfUid('1000')));
      expect(
        tester.widget<HeroUserAvatar>(find.descendant(of: chip, matching: find.byType(HeroUserAvatar))).disableHero,
        isTrue,
        reason: 'the chip never takes part in hero flights',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching the account changes the name shown', (tester) async {
      await pump(tester);
      await setAccounts(tester, 2);
      expect(find.text('Alice'), findsOneWidget);

      h.current = _bob;
      h.auth.add(const AuthStatusAuthed(_bob));
      await settle(tester);

      expect(find.text('Alice'), findsNothing);
      expect(find.descendant(of: find.byKey(_chipKey), matching: find.text('Bob')), findsOneWidget);
      expect(tester.widget<IconButton>(find.byKey(_buttonKey)).tooltip, 'Current account: Bob');
      final avatars = tester.widgetList<HeroUserAvatar>(find.byType(HeroUserAvatar)).toList();
      expect(avatars.map((e) => e.username), everyElement('Bob'));
      expect(avatars.map((e) => e.avatarUrl), everyElement(avatarUrlOfUid('1001')));

      // Down to one account: hidden again.
      await setAccounts(tester, 1);
      expect(find.byKey(_buttonKey), findsNothing);
      expect(find.byKey(_chipKey), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the button opens the user operations of the account in use', (tester) async {
      await pump(tester);
      await setAccounts(tester, 2);

      await tester.tap(find.byKey(_buttonKey));
      await tester.pumpAndSettle();

      final dialog = find.byType(UserOperationDialog);
      expect(dialog, findsOneWidget);
      final widget = tester.widget<UserOperationDialog>(dialog);
      expect(widget.username, 'Alice');
      expect(widget.avatarUrl, avatarUrlOfUid('1000'));
      expect(widget.heroTag, 'CurrentAccount_Alice');
      expect(widget.latestThreadUrl, isNull);
      expect(find.descendant(of: dialog, matching: find.text('Alice')), findsOneWidget);
      expect(find.descendant(of: dialog, matching: find.text('Manage accounts')), findsOneWidget);
      final latest = find.descendant(of: dialog, matching: find.widgetWithText(ListTile, 'Latest threads'));
      expect(tester.widget<ListTile>(latest).onTap, isNull, reason: 'only the homepage knows the latest thread');

      // The barrier closes it.
      await tester.tapAt(const Offset(5, 590));
      await tester.pumpAndSettle();
      expect(find.byType(UserOperationDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
