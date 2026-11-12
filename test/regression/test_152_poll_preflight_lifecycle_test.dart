import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/post/cubit/poll_create_cubit.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/repository/poll_create_repository.dart';
import 'package:tsdm_client/features/post/view/poll_create_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';

import 'poll_fixtures.dart';

// Fresh form check before the single POST, and the session lifetime around it. Synthetic data only.

PollDraft _draft({List<String> options = const ['Alpha', 'Beta', 'Gamma'], bool visible = false}) => PollDraft(
  subject: 'Synthetic poll',
  message: '',
  options: options,
  maxChoices: '1',
  expiry: '',
  visibleAfterVote: visible,
  publicVoters: false,
  threadType: null,
  extraOptions: const [],
);

Response<dynamic> _published() => pollResponse('', status: 301, location: 'forum.php?mod=viewthread&tid=321');

/// Form GETs are answered by [forms] in order (the last one repeats); a null entry stays pending on [pending].
final class _Env {
  _Env(this.forms);

  final List<String? Function()> forms;
  final pending = Completer<SyncEither<Response<dynamic>>>();
  int formGets = 0;
  int uid = 1000;
  int posts = 0;
  Map<String, String>? payload;
  final auth = StreamController<AuthStatus>.broadcast();

  late final repo = PollCreateRepository.withTransport(
    currentUid: () => uid,
    getPage: (url) {
      if (url.contains('viewthread')) return Future.value(right(pollResponse(pollThread())));
      final html = forms[formGets < forms.length ? formGets : forms.length - 1]();
      formGets++;
      return html == null ? pending.future : Future.value(right(pollResponse(html)));
    },
    sendForm: (_, body) {
      posts++;
      payload = body;
      return Future.value(right<AppException, Response<dynamic>>(_published()));
    },
  );

  bool active = true;
  late final cubit = PollCreateCubit(repository: repo, fid: '4', authChanges: auth.stream, isActive: () => active);

  Future<void> reviewed(PollDraft draft) async {
    await cubit.load();
    expect(cubit.state.status, PollCreateStatus.editing);
    expect(cubit.review(draft)!.isValid, isTrue);
  }

  Future<void> close() async {
    await cubit.close();
    await auth.close();
  }
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

/// `FilledButton.icon` builds a subclass, so match by predicate; the app bar title has the same text.
final _createButton = find.ancestor(
  of: find.text('Create poll'),
  matching: find.byWidgetPredicate((widget) => widget is FilledButton),
);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('fresh form check', () {
    test('a refreshed token and post time are used for the one POST', () async {
      final env = _Env([
        pollForm,
        () => pollForm().replaceFirst('synthetic-token', 'fresh-token').replaceFirst('1700000000', '1700000100'),
      ]);
      addTearDown(env.close);
      await env.reviewed(_draft());
      await env.cubit.confirm();
      expect(env.formGets, 2);
      expect(env.posts, 1);
      expect(env.payload!['formhash'], 'fresh-token');
      expect(env.payload!['posttime'], '1700000100');
      expect(env.payload!['polloptions'], 'Alpha\nBeta\nGamma');
      expect(env.cubit.state.status, PollCreateStatus.published);
    });

    test('a reduced choice limit stops before POST and keeps the input for review again', () async {
      final env = _Env([pollForm, () => pollForm(maxOptionsScript: "var maxoptions = parseInt('2');")]);
      addTearDown(env.close);
      await env.reviewed(_draft());
      await env.cubit.confirm();
      expect(env.posts, 0);
      expect(env.cubit.state.status, PollCreateStatus.preflightFailed);
      expect(env.cubit.state.preflight, PollPreflightKind.changed);
      expect(env.cubit.state.form!.maxOptions, 2);
      expect(env.cubit.state.interruptedSubmit, isFalse);
      // Review again against the fresh form: the extra choice is reported, never silently dropped.
      expect(env.cubit.review(_draft())!.issues, contains(PollInputIssue.tooManyOptions));
      expect(env.cubit.review(_draft(options: ['Alpha', 'Beta']))!.isValid, isTrue);
      await env.cubit.confirm();
      expect(env.posts, 1);
    });

    test('a flag the fresh form no longer offers stops before POST', () async {
      final env = _Env([pollForm, () => pollForm(flags: '')]);
      addTearDown(env.close);
      await env.reviewed(_draft(visible: true));
      await env.cubit.confirm();
      expect(env.posts, 0);
      expect(env.cubit.state.preflight, PollPreflightKind.changed);
    });

    test('a failed check posts nothing and an explicit retry is safe', () async {
      var fail = false;
      var posts = 0;
      final repo = PollCreateRepository.withTransport(
        currentUid: () => 1000,
        getPage: (_) async => fail ? left(HttpRequestFailedException(500)) : right(pollResponse(pollForm())),
        sendForm: (_, _) async {
          posts++;
          return right(_published());
        },
      );
      final cubit = PollCreateCubit(repository: repo, fid: '4');
      addTearDown(cubit.close);
      await cubit.load();
      cubit.review(_draft());
      fail = true;
      await cubit.confirm();
      expect(posts, 0);
      expect(cubit.state.status, PollCreateStatus.preflightFailed);
      expect(cubit.state.preflight, PollPreflightKind.failed);
      fail = false;
      expect(cubit.review(_draft())!.isValid, isTrue);
      await cubit.confirm();
      expect(posts, 1);
    });
  });

