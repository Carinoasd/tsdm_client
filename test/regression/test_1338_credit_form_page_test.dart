/// The native transfer and exchange pages (plugin 4.1.0).
///
/// * Transfer: what the member receives and what is left are shown as the amount is typed; the button stays off for
///   the account's own name, an amount above what may be transferred, or one that leaves nothing after the tax.
/// * The confirmation lists the recipient, the amount, what is received, the tax and what is left, and asks for the
///   login password; one write is sent however fast the button is tapped. Done: the credits are read again and the
///   page closes.
/// * The forum's 503 page of an expired form: the form is read again (a new formhash), nothing is sent again.
/// * Exchange: what it costs of the source shown as the amount is typed.
/// * No form as fields: the page closes for the web page.
///
/// Fixtures: the answers of the test forum (cleaned).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/points/models/credit_forms.dart';
import 'package:tsdm_client/features/points/repository/credit_forms_repository.dart';
import 'package:tsdm_client/features/points/views/credit_form_page.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;

Map<String, dynamic> _result(String name) => Map<String, dynamic>.from(v4Json('credit_results_v13.json')[name] as Map);

/// A forum answering the page of [kind] to a GET and [post] to a POST.
V4Forum _forum(CreditFormKind kind, V4Reply post) => V4Forum(
  (o) => o.method == 'POST'
      ? post
      : V4Reply(v4Json(kind == CreditFormKind.transfer ? 'credit_transfer_v72.json' : 'credit_exchange_v73.json')),
);

/// The transfer page answered as recorded, with formhash [hash] and the balance lowered by [spent].
Map<String, dynamic> _transferPage({String hash = 'f1f2f3f4', int spent = 0}) {
  final json = v4Json('credit_transfer_v72.json');
  ((json['submit'] as Map)['fields'] as Map)['formhash'] = hash;
  json['balance'] = (json['balance'] as int) - spent;
  return json;
}

/// [forum], with the POSTs held until [release] completes.
final class _HeldPosts implements HttpClientAdapter {
  _HeldPosts(this.forum);

  final V4Forum forum;
  final release = Completer<void>();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'POST') {
      await release.future;
    }
    return forum.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

/// Type a transfer of 10 to a member, confirm it with a password.
Future<void> _sendTransfer(WidgetTester tester, {bool settle = true}) async {
  final tr = t.pointsPage.creditForms;
  await tester.enterText(_field(tr.to), '测试会员');
  await tester.enterText(_field(tr.amount), '10');
  await tester.pump();
  await tester.tap(_button(tr.transfer));
  await tester.pumpAndSettle();
  await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'pw');
  await tester.pump();
  await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    // The confirmation closed, the answer held.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(AlertDialog), findsNothing);
  }
}

