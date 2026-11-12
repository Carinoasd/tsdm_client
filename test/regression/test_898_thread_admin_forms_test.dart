/// Taking the bounty off a thread and refunding a paid thread (tsdmapp 3.9.0 §11.2): offered in the thread's
/// management menu where `perms.allow_removereward` / `allow_refund` say so and the plugin is known to give their
/// windows (3.9.0: the flags are older); the window is the small form `removereward` / `refund` (the bounty or the
/// sales, the forum's reasons, the notice), its form posted once only back to that operation of
/// `forum.php?mod=topicadmin` on this forum, with its fields as served, after a confirmation; done only on
/// `admin_succeed`, the forum's words otherwise.
///
/// The windows are the test forum's (scrubbed); the write results are shaped as the plugin's other management results
/// (the operations themselves are left to the emulator check).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/moderate/models/thread_admin_forms.dart';
import 'package:tsdm_client/features/moderate/models/thread_perms.dart';
import 'package:tsdm_client/features/moderate/repository/thread_admin_repository.dart';
import 'package:tsdm_client/features/moderate/widgets/moderate_sheet.dart';
import 'package:tsdm_client/features/moderate/widgets/thread_admin_dialogs.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

Map<String, dynamic> _json(String path) =>
    jsonDecode(File('test/data/$path.json').readAsStringSync()) as Map<String, dynamic>;

/// The plugin's management result `admin_succeed` served to the administrator (uid 32).
Map<String, dynamic> _succeed() => _json('moderate/result_succeed')..['uid'] = 32;

/// A refusal of the forum as a write result.
Map<String, dynamic> _refused(String key, String message) => {
  ..._succeed(),
  'ok': 0,
  'kind': 'message',
  'message': message,
  'message_key': key,
  'alert': 'error',
};

typedef _Posted = ({String url, Map<String, String> body});

ThreadAdminRepository _repo({
  required Object? window,
  Object? result,
  List<String>? asked,
  List<_Posted>? posted,
  int uid = 32,
}) => ThreadAdminRepository(
  get: (url) async {
    asked?.add(url);
    return right((statusCode: 200, data: window));
  },
  post: (url, body) async {
    posted?.add((url: url, body: body));
    return right((statusCode: 200, data: result));
  },
  currentUid: () => uid,
);

