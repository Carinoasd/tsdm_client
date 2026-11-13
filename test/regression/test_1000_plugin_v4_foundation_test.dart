/// The base of plugin 4.0.0 (`tsdmv=4`): what `status` tells, when the parameter is sent, how a page, a small form
/// and a write are asked and read.
///
/// * `status` of 4.0.0 names `v4: 1` and what it answers so (`announce`, `notify_paging`, `achievement` and the lists
///   `modcp_pages_v4`, `thread_lists`, `credit_pages`, `block_pages`, `space_pages`, `task_pages`, `magic_pages`,
///   `forms`); a `status` of an older plugin names none (all off), another action tells nothing (unknown).
/// * What a `status` told holds through the answers of the same version that leave it out (`notify`), and is dropped
///   with another version.
/// * Nothing is sent with `tsdmv=4` unless a `status` said so and the plugin is used (not missing, not too old);
///   `TsdmAppApi.ensureStatus` asks one `status` (shared by callers at the same moment, not again for a while after
///   one that told nothing).
/// * A page drops the AJAX parameters of the floating window; a small form keeps them; a write only adds.
/// * A page answer is the page, the forum's message or the plugin's refusal; anything else is read as before; an
///   answer served to another account is refused, the login prompt of a guest is the message it is.
///
/// Fixtures: the `status` of the test forum (cleaned); everything else synthetic.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider_android.dart'
    show singleAttemptHttpRequestKey;

import 'tsdmapp_v4_fake.dart';

