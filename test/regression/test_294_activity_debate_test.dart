/// New activity threads and debate threads from the editor.
///
/// The forum's new thread form of an activity (`special=4`) and of a debate (`special=5`) gives its fields in the
/// `activity` and `debate` blocks of the app API (plugin 2.9.0, `post_v16`). The editor asks them in a dialog, checks
/// them as the forum does (`extend_thread_activity::before_newthread`: a start, a category, a place, an end not before
/// the start; `extend_thread_debate::before_newthread`: both points, an end ahead) and posts them with the form
/// ([PostForm.bodyWith]). The member data an applicant fills in (`userfield[]`, checkboxes the website posts as a
/// list) go as `userfield[0]`, `userfield[1]`…, which PHP reads as the same list: the app's transports post a map.
///
/// The fixtures `post_v16_newthread_activity.json` and `post_v16_newthread_debate.json` are the plugin's 3.4.0 answers
/// on the test forum, scrubbed as the other `post_v16_*` fixtures; `result_activity_refused.json` and
/// `result_debate_refused.json` are the forum's refusals.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/post/bloc/post_edit_bloc.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/models/special_thread_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/widgets/activity_dialog.dart';
import 'package:tsdm_client/features/post/widgets/debate_dialog.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync()) as Map<String, dynamic>;

PostForm _form(String kind) => PostForm.fromJson(_json('post_v16_newthread_$kind'))!;

Response<dynamic> _response(Object? data) =>
    Response<dynamic>(requestOptions: RequestOptions(), data: data, statusCode: 200);

Map<String, dynamic> _redirectTo(int tid) => {
  'ok': 1,
  'api': 1,
  'time': 1792705300,
  'uid': 31,
  'formhash': 'f1f2f3f4',
  'type': 'result',
  'schema': 13,
  'kind': 'redirect',
  'message': '',
  'message_key': 'post_newthread_succeed',
  'url': 'forum.php?mod=viewthread&tid=$tid&extra=',
  'handlekey': '',
  'values': <String, Object?>{},
  'login': 0,
  'alert': '',
};

final _start = DateTime(2026, 12, 1, 10);

ActivityEdits _activity({
  String category = '朋友聚会',
  DateTime? start,
  DateTime? end,
  String place = '測試地點',
  List<String> userFields = const [],
  String extFields = '',
}) => ActivityEdits(
  category: category,
  start: start ?? _start,
  end: end,
  place: place,
  city: '台北',
  number: 10,
  userFields: userFields,
  expiration: DateTime(2026, 11, 30, 23),
  extFields: extFields,
);

Future<(PostEditState, Map<String, String>?)> _post(
  String kind,
  ThreadPubPostThread Function(PostEditContent) event, {
  required Object? answer,
}) async {
  Map<String, String>? sent;
  final repo = PostEditRepository.withTransport(
    currentUid: () => 31,
    getPage: (url) async => right(_response(_json('post_v16_newthread_$kind'))),
    sendForm: (url, body) async {
      sent = body;
      return right(_response(answer));
    },
  );
  final bloc = PostEditBloc(postEditRepository: repo);
  addTearDown(bloc.close);
  final loaded = bloc.stream.firstWhere((s) => s.status != PostEditStatus.loading);
  bloc.add(ThreadPubFetchInfoRequested(fid: '7', kind: ThreadKind.fromQuery(kind)));
  expect((await loaded.timeout(const Duration(seconds: 3))).status, PostEditStatus.editing);
  final done = bloc.stream.firstWhere((s) => s.status != PostEditStatus.uploading);
  bloc.add(event(bloc.state.content!));
  return (await done.timeout(const Duration(seconds: 3)), sent);
}

