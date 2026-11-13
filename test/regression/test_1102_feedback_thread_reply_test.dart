import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/diagnostics/feedback.dart';
import 'package:tsdm_client/features/diagnostics/view/feedback_page.dart';
import 'package:tsdm_client/features/thread/v1/models/thread_reply_prefill.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';

/// E: "reply in the feedback thread" opens thread 1265238 with the reply written (what the user wrote and one line of
/// the environment), and sends nothing: the opener has no client at all, it only pushes the page. Without an account
/// the login page comes first.

final class _Fake {
  _Fake({required this.loggedIn, this.logsIn = false});

  bool loggedIn;
  final bool logsIn;
  int logins = 0;
  final opened = <(RecognizedRoute, ThreadReplyPrefill)>[];

  FeedbackThreadOpener get opener => FeedbackThreadOpener(
    isLoggedIn: () => loggedIn,
    login: () async {
      logins++;
      loggedIn = logsIn;
    },
    open: (route, prefill) async => opened.add((route, prefill)),
  );
}

const _env = 'tsdm_client 1.57.0+172.abc (1) (2026-11-15) · android 14';

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  test('the feedback thread is tid 1265238, opened as a thread page', () {
    expect(feedbackThreadTid, 1265238);
    final route = feedbackThreadRoute();
    expect(route.screenPath, ScreenPaths.threadV1);
    expect(route.queryParameters['tid'], '1265238');
  });

  test('the thread route carries the reply to the thread page', () {
    const prefill = ThreadReplyPrefill('text');
    final page = ThreadPage.fromQuery(const {'tid': '1265238'}, replyPrefill: prefill);
    expect(page.threadID, '1265238');
    expect(page.replyPrefill, same(prefill));
    expect(ThreadPage.fromQuery(const {'tid': '1'}).replyPrefill, isNull);
  });

  test('the environment line: version, platform and system, one line, nothing of the account', () {
    expect(
      feedbackEnvironmentLine(appVersion: '1.57.0+172.abc', platform: 'ios', osVersion: 'Version 17.0\n(Build 21A329)'),
      'tsdm_client 1.57.0+172.abc · ios Version 17.0 (Build 21A329)',
    );
    // Android: the display id of the build names the device model, left out.
    for (final displayId in ['TP1A.220624.014.S908EXXU2CWA2', 'ANA-AN00 2.0.0.168(C00E160R5P3)']) {
      expect(
        feedbackEnvironmentLine(appVersion: '1.57.0', platform: 'android', osVersion: displayId),
        'tsdm_client 1.57.0 · android',
      );
    }
    // Linux: the kernel's build part (its time, a vendor tag) is left out.
    expect(
      feedbackEnvironmentLine(
        appVersion: '1.57.0',
        platform: 'linux',
        osVersion: 'Linux 6.8.0-49-generic #49-Ubuntu SMP PREEMPT_DYNAMIC Mon Nov  4 02:06:24 UTC 2026',
      ),
      'tsdm_client 1.57.0 · linux Linux 6.8.0-49-generic',
    );
    // The real one, as the app builds it.
    final real = feedbackEnvironmentLine();
    expect(real, isNot(contains('\n')));
    expect(real, startsWith('tsdm_client '));
  });

  test('the reply: what the user wrote, then the environment', () {
    expect(feedbackReplyText('  Pages go blank.\nSecond line  ', _env), 'Pages go blank.\nSecond line\n\n$_env');
    expect(feedbackReplyText('   ', _env), _env);
  });

  test('the reply is redacted as the diagnostics bundle', () {
    final text = feedbackReplyText('mail alice.secret@example.org, password=PwSecret-41aa', _env);
    expect(text, isNot(contains('alice.secret@example.org')));
    expect(text, isNot(contains('PwSecret-41aa')));
    expect(text, endsWith(_env));
  });

  test('logged in: the thread opens with the reply written', () async {
    final fake = _Fake(loggedIn: true);
    expect(await fake.opener.openWith('Pages go blank.', environment: _env), isTrue);
    expect(fake.logins, 0);
    expect(fake.opened, hasLength(1));
    final (route, prefill) = fake.opened.single;
    expect(route.queryParameters['tid'], '$feedbackThreadTid');
    expect(prefill.text, 'Pages go blank.\n\n$_env');
  });

  test('no account: the login page first; the thread once logged in', () async {
    final fake = _Fake(loggedIn: false, logsIn: true);
    expect(await fake.opener.openWith('x', environment: _env), isTrue);
    expect(fake.logins, 1);
    expect(fake.opened, hasLength(1));
  });

  test('no account and the login given up: nothing opened', () async {
    final fake = _Fake(loggedIn: false);
    expect(await fake.opener.openWith('x', environment: _env), isFalse);
    expect(fake.logins, 1);
    expect(fake.opened, isEmpty);
  });

  testWidgets('the page: the description and two actions; the reply action opens the thread with it', (tester) async {
    final fake = _Fake(loggedIn: true);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(home: FeedbackPage(opener: fake.opener)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('feedback-share-bundle')), findsOneWidget);
    expect(find.byKey(const ValueKey('feedback-reply-thread')), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('feedback-description')), 'The reply bar disappears.');
    await tester.tap(find.byKey(const ValueKey('feedback-reply-thread')));
    await tester.pumpAndSettle();
    expect(fake.opened, hasLength(1));

    final (route, prefill) = fake.opened.single;
    expect(route.queryParameters['tid'], '1265238');
    expect(prefill.text, startsWith('The reply bar disappears.\n\ntsdm_client '));
  });
}
