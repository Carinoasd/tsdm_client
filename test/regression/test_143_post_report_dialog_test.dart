import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/post_report/repository/post_report_repository.dart';
import 'package:tsdm_client/features/post_report/view/post_report_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

import 'fixtures/post_report_fixtures.dart';

class _Harness {
  _Harness({String? form, this.answer, this.browserOk = true}) : form = form ?? reportFormAjax();

  final String form;
  final Future<PostReportResponse> Function()? answer;
  final bool browserOk;
  int uid = viewerUid;
  final accountChanges = StreamController<Object?>.broadcast();
  final posts = <Map<String, String>>[];
  final opened = <Uri>[];
  Completer<void>? holdReads;

  PostReportRepository repository() => PostReportRepository(
    get: (url, {required ajax}) async {
      await holdReads?.future;
      return PostReportResponse(200, url.path == '/misc.php' ? form : threadPage());
    },
    post: (url, body) async {
      posts.add(body);
      return answer?.call() ?? PostReportResponse(200, successAjax());
    },
  );

  Widget dialog() => PostReportDialog(
    target: reportTarget,
    floorLabel: '#2',
    authorName: 'Synthetic author',
    currentUid: () => uid,
    accountChanges: accountChanges.stream,
    repository: repository,
    openBrowser: (uri) async {
      opened.add(uri);
      return browserOk;
    },
  );
}

