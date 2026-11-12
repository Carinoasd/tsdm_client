import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/repository/poll_create_repository.dart';
import 'package:tsdm_client/features/post/view/poll_create_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';

import 'poll_fixtures.dart';

/// Models the interval after the effective account changes but before auth.status is emitted.
final class _MutableAuth extends AuthenticationRepository {
  _MutableAuth() : super(user: const UserLoginInfo(uid: 1000, username: 'Synthetic A'));

  int uid = 1000;

  @override
  int get effectiveCurrentUid => uid;
}

const _privateSubject = 'Account A private subject';
const _privateBody = 'Account A private body';

final class _ModeHarness {
  final auth = _MutableAuth();
  Object? carried;
  int posts = 0;

  Future<void> open(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(1000, 2000)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(auth.dispose);
    await LocaleSettings.setLocale(AppLocale.en);
    final router = GoRouter(
      initialLocation: '/poll',
      routes: [
        GoRoute(
          path: '/poll',
          builder: (_, _) => PollCreatePage(
            fid: '4',
            repositoryBuilder: (currentUid) => PollCreateRepository.withTransport(
              currentUid: currentUid,
              getPage: (_) async => right(pollResponse(pollForm(uid: auth.uid))),
              sendForm: (_, _) async {
                posts++;
                throw StateError('A mode switch must never POST');
              },
            ),
          ),
        ),
        GoRoute(
          path: ScreenPaths.editPost,
          name: ScreenPaths.editPost,
          builder: (_, state) {
            carried = state.extra;
            return const Scaffold(body: Text('Ordinary editor destination'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      RepositoryProvider<AuthenticationRepository>.value(
        value: auth,
        child: TranslationProvider(child: MaterialApp.router(routerConfig: router)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Subject'), _privateSubject);
    await tester.enterText(find.widgetWithText(TextField, 'Body (optional)'), _privateBody);
    await tester.pump();
    expect(find.byTooltip('Switch to normal thread'), findsOneWidget);
  }
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  testWidgets('mode switch never relabels A input as B before the account event arrives', (tester) async {
    final harness = _ModeHarness();
    await harness.open(tester);

    // Do not emit auth.status: the source fields still belong to account A at this point.
    harness.auth.uid = 1001;
    await tester.tap(find.byTooltip('Switch to normal thread'));
    await tester.pumpAndSettle();

    // Either refuse the switch, omit the transfer, or retain its original owner so B cannot accept it.
    final transfer = harness.carried;
    if (transfer is ThreadModeTransfer && transfer.appliesTo(uid: 1001, fid: '4')) {
      expect(transfer.subject, isNot(contains(_privateSubject)), reason: 'A subject must not be rebound to B.');
      expect(transfer.body, isNot(contains(_privateBody)), reason: 'A body must not be rebound to B.');
    }
    expect(harness.posts, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a same-account mode switch keeps subject and body bound to their original owner', (tester) async {
    final harness = _ModeHarness();
    await harness.open(tester);
    await tester.tap(find.byTooltip('Switch to normal thread'));
    await tester.pumpAndSettle();

    expect(find.text('Ordinary editor destination'), findsOneWidget);
    expect(harness.carried, isA<ThreadModeTransfer>());
    final transfer = harness.carried! as ThreadModeTransfer;
    expect(transfer.appliesTo(uid: 1000, fid: '4'), isTrue);
    expect(transfer.appliesTo(uid: 1001, fid: '4'), isFalse);
    expect(transfer.subject, _privateSubject);
    expect(transfer.body, _privateBody);
    expect(harness.posts, 0);
    expect(tester.takeException(), isNull);
  });
}
