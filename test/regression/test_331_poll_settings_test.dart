/// The poll settings of the first post of a poll edited in the app.
///
/// #270 posted the poll of an edit back as served; the editor now lets the member change what
/// `extend_thread_poll::before_editpost` takes from an edit ([PollEditFormInfo], [PollEdits]):
/// - the text of the options, for a group with `alloweditpoll` only (the plugin marks the others `readonly`; the forum
///   keeps their text), votes or not: an option keeps its votes by its id;
/// - options added, under ids after the poll's (`polloption[]` on the website), for the author too;
/// - no option removed: the website offers no way, and the forum drops an empty option before it would remove it;
/// - the most choices (cut by the forum to the number of options), the days (counted from the edit), and the two
///   checkboxes.
///
/// `post_v16_edit_poll.json` is the author's form (no `alloweditpoll`), `post_v16_edit_poll_editable.json` an
/// administrator's of a poll with a vote: the plugin's 3.4.0 answers on the test forum, scrubbed as the other
/// `post_v16_*` fixtures.
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
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/models/special_thread_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/widgets/poll_settings_dialog.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// The author's form, without the fields of the test forum's other plugin (test_292 reads them).
Map<String, dynamic> _authorJson() => {..._json('post_v16_edit_poll'), 'hook_fields': <Object?>[]};

PostForm _author() => PostForm.fromJson(_authorJson())!;

PostForm _editable() => PostForm.fromJson(_json('post_v16_edit_poll_editable'))!;

Response<dynamic> _response(Object? data) =>
    Response<dynamic>(requestOptions: RequestOptions(), data: data, statusCode: 200);

PollEdits _with(
  PollEditFormInfo info, {
  Map<int, String> texts = const {},
  List<String> added = const [],
  String? maxChoices,
  String? expiration,
  bool? visibleAfterVote,
  bool? overt,
}) {
  final served = info.served;
  return PollEdits(
    texts: {...served.texts, ...texts},
    added: added,
    maxChoices: maxChoices ?? served.maxChoices,
    expiration: expiration ?? served.expiration,
    visibleAfterVote: visibleAfterVote ?? served.visibleAfterVote,
    overt: overt ?? served.overt,
  );
}