/// Open the page of [kind] on [forum] from a first page; returns how it was left (set once it closes).
Future<List<Object?>> _open(
  WidgetTester tester,
  CreditFormKind kind,
  V4Forum forum, {
  VoidCallback? onWritten,
  HttpClientAdapter? adapter,
}) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final exits = <Object?>[];
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        scaffoldMessengerKey: snackbarKey,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => exits.add(
                await Navigator.of(context).push(
                  MaterialPageRoute<CreditFormExit>(
                    builder: (_) => CreditFormPage(
                      kind: kind,
                      selfUsername: 'me',
                      onWritten: onWritten ?? () {},
                      repository: CreditFormsRepository(
                        client: adapter == null
                            ? v4Client(forum)
                            : NetClientProvider.buildNoCookie(
                                dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter,
                              ),
                        currentUid: () => _uid,
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return exits;
}

Finder _field(String label) => find.widgetWithText(TextField, label);

Finder _button(String label) => find.widgetWithText(FilledButton, label);

bool _enabled(WidgetTester tester, Finder button) => tester.widget<ButtonStyleButton>(button).onPressed != null;

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(() {
    TsdmAppApi.reset();
    knowV4Status(v4Status({'version': '4.1.0', 'credit_forms': 1}));
  });
  tearDown(TsdmAppApi.reset);

  final tr = t.pointsPage.creditForms;

  testWidgets('transfer: shown as typed, checked, confirmed, sent once', (tester) async {
    var written = 0;
    final forum = _forum(CreditFormKind.transfer, V4Reply(_result('transfer_succeed')));
    final exits = await _open(tester, CreditFormKind.transfer, forum, onWritten: () => written++);
    final send = _button(tr.transfer);
    expect(find.text('564 天使币'), findsOneWidget, reason: 'what may be transferred');
    expect(_enabled(tester, send), isFalse);

    await tester.enterText(_field(tr.to), 'me');
    await tester.enterText(_field(tr.amount), '10');
    await tester.pump();
    expect(find.text(tr.selfTransfer), findsOneWidget);
    expect(_enabled(tester, send), isFalse);

    await tester.enterText(_field(tr.to), '测试会员');
    await tester.enterText(_field(tr.amount), '565');
    await tester.pump();
    expect(find.text(tr.overMax), findsOneWidget);
    expect(_enabled(tester, send), isFalse);

    await tester.enterText(_field(tr.amount), '1');
    await tester.pump();
    expect(find.text(tr.nothingReceived), findsOneWidget);
    expect(_enabled(tester, send), isFalse);

    await tester.enterText(_field(tr.amount), '10');
    await tester.pump();
    expect(find.text('8 天使币'), findsOneWidget, reason: 'floor(10 × 0.8)');
    expect(find.text('1554 天使币'), findsOneWidget);
    expect(_enabled(tester, send), isTrue);

    // Tapped twice: one confirmation.
    await tester.tap(send);
    await tester.tap(send, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    final dialog = find.byType(AlertDialog);
    expect(find.descendant(of: dialog, matching: find.text(tr.confirmTransfer)), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('测试会员')), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('8 天使币')), findsOneWidget);
    expect(find.descendant(of: dialog, matching: find.text('20.00%')), findsOneWidget);
    final confirm = find.descendant(of: dialog, matching: find.widgetWithText(FilledButton, tr.transfer));
    expect(_enabled(tester, confirm), isFalse, reason: 'no password yet');

    await tester.enterText(find.descendant(of: dialog, matching: find.byType(TextField)), 'pw');
    await tester.pump();
    await tester.tap(confirm);
    await tester.tap(confirm, warnIfMissed: false);
    await tester.pumpAndSettle();

    final posts = forum.requests.where((r) => r.method == 'POST').toList();
    expect(posts, hasLength(1));
    expect(
      Uri.splitQueryString(forum.bodies[forum.requests.indexOf(posts.single)]),
      allOf(containsPair('to', '测试会员'), containsPair('transferamount', '10'), containsPair('password', 'pw')),
    );
    expect(written, 1);
    expect(exits, [null], reason: 'closed');
    expect(find.text(tr.transferDone), findsOneWidget);
  });

  testWidgets('an expired form: read again, nothing sent again', (tester) async {
    var written = 0;
    var gets = 0;
    final forum = V4Forum(
      (o) => o.method == 'POST'
          ? const V4Reply('<html>System Error</html>', status: 503)
          : V4Reply(_transferPage(hash: gets++ == 0 ? 'f1f2f3f4' : 'a1a2a3a4')),
    );
    await _open(tester, CreditFormKind.transfer, forum, onWritten: () => written++);
    await _sendTransfer(tester);

    expect([for (final r in forum.requests) r.method], ['GET', 'POST', 'GET']);
    expect(written, 0);
    expect(find.text(tr.expired), findsOneWidget);
    expect(find.byType(CreditFormPage), findsOneWidget, reason: 'still open, the typed values kept');
    expect(find.text('测试会员'), findsOneWidget);
  });

  group('a 503 that may not be of the formhash: unknown, not sent again', () {
    for (final (name, second) in [
      ('the balance went down', V4Reply(_transferPage(hash: 'a1a2a3a4', spent: 10))),
      ('the same formhash', V4Reply(_transferPage())),
      ('the form not read again', v4Offline),
      ("the forum's message instead", V4Reply(v4Json('credit_transfer_guest.json'))),
    ]) {
      testWidgets(name, (tester) async {
        var written = 0;
        var gets = 0;
        final forum = V4Forum((o) {
          if (o.method == 'POST') {
            return const V4Reply('<html>Service Unavailable</html>', status: 503);
          }
          return gets++ == 0 ? V4Reply(_transferPage()) : second;
        });
        await _open(tester, CreditFormKind.transfer, forum, onWritten: () => written++);
        await _sendTransfer(tester);
        expect([for (final r in forum.requests) r.method], ['GET', 'POST', 'GET']);
        expect(written, 1);
        expect(find.text(tr.unknown), findsOneWidget);
        expect(find.text(tr.expired), findsNothing);
      });
    }
  });

  testWidgets('not left while the write is on its way; its outcome told also so', (tester) async {
    var written = 0;
    final held = _HeldPosts(_forum(CreditFormKind.transfer, V4Reply(_result('transfer_succeed'))));
    final exits = await _open(
      tester,
      CreditFormKind.transfer,
      held.forum,
      onWritten: () => written++,
      adapter: held,
    );
    await _sendTransfer(tester, settle: false);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(CreditFormPage), findsOneWidget, reason: 'back held while sending');
    expect(exits, isEmpty);
    expect(_enabled(tester, _button(tr.transfer)), isFalse);
    expect(tester.widget<TextField>(_field(tr.amount)).enabled, isFalse);
    held.release.complete();
    await tester.pumpAndSettle();
    expect(written, 1);
    expect(exits, [null]);
    expect(held.forum.requests.where((r) => r.method == 'POST'), hasLength(1));
  });

  testWidgets('a refusal: its text, the page stays', (tester) async {
    final forum = _forum(CreditFormKind.transfer, V4Reply(_result('transfer_password')));
    await _open(tester, CreditFormKind.transfer, forum);
    await tester.enterText(_field(tr.to), '测试会员');
    await tester.enterText(_field(tr.amount), '10');
    await tester.pump();
    await tester.tap(_button(tr.transfer));
    await tester.pumpAndSettle();
    await tester.enterText(find.descendant(of: find.byType(AlertDialog), matching: find.byType(TextField)), 'x');
    await tester.pump();
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.byType(FilledButton)));
    await tester.pumpAndSettle();
    expect(find.text(tr.wrongPassword), findsOneWidget);
    expect(find.byType(CreditFormPage), findsOneWidget);
    expect(_enabled(tester, _button(tr.transfer)), isTrue, reason: 'sent again only when the user taps again');
    expect(forum.requests.where((r) => r.method == 'POST'), hasLength(1));
  });

  testWidgets('exchange: what it costs as typed', (tester) async {
    final forum = _forum(CreditFormKind.exchange, V4Reply(_result('exchange_succeed')));
    await _open(tester, CreditFormKind.exchange, forum);
    // The first target (天使币) and the first other source (威望, ratio 5).
    await tester.enterText(_field(tr.amount), '5');
    await tester.pump();
    expect(find.text('2 威望'), findsOneWidget, reason: 'ceil(1 / 5 × 5 × 1.2)');
    expect(_enabled(tester, _button(tr.exchange)), isTrue);
    await tester.enterText(_field(tr.amount), '0');
    await tester.pump();
    expect(find.text(tr.amountInvalid), findsOneWidget);
    expect(_enabled(tester, _button(tr.exchange)), isFalse);
  });

  testWidgets('no form as fields: closed for the web page', (tester) async {
    final forum = V4Forum((o) => V4Reply(v4Raw('g3_credit_base_web.html')));
    final exits = await _open(tester, CreditFormKind.transfer, forum);
    expect(exits, [CreditFormExit.web]);
    expect(find.byType(CreditFormPage), findsNothing);
  });
}