ThreadPublishInfo _info(PostEditContent content) => ThreadPublishInfo(
  formHash: content.formHash,
  postTime: content.postTime,
  delAttachOp: '0',
  wysiwyg: content.wysiwyg,
  fid: '7',
  threadType: null,
  checkbox: '0',
  subject: '標題',
  message: '內文內文內文',
  price: null,
  perm: null,
  save: '',
  options: const [],
);

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });
  setUp(TsdmAppApi.reset);

  test('the kinds by their query', () {
    expect(ThreadKind.fromQuery('activity'), ThreadKind.activity);
    expect(ThreadKind.fromQuery('debate'), ThreadKind.debate);
    expect(ThreadKind.activity.formQuery, '&special=4');
    expect(ThreadKind.debate.formQuery, '&special=5');
    expect(ThreadKind.activity.query, 'activity');
  });

  group('activity form', () {
    final form = _form('activity');

    test('the settings of the activity block', () {
      final info = form.activity!;
      expect(form.special, 4);
      expect(form.specialAllowed, containsAll([4, 5]));
      expect(info.types, ['朋友聚会', '出外郊游', '自驾出行', '公益活动', '线上活动']);
      expect(info.genders.map((e) => e.$1), ['0', '1', '2']);
      expect(info.userFields, [('mobile', '手机'), ('qq', 'QQ'), ('realname', '真实姓名')]);
      expect(info.credit, '威望');
      expect(info.extNum, 0);
      expect(info.hasCity, isTrue);
      expect(form.debate, isNull);
      expect(form.editorSupport('newthread'), PostFormSupport.supported);
    });

    test('checked as the forum checks it', () {
      final info = form.activity!;
      expect(_activity().check(info), isNull);
      expect(
        const ActivityEdits(category: '朋友聚会', start: null, place: '測試地點').check(info),
        ActivityIssue.startRequired,
      );
      expect(_activity(category: ' ').check(info), ActivityIssue.classRequired);
      expect(_activity(place: '').check(info), ActivityIssue.placeRequired);
      expect(_activity(end: DateTime(2026, 11, 30)).check(info), ActivityIssue.endBeforeStart);
      expect(_activity(end: _start).check(info), isNull, reason: 'the forum refuses a start after the end only');
      // No extra field allowed (`activityextnum` 0); numbers and empty lines do not count.
      expect(_activity(extFields: '\n12\n').check(info), isNull);
      expect(_activity(extFields: '學校').check(info), ActivityIssue.extFieldsTooMany);
    });

    test('posted as the website posts it: a start alone, or a range', () {
      final single = form.bodyWith(
        PostFormEdits(
          message: 'm',
          activity: _activity(userFields: ['qq', 'mobile']),
        ),
      );
      final body = single.toMap()!;
      expect(body['special'], '4');
      expect(body['starttimefrom[0]'], '2026-12-01 10:00');
      expect(body['starttimefrom[1]'], '');
      expect(body.containsKey('activitytime'), isFalse);
      expect(body['activityclass'], '朋友聚会');
      expect(body['activityplace'], '測試地點');
      expect(body['activitycity'], '台北');
      expect(body['activitynumber'], '10');
      expect(body['gender'], '0');
      expect(body['activityexpiration'], '2026-11-30 23:00');
      expect(body['activitycredit'], '');
      expect(body['cost'], '');
      // In the order of the form, by index.
      expect(body['userfield[0]'], 'mobile');
      expect(body['userfield[1]'], 'qq');
      expect(body.containsKey('userfield[2]'), isFalse);
      expect(body.containsKey('userfield[]'), isFalse);
      expect(body.containsKey('extfield'), isFalse);

      final ranged = form.bodyWith(
        PostFormEdits(
          message: 'm',
          activity: _activity(end: DateTime(2026, 12, 1, 18)),
        ),
      );
      final rangedBody = ranged.toMap()!;
      expect(rangedBody['activitytime'], '1');
      expect(rangedBody['starttimefrom[0]'], '');
      expect(rangedBody['starttimefrom[1]'], '2026-12-01 10:00');
      expect(rangedBody['starttimeto'], '2026-12-01 18:00');
    });

    test('without the fields the forum requires, left to the website', () {
      final json = _json('post_v16_newthread_activity');
      final block = json['activity'] as Map<String, dynamic>;
      final without = PostForm.fromJson({
        ...json,
        'activity': {
          ...block,
          'inputs': [
            for (final input in block['inputs'] as List<dynamic>)
              if ((input as Map<String, dynamic>)['name'] != 'activityclass') input,
          ],
        },
      })!;
      expect(without.activity, isNull);
      expect(without.editorSupport('newthread'), PostFormSupport.unsupported);
    });

    test('the editor posts the activity and goes to the thread', () async {
      final (state, sent) = await _post(
        'activity',
        (content) => ThreadPubPostThread(_info(content), activity: _activity(userFields: ['realname'])),
        answer: _redirectTo(9600040),
      );
      expect(state.status, PostEditStatus.success);
      expect(state.redirectTid, '9600040');
      expect(sent!['starttimefrom[0]'], '2026-12-01 10:00');
      expect(sent['userfield[0]'], 'realname');
    });

    test("the forum's refusal is shown", () async {
      final (state, _) = await _post(
        'activity',
        (content) => ThreadPubPostThread(_info(content), activity: _activity()),
        answer: _json('result_activity_refused'),
      );
      expect(state.status, PostEditStatus.failedToUpload);
      expect(state.errorText, '抱歉，活动所属类别不能为空');
    });
  });

  group('debate form', () {
    final form = _form('debate');

    test('the settings of the debate block', () {
      final info = form.debate!;
      expect(form.special, 5);
      expect(info.hasEnd, isTrue);
      expect(info.hasUmpire, isTrue);
      expect(form.activity, isNull);
      expect(form.editorSupport('newthread'), PostFormSupport.supported);
    });

    test('checked as the forum checks it', () {
      final now = DateTime(2026, 11, 7, 12);
      expect(const DebateEdits(affirm: '正', negate: '反').check(now), isNull);
      expect(const DebateEdits(affirm: '正', negate: ' ').check(now), DebateIssue.pointsRequired);
      expect(const DebateEdits(affirm: '', negate: '反').check(now), DebateIssue.pointsRequired);
      expect(DebateEdits(affirm: '正', negate: '反', end: now).check(now), DebateIssue.endPassed);
      expect(DebateEdits(affirm: '正', negate: '反', end: DateTime(2026, 12)).check(now), isNull);
    });

    test('posted with the points, the end and the umpire', () {
      final body = form
          .bodyWith(
            PostFormEdits(
              message: 'm',
              debate: DebateEdits(affirm: '正方觀點', negate: '反方觀點', end: DateTime(2026, 12, 1, 10), umpire: ' Bob '),
            ),
          )
          .toMap()!;
      expect(body['special'], '5');
      expect(body['affirmpoint'], '正方觀點');
      expect(body['negapoint'], '反方觀點');
      expect(body['endtime'], '2026-12-01 10:00');
      expect(body['umpire'], 'Bob');
      // Without the debate: the served (empty) fields, which the forum refuses.
      expect(form.body().toMap()!['affirmpoint'], '');
    });

    test("the editor posts the debate; the forum's refusal is shown", () async {
      final (posted, sent) = await _post(
        'debate',
        (content) => ThreadPubPostThread(
          _info(content),
          debate: const DebateEdits(affirm: '正方觀點', negate: '反方觀點'),
        ),
        answer: _redirectTo(9600041),
      );
      expect(posted.status, PostEditStatus.success);
      expect(sent!['affirmpoint'], '正方觀點');
      expect(sent['endtime'], '');

      final (refused, _) = await _post(
        'debate',
        (content) => ThreadPubPostThread(
          _info(content),
          debate: const DebateEdits(affirm: '正方觀點', negate: '反方觀點'),
        ),
        answer: _json('result_debate_refused'),
      );
      expect(refused.status, PostEditStatus.failedToUpload);
      expect(refused.errorText, '抱歉，您设置辩论的结束时间小于当前时间');
    });
  });

  test('an activity or a debate is only posted on its own form', () {
    final ordinary = PostForm.fromJson({..._json('post_v16_newthread'), 'hook_fields': <Object?>[]})!;
    final body = ordinary
        .bodyWith(
          PostFormEdits(
            message: 'm',
            activity: _activity(),
            debate: const DebateEdits(affirm: '正', negate: '反'),
          ),
        )
        .toMap()!;
    expect(body.containsKey('activityclass'), isFalse);
    expect(body.containsKey('affirmpoint'), isFalse);
  });

  group('dialogs', () {
    /// Open [dialog] from a page and give what it returned.
    Future<Object? Function()> open(WidgetTester tester, Future<Object?> Function(BuildContext) dialog) async {
      Object? result;
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, _) => Scaffold(
              body: TextButton(onPressed: () async => result = await dialog(context), child: const Text('open')),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      tester.view
        ..physicalSize = const Size(1000, 2400)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(TranslationProvider(child: MaterialApp.router(routerConfig: router)));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () => result;
    }

    Finder field(String label) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == label);

    testWidgets('the activity: its issues shown, what was set returned', (tester) async {
      final info = _form('activity').activity!;
      final result = await open(
        tester,
        (context) => showActivityDialog(context, info, ActivityEdits(category: '', start: _start, place: '')),
      );
      await tester.tap(find.text('確定'));
      await tester.pumpAndSettle();
      expect(find.text('請填寫活動類別'), findsOneWidget);
      expect(result(), isNull);
      await tester.enterText(field('活動類別'), '公益活动');
      await tester.enterText(field('活動地點'), '測試地點');
      await tester.tap(find.text('QQ'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('確定'));
      await tester.pumpAndSettle();
      final set = result()! as ActivityEdits;
      expect(set.category, '公益活动');
      expect(set.place, '測試地點');
      expect(set.start, _start);
      expect(set.userFields, ['qq']);
    });

    testWidgets('the debate: both points asked, what was set returned', (tester) async {
      final info = _form('debate').debate!;
      final result = await open(tester, (context) => showDebateDialog(context, info, null));
      await tester.tap(find.text('確定'));
      await tester.pumpAndSettle();
      expect(find.text('請填寫正方和反方觀點'), findsNWidgets(2));
      await tester.enterText(field('正方觀點'), '正方');
      await tester.enterText(field('反方觀點'), '反方');
      await tester.enterText(field('裁判'), 'Bob');
      await tester.tap(find.text('確定'));
      await tester.pumpAndSettle();
      final set = result()! as DebateEdits;
      expect(set.affirm, '正方');
      expect(set.negate, '反方');
      expect(set.umpire, 'Bob');
      expect(set.end, isNull);
    });
  });
}