Future<void> _open(WidgetTester tester, _Harness h, {Size size = const Size(800, 900), double textScale = 1}) async {
  await LocaleSettings.setLocale(AppLocale.en);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(h.accountChanges.close);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showDialog<void>(context: context, barrierDismissible: false, builder: (_) => h.dialog()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder _key(String key) => find.byKey(ValueKey(key));

bool _enabled(WidgetTester tester, String key) => tester.widget<ButtonStyleButton>(_key(key)).onPressed != null;

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  testWidgets('shows the floor and reasons; cancelling the confirmation sends nothing', (tester) async {
    final h = _Harness();
    await _open(tester, h);
    expect(find.text('Report floor #2'), findsOneWidget);
    expect(find.text('Author: Synthetic author'), findsOneWidget);
    for (final reason in ['广告垃圾', '违规内容', '恶意灌水', '重复发帖', '其他']) {
      expect(find.text(reason), findsOneWidget);
    }
    expect(_enabled(tester, 'post-report-submit'), isFalse, reason: 'a reason must be chosen');
    await tester.tap(_key('post-report-reason-1'));
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'post-report-submit'), isTrue);

    await tester.tap(_key('post-report-submit'));
    await tester.pumpAndSettle();
    expect(find.text('Send this report?'), findsOneWidget);
    expect(find.textContaining('Floor: #2'), findsOneWidget);
    expect(find.textContaining('Reason: 违规内容'), findsOneWidget);
    await tester.tap(_key('post-report-confirm-cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Send this report?'), findsNothing);
    expect(find.text('Report floor #2'), findsOneWidget);
    expect(h.posts, isEmpty);
    expect(_enabled(tester, 'post-report-submit'), isTrue, reason: 'the choice is kept');
  });

  testWidgets('confirming sends once and shows the forum success', (tester) async {
    final h = _Harness();
    await _open(tester, h);
    await tester.tap(_key('post-report-reason-0'));
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-submit'));
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-confirm'));
    await tester.pumpAndSettle();
    expect(h.posts, hasLength(1));
    expect(h.posts.single['message'], '广告垃圾');
    expect(find.text('The forum accepted the report.'), findsOneWidget);
    expect(find.text('合成的成功提示'), findsOneWidget);
    expect(_key('post-report-submit'), findsNothing);
  });

  testWidgets('custom reason: remaining count, over limit refused, never cut', (tester) async {
    final h = _Harness();
    await _open(tester, h);
    await tester.tap(_key('post-report-reason-4'));
    await tester.pumpAndSettle();
    expect(_enabled(tester, 'post-report-submit'), isFalse, reason: 'empty description');
    await tester.enterText(_key('post-report-custom'), '中😀a');
    await tester.pumpAndSettle();
    expect(find.textContaining('195 left'), findsOneWidget);
    expect(_enabled(tester, 'post-report-submit'), isTrue);
    await tester.enterText(_key('post-report-custom'), '中' * 101);
    await tester.pumpAndSettle();
    expect(find.textContaining('Too long by 2'), findsOneWidget);
    expect(_enabled(tester, 'post-report-submit'), isFalse);
    await tester.enterText(_key('post-report-custom'), '中' * 100);
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-submit'));
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-confirm'));
    await tester.pumpAndSettle();
    expect(h.posts.single['message'], '中' * 100);
  });

  testWidgets('switching account closes the confirmation and the dialog; coming back restores nothing', (tester) async {
    final h = _Harness();
    await _open(tester, h);
    await tester.tap(_key('post-report-reason-4'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('post-report-custom'), 'private text');
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-submit'));
    await tester.pumpAndSettle();
    expect(find.text('Send this report?'), findsOneWidget);

    h.uid = otherUid;
    h.accountChanges.add(null);
    await tester.pump();
    h.uid = viewerUid;
    h.accountChanges.add(null);
    await tester.pumpAndSettle();
    expect(find.text('Send this report?'), findsNothing);
    expect(find.text('Report floor #2'), findsNothing);
    expect(find.text('private text'), findsNothing);
    expect(h.posts, isEmpty);
  });

  testWidgets('a confirmation tapped while animating out after a switch sends nothing', (tester) async {
    final h = _Harness();
    await _open(tester, h);
    await tester.tap(_key('post-report-reason-0'));
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-submit'));
    await tester.pumpAndSettle();
    final confirm = tester.widget<ButtonStyleButton>(_key('post-report-confirm'));
    h.uid = otherUid;
    h.accountChanges.add(null);
    await tester.pump();
    // The old button's callback, as a late tap on the route animating out would call it.
    confirm.onPressed?.call();
    await tester.pumpAndSettle();
    expect(h.posts, isEmpty);
  });

  testWidgets('an authentication event of the same account keeps the dialog and the input', (tester) async {
    final h = _Harness();
    await _open(tester, h);
    await tester.tap(_key('post-report-reason-4'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('post-report-custom'), 'kept text');
    h.accountChanges.add(null);
    await tester.pumpAndSettle();
    expect(find.text('kept text'), findsOneWidget);
    expect(_enabled(tester, 'post-report-submit'), isTrue);
  });

  testWidgets('account switch clears the private confirmation before the exit animation completes', (tester) async {
    final h = _Harness();
    await _open(tester, h);
    await tester.tap(_key('post-report-reason-4'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('post-report-custom'), 'private confirmation reason');
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-submit'));
    await tester.pumpAndSettle();
    h.uid = otherUid;
    h.accountChanges.add(null);
    // Deliver the asynchronous auth event before requesting its first frame; a settled pump otherwise only flushes
    // microtasks and does not draw that frame. Still do not advance the exit animation or pumpAndSettle.
    await tester.idle();
    await tester.pump();
    expect(find.textContaining('private confirmation reason'), findsNothing);
    expect(find.textContaining('Synthetic author'), findsNothing);
    expect(h.posts, isEmpty);
    await tester.pumpAndSettle();
  });

  testWidgets('account switch clears an already-popped confirmation during its exit animation', (tester) async {
    final h = _Harness();
    await _open(tester, h);
    await tester.tap(_key('post-report-reason-4'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('post-report-custom'), 'private exiting reason');
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-submit'));
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-confirm-cancel'));
    await tester.pump();
    h.uid = otherUid;
    h.accountChanges.add(null);
    await tester.pump();
    expect(find.textContaining('private exiting reason'), findsNothing);
    expect(h.posts, isEmpty);
    await tester.pumpAndSettle();
  });

  testWidgets('account switch preserves unrelated routes above the report dialogs', (tester) async {
    final h = _Harness();
    await _open(tester, h);
    await tester.tap(_key('post-report-reason-0'));
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-submit'));
    await tester.pumpAndSettle();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Unrelated destination')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    h.uid = otherUid;
    h.accountChanges.add(null);
    await tester.pumpAndSettle();
    expect(find.text('Unrelated destination'), findsOneWidget);
    expect(h.posts, isEmpty);
  });

  testWidgets('closing the report route immediately invalidates a pending fresh check', (tester) async {
    final h = _Harness();
    await _open(tester, h);
    await tester.tap(_key('post-report-reason-0'));
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-submit'));
    await tester.pumpAndSettle();
    h.holdReads = Completer<void>();
    await tester.tap(_key('post-report-confirm'));
    await tester.pump();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.pop();
    await tester.pump();
    h.holdReads!.complete();
    await tester.pump();
    expect(h.posts, isEmpty, reason: 'Closing the route cancels preflight even before dispose.');
    await tester.pumpAndSettle();
  });

  testWidgets('removing the report route also removes its still-open confirmation', (tester) async {
    final h = _Harness();
    await _open(tester, h);
    final reportRoute = ModalRoute.of(tester.element(find.byType(PostReportDialog)))!;
    await tester.tap(_key('post-report-reason-4'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('post-report-custom'), 'orphaned private reason');
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-submit'));
    await tester.pumpAndSettle();
    reportRoute.navigator!.removeRoute(reportRoute);
    await tester.pumpAndSettle();
    expect(find.text('Send this report?'), findsNothing);
    expect(find.textContaining('orphaned private reason'), findsNothing);
    expect(h.posts, isEmpty);
    h.uid = otherUid;
    h.accountChanges.add(null);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('browser fallback opens the full floor; a failure keeps the dialog and input', (tester) async {
    final h = _Harness(browserOk: false);
    await _open(tester, h);
    await tester.tap(_key('post-report-reason-4'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('post-report-custom'), 'kept text');
    await tester.tap(_key('post-report-browser'));
    await tester.pumpAndSettle();
    expect(h.opened, [reportTarget.floorUrl]);
    expect(find.text('Could not open a browser. Your input is kept.'), findsOneWidget);
    expect(find.text('kept text'), findsOneWidget);
    expect(h.posts, isEmpty);
  });

  testWidgets('unknown result: no way to send again, the website is offered', (tester) async {
    final h = _Harness(answer: () async => throw Exception('timeout'));
    await _open(tester, h);
    await tester.tap(_key('post-report-reason-0'));
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-submit'));
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-confirm'));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be confirmed'), findsOneWidget);
    expect(_key('post-report-submit'), findsNothing);
    expect(_key('post-report-browser'), findsOneWidget);
    expect(h.posts, hasLength(1));
  });

  testWidgets('explicit refusal shows the forum text and keeps the input', (tester) async {
    final h = _Harness(answer: () async => PostReportResponse(200, rejectionAjax()));
    await _open(tester, h);
    await tester.tap(_key('post-report-reason-4'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('post-report-custom'), 'kept text');
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-submit'));
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-confirm'));
    await tester.pumpAndSettle();
    expect(find.text('The forum refused the report:'), findsOneWidget);
    expect(find.text('合成的拒绝提示'), findsOneWidget);
    expect(find.text('kept text'), findsOneWidget);
    expect(h.posts, hasLength(1));
  });

  testWidgets('an unsupported form offers only the browser', (tester) async {
    final h = _Harness(form: reportFormAjax(extraFields: '<input type="text" name="seccodeverify" />'));
    await _open(tester, h);
    expect(find.textContaining('verification the app does not support'), findsOneWidget);
    expect(_key('post-report-submit'), findsNothing);
    expect(_key('post-report-browser'), findsOneWidget);
  });

  testWidgets('narrow phone with large text: no overflow', (tester) async {
    final h = _Harness();
    await _open(tester, h, size: const Size(320, 640), textScale: 2);
    expect(tester.takeException(), isNull);
    // At 320x640 with 2x text the last reason is below the fold: scroll it into view before tapping it.
    await tester.ensureVisible(_key('post-report-reason-4'));
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-reason-4'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(_key('post-report-custom'));
    await tester.pumpAndSettle();
    await tester.enterText(_key('post-report-custom'), '中' * 90);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('20 left'), findsOneWidget);
    await tester.ensureVisible(_key('post-report-submit'));
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-submit'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Send this report?'), findsOneWidget);
    expect(find.textContaining('Reason: ${'中' * 90}'), findsOneWidget);
    await tester.ensureVisible(_key('post-report-confirm'));
    await tester.pumpAndSettle();
    await tester.tap(_key('post-report-confirm'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(h.posts.single['message'], '中' * 90);
  });
}
