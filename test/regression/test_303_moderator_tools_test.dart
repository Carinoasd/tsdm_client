/// Thread management for moderators (stick, digest, close and open, move, delete).
///
/// The fixtures under `test/data/moderate` are the test forum's answers to account 31 moderating forum 10 (Discuz!
/// X5 with plugin tsdmapp 3.5.0), scrubbed: the management windows `forum.php?mod=topicadmin&action=moderate&optgroup=N`
/// asked with `tsdmapp=json` (the write result `page` carrying the window) and once without (the AJAX fragment), the
/// refusal to open one for an account that does not moderate the forum, and the answers to the management requests
/// (success `admin_succeed`, `no_privilege_stickthread`, `admin_expiration_invalid`), as JSON and as AJAX.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_sheet.dart';
import 'package:tsdm_client/instance.dart';

const _dir = 'test/data/moderate';
const _tid = '1234567';
const _fid = 10;
const _uid = 31;

Object? _data(String name) {
  final text = File('$_dir/$name').readAsStringSync();
  return name.endsWith('.json') ? jsonDecode(text) : text;
}

ModerateForm _window(String name, ModerateOperation operation, {int uid = _uid}) =>
    switch (ModerateRepository.windowOf(_data(name), operation, tid: _tid, fid: _fid, uid: uid)) {
      Right(value: ModerateWindowReady(:final form)) => form,
      final other => throw StateError('no window: $other'),
    };