void _knowPlugin(String? version) {
  TsdmAppApi.pluginInfo.value = version == null ? null : TsdmAppPluginInfo(version: version, api: 1, nodoc: true);
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        scaffoldMessengerKey: snackbarKey,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  tearDown(() => _knowPlugin(null));

  group('offered', () {
    test('by the flags, once the plugin gives the windows', () {
      final perms = ThreadPerms.fromApi(_json('tsdmapp_390/thread_viewip')['perms'])!;
      expect(perms.adminActions(formsKnown: true), [ThreadAdminAction.removeReward]);
      expect(perms.adminActions(formsKnown: false), isEmpty);
      final both = ThreadPerms.fromApi({'allow_removereward': 1, 'allow_refund': 1})!;
      expect(both.adminActions(formsKnown: true), [ThreadAdminAction.removeReward, ThreadAdminAction.refund]);

      _knowPlugin(null);
      expect(threadAdminFormsKnown(), isFalse);
      _knowPlugin('3.8.2');
      expect(threadAdminFormsKnown(), isFalse);
      _knowPlugin('3.9.0');
      expect(threadAdminFormsKnown(), isTrue);
      _knowPlugin('3.10.0');
      expect(threadAdminFormsKnown(), isTrue);
    });

    testWidgets("in the thread's management menu, before delete", (tester) async {
      _knowPlugin('3.9.0');
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showThreadModerateSheet(
              context,
              tid: '9203116',
              fid: 2,
              closed: false,
              perms: ThreadPerms.fromApi({'allow_delthread': 1, 'allow_removereward': 1, 'allow_refund': 1}),
            ),
            child: const Text('menu'),
          ),
        ),
      );
      await tester.tap(find.text('menu'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('moderate-removereward')), findsOneWidget);
      expect(find.byKey(const ValueKey('moderate-refund')), findsOneWidget);
      final reward = tester.getTopLeft(find.byKey(const ValueKey('moderate-refund'))).dy;
      expect(tester.getTopLeft(find.text(t.moderate.delete)).dy, greaterThan(reward));
    });
  });

  group('window', () {
    test('removereward: the bounty, the reasons, the notice; asked as a small form', () async {
      final asked = <String>[];
      final answer = await _repo(
        window: _json('moderate/removereward_form'),
        asked: asked,
      ).fetchForm(ThreadAdminAction.removeReward, fid: 2, tid: 9203116);
      final form = (answer.getRight().toNullable()! as ThreadAdminWindowReady<ThreadAdminForm>).value;
      expect(
        (form.uid, form.tid, form.subject, form.price, form.solved, form.creditTitle),
        (
          32,
          9203116,
          'tsdmapp 3.9.0 reward thread',
          5,
          false,
          '天使币',
        ),
      );
      expect(form.reasons, hasLength(8), reason: 'the separator is no reason');
      expect(form.reasons, isNot(contains('--------')));
      expect((form.reasonField, form.reasonRequired), ('reason', false));
      expect((form.notifyField, form.notifyValue, form.notifyForced), ('sendreasonpm', 'on', false));
      expect(form.submitUrl, startsWith('$baseUrl/forum.php?mod=topicadmin&action=removereward&modsubmit=yes'));
      final query = Uri.parse(asked.single).queryParameters;
      expect(query, {
        'mod': 'topicadmin',
        'action': 'removereward',
        'fid': '2',
        'tid': '9203116',
        'tsdmapp': 'json',
        'tsdmform': '1',
        'nodoc': '1',
      });
    });

    test('refund: the sales; a special thread refused in the forum words', () async {
      final answer = await _repo(
        window: _json('moderate/refund_form'),
      ).fetchForm(ThreadAdminAction.refund, fid: 2, tid: 9203117);
      final form = (answer.getRight().toNullable()! as ThreadAdminWindowReady<ThreadAdminForm>).value;
      expect((form.price, form.payers, form.income), (3, 0, 0));
      final refused = await _repo(
        window: _json('moderate/refund_refused'),
      ).fetchForm(ThreadAdminAction.refund, fid: 2, tid: 9203116);
      expect(
        (refused.getRight().toNullable()! as ThreadAdminWindowRefused<ThreadAdminForm>).message,
        '抱歉，特殊主题不能执行强制退款',
      );
    });

    test('a form posting elsewhere, of another thread, or served to another account is never used', () async {
      Future<Either<AppException, ThreadAdminWindow<ThreadAdminForm>>> fetch(
        Map<String, dynamic> json, {
        int uid = 32,
      }) => _repo(window: json, uid: uid).fetchForm(ThreadAdminAction.removeReward, fid: 2, tid: 9203116);
      Map<String, dynamic> withUrl(String url) {
        final json = _json('moderate/removereward_form');
        (json['submit'] as Map<String, dynamic>)['url'] = url;
        return json;
      }

      expect((await fetch(withUrl('forum.php?mod=topicadmin&action=moderate&modsubmit=yes'))).isLeft(), isTrue);
      expect(
        (await fetch(withUrl('https://example.com/forum.php?mod=topicadmin&action=removereward'))).isLeft(),
        isTrue,
      );
      expect((await fetch(_json('moderate/removereward_form')..['tid'] = 1)).isLeft(), isTrue);
      expect(
        (await fetch(_json('moderate/removereward_form'), uid: 35)).getLeft().toNullable(),
        isA<IdentityChangedException>(),
      );
      // The window of the other operation is not this one.
      expect((await fetch(_json('moderate/refund_form'))).isLeft(), isTrue);
    });
  });

  group('send', () {
    Future<ThreadAdminForm> form() async =>
        ((await _repo(
                  window: _json('moderate/removereward_form'),
                ).fetchForm(ThreadAdminAction.removeReward, fid: 2, tid: 9203116)).getRight().toNullable()!
                as ThreadAdminWindowReady<ThreadAdminForm>)
            .value;

    test('the fields as served, the reason, the notice when asked; posted once in the JSON mode', () async {
      final posted = <_Posted>[];
      final outcome = await _repo(
        window: null,
        result: _succeed(),
        posted: posted,
      ).submit(await form(), reason: ' 广告/SPAM ', notify: true);
      expect(outcome.getRight().toNullable()!.done, isTrue);
      final sent = posted.single;
      final query = Uri.parse(sent.url).queryParameters;
      expect(
        (query['action'], query['modsubmit'], query['inajax'], query['tsdmapp']),
        ('removereward', 'yes', '1', 'json'),
      );
      expect(sent.body, {
        'formhash': 'f1f2f3f4',
        'fid': '2',
        'tid': '9203116',
        'handlekey': 'mods',
        'modsubmit': 'ture',
        'reason': '广告/SPAM',
        'sendreasonpm': 'on',
      });

      final quiet = <_Posted>[];
      await _repo(window: null, result: _succeed(), posted: quiet).submit(await form());
      expect(quiet.single.body.containsKey('sendreasonpm'), isFalse);
    });

    test("only admin_succeed is done; a refusal in the forum's words; another account's answer is dropped", () async {
      final refused = await _repo(
        window: null,
        result: _refused('reward_end', '抱歉，该主题已经不是悬赏主题'),
      ).submit(await form());
      expect(refused.getRight().toNullable(), (done: false, message: '抱歉，该主题已经不是悬赏主题'));
      final other = await _repo(window: null, result: _succeed()..['uid'] = 35).submit(await form());
      expect(other.getLeft().toNullable(), isA<IdentityChangedException>());
      final posted = <_Posted>[];
      final changed = await _repo(window: null, posted: posted, uid: 35).submit(await form());
      expect(changed.isLeft(), isTrue);
      expect(posted, isEmpty, reason: 'the account changed since the window was served');
    });

    testWidgets('the dialog: a required reason, a confirmation, then sent once', (tester) async {
      final window = _json('moderate/removereward_form');
      (window['reason'] as Map<String, dynamic>)['required'] = 1;
      final posted = <_Posted>[];
      bool? done;
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => done = await showThreadAdminDialog(
              context,
              action: ThreadAdminAction.removeReward,
              fid: 2,
              tid: 9203116,
              repository: _repo(window: window, result: _succeed(), posted: posted),
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.rewardPrice(amount: '5 天使币')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('thread-admin-submit')));
      await tester.pumpAndSettle();
      expect(find.text(t.moderate.reasonRequired), findsOneWidget);
      expect(posted, isEmpty);

      await tester.tap(find.text('广告/SPAM'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('thread-admin-submit')));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, t.moderate.removeReward), findsOneWidget, reason: 'confirmed first');
      expect(posted, isEmpty);
      await tester.tap(find.widgetWithText(FilledButton, t.moderate.removeReward));
      await tester.pumpAndSettle();
      expect(posted.single.body['reason'], '广告/SPAM');
      expect(done, isTrue);
      expect(find.text('管理操作成功'), findsOneWidget);
    });
  });
}
