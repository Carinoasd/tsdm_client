/// Reading and sending the transfer and the exchange forms of plugin 4.1.0.
///
/// * Nothing is asked without `status.credit_forms` (plugin 4.0.x): the web page is the way. With it the page is
///   asked as one of 4.0.0 (`tsdmapp=json&tsdmv=4&nodoc=1`, no `inajax`); an answer that is not the page is the web
///   page's way too, the forum's message (closed for the group, log in) is shown, another account's answer refused.
/// * A form is posted once to its page with `tsdmapp=json&tsdmv=4` and without `inajax`, never sent again by itself:
///   not after a timeout (unknown: it may have been carried out), not after the forum's 503 page of a wrong formhash
///   (the form expired: read again, the user sends again).
/// * Done only for the success key of the form (`credits_transfer_succeed`, `credits_transaction_succeed`), whatever
///   `ok` says; any other key the forum names is a refusal (it checks them all before it takes anything); no key (a
///   page instead of a message) is unknown. An answer of another account, or an account switched before sending, is
///   no outcome of this one.
/// * Each refusal key the test forum answered has the app's own text.
///
/// Fixtures: the answers of the test forum (cleaned); the 503 page is a minimal stand-in.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/points/models/credit_forms.dart';
import 'package:tsdm_client/features/points/repository/credit_forms_repository.dart';
import 'package:tsdm_client/features/points/views/credit_form_page.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;

/// The `status` of 4.1.0 (the recorded one of 4.0.0 with `credit_forms`).
Map<String, dynamic> _status() => v4Status({'version': '4.1.0', 'credit_forms': 1});

Map<String, dynamic> _result(String name) => Map<String, dynamic>.from(v4Json('credit_results_v13.json')[name] as Map);

/// The forum's page for a wrong formhash (HTTP 503), as a stand-in.
const _expiredPage = V4Reply(
  '<!DOCTYPE html><html><head><title>System Error</title></head><body></body></html>',
  status: 503,
);