Map<String, dynamic> _forumPage({required int uid, required int fid, required int moderates}) => {
  'ok': 1,
  'api': 1,
  'uid': uid,
  'type': 'forum',
  'schema': 2,
  'forum': {'fid': fid, 'name': 'Forum', 'ismoderator': moderates},
};

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });
  setUp(ModerateRepository.resetModeratorCache);

  group('window', () {
    test('stick and digest: the levels the account may set, the current one selected', () {
      final stick = _window('window_stick_digest.json', ModerateOperation.stick);
      expect(stick.uid, _uid);
      expect(stick.levels.map((e) => e.value), ['0', '1']);
      expect(stick.currentLevel?.value, '1');
      expect(stick.fields, {
        'frommodcp': '',
        'formhash': 'f1f2f3f4',
        'fid': '10',
        'redirect': 'https://forum.test/./',
        'handlekey': 'mods',
        'moderate[]': _tid,
      });
      expect(stick.reasons, containsAll(['广告/SPAM', '原创内容']));
      expect(stick.reasons.any((e) => e.startsWith('-')), isFalse);
      expect(stick.canNotify, isTrue);
      expect(stick.notifyForced, isFalse);

      final digest = _window('window_stick_digest.json', ModerateOperation.digest);
      expect(digest.levels.map((e) => e.value), ['0', '1', '2', '3']);
      expect(digest.currentLevel?.value, '2');
    });

    test('close and open: both offered by the same window', () {
      expect(_window('window_close.json', ModerateOperation.open).operation, ModerateOperation.open);
      expect(_window('window_close.json', ModerateOperation.close).operation, ModerateOperation.close);
    });

    test("move: the forums by category, the thread's own forum left out", () {
      final move = _window('window_move.json', ModerateOperation.move);
      final fids = move.forums.map((e) => e.value).toList();
      expect(fids, isNot(contains('10')));
      expect(fids, containsAll(['2', '15', '9', '11']));
      expect(move.forums.firstWhere((e) => e.value == '15').depth, greaterThan(0));
      expect(move.forums.firstWhere((e) => e.value == '2').depth, 0);
      expect(move.forums.firstWhere((e) => e.value == '9').group, '🎮 遊戲次元');
      expect(move.canRedirect, isTrue);
    });

    test('delete', () {
      final delete = _window('window_delete.json', ModerateOperation.delete);
      expect(delete.canNotify, isTrue);
      expect(delete.submitUrl, contains('optgroup=3&modsubmit=yes'));
    });

    test('the AJAX fragment of a forum without the plugin', () {
      final form = _window('window_close_ajax.xml', ModerateOperation.close);
      expect(form.uid, 0);
      expect(form.fields['formhash'], 'f1f2f3f4');
    });

    test('a window of another group, thread or forum is not taken', () {
      // The close window (optgroup 4) is not the stick window.
      expect(
        ModerateRepository.windowOf(_data('window_close.json'), ModerateOperation.stick, tid: _tid, fid: _fid, uid: 31),
        isA<Left<AppException, ModerateWindow>>(),
      );
      expect(
        ModerateRepository.windowOf(_data('window_close.json'), ModerateOperation.close, tid: '1', fid: _fid, uid: 31),
        isA<Left<AppException, ModerateWindow>>(),
      );
      expect(
        ModerateRepository.windowOf(_data('window_close.json'), ModerateOperation.close, tid: _tid, fid: 2, uid: 31),
        isA<Left<AppException, ModerateWindow>>(),
      );
    });

    test('a window served to another account is dropped', () {
      final answer = ModerateRepository.windowOf(
        _data('window_close.json'),
        ModerateOperation.close,
        tid: _tid,
        fid: _fid,
        uid: 32,
      );
      expect(answer.getLeft().toNullable(), isA<IdentityChangedException>());
    });

    test("the forum's refusal to open it, in its words", () {
      final answer = ModerateRepository.windowOf(
        _data('window_nopermission.json'),
        ModerateOperation.close,
        tid: _tid,
        fid: _fid,
        uid: _uid,
      );
      expect(
        answer.getRight().toNullable(),
        isA<ModerateWindowRefused>().having((e) => e.message, 'message', '抱歉，您没有权限使用管理功能'),
      );
    });
  });

  group('request body', () {
    test('stick with an end day', () {
      final form = _window('window_stick_digest.json', ModerateOperation.stick);
      final body = ModerateRequest(
        operation: ModerateOperation.stick,
        level: '1',
        expiration: DateTime(2026, 11, 20),
        reason: ' 置頂公告 ',
        notify: true,
      ).body(form);
      expect(body, {
        ...form.fields,
        'operations[]': 'stick',
        'sticklevel': '1',
        'expirationstick': '2026-11-20',
        'reason': '置頂公告',
        'sendreasonpm': 'on',
      });
    });

    test('level 0 sends no end day', () {
      final form = _window('window_stick_digest.json', ModerateOperation.digest);
      final body = ModerateRequest(
        operation: ModerateOperation.digest,
        level: '0',
        expiration: DateTime(2026, 11, 20),
      ).body(form);
      expect(body['digestlevel'], '0');
      expect(body['expirationdigest'], '');
      expect(body.containsKey('sendreasonpm'), isFalse);
      expect(body.containsKey('highlight_color'), isFalse);
    });

    test('close, open', () {
      final form = _window('window_close.json', ModerateOperation.close);
      expect(const ModerateRequest(operation: ModerateOperation.close).body(form)['operations[]'], 'close');
      expect(const ModerateRequest(operation: ModerateOperation.open).body(form)['operations[]'], 'open');
    });

    test('move', () {
      final form = _window('window_move.json', ModerateOperation.move);
      final body = const ModerateRequest(operation: ModerateOperation.move, moveTo: '2', redirect: true).body(form);
      expect(body['operations[]'], 'move');
      expect(body['moveto'], '2');
      expect(body['threadtypeid'], '0');
      expect(body['type'], 'redirect');
    });

    test('delete sends no user operation', () {
      final form = _window('window_delete.json', ModerateOperation.delete);
      final body = const ModerateRequest(operation: ModerateOperation.delete, reason: '重复发帖').body(form);
      expect(body['operations[]'], 'delete');
      expect(body['reason'], '重复发帖');
      for (final key in ['banuser', 'userdelpost', 'crimerecord']) {
        expect(body.containsKey(key), isFalse);
      }
    });
  });

  group('outcome', () {
    test('success, by the language key', () {
      expect(
        ModerateRepository.outcomeOf(_data('result_succeed.json')),
        isA<ModerateSucceeded>().having((e) => e.message, 'message', '管理操作成功'),
      );
      expect(
        ModerateRepository.outcomeOf(_data('result_succeed_ajax.xml')),
        isA<ModerateSucceeded>().having((e) => e.message, 'message', '管理操作成功'),
      );
    });

    test("refusals in the forum's words", () {
      expect(
        ModerateRepository.outcomeOf(_data('result_stick_refused.json')),
        isA<ModerateRefused>().having((e) => e.message, 'message', '抱歉，您没有权限设置主题置顶'),
      );
      expect(
        ModerateRepository.outcomeOf(_data('result_stick_refused_ajax.xml')),
        isA<ModerateRefused>().having((e) => e.message, 'message', '抱歉，您没有权限设置主题置顶'),
      );
      expect(
        ModerateRepository.outcomeOf(_data('result_expiration_invalid.json')),
        isA<ModerateRefused>().having((e) => e.message, 'message', startsWith('抱歉，有效期无效')),
      );
      expect(ModerateRepository.outcomeOf('<html></html>'), isA<ModerateRefused>());
    });
  });

  group('repository', () {
    test('posts the window once, to the target of its group', () async {
      final posted = <(String, Map<String, String>)>[];
      final repo = ModerateRepository(
        get: (url) async => right((statusCode: 200, data: _data('window_stick_digest.json'))),
        post: (url, body) async {
          posted.add((url, body));
          return right((statusCode: 200, data: _data('result_succeed.json')));
        },
        currentUid: () => _uid,
      );
      final window = (await repo.fetchWindow(ModerateOperation.stick, tid: _tid, fid: _fid).run())
          .getRight()
          .toNullable();
      final form = (window! as ModerateWindowReady).form;
      final outcome = await repo
          .submit(form, const ModerateRequest(operation: ModerateOperation.stick, level: '0'))
          .run();
      expect(outcome.getRight().toNullable(), isA<ModerateSucceeded>());
      expect(posted, hasLength(1));
      expect(
        posted.single.$1,
        endsWith('/forum.php?mod=topicadmin&action=moderate&optgroup=1&modsubmit=yes&infloat=yes&inajax=1'),
      );
    });

    test('the window of one account is never posted for another', () async {
      var uid = _uid;
      var posts = 0;
      final repo = ModerateRepository(
        get: (url) async => right((statusCode: 200, data: _data('window_close.json'))),
        post: (url, body) async {
          posts++;
          return right((statusCode: 200, data: _data('result_succeed.json')));
        },
        currentUid: () => uid,
      );
      final window = (await repo.fetchWindow(ModerateOperation.close, tid: _tid, fid: _fid).run())
          .getRight()
          .toNullable();
      uid = 32;
      final outcome = await repo
          .submit((window! as ModerateWindowReady).form, const ModerateRequest(operation: ModerateOperation.close))
          .run();
      expect(outcome.getLeft().toNullable(), isA<IdentityChangedException>());
      expect(posts, 0);
    });
  });

  group('entry', () {
    ModerateRepository repo(Object? Function(String url) answer, {int uid = _uid, List<String>? asked}) =>
        ModerateRepository(
          get: (url) async {
            asked?.add(url);
            return right((statusCode: 200, data: answer(url)));
          },
          post: (url, body) async => throw StateError('no post'),
          currentUid: () => uid,
        );

    test('offered only when the forum says the account moderates the forum', () async {
      final asked = <String>[];
      expect(
        await repo(
          (_) => _forumPage(uid: _uid, fid: _fid, moderates: 1),
          asked: asked,
        ).isModerator(_fid),
        isTrue,
      );
      expect(asked.single, contains('mod=forumdisplay&fid=10'));
      expect(asked.single, contains('tsdmapp=json'));
      ModerateRepository.resetModeratorCache();
      expect(await repo((_) => _forumPage(uid: _uid, fid: _fid, moderates: 0)).isModerator(_fid), isFalse);
    });

    test('not offered to a guest, nor on an answer for another account or forum, nor without the plugin', () async {
      final asked = <String>[];
      expect(
        await repo((_) => _forumPage(uid: 0, fid: _fid, moderates: 1), uid: 0, asked: asked).isModerator(_fid),
        isFalse,
      );
      expect(asked, isEmpty);
      expect(await repo((_) => _forumPage(uid: 32, fid: _fid, moderates: 1)).isModerator(_fid), isFalse);
      expect(await repo((_) => _forumPage(uid: _uid, fid: 9, moderates: 1)).isModerator(_fid), isFalse);
      expect(await repo((_) => '<html><body>forum</body></html>').isModerator(_fid), isFalse);
      expect(
        await repo((_) => {'ok': 0, 'error': 'message', 'message': '抱歉，您没有权限访问该版块', 'uid': _uid}).isModerator(_fid),
        isFalse,
      );
    });

    test('kept per account and forum', () async {
      final asked = <String>[];
      final r = repo(
        (_) => _forumPage(uid: _uid, fid: _fid, moderates: 1),
        asked: asked,
      );
      await r.isModerator(_fid);
      await r.isModerator(_fid);
      expect(asked, hasLength(1));
    });

    test('the operations: close or open as the thread is, delete last', () {
      expect(moderateOperationsFor(closed: false), [
        ModerateOperation.stick,
        ModerateOperation.digest,
        ModerateOperation.close,
        ModerateOperation.move,
        ModerateOperation.delete,
      ]);
      expect(moderateOperationsFor(closed: true), contains(ModerateOperation.open));
      expect(moderateOperationsFor(closed: true), isNot(contains(ModerateOperation.close)));
    });
  });
}