  group('pending check', () {
    test('closing while the check is pending never posts', () async {
      final env = _Env([pollForm, () => null]);
      addTearDown(env.auth.close);
      await env.reviewed(_draft());
      final confirming = env.cubit.confirm();
      await _tick();
      expect(env.cubit.state.status, PollCreateStatus.checking);
      await env.cubit.close();
      env.pending.complete(right(pollResponse(pollForm())));
      await confirming;
      expect(env.posts, 0);
    });

    test('leaving the route while the check is pending never posts', () async {
      final env = _Env([pollForm, () => null]);
      addTearDown(env.close);
      await env.reviewed(_draft());
      final confirming = env.cubit.confirm();
      await _tick();
      env.active = false;
      env.pending.complete(right(pollResponse(pollForm())));
      await confirming;
      expect(env.posts, 0);
      expect(env.cubit.canConfirm, isFalse);
    });

    test('going back during the check cancels it; a late answer does not post', () async {
      final env = _Env([pollForm, () => null, pollForm]);
      addTearDown(env.close);
      await env.reviewed(_draft());
      final confirming = env.cubit.confirm();
      await _tick();
      env.cubit.cancelReview();
      expect(env.cubit.state.status, PollCreateStatus.editing);
      env.pending.complete(right(pollResponse(pollForm())));
      await confirming;
      expect(env.posts, 0);
      expect(env.cubit.state.status, PollCreateStatus.editing);
    });

    test('A to B to A during the check posts nothing and is not reported as a sent request', () async {
      final env = _Env([pollForm, () => null]);
      addTearDown(env.close);
      await env.reviewed(_draft());
      final confirming = env.cubit.confirm();
      await _tick();
      env
        ..uid = 1001
        ..auth.add(const AuthStatusAuthed(UserLoginInfo(uid: 1001, username: 'B')));
      await _tick();
      env
        ..uid = 1000
        ..auth.add(const AuthStatusAuthed(UserLoginInfo(uid: 1000, username: 'A')));
      await _tick();
      env.pending.complete(right(pollResponse(pollForm())));
      await confirming;
      expect(env.posts, 0);
      expect(env.cubit.state.status, PollCreateStatus.identityChanged);
      expect(env.cubit.state.interruptedSubmit, isFalse);
      expect(env.cubit.canConfirm, isFalse);
    });
  });

  group('page', () {
    Future<AuthenticationRepository> auth(WidgetTester tester) async {
      final repository = AuthenticationRepository(user: const UserLoginInfo(uid: 1000, username: 'Synthetic'));
      addTearDown(repository.dispose);
      await LocaleSettings.setLocale(AppLocale.en);
      return repository;
    }

    PollCreateRepository repo(_Env env) => env.repo;

    Future<void> scrollTo(WidgetTester tester, Finder finder) async {
      await tester.scrollUntilVisible(
        finder,
        120,
        scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)).first,
      );
      await tester.pump();
    }