Map<String, String> _query(String url) => Uri.parse(url).queryParameters;

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  group('status flags', () {
    test('the recorded status of 4.0.0: every flag and list', () {
      final flags = TsdmAppPluginInfo.fromAnswer(v4Json('status_v400.json'))!.v4!;
      expect(flags.on, isTrue);
      expect(flags.announce, isTrue);
      expect(flags.notifyPaging, isTrue);
      expect(flags.achievement, isTrue);
      expect(flags.lists[TsdmAppV4Group.threadLists], {'ratings', 'poll_voters', 'thread_mod', 'payments'});
      expect(flags.lists[TsdmAppV4Group.modcpPages], containsAll(['moderate', 'member', 'ipban', 'announcement']));
      expect(flags.lists[TsdmAppV4Group.creditPages], {'credit_base', 'credit_rule', 'usergroup_info'});
      expect(flags.lists[TsdmAppV4Group.blockPages], contains('privacy_filter'));
      expect(flags.lists[TsdmAppV4Group.spacePages], containsAll(['doing', 'feed', 'wall', 'poke']));
      expect(flags.lists[TsdmAppV4Group.taskPages], {'task_list', 'task', 'task_parter'});
      expect(flags.lists[TsdmAppV4Group.magicPages], {'magic_shop', 'magic_mybox', 'magic_log'});
      expect(flags.has(TsdmAppV4Group.forms, 'moderate'), isTrue);
      expect(flags.has(TsdmAppV4Group.forms, 'magicuse'), isTrue);
      expect(flags.has(TsdmAppV4Group.forms, 'nonsense'), isFalse);
      expect(flags.has(TsdmAppV4Group.threadLists, 'moderate'), isFalse, reason: 'each list on its own');
    });

    test('a status of an older plugin names none of it; another action tells nothing', () {
      final older = TsdmAppPluginInfo.fromAnswer(v4Status({'version': '3.9.0', 'v4': null}))!;
      expect(older.v4, TsdmAppV4Flags.none);
      expect(older.v4!.has(TsdmAppV4Group.threadLists, 'ratings'), isFalse, reason: 'lists without v4 count nothing');
      expect(TsdmAppPluginInfo.fromAnswer(const {'ok': 1, 'version': '4.0.0', 'v4': 1})!.v4, isNull);
      expect(TsdmAppPluginInfo.fromAnswer(v4Status({'v4': 0}))!.v4, TsdmAppV4Flags.none);
      final off = TsdmAppPluginInfo.fromAnswer(v4Status({'notify_paging': 0, 'thread_lists': <String>[]}))!.v4!;
      expect(off.notifyPaging, isFalse);
      expect(off.has(TsdmAppV4Group.threadLists, 'ratings'), isFalse);
      expect(off.announce, isTrue);
    });

    test('equality: same flags equal, whatever the order of a list', () {
      final a = TsdmAppV4Flags.fromStatus(v4Status());
      final b = TsdmAppV4Flags.fromStatus(
        v4Status({
          'thread_lists': ['payments', 'thread_mod', 'poll_voters', 'ratings'],
        }),
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(TsdmAppV4Flags.fromStatus(v4Status({'announce': 0}))));
    });

    test('kept through a notify of the same version, dropped with another version', () async {
      var notifyVersion = '4.0.0';
      final forum = V4Forum(
        (o) => switch (o.uri.queryParameters['action']) {
          'status' => V4Reply(v4Status()),
          'notify' => V4Reply({
            'ok': 1,
            'api': 1,
            'version': notifyVersion,
            'time': 1794534229,
            'uid': 31,
            'notices': <Object>[],
          }),
          _ => null,
        },
      );
      final client = v4Client(forum);
      await TsdmAppApi.ask(client, 'status');
      expect(TsdmAppV4.on, isTrue);
      await TsdmAppApi.ask(client, 'notify', {'since': '0'});
      expect(TsdmAppV4.notifyPaging, isTrue, reason: 'notify names no flags: what status said holds');
      notifyVersion = '4.0.1';
      await TsdmAppApi.ask(client, 'notify', {'since': '0'});
      expect(TsdmAppApi.pluginInfo.value!.v4, isNull);
      expect(TsdmAppV4.on, isFalse, reason: 'another version: unknown until its status tells');
    });

    test('nothing is on for a plugin missing, switched off or too old', () {
      knowV4Status();
      expect(TsdmAppV4.on, isTrue);
      expect(TsdmAppV4.has(TsdmAppV4Group.threadLists, 'ratings'), isTrue);
      TsdmAppApi.markUnavailable();
      expect(TsdmAppV4.on, isFalse);
      expect(TsdmAppV4.has(TsdmAppV4Group.threadLists, 'ratings'), isFalse);
      TsdmAppApi.reset();
      knowV4Status(v4Status({'version': '3.4.0'}));
      expect(TsdmAppV4.on, isFalse, reason: 'older than the minimum: nothing of it is used');
      TsdmAppApi.reset();
      expect(TsdmAppV4.on, isFalse, reason: 'nothing known');
      expect(TsdmAppV4.announce || TsdmAppV4.notifyPaging || TsdmAppV4.achievement, isFalse);
    });

    test('the version the app is written against is 4.0.0', () {
      expect(expectedTsdmAppVersion, '4.0.0');
      expect(TsdmAppPluginInfo.fromAnswer(v4Status({'version': '3.9.0'}))!.olderThanExpected, isTrue);
      expect(TsdmAppPluginInfo.fromAnswer(v4Status())!.olderThanExpected, isFalse);
    });
  });

  group('TsdmAppApi.ensureStatus', () {
    test('asks status once; callers at the same moment share it; known afterwards', () async {
      final forum = V4Forum((o) => o.uri.queryParameters['action'] == 'status' ? V4Reply(v4Status()) : null);
      final client = v4Client(forum);
      final both = await Future.wait([TsdmAppApi.ensureStatus(client), TsdmAppApi.ensureStatus(client)]);
      expect(both.every((e) => e?.v4?.on ?? false), isTrue);
      expect(forum.names, ['status']);
      await TsdmAppApi.ensureStatus(client);
      expect(forum.names, ['status'], reason: 'known: not asked again');
    });

    test('one that told nothing is not asked again for a while; never throws', () async {
      final forum = V4Forum((o) => v4Offline);
      final client = v4Client(forum);
      expect(await TsdmAppApi.ensureStatus(client), isNull);
      expect(await TsdmAppApi.ensureStatus(client), isNull);
      expect(forum.requests, hasLength(1));
      TsdmAppApi.reset();
      expect(await TsdmAppApi.ensureStatus(client), isNull);
      expect(forum.requests, hasLength(2), reason: 'reset forgets the miss');
    });

    test('not asked for a plugin known missing', () async {
      final forum = V4Forum((o) => V4Reply(v4Status()));
      TsdmAppApi.markUnavailable();
      expect(await TsdmAppApi.ensureStatus(v4Client(forum)), isNull);
      expect(forum.requests, isEmpty);
    });

    test('a status of an older plugin is known too: not asked again', () async {
      final forum = V4Forum((o) => V4Reply(v4Status({'version': '3.9.0', 'v4': null})));
      final client = v4Client(forum);
      expect((await TsdmAppApi.ensureStatus(client))!.v4, TsdmAppV4Flags.none);
      await TsdmAppApi.ensureStatus(client);
      expect(forum.requests, hasLength(1));
      expect(TsdmAppV4.on, isFalse);
    });
  });

  group('urls', () {
    test('a page: tsdmapp, tsdmv, nodoc added once; the floating window parameters dropped; the rest kept', () {
      final url = withTsdmAppV4Page(
        '$baseUrl/forum.php?mod=misc&action=viewratings&tid=5&pid=7&infloat=yes&handlekey=viewratings'
        '&inajax=1&ajaxtarget=fwin_content_viewratings#x',
      );
      expect(url, endsWith('#x'));
      expect(_query(url), {
        'mod': 'misc',
        'action': 'viewratings',
        'tid': '5',
        'pid': '7',
        'tsdmapp': 'json',
        'tsdmv': '4',
        'nodoc': '1',
      });
      expect(withTsdmAppV4Page(url), url, reason: 'not added twice');
      expect(withTsdmAppV4Page('$baseUrl/home.php'), '$baseUrl/home.php?tsdmapp=json&tsdmv=4&nodoc=1');
    });

    test('a small form keeps its AJAX parameters and repeated fields; all three parameters added', () {
      final url = withTsdmAppV4Form(
        '$baseUrl/forum.php?mod=topicadmin&action=moderate&fid=2&moderate[]=3&moderate[]=4&infloat=yes&inajax=1',
      );
      final uri = Uri.parse(url);
      expect(uri.queryParametersAll['moderate[]'], ['3', '4']);
      expect(uri.queryParameters, containsPair('inajax', '1'));
      for (final p in ['tsdmapp', 'tsdmv', 'tsdmform', 'nodoc']) {
        expect(uri.queryParameters, contains(p));
      }
      expect(uri.queryParameters['tsdmv'], '4');
    });

    test('a write: tsdmapp and tsdmv only', () {
      final url = withTsdmAppV4Write('$baseUrl/forum.php?mod=topicadmin&action=moderate&modsubmit=yes&infloat=yes');
      expect(_query(url), containsPair('tsdmv', '4'));
      expect(_query(url), containsPair('tsdmapp', 'json'));
      expect(_query(url), containsPair('infloat', 'yes'));
      expect(_query(url).containsKey('nodoc'), isFalse);
    });
  });

  group('tsdmAppV4AnswerOf', () {
    Map<String, dynamic> page([Map<String, Object?> more = const {}]) => {
      'ok': 1,
      'uid': 31,
      'type': 'ratings',
      'schema': 48,
      'timeoffset': 8,
      ...more,
    };

    test('the page, a later schema too; another type or an older schema is not it', () {
      expect(tsdmAppV4AnswerOf(page(), type: 'ratings', schema: 48), isA<TsdmAppV4Page>());
      expect(tsdmAppV4AnswerOf(page({'schema': 49}), type: 'ratings', schema: 48), isA<TsdmAppV4Page>());
      expect(tsdmAppV4AnswerOf(page({'type': 'credit'}), type: 'ratings', schema: 48), isNull);
      expect(tsdmAppV4AnswerOf(page({'schema': 13}), type: 'ratings', schema: 48), isNull);
      expect(tsdmAppV4AnswerOf('<html></html>', type: 'ratings', schema: 48), isNull);
      expect(tsdmAppV4AnswerOf(null, type: 'ratings', schema: 48), isNull);
    });

    test("the forum's message, with its key; the plugin's refusal; errors telling nothing are not answers", () {
      final message = tsdmAppV4AnswerOf(v4Json('ratings_v48_none.json'), type: 'ratings', schema: 48);
      expect(message, isA<TsdmAppV4Message>());
      expect((message! as TsdmAppV4Message).messageKey, 'thread_rate_log_nonexistence');
      expect((message as TsdmAppV4Message).reason, isNotEmpty);
      const guest = {'ok': 0, 'error': 'message', 'message': '', 'login': 1, 'uid': 0};
      expect((tsdmAppV4AnswerOf(guest, type: 'x', schema: 1)! as TsdmAppV4Message).reason, isNotEmpty);
      final refused = tsdmAppV4AnswerOf(
        const {'ok': 0, 'error': 'polloption', 'message': '', 'uid': 31},
        type: 'poll_voters',
        schema: 49,
      );
      expect((refused! as TsdmAppV4Refused).error, 'polloption');
      for (final error in ['off', 'action', 'unknown', 'internal', 'busy', '']) {
        expect(tsdmAppV4AnswerOf({'ok': 0, 'error': error}, type: 'x', schema: 1), isNull, reason: error);
      }
    });
  });

  group('fetchTsdmAppV4Page', () {
    const url = '$baseUrl/forum.php?mod=misc&action=viewratings&tid=5&pid=7&inajax=1';

    test('nothing asked unless status said v4', () async {
      final forum = V4Forum((o) => V4Reply(v4Json('ratings_v48.json')));
      final r = await fetchTsdmAppV4Page(v4Client(forum), url, type: 'ratings', schema: 48, uid: 31).run();
      expect(r, right<AppException, TsdmAppV4Answer?>(null));
      expect(forum.requests, isEmpty);
    });

    test('the page served to the account; asked with tsdmv=4 and without inajax', () async {
      knowV4Status();
      final forum = V4Forum((o) => V4Reply(v4Json('ratings_v48.json')));
      final r = await fetchTsdmAppV4Page(v4Client(forum), url, type: 'ratings', schema: 48, uid: 31).run();
      expect(r.getOrElse((e) => throw e), isA<TsdmAppV4Page>());
      final q = forum.requests.single.uri.queryParameters;
      expect(q['tsdmv'], '4');
      expect(q['nodoc'], '1');
      expect(q.containsKey('inajax'), isFalse);
    });

    test('another account: refused; the login prompt of a guest: the message', () async {
      knowV4Status();
      final forum = V4Forum((o) => V4Reply(v4Json('ratings_v48.json')));
      final other = await fetchTsdmAppV4Page(v4Client(forum), url, type: 'ratings', schema: 48, uid: 35).run();
      expect(other.getLeft().toNullable(), isA<IdentityChangedException>());
      final guest = V4Forum(
        (o) => const V4Reply({'ok': 0, 'error': 'message', 'message': 'login', 'login': 1, 'uid': 0}),
      );
      final r = await fetchTsdmAppV4Page(v4Client(guest), url, type: 'ratings', schema: 48, uid: 31).run();
      expect(r.getOrElse((e) => throw e), isA<TsdmAppV4Message>());
    });

    test('not the page: null (the caller reads the window); a failed request: the failure', () async {
      knowV4Status();
      final web = V4Forum((o) => const V4Reply('<?xml version="1.0"?><root><![CDATA[]]></root>'));
      final r = await fetchTsdmAppV4Page(v4Client(web), url, type: 'ratings', schema: 48, uid: 31).run();
      expect(r.getOrElse((e) => throw e), isNull);
      final down = V4Forum((o) => const V4Reply('error', status: 503));
      final failed = await fetchTsdmAppV4Page(v4Client(down), url, type: 'ratings', schema: 48, uid: 31).run();
      expect(failed.isLeft(), isTrue);
    });
  });

  group('writes', () {
    test('posted once with tsdmv=4; the result or the page drawn again', () async {
      final forum = V4Forum(
        (o) => const V4Reply({
          'ok': 1,
          'type': 'result',
          'schema': 13,
          'kind': 'message',
          'message_key': 'admin_succeed',
          'uid': 31,
        }),
      );
      final data = await postTsdmAppV4(v4Client(forum), '$baseUrl/forum.php?mod=topicadmin&action=moderate', {
        'formhash': 'f1f2f3f4',
      }).run();
      final outcome = tsdmAppV4WriteOutcomeOf(data.getOrElse((e) => throw e));
      expect((outcome as TsdmAppV4Written).result.messageKey, 'admin_succeed');
      final request = forum.requests.single;
      expect(request.method, 'POST');
      expect(request.uri.queryParameters, containsPair('tsdmv', '4'));
      expect(request.extra[singleAttemptHttpRequestKey], isTrue);

      final redrawn = tsdmAppV4WriteOutcomeOf(
        const {'ok': 1, 'uid': 31, 'type': 'modcp_ipban', 'schema': 44, 'message_key': ''},
        type: 'modcp_ipban',
        schema: 44,
      );
      expect(redrawn, isA<TsdmAppV4Redrawn>());
      expect(tsdmAppV4WriteOutcomeOf('<html></html>'), isA<TsdmAppV4WriteUnknown>());
    });

    test('a GET that writes: sent once, never retried, an error status kept as the answer', () async {
      final forum = V4Forum(
        (o) => const V4Reply({
          'ok': 0,
          'type': 'result',
          'schema': 13,
          'kind': 'message',
          'message_key': 'task_waiting',
          'uid': 31,
        }, status: 500),
      );
      final data = await getTsdmAppV4Write(
        v4Client(forum),
        '$baseUrl/home.php?mod=task&do=draw&id=1',
      ).run();
      final outcome = tsdmAppV4WriteOutcomeOf(data.getOrElse((e) => throw e));
      expect((outcome as TsdmAppV4Written).result.messageKey, 'task_waiting');
      expect(forum.requests, hasLength(1));
      expect(forum.requests.single.extra[singleAttemptHttpRequestKey], isTrue);
    });
  });

  group('small forms of 4.0.0', () {
    test('the fourteen names, as the plugin writes them', () {
      final names = SmallFormKind.values.map((e) => e.name).toSet();
      final status = (v4Json('status_v400.json')['forms'] as List).cast<String>();
      expect(names, containsAll(status), reason: 'every form status lists has a kind');
    });

    test('submit.lists: the repeated fields, numbered for a form of one value per name', () {
      final answer = smallFormAnswerOf({
        'ok': 1,
        'uid': 31,
        'type': 'form',
        'schema': 17,
        'form': 'moderate',
        'submit': {
          'url': 'forum.php?mod=topicadmin&action=moderate&optgroup=1&modsubmit=yes&infloat=yes',
          'fields': {'formhash': 'f1f2f3f4', 'fid': '2'},
          'lists': {
            'moderate[]': ['3', '4'],
            'single': ['x'],
          },
        },
      }, SmallFormKind.moderate);
      final form = answer! as SmallFormFields;
      expect(form.submitLists, {
        'moderate[]': ['3', '4'],
        'single': ['x'],
      });
      expect(form.submitListFields, {'moderate[0]': '3', 'moderate[1]': '4', 'single': 'x'});
      expect(form.submitFields, {'formhash': 'f1f2f3f4', 'fid': '2'});
    });
  });
}
