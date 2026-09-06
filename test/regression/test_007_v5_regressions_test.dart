import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/bloc/authentication_bloc.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/authentication/view/login_page.dart';
import 'package:tsdm_client/features/authentication/widgets/login_form.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/repository/auto_checkin_repository.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/html/review_parser.dart';
import 'package:tsdm_client/widgets/card/review_card.dart';
import 'package:universal_html/parsing.dart';

class _LoginRepository extends AuthenticationRepository {
  int fetches = 0;
  bool failFetch = true;
  final pending = <Completer<Either<AppException, LoginHash>>>[];

  @override
  AsyncEither<LoginHash> fetchHash() => AsyncEither(() async {
    fetches++;
    // Bound the broken retry loop so the original implementation fails fast.
    if (failFetch && fetches == 1) return left(LoginFormHashNotFoundException());
    if (failFetch) {
      final completer = Completer<Either<AppException, LoginHash>>();
      pending.add(completer);
      return completer.future;
    }
    return right(const LoginHash(formHash: 'hash', loginHash: 'login'));
  });

  @override
  AsyncVoidEither loginWithPassword(UserCredential credential) =>
      AsyncVoidEither(() async => left(LoginInvalidCredentialException()));

  void finishPending() {
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.complete(right(const LoginHash(formHash: 'hash', loginHash: 'login')));
      }
    }
  }
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDown(() async {
    await getIt.reset();
    await db.close();
  });

  test('review keeps nested text, links and line breaks without metadata', () {
    final cm = parseHtmlDocument('''
<div class="cm"><div class="pstl"><div class="psta"><a class="xi2">Alice</a></div>
<div class="psti">Read <a href="https://example.invalid">this link</a>, <b>important</b><br>next line<span class="xg1">posted today</span></div></div></div>
''').querySelector('div.cm')!;
    expect(parseReviewElement(cm).content, 'Read this link, important\nnext line');
  });

  testWidgets('renderer creates a card for every comment, including one without a heading', (tester) async {
    Future<List<ReviewCard>> render(String inner) async {
      final cards = <ReviewCard>[];
      void collect(InlineSpan span) {
        if (span is WidgetSpan && span.child is ReviewCard) cards.add(span.child as ReviewCard);
        if (span is TextSpan) {
          span.children?.forEach(collect);
        }
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              final body = parseHtmlDocument('<div class="cm">$inner</div>').body!;
              final rendered = munchElement(context, body);
              if (rendered is ConstrainedBox && rendered.child is Text) {
                collect((rendered.child! as Text).textSpan!);
              }
              // Inspect the real renderer output without loading avatar URLs.
              return const SizedBox();
            },
          ),
        ),
      );
      return cards;
    }

    const first =
        '<div class="pstl"><div class="psta"><a class="xi2">Alice</a></div><div class="psti">first</div></div>';
    const second =
        '<div class="pstl"><div class="psta"><a class="xi2">Bob</a></div><div class="psti">second</div></div>';
    final cards = await render('<h3>Reviews</h3>$first$second');
    expect(cards.map((e) => (e.name, e.content)), [('Alice', 'first'), ('Bob', 'second')]);
    expect((await render(first)).single.content, 'first');
    expect(await render(''), isEmpty);
  });

  for (final failFetch in [true, false]) {
    testWidgets(failFetch ? 'login page stops after a failed form load' : 'failed login refreshes the form once', (
      tester,
    ) async {
      final repo = _LoginRepository()..failFetch = failFetch;
      final notices = NotificationRepository();
      final auto = AutoNotificationCubit(
        authenticationRepository: repo,
        notificationRepository: notices,
        storageProvider: storage,
      );
      addTearDown(() async {
        repo.finishPending();
        await auto.close();
        await repo.dispose();
        await notices.dispose();
      });
      await tester.pumpWidget(
        RepositoryProvider<AuthenticationRepository>.value(
          value: repo,
          child: BlocProvider<AutoNotificationCubit>.value(
            value: auto,
            child: TranslationProvider(child: const MaterialApp(home: LoginPage())),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      if (!failFetch) {
        final context = tester.element(find.byType(LoginForm));
        context.read<AuthenticationBloc>().add(
          const AuthenticationLoginRequested(
            UserCredential(loginField: LoginField.username, loginFieldValue: 'test', password: 'wrong', tsdmVerify: ''),
          ),
        );
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }
      final fetches = repo.fetches;
      if (failFetch) {
        repo.failFetch = false;
        final retry = find.byType(FilledButton);
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(repo.fetches, 2);
        expect(
          tester.element(find.byType(LoginForm)).read<AuthenticationBloc>().state.status,
          AuthenticationStatus.gotHash,
        );
      }
      await tester.pumpWidget(const SizedBox());
      repo.finishPending();
      await tester.pump();
      expect(fetches, failFetch ? 1 : 2);
    });
  }

  test('batch checkin records missing cookies and continues to later groups', () async {
    final repo = AutoCheckinRepository(storageProvider: storage);
    final states = <AutoCheckinInfo>[];
    final sub = repo.status.listen(states.add);
    addTearDown(() async {
      await sub.cancel();
      await repo.dispose();
    });
    final users = List.generate(5, (i) => UserLoginInfo(username: 'user$i', uid: i + 1));
    final result = await repo
        .checkinAll(
          waitingList: users,
          skippedList: [],
          feeling: CheckinFeeling.from('kx'),
          message: 'test',
        )
        .run();
    await Future<void>.delayed(Duration.zero);
    expect(result.isRight(), isTrue);
    expect(states.last.running, isEmpty);
    expect(states.last.waiting, isEmpty);
    expect(states.last.failed.map((e) => e.$1.uid), users.map((e) => e.uid));
  });

  test('failed account verification preserves the current account cookie', () async {
    const alice = UserLoginInfo(username: 'Alice', uid: 1);
    const bob = UserLoginInfo(username: 'Bob', uid: 2);
    await storage.saveCookie(username: 'Alice', uid: 1, cookie: {'marker': 'Alice'});
    await storage.saveCookie(username: 'Bob', uid: 2, cookie: {'marker': 'Bob'});
    final current = CookieProvider(alice, {'marker': 'Alice'});
    getIt
      ..registerSingleton<CookieProvider>(current)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver());
    final settings = SettingsRepository(storage);
    await settings.init();
    getIt.registerSingleton<SettingsRepository>(settings);
    addTearDown(settings.dispose);
    NetClientProvider failingClient(CookieProvider cookie) {
      final dio = Dio()
        ..interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              handler.reject(DioException(requestOptions: options, type: DioExceptionType.connectionError));
            },
          ),
        );
      return NetClientProvider.buildNoCookie(dio: dio, cookie: cookie);
    }

    getIt.registerFactory<NetClientProvider>(() => failingClient(current));
    final repo = AuthenticationRepository(user: alice, clientFactory: failingClient);
    addTearDown(repo.dispose);
    expect((await repo.switchUser(bob).run()).isLeft(), isTrue);
    expect(repo.currentUser?.uid, alice.uid);
    expect(await current.read('marker'), 'Alice');
  });
}