CreditFormsRepository _repository(V4Forum forum, {int uid = _uid}) =>
    CreditFormsRepository(client: v4Client(forum), currentUid: () => uid);

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);
  tearDown(TsdmAppApi.reset);

  group('reading', () {
    test('without credit_forms nothing is asked', () async {
      knowV4Status();
      final forum = V4Forum((o) => null);
      final transfer = (await _repository(forum).fetchTransfer().run()).getOrElse((e) => throw e);
      final exchange = (await _repository(forum).fetchExchange().run()).getOrElse((e) => throw e);
      expect(transfer, isA<CreditFormWebOnly<CreditTransferForm>>());
      expect(exchange, isA<CreditFormWebOnly<CreditExchangeForm>>());
      expect(forum.requests, isEmpty);
    });

    test('with it: the page of 4.0.0, read as the form', () async {
      knowV4Status(_status());
      final forum = V4Forum(
        (o) => V4Reply(
          v4Json(o.uri.queryParameters['op'] == 'transfer' ? 'credit_transfer_v72.json' : 'credit_exchange_v73.json'),
        ),
      );
      final transfer = (await _repository(forum).fetchTransfer().run()).getOrElse((e) => throw e);
      final exchange = (await _repository(forum).fetchExchange().run()).getOrElse((e) => throw e);
      expect((transfer as CreditFormReady<CreditTransferForm>).form.credit.id, 2);
      expect((exchange as CreditFormReady<CreditExchangeForm>).form.to, hasLength(2));
      expect(forum.requests, hasLength(2));
      for (final (request, op) in [(forum.requests[0], 'transfer'), (forum.requests[1], 'exchange')]) {
        expect(request.method, 'GET');
        expect(
          request.uri.queryParameters,
          allOf(
            containsPair('mod', 'spacecp'),
            containsPair('ac', 'credit'),
            containsPair('op', op),
            containsPair('tsdmapp', 'json'),
            containsPair('tsdmv', '4'),
            containsPair('nodoc', '1'),
          ),
        );
        expect(request.uri.queryParameters.containsKey('inajax'), isFalse);
      }
    });

    test("the forum's message; another account; an answer that is not the page", () async {
      knowV4Status(_status());
      final closed = (await _repository(
        V4Forum((o) => V4Reply(v4Json('credit_transfer_closed.json'))),
      ).fetchTransfer().run()).getOrElse((e) => throw e);
      expect((closed as CreditFormMessage).message, v4Json('credit_transfer_closed.json')['message']);

      final guest = (await _repository(
        V4Forum((o) => V4Reply(v4Json('credit_transfer_guest.json'))),
        uid: 0,
      ).fetchTransfer().run()).getOrElse((e) => throw e);
      expect(guest, isA<CreditFormMessage<CreditTransferForm>>());

      final other = await _repository(
        V4Forum((o) => V4Reply({...v4Json('credit_transfer_v72.json'), 'uid': 35})),
      ).fetchTransfer().run();
      expect(other.getLeft().toNullable(), isA<IdentityChangedException>());

      for (final reply in [
        V4Reply(v4Raw('g3_credit_base_web.html')),
        const V4Reply({'ok': 0, 'error': 'off'}),
        V4Reply(v4Json('credit_base_v52_forms.json')),
      ]) {
        final answer = (await _repository(V4Forum((o) => reply)).fetchTransfer().run()).getOrElse((e) => throw e);
        expect(answer, isA<CreditFormWebOnly<CreditTransferForm>>());
      }

      // Nothing to exchange: the web page (which also has the exchanges with the user center's applications).
      final empty = (await _repository(
        V4Forum((o) => V4Reply({...v4Json('credit_exchange_v73.json'), 'to': <Object>[]})),
      ).fetchExchange().run()).getOrElse((e) => throw e);
      expect(empty, isA<CreditFormWebOnly<CreditExchangeForm>>());
    });
  });

  group('sending', () {
    final transferForm = CreditTransferForm.fromJson(v4Json('credit_transfer_v72.json'), uid: _uid)!;
    final exchangeForm = CreditExchangeForm.fromJson(v4Json('credit_exchange_v73.json'), uid: _uid)!;

    Future<CreditFormOutcome> transfer(V4Forum forum, {int uid = _uid}) => _repository(
      forum,
      uid: uid,
    ).transfer(transferForm, to: '测试会员', amount: 10, message: '', password: 'pw');

    Future<CreditFormOutcome> exchange(V4Forum forum) => _repository(
      forum,
    ).exchange(exchangeForm, target: exchangeForm.to.first, source: exchangeForm.from.first, amount: 5, password: 'pw');

    test('posted once, with tsdmapp=json&tsdmv=4 and without inajax', () async {
      for (final (send, op, success) in [
        (transfer, 'transfer', 'transfer_succeed'),
        (exchange, 'exchange', 'exchange_succeed'),
      ]) {
        final forum = V4Forum((o) => V4Reply(_result(success)));
        expect(await send(forum), isA<CreditFormDone>(), reason: op);
        expect(forum.requests, hasLength(1));
        final request = forum.requests.single;
        expect(request.method, 'POST');
        expect(
          request.uri.queryParameters,
          allOf(containsPair('op', op), containsPair('tsdmapp', 'json'), containsPair('tsdmv', '4')),
        );
        expect(request.uri.queryParameters.containsKey('inajax'), isFalse);
        expect(request.headers.containsKey('X-Requested-With'), isFalse);
        expect(request.uri.query, isNot(contains('pw')), reason: 'the password only in the body');
        expect(Uri.splitQueryString(forum.bodies.single), containsPair('password', 'pw'));
      }
    });

    test('done only for the success key of the form', () async {
      expect(await exchange(V4Forum((o) => V4Reply(_result('transfer_succeed')))), isA<CreditFormRefused>());
      expect(await transfer(V4Forum((o) => V4Reply(_result('exchange_succeed')))), isA<CreditFormRefused>());
      final noKey = {..._result('transfer_succeed'), 'message_key': ''};
      expect(await transfer(V4Forum((o) => V4Reply(noKey))), isA<CreditFormUnknown>(), reason: 'ok 1 without a key');
      final refusedButOk = {..._result('transfer_password'), 'ok': 1};
      expect(await transfer(V4Forum((o) => V4Reply(refusedButOk))), isA<CreditFormRefused>());
      final succeededButNotOk = {..._result('transfer_succeed'), 'ok': 0};
      expect(await transfer(V4Forum((o) => V4Reply(succeededButNotOk))), isA<CreditFormDone>());
    });

    test("each refusal of the test forum, with the app's own text", () async {
      final results = v4Json('credit_results_v13.json');
      for (final name in results.keys.where((k) => !k.endsWith('_succeed'))) {
        final forum = V4Forum((o) => V4Reply(_result(name)));
        final outcome = name.startsWith('transfer_') ? await transfer(forum) : await exchange(forum);
        expect(outcome, isA<CreditFormRefused>(), reason: name);
        final refused = outcome as CreditFormRefused;
        expect(refused.messageKey, isNotEmpty, reason: name);
        expect(refused.wrongPassword, name.endsWith('_password'), reason: name);
        final text = creditFormRefusalText(t, refused, credit: '天使币', minBalance: 1000, target: '威望');
        expect(text, isNot(refused.message), reason: '$name: the app has its own text');
        expect(text, isNot(t.pointsPage.creditForms.unknown), reason: name);
      }
      expect(
        creditFormRefusalText(
          t,
          const CreditFormRefused(messageKey: 'credits_transfer_balance_insufficient', message: ''),
          credit: '天使币',
          minBalance: 1000,
        ),
        t.pointsPage.creditForms.belowMin(credit: '天使币', min: 1000),
        reason: "the forum's values come empty: the form names the credit",
      );
      expect(
        creditFormRefusalText(
          t,
          const CreditFormRefused(messageKey: 'action_closed', message: '站点尚未开启此功能'),
          credit: '',
          minBalance: 0,
        ),
        '站点尚未开启此功能',
        reason: "another key: the forum's message",
      );
    });

    test('a wrong formhash: the form expired, nothing sent again', () async {
      final forum = V4Forum((o) => _expiredPage);
      expect(await transfer(forum), isA<CreditFormExpired>());
      expect(forum.requests, hasLength(1));
    });

    test('no answer, or an answer the app does not know: unknown, nothing sent again', () async {
      for (final reply in [
        v4Offline,
        V4Reply(v4Raw('g3_credit_base_web.html')),
        const V4Reply('', status: 500),
        // The forum's error page wrapped by the plugin (a source without a ratio): no key.
        const V4Reply({
          'ok': 0,
          'uid': _uid,
          'type': 'result',
          'schema': 13,
          'kind': 'page',
          'message': '',
          'message_key': '',
          'values': <String, Object>{},
          'login': 0,
        }),
      ]) {
        final forum = V4Forum((o) => reply);
        expect(await exchange(forum), isA<CreditFormUnknown>(), reason: '${reply.status} ${reply.body}');
        expect(forum.requests, hasLength(1));
      }
    });

    test('another account: switched before sending (nothing sent), or answered for another', () async {
      final before = V4Forum((o) => V4Reply(_result('transfer_succeed')));
      expect(await transfer(before, uid: 35), isA<CreditFormAccountChanged>());
      expect(before.requests, isEmpty);
      final other = V4Forum((o) => V4Reply({..._result('transfer_succeed'), 'uid': 35}));
      expect(await transfer(other), isA<CreditFormAccountChanged>());
      final loggedOut = V4Forum((o) => V4Reply({..._result('transfer_password'), 'uid': 0, 'login': 1}));
      expect(await transfer(loggedOut), isA<CreditFormAccountChanged>());
    });
  });

  test('the request of the web page way and of the forms is the same page', () {
    expect(CreditFormKind.transfer.pageUrl, endsWith('home.php?mod=spacecp&ac=credit&op=transfer'));
    expect(CreditFormKind.exchange.pageUrl, endsWith('home.php?mod=spacecp&ac=credit&op=exchange'));
  });
}
