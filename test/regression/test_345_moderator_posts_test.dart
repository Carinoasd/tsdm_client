/// Floor management for moderators (warn, hide, delete a reply) and the moderation queue of a forum.
///
/// The fixtures `test/data/moderate/posts_*`, `queue_*` and `panel_*` are the test forum's answers to a moderator of
/// forum 10 (Discuz! X5 with plugin tsdmapp 3.4.0), scrubbed: the floor windows
/// `forum.php?mod=topicadmin&action=warn|banpost|delpost&topiclist[]=PID` asked with `tsdmapp=json` and once without
/// (the AJAX fragment), the refusals (no moderator, no permission to warn this author, the first floor's deletion
/// redirected to the thread's), the results; the moderation panel's lists
/// `forum.php?mod=modcp&action=moderate&op=threads|replies` cut to their main column, the panel's password form, its
/// refusals (no access, locked), and the answers to the queue's operations and to the panel's password.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/moderate_form.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:tsdm_client/features/moderate/repository/moderate_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/floor_moderate_dialog.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

const _dir = 'test/data/moderate';
const _tid = '1234567';
const _pid = '7654321';
const _fid = 10;
const _uid = 31;

String _text(String name) => File('$_dir/$name').readAsStringSync();

Object? _data(String name) {
  final text = _text(name);
  return name.endsWith('.json') ? jsonDecode(text) : text;
}

Either<AppException, FloorModerateWindow> _windowOf(
  String name,
  FloorModerateAction action, {
  String pid = _pid,
  int uid = _uid,
}) => ModerateRepository.floorWindowOf(_data(name), action, tid: _tid, fid: _fid, pid: pid, uid: uid);

FloorModerateForm _window(String name, FloorModerateAction action, {String pid = _pid}) =>
    switch (_windowOf(name, action, pid: pid)) {
      Right(value: FloorModerateWindowReady(:final form)) => form,
      final other => throw StateError('no window: $other'),
    };

ModerateQueueList _queue(String name, ModerateQueueKind kind, {Object? data}) =>
    switch (ModerateRepository.queueOf(data ?? _data(name), kind, fid: _fid, uid: _uid)) {
      Right(value: ModerateQueueReady(:final page)) => page,
      final other => throw StateError('no list: $other'),
    };

