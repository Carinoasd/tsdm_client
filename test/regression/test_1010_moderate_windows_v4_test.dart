/// The thread and floor management windows read from the forum's app API (plugin 4.0.0, `tsdmv=4`, small forms
/// `moderate`, `delpost`, `warn`, `banpost`, `removerate`, `threadtypes`; G2).
///
/// * Asked as a small form (`tsdmapp=json&tsdmv=4&tsdmform=1&nodoc=1`, the window's `inajax=1` kept) only once `status`
///   listed the form in `forms`; otherwise the window is asked exactly as before (the write result of plugin 2.6.0, or
///   the AJAX fragment), one request.
/// * The same window read either way gives the same model (the recorded answer and fragment of the same window, asked
///   one after the other on the test forum): the fields sent back, the levels, forums, choices, reasons, the notice.
/// * The forum's refusal is the same refusal; a window served without the operation the same "unavailable"; an answer
///   that is not the form reads the window as before and forgets the stale flag; another account's answer is refused.
/// * A window of the API is posted with `tsdmv=4`, its verdict told by `message_key`; one of the web page as before.
///
/// Fixtures `test/data/tsdmapp/v4/g2_*`: a moderator of forum 2 (uid 70) and an administrator (uid 32) on the test
/// forum, both ways (`.json` and `.xml`), cleaned.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/models/remove_rate.dart';
import 'package:tsdm_client/features/moderate/repository/floor_ops_repository.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

import 'tsdmapp_v4_fake.dart';

const _mod = 70;
const _admin = 32;
const _fid = 2;
const _tid = '9202952';

/// Fixture `g2_[name]` as the client decodes it: JSON as a map, the fragment as text.
Object? _fx(String name) => name.endsWith('.json') ? v4Json('g2_$name') : v4Raw('g2_$name');

/// The requests a repository made, and what it posted.
final class _Log {
  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];
}

/// A moderation repository answering [api] to a request with `tsdmv=4` and [web] to the others, posting answers
/// [posted].
ModerateRepository _repo(_Log log, {Object? api, Object? web, Object? posted, int uid = _mod}) => ModerateRepository(
  get: (url) async {
    log.gets.add(url);
    final v4 = Uri.parse(url).queryParameters['tsdmv'] == '4';
    final data = v4 ? api : web;
    return data == null ? left(HttpRequestFailedException(null)) : right((statusCode: 200, data: data));
  },
  post: (url, body) async {
    log.posts.add((url, body));
    return posted == null ? left(HttpRequestFailedException(null)) : right((statusCode: 200, data: posted));
  },
  currentUid: () => uid,
);

/// What the user sees of a choice (the picture's host is the forum's either way, compared apart).
String _choice(ModerateChoice c) => '${c.value}|${c.label}|${c.selected}|${c.depth}|${c.group}|${c.image != null}';

/// Everything of a window the app shows or sends, but [ModerateForm.v4].
Map<String, Object?> _form(ModerateForm f) => {
  'operation': f.operation,
  'tid': f.tid,
  'fid': f.fid,
  'fields': f.fields,
  'uid': f.uid,
  'levels': f.levels.map(_choice).toList(),
  'forums': f.forums.map(_choice).toList(),
  'canRedirect': f.canRedirect,
  'reasons': f.reasons,
  'canNotify': f.canNotify,
  'notifyForced': f.notifyForced,
  'expiration': f.expiration,
  'highlight': f.highlight,
  'recommendTitle': f.recommendTitle,
  'recommendFields': f.recommendFields,
  'choices': f.choices.map(_choice).toList(),
};

Map<String, Object?> _floor(FloorModerateForm f) => {
  'action': f.action,
  'tid': f.tid,
  'fid': f.fid,
  'pid': f.pid,
  'fields': f.fields,
  'uid': f.uid,
  'undo': f.undo,
  'reasons': f.reasons,
  'canNotify': f.canNotify,
  'notifyForced': f.notifyForced,
};