Future<Map<String, String>> _submit(Map<String, dynamic> form, PollEdits Function(PollEditFormInfo) poll) async {
  final posts = <Map<String, String>>[];
  final repo = PostEditRepository.withTransport(
    currentUid: () => 31,
    getPage: (url) async => right(_response(form)),
    sendForm: (url, body) async {
      posts.add(body);
      return right(
        _response({
          'ok': 1,
          'api': 1,
          'uid': 31,
          'formhash': 'f1f2f3f4',
          'type': 'result',
          'schema': 13,
          'kind': 'redirect',
          'message': '',
          'message_key': 'post_edit_succeed',
          'url': 'forum.php?mod=viewthread&tid=${form['tid']}&page=&extra=#pid${form['pid']}',
          'handlekey': '',
          'values': <String, Object?>{},
          'login': 0,
          'alert': '',
        }),
      );
    },
  );
  final bloc = PostEditBloc(postEditRepository: repo);
  addTearDown(bloc.close);
  final loaded = bloc.stream.firstWhere((s) => s.status != PostEditStatus.loading);
  bloc.add(
    PostEditLoadDataRequested(
      'https://www.tsdm39.com/forum.php?mod=post&action=edit&fid=7&tid=${form['tid']}&pid=${form['pid']}',
    ),
  );
  expect((await loaded.timeout(const Duration(seconds: 3))).status, PostEditStatus.editing);
  final content = bloc.state.content!;
  final done = bloc.stream.firstWhere((s) => s.status != PostEditStatus.uploading);
  bloc.add(
    PostEditCompleteEditRequested(
      formHash: content.formHash,
      postTime: content.postTime,
      delattachop: '0',
      page: content.page ?? '',
      wysiwyg: content.wysiwyg,
      fid: '7',
      tid: '${form['tid']}',
      pid: '${form['pid']}',
      threadType: null,
      threadTitle: content.threadTitle,
      data: '投票內文，改過',
      options: const [],
      save: '',
      perm: null,
      price: null,
      poll: poll(content.form!.pollEdit!),
    ),
  );
  expect((await done.timeout(const Duration(seconds: 3))).status, PostEditStatus.success);
  return posts.single;
}

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });
  setUp(TsdmAppApi.reset);

  group('the poll of the form', () {
    test("the author's: the options as they are, their text kept", () {
      final info = _author().pollEdit!;
      expect(info.options.map((e) => e.id), [1001, 1002, 1003]);
      expect(info.options.every((e) => e.readonly), isTrue);
      expect(info.textEditable, isFalse);
      expect(info.maxOptions, 20);
      expect(info.maxChoices, '2');
      expect(info.expiration, '3');
      expect(info.visibleAfterVote, isTrue);
      expect(info.overt, isTrue);
    });

    test("an administrator's: the text of every option may change", () {
      final info = _editable().pollEdit!;
      expect(info.options.map((e) => e.id), [2001, 2002, 2003, 2004]);
      expect(info.textEditable, isTrue);
      expect(info.options.first.text, '選項甲 & "乙"改');
      expect(info.expiration, '5');
      expect(info.visibleAfterVote, isFalse);
      expect(info.overt, isFalse);
    });

    test('no poll settings for a form whose poll is not posted back', () {
      final json = _authorJson();
      final noOptions = PostForm.fromJson({
        ...json,
        'poll': {...(json['poll'] as Map<String, dynamic>), 'options': <Object?>[]},
      })!;
      expect(noOptions.pollEdit, isNull);
      expect(PostForm.fromJson(_json('post_v16_edit_reward_open'))!.pollEdit, isNull);
    });
  });

  group('what is posted', () {
    test('an option added after the last, the settings changed; the text of the author kept', () {
      final form = _author();
      final info = form.pollEdit!;
      final set = _with(
        info,
        texts: {1001: '不會送出'},
        added: const ['新選項', '  '],
        maxChoices: '3',
        expiration: '7',
        visibleAfterVote: false,
        overt: false,
      );
      expect(set.check(info), isNull);
      final body = form.bodyWith(PostFormEdits(message: 'm', poll: set)).toMap()!;
      expect(body['polloption[1001]'], '選項甲 & "乙" 000000');
      expect(body['polloption[1004]'], '新選項');
      expect(body['displayorder[1004]'], '3');
      expect(body.containsKey('polloptionid[1004]'), isFalse, reason: 'an id the poll does not have: added');
      expect(body.containsKey('polloption[1005]'), isFalse, reason: 'an empty row is not an option');
      expect(body['maxchoices'], '3');
      expect(body['expiration'], '7');
      expect(body.containsKey('visibilitypoll'), isFalse);
      expect(body.containsKey('overt'), isFalse);
      // Every option of the poll still posted with its id: none is lost.
      for (final id in [1001, 1002, 1003]) {
        expect(body['polloptionid[$id]'], '$id');
      }
    });

    test('the text changed by a member who may', () {
      final form = _editable();
      final set = _with(form.pollEdit!, texts: {2001: '  甲  ', 2003: '丙'}, visibleAfterVote: true, overt: true);
      final body = form.bodyWith(PostFormEdits(message: 'm', poll: set)).toMap()!;
      expect(body['polloption[2001]'], '甲');
      expect(body['polloption[2002]'], '選項二改');
      expect(body['polloption[2003]'], '丙');
      expect(body['visibilitypoll'], '1');
      expect(body['overt'], '1');
    });

    test('the settings as served: the body of #270', () {
      for (final form in [_author(), _editable()]) {
        final served = form.bodyWith(PostFormEdits(message: 'm', poll: form.pollEdit!.served)).toMap();
        expect(served, form.bodyWith(const PostFormEdits(message: 'm')).toMap());
      }
    });

    test('a poll ended keeps its words unless days are typed: -1 as #270, or the days', () {
      final json = _authorJson();
      final ended = PostForm.fromJson({
        ...json,
        'poll': {
          ...(json['poll'] as Map<String, dynamic>),
          'inputs': [
            for (final input in ((json['poll'] as Map<String, dynamic>)['inputs'] as List).cast<Map<String, dynamic>>())
              input['name'] == 'expiration' ? {...input, 'value': '已结束'} : input,
          ],
        },
      })!;
      final info = ended.pollEdit!;
      expect(info.served.check(info), isNull);
      expect(ended.bodyWith(PostFormEdits(message: 'm', poll: info.served)).toMap()!['expiration'], '-1');
      final reopened = _with(info, expiration: '2');
      expect(ended.bodyWith(PostFormEdits(message: 'm', poll: reopened)).toMap()!['expiration'], '2');
      expect(_with(info, expiration: '結束').check(info), PollEditIssue.expiryInvalid);
    });
  });

  group('the checks', () {
    test('an option emptied, too many options, the most choices, the days', () {
      final info = _editable().pollEdit!;
      final empty = _with(info, texts: {2002: ' '}).issues(info);
      expect(empty.options, {2002: PollEditIssue.optionEmpty});
      expect(empty.poll, {PollEditIssue.optionEmpty});
      // The author may not change the text: an empty one is not his.
      expect(_with(_author().pollEdit!, texts: {1002: ''}).check(_author().pollEdit!), isNull);

      expect(_with(info, added: List.filled(16, '新')).check(info), isNull);
      expect(_with(info, added: List.filled(17, '新')).check(info), PollEditIssue.tooManyOptions);
      expect(_with(info, added: ['a\nb']).issues(info).added, {0: PollEditIssue.optionLineBreak});
      expect(_with(info, added: ['長' * 81]).issues(info).added, {0: PollEditIssue.optionTooLong});

      expect(_with(info, maxChoices: '0').check(info), PollEditIssue.maxChoicesInvalid);
      expect(_with(info, maxChoices: '4').check(info), isNull);
      expect(_with(info, maxChoices: '5').check(info), PollEditIssue.maxChoicesInvalid);
      expect(_with(info, maxChoices: '5', added: const ['新']).check(info), isNull);

      expect(_with(info, expiration: '').check(info), isNull);
      expect(_with(info, expiration: '0').check(info), isNull);
      expect(_with(info, expiration: '-1').check(info), PollEditIssue.expiryInvalid);
    });

    test('only what the member changed is checked and posted', () {
      final json = _json('post_v16_edit_poll_editable');
      final poll = json['poll'] as Map<String, dynamic>;
      // A form whose own values would not pass (most choices above the options, an option too long) and that lacks
      // the days: posted back as served when the member changes none of it.
      final odd = PostForm.fromJson({
        ...json,
        'poll': {
          ...poll,
          'options': [
            for (final option in (poll['options'] as List).cast<Map<String, dynamic>>())
              option['id'] == 2002 ? {...option, 'text': '長' * 81} : option,
          ],
          'inputs': [
            for (final input in (poll['inputs'] as List).cast<Map<String, dynamic>>())
              if (input['name'] != 'expiration')
                switch (input['name']) {
                  'maxchoices' => {...input, 'value': '9'},
                  'polloption[2002]' => {...input, 'value': '長' * 81},
                  _ => input,
                },
          ],
        },
      })!;
      final info = odd.pollEdit!;
      expect(info.served.check(info), isNull);
      final body = odd.bodyWith(PostFormEdits(message: 'm', poll: info.served)).toMap()!;
      expect(body['maxchoices'], '9');
      expect(body.containsKey('expiration'), isFalse);
      expect(body, odd.bodyWith(const PostFormEdits(message: 'm')).toMap());
      // Changed, they are checked.
      // An option added: the most choices kept is cut by the forum, not checked.
      expect(_with(info, added: const ['新']).check(info), isNull);
      expect(_with(info, maxChoices: '8').check(info), PollEditIssue.maxChoicesInvalid);
      expect(_with(info, texts: {2002: '長' * 82}).check(info), PollEditIssue.optionTooLong);
    });

    test('the days as the forum reads them: 00 is no expiry, not a poll ended at once', () {
      final form = _editable();
      final info = form.pollEdit!;
      expect(_with(info, expiration: '00').check(info), isNull);
      expect(
        form
            .bodyWith(
              PostFormEdits(
                message: 'm',
                poll: _with(info, expiration: '00'),
              ),
            )
            .toMap()!['expiration'],
        '0',
      );
      expect(
        form
            .bodyWith(
              PostFormEdits(
                message: 'm',
                poll: _with(info, expiration: ''),
              ),
            )
            .toMap()!['expiration'],
        '0',
      );
      expect(
        form
            .bodyWith(
              PostFormEdits(
                message: 'm',
                poll: _with(info, expiration: '07'),
              ),
            )
            .toMap()!['expiration'],
        '7',
      );
    });

    test('settings equal when nothing changed', () {
      final info = _editable().pollEdit!;
      expect(_with(info), info.served);
      expect(_with(info, added: const ['新']), isNot(info.served));
      // Rows added and left empty add nothing.
      expect(_with(info, added: const ['', ' ']), info.served);
      expect(_with(info, overt: true), isNot(info.served));
    });
  });

  group('the editor', () {
    test("posts the author's poll with an option added", () async {
      final body = await _submit(_authorJson(), (info) => _with(info, added: const ['新選項'], maxChoices: '1'));
      expect(body['polloption[1004]'], '新選項');
      expect(body['maxchoices'], '1');
      expect(body['message'], '投票內文，改過');
    });

    test('posts the poll as served when nothing is changed', () async {
      final body = await _submit(_json('post_v16_edit_poll_editable'), (info) => info.served);
      expect(body['polloption[2001]'], '選項甲 & "乙"改');
      expect(body['expiration'], '5');
      expect(body.containsKey('visibilitypoll'), isFalse);
    });
  });

  testWidgets('the dialog: the issues shown, an option added, the settings returned', (tester) async {
    final info = _editable().pollEdit!;
    Object? result;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await showPollSettingsDialog(context, info, info.served),
              child: const Text('open'),
            ),
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

    Finder field(String label) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == label);
    await tester.enterText(field('選項 2'), '');
    await tester.enterText(field('最多可選'), '9');
    await tester.tap(find.text('確定'));
    await tester.pumpAndSettle();
    expect(find.text('選項不能為空白'), findsOneWidget);
    expect(find.text('最多可選需為 1 到選項數量之間的整數'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(field('選項 2'), '乙');
    // Two rows added, the second too long: its issue follows its row when the row above it goes.
    await tester.tap(find.text('新增選項'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新增選項'));
    await tester.pumpAndSettle();
    await tester.enterText(field('選項 5'), '');
    await tester.enterText(field('選項 6'), '長' * 81);
    await tester.tap(find.text('確定'));
    await tester.pumpAndSettle();
    String tooLong() {
      final row = field('選項 6').evaluate().isEmpty ? field('選項 5') : field('選項 6');
      return tester.widget<TextField>(row).decoration!.errorText!;
    }

    expect(tooLong(), startsWith('選項過長'));
    await tester.tap(find.byTooltip('移除這個選項').first);
    await tester.pumpAndSettle();
    expect(field('選項 6'), findsNothing);
    expect(tooLong(), startsWith('選項過長'));
    expect(tester.widget<TextField>(field('選項 5')).controller!.text, '長' * 81);
    await tester.enterText(field('選項 5'), '戊');
    await tester.enterText(field('最多可選'), '5');
    await tester.tap(find.text('公開投票參與人'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確定'));
    await tester.pumpAndSettle();
    final set = result! as PollEdits;
    expect(set.texts[2002], '乙');
    expect(set.addedOptions, ['戊']);
    expect(set.maxChoices, '5');
    expect(set.overt, isTrue);
    expect(set.visibleAfterVote, isFalse);
  });
}