ModerateResponse _ok(Object? data) => (statusCode: 200, data: data);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('floor window', () {
    test('warn: the served fields, the reasons, the notice; warning is what the window checks', () {
      final form = _window('posts_window_warn.json', FloorModerateAction.warn);
      expect(form.uid, _uid);
      expect(form.fields, {
        'formhash': 'f1f2f3f4',
        'fid': '10',
        'tid': _tid,
        'handlekey': 'mods',
        'topiclist[]': _pid,
      });
      expect(form.undo, isFalse);
      expect(form.reasons, containsAll(['广告/SPAM', '原创内容']));
      expect(form.reasons.any((e) => e.startsWith('-')), isFalse);
      expect(form.canNotify, isTrue);
      expect(form.notifyForced, isFalse);
    });

    test('a hidden floor: the window checks showing it again', () {
      final form = _window('posts_window_ban_banned.json', FloorModerateAction.ban, pid: '7654322');
      expect(form.undo, isTrue);
      expect(form.body(), containsPair('banned', '0'));
    });

    test('delete: no choice, no user operation sent', () {
      final form = _window('posts_window_delete.json', FloorModerateAction.delete);
      expect(form.undo, isFalse);
      final body = form.body(reason: ' 重复发帖 ', notify: true);
      expect(body, {
        'formhash': 'f1f2f3f4',
        'fid': '10',
        'tid': _tid,
        'handlekey': 'mods',
        'topiclist[]': _pid,
        'reason': '重复发帖',
        'sendreasonpm': 'on',
      });
      // The window offers them; the app never sends them.
      expect(
        body.containsKey('banuser') || body.containsKey('userdelpost') || body.containsKey('crimerecord'),
        isFalse,
      );
    });

    test('warn body: warned 1, no notice unless asked', () {
      final body = _window('posts_window_warn.json', FloorModerateAction.warn).body(reason: '违规内容');
      expect(body['warned'], '1');
      expect(body['reason'], '违规内容');
      expect(body.containsKey('sendreasonpm'), isFalse);
    });

    test('the AJAX fragment of a forum without the plugin', () {
      final form = _window('posts_window_warn_ajax.xml', FloorModerateAction.warn);
      expect(form.fields['topiclist[]'], _pid);
      expect(form.undo, isFalse);
    });

    test('a window of another action, floor or account is not taken', () {
      // The warn window asked as the hiding.
      expect(_windowOf('posts_window_warn.json', FloorModerateAction.ban).isLeft(), isTrue);
      expect(_windowOf('posts_window_warn.json', FloorModerateAction.warn, pid: '1').isLeft(), isTrue);
      expect(
        _windowOf('posts_window_warn.json', FloorModerateAction.warn, uid: 99),
        isA<Left<AppException, FloorModerateWindow>>().having(
          (e) => e.value,
          'value',
          isA<IdentityChangedException>(),
        ),
      );
    });

    test("the forum's refusals in its words; the first floor's deletion is no window", () {
      expect(
        _windowOf('posts_window_nopermission.json', FloorModerateAction.warn),
        isA<Right<AppException, FloorModerateWindow>>().having(
          (e) => (e.value as FloorModerateWindowRefused).message,
          'message',
          '抱歉，您没有权限使用管理功能',
        ),
      );
      expect(
        _windowOf('posts_window_warn_nopermission.json', FloorModerateAction.warn),
        isA<Right<AppException, FloorModerateWindow>>().having(
          (e) => (e.value as FloorModerateWindowRefused).message,
          'message',
          '抱歉，您没有权限警告该作者',
        ),
      );
      expect(
        _windowOf('posts_window_firstfloor.json', FloorModerateAction.delete, pid: '7654320'),
        isA<Right<AppException, FloorModerateWindow>>().having(
          (e) => e.value,
          'value',
          isA<FloorModerateWindowRefused>(),
        ),
      );
    });

    test('the operations of a floor: no reply deletion on the first floor', () {
      expect(floorModerateActionsFor(first: false), [
        FloorModerateAction.warn,
        FloorModerateAction.ban,
        FloorModerateAction.delete,
      ]);
      expect(floorModerateActionsFor(first: true), [FloorModerateAction.warn, FloorModerateAction.ban]);
    });
  });

  group('outcome', () {
    test('a floor: admin_succeed, as JSON and as AJAX', () {
      expect(ModerateRepository.outcomeOf(_data('posts_result_succeed.json')), isA<ModerateSucceeded>());
      expect(
        (ModerateRepository.outcomeOf(_data('posts_result_succeed_ajax.xml')) as ModerateSucceeded).message,
        '管理操作成功',
      );
    });

    test('the queue: modcp_mod_succeed, the key of the other flow is no success', () {
      expect(
        ModerateRepository.outcomeOf(_data('queue_result_succeed.json'), successKey: 'modcp_mod_succeed'),
        isA<ModerateSucceeded>(),
      );
      expect(ModerateRepository.outcomeOf(_data('queue_result_succeed.json')), isA<ModerateRefused>());
      expect(
        ModerateRepository.outcomeOf(_data('posts_result_succeed.json'), successKey: 'modcp_mod_succeed'),
        isA<ModerateRefused>(),
      );
      expect(
        (ModerateRepository.outcomeOf(_data('queue_result_succeed_ajax.xml'), successKey: 'modcp_mod_succeed')
                as ModerateSucceeded)
            .message,
        '审核处理完毕',
      );
    });

    test("the panel's session ended: a refusal without words", () {
      final outcome = ModerateRepository.outcomeOf(_data('queue_result_expired.json'), successKey: 'modcp_mod_succeed');
      expect(outcome, isA<ModerateRefused>().having((e) => e.message, 'message', isEmpty));
    });
  });

  group('queue', () {
    test('threads: the waiting threads and the fields of the list', () {
      final list = _queue('queue_threads.html', ModerateQueueKind.threads);
      expect(list.uid, _uid);
      expect(list.fields, {'formhash': 'f1f2f3f4', 'fid': '10', 'filter': '0', 'posttableid': ''});
      expect(list.items.map((e) => e.id), ['1234572', '1234571']);
      final item = list.items.first;
      expect(item.subject, '测试待审主題 2');
      expect(item.author, '测试会员');
      expect(item.authorUid, 32);
      expect(item.time, '发表于 2026-11-7 22:26');
      expect(item.message, '待審核主題 2 的內容，用來測試審核隊列。');
      expect(list.hasNext, isFalse);
    });

    test('replies: the thread replied to, an author without a link', () {
      final list = _queue('queue_replies.html', ModerateQueueKind.replies);
      expect(list.items.map((e) => e.id), ['7654330']);
      expect(list.items.single.subject, '测试主题');
      expect(list.items.single.author, '测试会员');
      expect(list.items.single.authorUid, isNull);
      expect(list.fields['posttableid'], '0');
    });

    test('the list of another forum, empty or not, is not taken', () {
      for (final name in ['queue_replies_empty.html', 'queue_replies.html']) {
        expect(
          ModerateRepository.queueOf(_data(name), ModerateQueueKind.replies, fid: 2, uid: _uid),
          isA<Left<AppException, ModerateQueueAnswer>>(),
        );
      }
    });

    test('nothing waiting', () {
      final list = _queue('queue_replies_empty.html', ModerateQueueKind.replies);
      expect(list.items, isEmpty);
      expect(list.hasNext, isFalse);
    });

    test('a next page', () {
      final html = _text(
        'queue_threads.html',
      ).replaceFirst('</form>', '</form><div class="pg"><a href="forum.php?page=2" class="nxt">下一页</a></div>');
      expect(_queue('', ModerateQueueKind.threads, data: html).hasNext, isTrue);
      expect(ModerateQueueList.url(ModerateQueueKind.threads, fid: _fid, page: 2), contains('&page=2'));
    });

    test('the list of the other tab, or of another forum, is not taken', () {
      expect(
        ModerateRepository.queueOf(_data('queue_threads.html'), ModerateQueueKind.replies, fid: _fid, uid: _uid),
        isA<Left<AppException, ModerateQueueAnswer>>(),
      );
      expect(
        ModerateRepository.queueOf(_data('queue_threads.html'), ModerateQueueKind.threads, fid: 2, uid: _uid),
        isA<Left<AppException, ModerateQueueAnswer>>(),
      );
    });

    test('a page served to another account is dropped', () {
      expect(
        ModerateRepository.queueOf(_data('queue_threads.html'), ModerateQueueKind.threads, fid: _fid, uid: 99),
        isA<Left<AppException, ModerateQueueAnswer>>().having((e) => e.value, 'value', isA<IdentityChangedException>()),
      );
    });

    test("the panel's password form", () {
      expect(
        ModerateRepository.queueOf(_data('queue_login.html'), ModerateQueueKind.threads, fid: _fid, uid: _uid),
        isA<Right<AppException, ModerateQueueAnswer>>().having(
          (e) => (e.value as ModerateQueueNeedsLogin).formHash,
          'formHash',
          'f1f2f3f4',
        ),
      );
    });

    test("the panel's refusals in its words", () {
      String refusal(String name) => switch (ModerateRepository.queueOf(
        _data(name),
        ModerateQueueKind.threads,
        fid: _fid,
        uid: _uid,
      )) {
        Right(value: ModerateQueueRefused(:final message)) => message,
        final other => throw StateError('no refusal: $other'),
      };
      expect(refusal('queue_noaccess.html'), '抱歉，您没有权限访问管理面板，请重新登录站点，然后重试');
      expect(refusal('queue_locked.html'), startsWith('抱歉，由于密码尝试次数过多，管理面板已锁定'));
      expect(refusal('queue_locked.html'), contains('2026-11-7 22:47'));
    });

    test('an operation: the fields of the list, this forum, one item, never dismiss', () {
      final list = _queue('queue_threads.html', ModerateQueueKind.threads);
      expect(list.submitUrl, contains('mod=modcp&action=moderate&op=threads&fid=10'));
      expect(list.body(ModerateQueueAction.ignore, list.items.first, reason: ' 忽略 '), {
        'formhash': 'f1f2f3f4',
        'fid': '10',
        'filter': '0',
        'posttableid': '',
        'modact': 'ignore',
        'modsubmit': '1',
        'handlekey': 'mods',
        'moderate[]': '1234572',
        'reason': '忽略',
      });
      expect(ModerateQueueAction.values.map((e) => e.name), ['validate', 'ignore', 'delete']);
    });
  });

  group('panel password', () {
    test("the panel's answers", () {
      expect(ModerateRepository.panelLoginOf(_data('panel_login_redirect.json')), isA<ModeratePanelLoggedIn>());
      expect(ModerateRepository.panelLoginOf(_data('panel_login_wrong.json')), isA<ModeratePanelWrongPassword>());
      expect(
        ModerateRepository.panelLoginOf(_data('panel_login_locked.json')),
        isA<ModeratePanelRefused>().having((e) => e.message, 'message', startsWith('抱歉，由于密码尝试次数过多')),
      );
      // Without the plugin: the login form again, or the panel.
      expect(ModerateRepository.panelLoginOf(_text('queue_login.html')), isA<ModeratePanelWrongPassword>());
      expect(ModerateRepository.panelLoginOf(_text('queue_threads.html')), isA<ModeratePanelLoggedIn>());
    });
  });

  group('repository', () {
    test('a floor: the window asked with the plugin, posted once to its action', () async {
      final gets = <String>[];
      final posts = <(String, Map<String, String>)>[];
      final repo = ModerateRepository(
        get: (url) async {
          gets.add(url);
          return right(_ok(_data('posts_window_warn.json')));
        },
        post: (url, body) async {
          posts.add((url, body));
          return right(_ok(_data('posts_result_succeed.json')));
        },
        currentUid: () => _uid,
      );
      final window = await repo.fetchFloorWindow(FloorModerateAction.warn, tid: _tid, fid: _fid, pid: _pid).run();
      expect(gets.single, contains('action=warn&fid=10&tid=$_tid&topiclist%5B%5D=$_pid'));
      expect(gets.single, contains('tsdmapp=json'));
      final form = (window.getRight().toNullable()! as FloorModerateWindowReady).form;
      final outcome = await repo.submitFloor(form, reason: '违规内容').run();
      expect(outcome.getRight().toNullable(), isA<ModerateSucceeded>());
      expect(posts, hasLength(1));
      expect(posts.single.$1, contains('mod=topicadmin&action=warn&modsubmit=yes'));
      expect(posts.single.$2['warned'], '1');
    });

    test('the window or the list of one account is never posted for another', () async {
      var uid = _uid;
      var posted = 0;
      final repo = ModerateRepository(
        get: (_) async => right(_ok(_data('posts_window_warn.json'))),
        post: (_, _) async {
          posted++;
          return right(_ok(_data('posts_result_succeed.json')));
        },
        currentUid: () => uid,
      );
      final form = _window('posts_window_warn.json', FloorModerateAction.warn);
      final list = _queue('queue_threads.html', ModerateQueueKind.threads);
      uid = 99;
      expect(await repo.submitFloor(form).run(), isA<Left<AppException, ModerateOutcome>>());
      expect(
        await repo.submitQueue(list, ModerateQueueAction.validate, list.items.first).run(),
        isA<Left<AppException, ModerateOutcome>>(),
      );
      expect(posted, 0);
    });

    test('the queue: the list asked as a web page, an operation posted once', () async {
      final gets = <String>[];
      final posts = <(String, Map<String, String>)>[];
      final repo = ModerateRepository(
        get: (url) async {
          gets.add(url);
          return right(_ok(_text('queue_threads.html')));
        },
        post: (url, body) async {
          posts.add((url, body));
          return right(_ok(_data('queue_result_succeed.json')));
        },
        currentUid: () => _uid,
      );
      final answer = await repo.fetchQueue(ModerateQueueKind.threads, fid: _fid).run();
      expect(gets.single, endsWith('forum.php?mod=modcp&action=moderate&op=threads&fid=10&filter=0'));
      final list = (answer.getRight().toNullable()! as ModerateQueueReady).page;
      final outcome = await repo.submitQueue(list, ModerateQueueAction.validate, list.items.last).run();
      expect(outcome.getRight().toNullable(), isA<ModerateSucceeded>());
      expect(posts.single.$1, contains('op=threads&fid=10'));
      expect(posts.single.$2['modact'], 'validate');
      expect(posts.single.$2['moderate[]'], '1234571');
    });

    test("the panel's password: sent once, to the panel's login", () async {
      final posts = <(String, Map<String, String>)>[];
      final repo = ModerateRepository(
        get: (_) async => throw StateError('no get'),
        post: (url, body) async {
          posts.add((url, body));
          return right(_ok(_data('panel_login_redirect.json')));
        },
        currentUid: () => _uid,
      );
      final answer = await repo.loginPanel(formHash: 'f1f2f3f4', fid: _fid, password: 'secret').run();
      expect(answer.getRight().toNullable(), isA<ModeratePanelLoggedIn>());
      expect(posts.single.$1, endsWith('forum.php?mod=modcp&action=login'));
      expect(posts.single.$2, {
        'formhash': 'f1f2f3f4',
        'fid': '10',
        'submit': 'yes',
        'login_panel': 'yes',
        'cppwd': 'secret',
      });
    });
  });

  group('dialog', () {
    testWidgets('once sent, the floor dialog stays until the answer and tells the page to reload', (tester) async {
      final answer = Completer<Either<AppException, ModerateResponse>>();
      final repo = ModerateRepository(
        get: (_) async => right(_ok(_data('posts_window_warn.json'))),
        post: (_, _) => answer.future,
        currentUid: () => _uid,
      );
      bool? done;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async => done = await showFloorModerateDialog(
                    context,
                    action: FloorModerateAction.warn,
                    tid: _tid,
                    fid: _fid,
                    pid: _pid,
                    repository: repo,
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
      expect(find.byType(FloorModerateDialog), findsOneWidget);
      await tester.tap(find.text(t.general.ok));
      await tester.pump();
      // Back and the barrier do not close it while the request is out.
      await tester.binding.handlePopRoute();
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      expect(find.byType(FloorModerateDialog), findsOneWidget);
      answer.complete(right(_ok(_data('posts_result_succeed.json'))));
      await tester.pumpAndSettle();
      expect(find.byType(FloorModerateDialog), findsNothing);
      expect(done, isTrue);
    });
  });
}