    testWidgets('leaving while the fresh check is pending never posts', (tester) async {
      final env = _Env([pollForm, () => null]);
      addTearDown(env.auth.close);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        RepositoryProvider<AuthenticationRepository>.value(
          value: await auth(tester),
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigator,
              home: const Scaffold(body: Text('Underlying forum')),
            ),
          ),
        ),
      );
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => PollCreatePage(fid: '4', authChanges: env.auth.stream, repositoryBuilder: (_) => repo(env)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Subject'), 'Synthetic poll');
      await tester.enterText(find.widgetWithText(TextField, 'Choice 1'), 'Alpha');
      await tester.enterText(find.widgetWithText(TextField, 'Choice 2'), 'Beta');
      await scrollTo(tester, find.text('Review'));
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await scrollTo(tester, _createButton);
      await tester.tap(_createButton);
      await tester.pump();
      expect(env.formGets, 2, reason: 'The fresh form check is pending.');

      navigator.currentState!.pop();
      await tester.pump();
      env.pending.complete(right(pollResponse(pollForm())));
      await tester.pumpAndSettle();
      expect(env.posts, 0);
      expect(find.text('Underlying forum'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow phone with larger text: add choices, review, back and confirm', (tester) async {
      tester.view
        ..physicalSize = const Size(360, 800)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final env = _Env([pollForm]);
      addTearDown(env.auth.close);
      await tester.pumpWidget(
        RepositoryProvider<AuthenticationRepository>.value(
          value: await auth(tester),
          child: TranslationProvider(
            child: MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.3)),
                child: child!,
              ),
              home: PollCreatePage(fid: '4', authChanges: env.auth.stream, repositoryBuilder: (_) => repo(env)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Future<void> type(String label, String text) async {
        final field = find.widgetWithText(TextField, label);
        await scrollTo(tester, field);
        await tester.enterText(field, text);
        await tester.pump();
      }

      await type('Subject', 'Synthetic narrow poll');
      await type('Choice 1', 'Alpha');
      await type('Choice 2', 'Beta');
      await type('Choice 3', 'Gamma');
      await scrollTo(tester, find.text('Add choice'));
      await tester.tap(find.text('Add choice'));
      await tester.pump();
      await type('Choice 4', 'Delta');
      await scrollTo(tester, find.text('Review'));
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm poll'), findsOneWidget);
      expect(find.text('4. Delta'), findsOneWidget);

      await scrollTo(tester, find.text('Back to edit'));
      await tester.tap(find.text('Back to edit'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);
      expect(env.posts, 0);

      await scrollTo(tester, find.text('Review'));
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await scrollTo(tester, _createButton);
      await tester.tap(_createButton);
      await tester.pumpAndSettle();
      expect(env.posts, 1);
      expect(env.payload!['polloptions'], 'Alpha\nBeta\nGamma\nDelta');
      expect(find.textContaining('Poll published'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('switching to the ordinary editor carries subject and body and ends the poll session', (tester) async {
      final env = _Env([pollForm]);
      addTearDown(env.auth.close);
      Object? carried;
      final router = GoRouter(
        initialLocation: '/poll',
        routes: [
          GoRoute(
            path: '/poll',
            builder: (_, _) => PollCreatePage(
              fid: '4',
              transfer: const ThreadModeTransfer(uid: 1000, fid: '4', subject: 'Carried subject', body: 'Carried body'),
              authChanges: env.auth.stream,
              repositoryBuilder: (_) => repo(env),
            ),
          ),
          GoRoute(
            path: ScreenPaths.editPost,
            name: ScreenPaths.editPost,
            builder: (_, state) {
              carried = state.extra;
              return const Scaffold(body: Text('Ordinary editor'));
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        RepositoryProvider<AuthenticationRepository>.value(
          value: await auth(tester),
          child: TranslationProvider(child: MaterialApp.router(routerConfig: router)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Carried subject'), findsOneWidget);
      expect(find.text('Carried body'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'Subject'), 'Edited subject');
      await tester.pump();

      await tester.tap(find.byTooltip('Switch to normal thread'));
      await tester.pumpAndSettle();
      expect(find.text('Ordinary editor'), findsOneWidget);
      expect(find.byType(PollCreatePage), findsNothing);
      final transfer = carried! as ThreadModeTransfer;
      expect(transfer.subject, 'Edited subject');
      expect(transfer.body, 'Carried body');
      expect(transfer.appliesTo(uid: 1000, fid: '4'), isTrue);
      expect(env.posts, 0);
      expect(tester.takeException(), isNull);
    });
  });
}