String _describe(Object? window) => switch (window) {
  ModerateWindowRefused(:final message, :final unavailable) => 'refused($message, $unavailable)',
  ModerateBatchWindowRefused(:final message, :final unavailable) => 'refused($message, $unavailable)',
  FloorModerateWindowRefused(:final message) => 'refused($message)',
  RemoveRateWindowRefused(:final message) => 'refused($message)',
  _ => '$window',
};

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(() {
    TsdmAppApi.reset();
    ModerateRepository.resetModeratorCache();
  });

  group('thread window (moderate)', () {
    Future<(ModerateWindow, _Log)> open(
      String name,
      ModerateOperation op, {
      bool v4 = true,
      String tid = _tid,
      int uid = _mod,
    }) async {
      final log = _Log();
      final repo = _repo(log, api: v4 ? _fx('$name.json') : null, web: _fx('$name.xml'), uid: uid);
      final window = await repo.fetchWindow(op, tid: tid, fid: _fid).run();
      return (window.getOrElse((e) => throw StateError('$e')), log);
    }

    ModerateWindow webOf(String name, ModerateOperation op, {String tid = _tid}) =>
        ModerateRepository.windowOf(_fx('$name.xml'), op, tid: tid, fid: _fid, uid: _mod).getOrElse(
          (e) => throw StateError('$e'),
        );

    const cases = <(String, ModerateOperation)>[
      ('mod_1_stick', ModerateOperation.stick),
      ('mod_1_stick', ModerateOperation.digest),
      ('mod_1_highlight', ModerateOperation.highlight),
      ('mod_2_x', ModerateOperation.move),
      ('mod_3_delete', ModerateOperation.delete),
      ('mod_3_x', ModerateOperation.bump),
      ('mod_3_x', ModerateOperation.down),
      ('mod_4_x', ModerateOperation.open),
      ('mod_4_x', ModerateOperation.close),
      ('act_stamp', ModerateOperation.stamp),
      ('act_stamplist', ModerateOperation.stamplist),
      ('act_copy', ModerateOperation.copy),
      ('act_merge', ModerateOperation.merge),
      ('act_split', ModerateOperation.split),
    ];
    for (final (name, op) in cases) {
      test('${op.name}: the answer and the fragment give the same window, one request', () async {
        knowV4Status();
        final (window, log) = await open(name, op);
        final api = (window as ModerateWindowReady).form;
        final web = (webOf(name, op) as ModerateWindowReady).form;
        expect(_form(api), _form(web));
        expect(api.v4, isTrue);
        expect(web.v4, isFalse);
        expect(log.gets, hasLength(1));
        final asked = Uri.parse(log.gets.single).queryParameters;
        expect(asked, containsPair('tsdmv', '4'));
        expect(asked, containsPair('tsdmform', '1'));
        expect(asked, containsPair('inajax', '1'));
        if (op == ModerateOperation.stamp || op == ModerateOperation.stamplist) {
          expect(api.choices.where((e) => e.value.isNotEmpty).every((e) => e.image != null), isTrue);
        }
      });
    }

    test('close and open follow the one the window checks (the thread is open: close)', () async {
      knowV4Status();
      final (window, _) = await open('mod_4_x', ModerateOperation.open);
      expect((window as ModerateWindowReady).form.operation, ModerateOperation.close);
    });

    test('the levels: none is never the current level, as the web page marks none', () async {
      knowV4Status();
      final (window, _) = await open('mod_1_stick', ModerateOperation.stick);
      final form = (window as ModerateWindowReady).form;
      expect(form.levels.map((e) => e.value), ['0', '1']);
      expect(form.currentLevel, isNull);
    });

    test("move leaves the thread's own forum out, copy keeps it, both with their categories", () async {
      knowV4Status();
      final (move, _) = await open('mod_2_x', ModerateOperation.move);
      final (copy, _) = await open('act_copy', ModerateOperation.copy);
      final moving = (move as ModerateWindowReady).form;
      expect(moving.forums.map((e) => e.value), isNot(contains('$_fid')));
      expect(moving.forums.firstWhere((e) => e.value == '15').depth, 1);
      expect(moving.canRedirect, isTrue);
      expect((copy as ModerateWindowReady).form.forums.map((e) => e.value), contains('$_fid'));
    });

    test(
      'a window served without the operation is unavailable either way (no recommendation, no categories)',
      () async {
        knowV4Status();
        for (final (name, op) in [
          ('mod_1_recommend', ModerateOperation.recommend),
          ('mod_2_type', ModerateOperation.type),
        ]) {
          final (window, log) = await open(name, op);
          expect(_describe(window), 'refused(, true)', reason: name);
          expect(_describe(webOf(name, op)), 'refused(, true)', reason: name);
          expect(log.gets, hasLength(1));
        }
      },
    );

    test("the forum's refusal is the refusal of the fragment, in its words", () async {
      knowV4Status();
      final (window, log) = await open('mod_nopermission', ModerateOperation.stick, tid: '1125');
      expect(_describe(window), _describe(webOf('mod_nopermission', ModerateOperation.stick, tid: '1125')));
      expect(_describe(window), 'refused(抱歉，您没有权限使用管理功能, false)');
      expect(log.gets, hasLength(1));
    });

    test('a group refusal for good stays unavailable', () async {
      knowV4Status();
      final log = _Log();
      final window = await _repo(
        log,
        api: {
          'ok': 0,
          'error': 'message',
          'message': '抱歉，您没有权限添加图章',
          'message_key': 'no_privilege_stampthread',
          'login': 0,
          'uid': _mod,
          'form': 'moderate',
        },
      ).fetchWindow(ModerateOperation.stamp, tid: _tid, fid: _fid).run();
      expect(_describe(window.getOrElse((e) => throw StateError('$e'))), 'refused(抱歉，您没有权限添加图章, true)');
    });

    test('flag off: asked exactly as before, no tsdmv', () async {
      for (final status in [
        null,
        v4Status({'v4': null}),
        v4Status({
          'forms': <String>['rate', 'report'],
        }),
      ]) {
        TsdmAppApi.reset();
        if (status != null) {
          knowV4Status(status);
        }
        final (window, log) = await open('mod_1_stick', ModerateOperation.stick, v4: false);
        expect(window, isA<ModerateWindowReady>());
        expect((window as ModerateWindowReady).form.v4, isFalse);
        expect(log.gets, [
          withTsdmAppJsonWrite(ModerateForm.windowUrl(ModerateOperation.stick, tid: _tid, fid: _fid)),
        ]);
      }
    });

    test('an answer that is not the form: read the window as before, the stale flag forgotten', () async {
      knowV4Status();
      final log = _Log();
      // A plugin that took the flag back answers the 3.9.0 result of the window.
      final window = await _repo(
        log,
        api: _fx('mod_1_stick.xml'),
        web: _fx('mod_1_stick.xml'),
      ).fetchWindow(ModerateOperation.stick, tid: _tid, fid: _fid).run();
      expect(window.getOrElse((e) => throw StateError('$e')), isA<ModerateWindowReady>());
      expect(log.gets, hasLength(2));
      expect(Uri.parse(log.gets.last).queryParameters, isNot(contains('tsdmv')));
      expect(TsdmAppApi.pluginInfo.value?.v4, isNull);
    });

    test("another account's answer is refused, nothing read after it", () async {
      knowV4Status();
      final log = _Log();
      final window = await _repo(
        log,
        api: _fx('mod_1_stick.json'),
        web: _fx('mod_1_stick.xml'),
        uid: 31,
      ).fetchWindow(ModerateOperation.stick, tid: _tid, fid: _fid).run();
      expect(window.getLeft().toNullable(), isA<IdentityChangedException>());
      expect(log.gets, hasLength(1));
    });

    test('a window of the API is posted once with tsdmv=4, told by message_key', () async {
      knowV4Status();
      final (window, _) = await open('mod_1_stick', ModerateOperation.stick);
      final form = (window as ModerateWindowReady).form;
      const request = ModerateRequest(operation: ModerateOperation.stick, level: '1', reason: '广告/SPAM');
      for (final (posted, expected) in [
        (
          {'ok': 1, 'type': 'result', 'schema': 13, 'kind': 'handle', 'uid': _mod, 'message_key': 'admin_succeed'},
          'ok',
        ),
        (
          {
            'ok': 0,
            'type': 'result',
            'schema': 13,
            'kind': 'handle',
            'uid': _mod,
            'message': '抱歉，您没有权限设置主题置顶',
            'message_key': 'no_privilege_stickthread',
          },
          '抱歉，您没有权限设置主题置顶',
        ),
        // Done in the forum's words without the key: not told a success.
        ({'ok': 1, 'type': 'result', 'schema': 13, 'kind': 'handle', 'uid': _mod, 'message_key': ''}, ''),
      ]) {
        final log = _Log();
        final outcome = await _repo(log, posted: posted).submit(form, request).run();
        final told = switch (outcome.getOrElse((e) => throw StateError('$e'))) {
          ModerateSucceeded() => 'ok',
          ModerateRefused(:final message) => message,
        };
        expect(told, expected);
        expect(log.posts, hasLength(1));
        final (url, body) = log.posts.single;
        expect(Uri.parse(url).queryParameters, allOf(containsPair('tsdmv', '4'), containsPair('tsdmapp', 'json')));
        expect(Uri.parse(url).queryParameters, containsPair('optgroup', '1'));
        expect(body, containsPair('moderate[]', _tid));
        expect(body, containsPair('operations[]', 'stick'));
        expect(body, containsPair('sticklevel', '1'));
        expect(body, isNot(contains('modsubmit')));
      }
    });

    test('a window of the web page is posted as before', () async {
      final form = (webOf('mod_1_stick', ModerateOperation.stick) as ModerateWindowReady).form;
      final log = _Log();
      await _repo(log, posted: '').submit(form, const ModerateRequest(operation: ModerateOperation.stick)).run();
      expect(log.posts.single.$1, form.submitUrl);
      expect(Uri.parse(log.posts.single.$1).queryParameters, isNot(contains('tsdmv')));
    });
  });

  group('several threads (moderate[])', () {
    const tids = ['9202952', '9202810', '9202809'];

    Future<ModerateBatchWindow> open(String name, ModerateOperation op, List<String> asked) async {
      final log = _Log();
      final window = await _repo(
        log,
        api: _fx('$name.json'),
        web: _fx('$name.xml'),
      ).fetchBatchWindow(op, tids: asked, fid: _fid).run();
      expect(log.gets, hasLength(1));
      return window.getOrElse((e) => throw StateError('$e'));
    }

    for (final (name, op, asked) in [
      ('batch_1', ModerateOperation.stick, tids),
      ('batch_1', ModerateOperation.highlight, tids),
      ('batch_4', ModerateOperation.open, tids.take(2).toList()),
    ]) {
      test('${op.name}: the same threads and window either way', () async {
        knowV4Status();
        final api = (await open(name, op, asked) as ModerateBatchWindowReady).form;
        final web =
            (ModerateRepository.batchWindowOf(
                      _fx('$name.xml'),
                      op,
                      tids: asked,
                      fid: _fid,
                      uid: _mod,
                    ).getOrElse((e) => throw StateError('$e'))
                    as ModerateBatchWindowReady)
                .form;
        expect(api.tids, web.tids);
        expect(_form(api.window), _form(web.window));
        expect(api.window.fields, isNot(contains('moderate[]')));
        // As picked: the window of several threads does not follow what one thread's checks.
        expect(api.window.operation, op);
        final body = api.body(ModerateRequest(operation: op));
        expect([for (var i = 0; i < api.tids.length; i++) body['moderate[$i]']], api.tids);
      });
    }

    test('a thread served that was not asked: not that window, read as before', () async {
      knowV4Status();
      final answer = _fx('batch_1.json')! as Map<String, dynamic>;
      final other = jsonDecode(jsonEncode(answer)) as Map<String, dynamic>;
      (other['submit'] as Map<String, dynamic>)['lists'] = {
        'moderate[]': ['1'],
      };
      final log = _Log();
      final window = await _repo(
        log,
        api: other,
        web: _fx('batch_1.xml'),
      ).fetchBatchWindow(ModerateOperation.stick, tids: tids, fid: _fid).run();
      expect(window.getOrElse((e) => throw StateError('$e')), isA<ModerateBatchWindowReady>());
      expect(log.gets, hasLength(2));
    });
  });

  group('floor windows (delpost, warn, banpost)', () {
    Future<(FloorModerateWindow, _Log)> open(String name, FloorModerateAction action, String tid, String pid) async {
      final log = _Log();
      final window = await _repo(
        log,
        api: _fx('$name.json'),
        web: _fx('$name.xml'),
      ).fetchFloorWindow(action, tid: tid, fid: _fid, pid: pid).run();
      return (window.getOrElse((e) => throw StateError('$e')), log);
    }

    FloorModerateWindow webOf(String name, FloorModerateAction action, String tid, String pid) =>
        ModerateRepository.floorWindowOf(
          _fx('$name.xml'),
          action,
          tid: tid,
          fid: _fid,
          pid: pid,
          uid: _mod,
        ).getOrElse((e) => throw StateError('$e'));

    for (final (name, action, tid, pid) in [
      ('floor_delpost', FloorModerateAction.delete, _tid, '11737'),
      ('floor_banpost', FloorModerateAction.ban, _tid, '11737'),
      ('floor_warn_ok', FloorModerateAction.warn, '9202780', '11244'),
    ]) {
      test('${action.action}: the same window either way, posted with tsdmv=4', () async {
        knowV4Status();
        final (window, log) = await open(name, action, tid, pid);
        final api = (window as FloorModerateWindowReady).form;
        final web = (webOf(name, action, tid, pid) as FloorModerateWindowReady).form;
        expect(_floor(api), _floor(web));
        expect(log.gets, hasLength(1));
        expect(Uri.parse(api.submitUrl).queryParameters, containsPair('tsdmv', '4'));
        expect(Uri.parse(web.submitUrl).queryParameters, isNot(contains('tsdmv')));
        expect(api.body(reason: 'x'), web.body(reason: 'x'));
      });
    }

    test(
      "refusals as the fragment's: the forum's words; the first floor sent on to the thread's deletion",
      () async {
        knowV4Status();
        final (warn, _) = await open('floor_warn_refused', FloorModerateAction.warn, _tid, '11737');
        expect(_describe(warn), _describe(webOf('floor_warn_refused', FloorModerateAction.warn, _tid, '11737')));
        expect(_describe(warn), 'refused(抱歉，您没有权限警告该作者)');
        // The first floor: the forum sends the window on to the thread's deletion, without words; the write result
        // of plugin 3.9.0 (the old path) is the redirect.
        final log = _Log();
        final first =
            (await _repo(
              log,
              api: _fx('floor_delpost_first.json'),
            ).fetchFloorWindow(FloorModerateAction.delete, tid: _tid, fid: _fid, pid: '11736').run()).getOrElse(
              (e) => throw StateError('$e'),
            );
        final before = ModerateRepository.floorWindowOf(
          _fx('floor_delpost_first_v39.json'),
          FloorModerateAction.delete,
          tid: _tid,
          fid: _fid,
          pid: '11736',
          uid: _mod,
        ).getOrElse((e) => throw StateError('$e'));
        expect(_describe(first), _describe(before));
        expect(_describe(first), 'refused()');
        expect(log.gets, hasLength(1));
      },
    );

    test('a message with words and a url keeps its words; only the thread deletion goes without', () async {
      knowV4Status();
      Map<String, Object?> message(String text, String url) => {
        'ok': 0,
        'error': 'message',
        'message': text,
        'message_key': text.isEmpty ? '' : 'admin_nopermission',
        'login': 0,
        'uid': _mod,
        'form': 'delpost',
        'url': url,
      };
      for (final (answer, expected) in [
        (message('抱歉，您没有权限使用管理功能', 'https://forum.test/forum.php?mod=viewthread&tid=$_tid'), 'refused(抱歉，您没有权限使用管理功能)'),
        (
          message(
            '',
            'https://forum.test/forum.php?mod=topicadmin&action=moderate&operation=delete&optgroup=3&fid=2&moderate[]=$_tid',
          ),
          'refused()',
        ),
      ]) {
        final window = await _repo(
          _Log(),
          api: answer,
        ).fetchFloorWindow(FloorModerateAction.delete, tid: _tid, fid: _fid, pid: '11736').run();
        expect(_describe(window.getOrElse((e) => throw StateError('$e'))), expected);
      }
    });

    test('a hidden floor checks the undoing', () async {
      knowV4Status();
      final answer = jsonDecode(jsonEncode(_fx('floor_banpost.json'))) as Map<String, dynamic>;
      (answer['banned'] as Map<String, dynamic>)['value'] = '0';
      final log = _Log();
      final window = await _repo(
        log,
        api: answer,
      ).fetchFloorWindow(FloorModerateAction.ban, tid: _tid, fid: _fid, pid: '11737').run();
      final form = (window.getOrElse((e) => throw StateError('$e')) as FloorModerateWindowReady).form;
      expect(form.undo, isTrue);
      expect(form.body(), containsPair('banned', '0'));
    });

    test('sticking a reply is not a form of the API: asked as before', () async {
      knowV4Status();
      final log = _Log();
      await _repo(log, web: '').fetchFloorWindow(FloorModerateAction.stick, tid: _tid, fid: _fid, pid: '11737').run();
      expect(Uri.parse(log.gets.single).queryParameters, isNot(contains('tsdmv')));
    });

    test('flag off: asked as before', () async {
      knowV4Status(
        v4Status({
          'forms': <String>['moderate'],
        }),
      );
      final (window, log) = await open('floor_delpost', FloorModerateAction.delete, _tid, '11737');
      expect((window as FloorModerateWindowReady).form.v4, isFalse);
      expect(log.gets, [
        withTsdmAppJsonWrite(
          FloorModerateForm.windowUrl(FloorModerateAction.delete, tid: _tid, fid: _fid, pid: '11737'),
        ),
      ]);
    });
  });

  group('categories (threadtypes)', () {
    for (final fid in [13, 2]) {
      test('forum $fid: the same categories either way', () async {
        knowV4Status();
        final log = _Log();
        final types = await _repo(
          log,
          api: _fx('threadtypes_$fid.json'),
          web: _fx('threadtypes_$fid.xml'),
        ).fetchThreadTypes(fid).run();
        final web = ModerateRepository.threadTypesOf(_fx('threadtypes_$fid.xml'), uid: _mod);
        String show(List<ModerateChoice> l) => l.map(_choice).join(',');
        expect(
          show(types.getOrElse((e) => throw StateError('$e'))),
          show(web.getOrElse((e) => throw StateError('$e'))),
        );
        expect(log.gets, hasLength(1));
        expect(Uri.parse(log.gets.single).queryParameters, containsPair('tsdmv', '4'));
      });
    }
  });

  group('taking rates back (removerate)', () {
    const tid = '1125';
    const pid = '200010';

    FloorOpsRepository repo(_Log log, {Object? api, Object? web, Object? posted, Object? once}) => FloorOpsRepository(
      get: (url) async {
        log.gets.add(url);
        final data = Uri.parse(url).queryParameters['tsdmv'] == '4' ? api : web;
        return data == null ? left(HttpRequestFailedException(null)) : right((statusCode: 200, data: data));
      },
      getOnce: (url) async {
        log.gets.add(url);
        return once == null ? left(HttpRequestFailedException(null)) : right((statusCode: 200, data: once));
      },
      post: (url, body) async {
        log.posts.add((url, body));
        return posted == null ? left(HttpRequestFailedException(null)) : right((statusCode: 200, data: posted));
      },
      currentUid: () => _admin,
    );

    Map<String, Object?> show(RemoveRateForm f) => {
      'fields': f.fields,
      'entries': [for (final e in f.entries) '${e.logId}|${e.username}|${e.uid}|${e.time}|${e.credit}|${e.reason}'],
      'canNotify': f.canNotify,
      'notifyForced': f.notifyForced,
      'body': f.body([f.entries.first.logId], reason: 'r'),
    };

    test('the same rates either way, posted once with tsdmv=4 and told by message_key', () async {
      knowV4Status();
      final log = _Log();
      final r = repo(
        log,
        api: _fx('removerate.json'),
        web: _fx('removerate.xml'),
        posted: {
          'ok': 1,
          'type': 'result',
          'schema': 13,
          'kind': 'handle',
          'uid': _admin,
          'message': '评分已撤销',
          'message_key': 'thread_rate_removesucceed',
        },
      );
      final window = await r.fetchRemoveRateWindow(tid: tid, pid: pid).run();
      final api = (window.getOrElse((e) => throw StateError('$e')) as RemoveRateWindowReady).form;
      final web =
          (FloorOpsRepository.removeRateWindowOf(
                    _fx('removerate.xml'),
                    tid: tid,
                    pid: pid,
                    uid: _admin,
                  ).getOrElse((e) => throw StateError('$e'))
                  as RemoveRateWindowReady)
              .form;
      expect(show(api), show(web));
      expect(api.entries.single.time, '2026-10-1 07:21');
      expect(api.entries.single.credit, '威望 +20');
      expect(log.gets, hasLength(1));
      final outcome = await r.removeRates(api, [api.entries.single.logId]).run();
      expect(outcome.getOrElse((e) => throw StateError('$e')), isA<FloorOpSucceeded>());
      expect(Uri.parse(log.posts.single.$1).queryParameters, containsPair('tsdmv', '4'));
    });

    test("the forum's refusal in its words; flag off asked as before", () async {
      knowV4Status();
      final log = _Log();
      final refused = await repo(
        log,
        api: {
          'ok': 0,
          'error': 'message',
          'message': '抱歉，您没有权限撤销评分',
          'message_key': 'no_privilege_removerate',
          'login': 0,
          'uid': _admin,
          'form': 'removerate',
        },
      ).fetchRemoveRateWindow(tid: tid, pid: pid).run();
      expect(_describe(refused.getOrElse((e) => throw StateError('$e'))), 'refused(抱歉，您没有权限撤销评分)');

      TsdmAppApi.reset();
      final before = _Log();
      await repo(before, web: _fx('removerate.xml')).fetchRemoveRateWindow(tid: tid, pid: pid).run();
      expect(before.gets, [withTsdmAppJsonWrite(RemoveRateForm.windowUrl(tid: tid, pid: pid))]);
    });

    test('an attachment deleted: told by count and message_key with tsdmv=4', () async {
      Map<String, Object?> result(int count, String key) => {
        'ok': count > 0 ? 1 : 0,
        'type': 'result',
        'schema': 13,
        'kind': 'handle',
        'uid': _admin,
        'count': count,
        'message': '',
        'message_key': key,
      };
      expect(deleteAttachmentOutcomeOf(result(1, 'deleteattach_succeed')), isA<FloorOpSucceeded>());
      expect(deleteAttachmentOutcomeOf(result(0, 'deleteattach_none')), isA<FloorOpRefused>());
      expect(deleteAttachmentOutcomeOf(result(0, 'deleteattach_succeed')), isA<FloorOpRefused>());

      knowV4Status();
      final log = _Log();
      final outcome = await repo(
        log,
        once: result(1, 'deleteattach_succeed'),
      ).deleteAttachment(tid: tid, pid: pid, aid: 9, formHash: 'f1f2f3f4', formUid: _admin).run();
      expect(outcome.getOrElse((e) => throw StateError('$e')), isA<FloorOpSucceeded>());
      expect(Uri.parse(log.gets.single).queryParameters, containsPair('tsdmv', '4'));

      TsdmAppApi.reset();
      final before = _Log();
      await repo(before, once: '1')
          .deleteAttachment(
            tid: tid,
            pid: pid,
            aid: 9,
            formHash: 'f1f2f3f4',
            formUid: _admin,
          )
          .run();
      expect(before.gets, [
        withTsdmAppJsonWrite(deleteAttachmentUrl(tid: tid, pid: pid, aid: 9, formHash: 'f1f2f3f4')),
      ]);
      expect(baseUrl, isNotEmpty);
    });
  });
}
