/// The first post of an activity thread or of a debate thread edited in the app.
///
/// The edit form of the first post of an activity (`special=4`) or a debate (`special=5`) gives the activity or the
/// debate as it is in its `activity` or `debate` block (plugin 2.9.0, `post_v16`): the editor opens with it
/// ([ActivityFormInfo.served], [DebateFormInfo.served]), the member changes it in the dialogs of a new thread, and the
/// form posts it again: the forum (`extend_thread_activity::before_editpost`, `extend_thread_debate::before_editpost`)
/// checks it as for a new thread and writes every field again, applicants or not.
///
/// Two things the website's form gives otherwise:
/// - the image of the activity (`activityaid`): the plugin serves it empty, and the forum deletes the image of an
///   activity whose edit posts another one; the editor reads it from the web page of the form, and leaves the form to
///   the website when it cannot.
/// - the points of a debate: the edit page prints the row through `daddslashes()`, so a point served as `It\'s` is
///   posted back as it is stored, `It's` (the website adds a backslash with each edit).
///
/// The fixtures `post_v16_edit_activity_{image,ranged}.json` and `post_v16_edit_debate.json` are the plugin's 3.4.0
/// answers on the test forum, scrubbed as the other `post_v16_*` fixtures.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/post/bloc/post_edit_bloc.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/models/special_thread_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync()) as Map<String, dynamic>;

Response<dynamic> _response(Object? data) =>
    Response<dynamic>(requestOptions: RequestOptions(), data: data, statusCode: 200);

String _page({String? aid = '1601', bool form = true}) =>
    "<html><head><script>var discuz_uid = '31';</script></head><body>"
    '${form ? '<form id="postform">' : '<div>'}'
    '${aid == null ? '' : '<input type="hidden" name="activityaid" id="activityaid" value="$aid" />'}'
    '${form ? '</form>' : '</div>'}'
    '</body></html>';

/// The form of [name] with the web page [page] read, as the repository reads it.
PostForm _read(String name, {String page = ''}) {
  final form = PostForm.fromJson(_json(name))!;
  if (!form.editsActivity) {
    return form;
  }
  final document = parseHtmlDocument(page.isEmpty ? _page() : page);
  return form.withActivityImage(hookValuesOf(document, const ['activityaid'])?.lastOrNull?.$2);
}

String _editUrl(int tid, int pid) => 'https://www.tsdm39.com/forum.php?mod=post&action=edit&fid=7&tid=$tid&pid=$pid';

Map<String, dynamic> _edited(int tid, int pid) => {
  'ok': 1,
  'api': 1,
  'time': 1792705300,
  'uid': 31,
  'formhash': 'f1f2f3f4',
  'type': 'result',
  'schema': 13,
  'kind': 'redirect',
  'message': '',
  'message_key': 'post_edit_succeed',
  'url': 'forum.php?mod=viewthread&tid=$tid&page=&extra=#pid$pid',
  'handlekey': '',
  'values': <String, Object?>{},
  'login': 0,
  'alert': '',
};

final class _Harness {
  _Harness({required this.form, required this.page});

  final Map<String, dynamic> form;
  final Either<AppException, String> page;
  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];

  late final repo = PostEditRepository.withTransport(
    currentUid: () => 31,
    getPage: (url) async {
      gets.add(url);
      if (url.contains('tsdmapp=json')) {
        return right(_response(form));
      }
      return page.map(_response);
    },
    sendForm: (url, body) async {
      posts.add((url, body));
      return right(_response(_edited(tsdmAppInt(form['tid']), tsdmAppInt(form['pid']))));
    },
  );
}

Future<PostEditBloc> _load(_Harness harness) async {
  final bloc = PostEditBloc(postEditRepository: harness.repo);
  addTearDown(bloc.close);
  final settled = bloc.stream.firstWhere((s) => s.status != PostEditStatus.loading);
  final form = harness.form;
  bloc.add(
    PostEditLoadDataRequested(_editUrl(tsdmAppInt(form['tid']), tsdmAppInt(form['pid']))),
  );
  await settled.timeout(const Duration(seconds: 3));
  return bloc;
}

Future<PostEditState> _submit(PostEditBloc bloc, {ActivityEdits? activity, DebateEdits? debate}) async {
  final content = bloc.state.content!;
  final settled = bloc.stream.firstWhere((s) => s.status != PostEditStatus.uploading);
  bloc.add(
    PostEditCompleteEditRequested(
      formHash: content.formHash,
      postTime: content.postTime,
      delattachop: '0',
      page: content.page ?? '',
      wysiwyg: content.wysiwyg,
      fid: '7',
      tid: '${content.form!.json['tid']}',
      pid: '${content.form!.json['pid']}',
      threadType: null,
      threadTitle: content.threadTitle,
      data: '內文，改過',
      options: const [],
      save: '',
      perm: null,
      price: null,
      activity: activity,
      debate: debate,
    ),
  );
  return settled.timeout(const Duration(seconds: 3));
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });
  setUp(TsdmAppApi.reset);

  test('the date and time of a form, and stripslashes', () {
    expect(parseDiscuzDateTime('2026-12-05 10:00'), DateTime(2026, 12, 5, 10));
    expect(parseDiscuzDateTime('2026-1-5'), DateTime(2026, 1, 5));
    expect(parseDiscuzDateTime(''), isNull);
    expect(parseDiscuzDateTime('2026-13-01 10:00'), isNull);
    expect(parseDiscuzDateTime('soon'), isNull);
    expect(stripSlashes(r'''It\'s \"q\" a\\b'''), 'It\'s "q" a\\b');
    expect(stripSlashes(r'a\0b'), 'a\u0000b');
    expect(stripSlashes(r'end\'), 'end');
  });

  group('activity', () {
    test('the activity as it is: a start alone, the member data asked', () {
      final form = _read('post_v16_edit_activity_image');
      final served = form.activity!.served!;
      expect(served.category, '朋友聚会');
      expect(served.start, DateTime(2026, 12, 5, 10));
      expect(served.end, isNull);
      expect(served.place, '圖片地點');
      expect(served.number, isNull);
      expect(served.credit, isNull);
      expect(served.cost, isNull);
      expect(served.expiration, isNull);
      expect(form.activity!.hasCity, isFalse, reason: 'the city is part of the title, asked for a new thread only');
      expect(form.editorSupport('edit'), PostFormSupport.supported);
    });

    test('a start and an end, a number, the member data checked', () {
      final served = _read('post_v16_edit_activity_ranged').activity!.served!;
      expect(served.start, DateTime(2026, 12, 2, 10));
      expect(served.end, DateTime(2026, 12, 2, 18));
      expect(served.userFields, isEmpty);
      final edited = PostForm.fromJson({
        ..._json('post_v16_edit_activity_ranged'),
        'activity': {
          ...(_json('post_v16_edit_activity_ranged')['activity'] as Map<String, dynamic>),
          'inputs': [
            ...((_json('post_v16_edit_activity_ranged')['activity'] as Map<String, dynamic>)['inputs'] as List)
                .cast<Map<String, dynamic>>()
                .map(
                  (e) => switch (e['name']) {
                    'activitynumber' => {...e, 'value': '10'},
                    'userfield[]' when e['value'] != 'realname' => {...e, 'checked': 1},
                    _ => e,
                  },
                ),
          ],
        },
      })!.withActivityImage('');
      expect(edited.activity!.served!.number, 10);
      expect(edited.activity!.served!.userFields, ['mobile', 'qq']);
      // Two checked boxes of one list: posted by index, which a map carries.
      final body = edited.body().toMap()!;
      expect(body['userfield[0]'], 'mobile');
      expect(body['userfield[1]'], 'qq');
      expect(body.containsKey('userfield[]'), isFalse);
      expect(edited.editorSupport('edit'), PostFormSupport.supported);
    });

    test('the image of the activity is posted as the web page has it', () {
      expect(_read('post_v16_edit_activity_image').body().toMap()!['activityaid'], '1601');
      expect(_read('post_v16_edit_activity_image', page: _page(aid: '')).body().toMap()!['activityaid'], '');
      // A page without the field (no image upload for the group): the website posts none either.
      final none = _read('post_v16_edit_activity_image', page: _page(aid: null)).body().toMap()!;
      expect(none.containsKey('activityaid'), isFalse);
    });

    test('without the web page of the form, the edit is left to the website', () {
      final form = PostForm.fromJson(_json('post_v16_edit_activity_image'))!;
      expect(form.editsActivity, isTrue);
      expect(form.activity, isNull);
      expect(form.editorSupport('edit'), PostFormSupport.unsupported);
    });

    test('the editor posts the activity changed, the image kept', () async {
      final harness = _Harness(form: _json('post_v16_edit_activity_image'), page: right(_page()));
      final bloc = await _load(harness);
      expect(bloc.state.status, PostEditStatus.editing);
      expect(harness.gets.last, isNot(contains('tsdmapp=json')));
      final served = bloc.state.content!.form!.activity!.served!;
      final state = await _submit(
        bloc,
        activity: ActivityEdits(
          category: served.category,
          start: served.start,
          end: DateTime(2026, 12, 6, 18),
          place: '${served.place}改',
          number: 20,
          gender: '2',
          userFields: const ['realname'],
          credit: 3,
          cost: 50,
        ),
      );
      expect(state.status, PostEditStatus.success);
      final body = harness.posts.single.$2;
      expect(body['activityaid'], '1601');
      expect(body['activitytime'], '1');
      expect(body['starttimefrom[1]'], '2026-12-05 10:00');
      expect(body['starttimeto'], '2026-12-06 18:00');
      expect(body['activityplace'], '圖片地點改');
      expect(body['activitynumber'], '20');
      expect(body['gender'], '2');
      expect(body['userfield[0]'], 'realname');
      expect(body['activitycredit'], '3');
      expect(body['cost'], '50');
      expect(body['message'], '內文，改過');
      expect(body.containsKey('activitycity'), isFalse);
    });

    test('the web page failing, the edit is left to the website', () async {
      final harness = _Harness(
        form: _json('post_v16_edit_activity_image'),
        page: left(HttpRequestFailedException(503)),
      );
      final bloc = await _load(harness);
      expect(bloc.state.status, PostEditStatus.unsupported);
    });
  });

  group('debate', () {
    test('the points as stored, without the backslashes of the edit page', () {
      final form = _read('post_v16_edit_debate');
      final served = form.debate!.served!;
      expect(served.affirm, 'It\'s "q" a\\b & <x> 正方');
      expect(served.negate, '反方觀點');
      expect(served.end, DateTime(2026, 12, 1, 10));
      expect(served.umpire, '');
      expect(form.editorSupport('edit'), PostFormSupport.supported);
      // The web page's way: the backslashes posted back.
      expect(form.body().toMap()!['affirmpoint'], r'''It\'s "q" a\\b & <x> 正方''');
    });

    test('once the umpire has judged, the forum refuses the edit of the first post to a member', () async {
      final harness = _Harness(
        form: {
          'ok': 0,
          'error': 'message',
          'message': '抱歉，裁判已进行过评判，您不能再进行编辑',
          'login': 0,
          'uid': 31,
          'message_key': 'debate_umpire_comment_invalid',
        },
        page: right(_page()),
      );
      final answer = await harness.repo.fetchForm(_editUrl(9600042, 9700042)).run();
      expect(answer.getRight().toNullable(), isA<PostEditFormRefused>());
      expect((answer.getRight().toNullable()! as PostEditFormRefused).message, '抱歉，裁判已进行过评判，您不能再进行编辑');
    });

    test('a debate ended cannot be posted with its end: the forum refuses an end passed', () {
      final served = _read('post_v16_edit_debate').debate!.served!;
      expect(served.check(DateTime(2026, 12, 2)), DebateIssue.endPassed);
      expect(served.check(DateTime(2026, 11, 30)), isNull);
    });

    test('the editor posts the debate as it is, or changed', () async {
      final harness = _Harness(form: _json('post_v16_edit_debate'), page: right(_page()));
      final bloc = await _load(harness);
      expect(bloc.state.status, PostEditStatus.editing);
      // No web page for a debate.
      expect(harness.gets, everyElement(contains('tsdmapp=json')));
      final served = bloc.state.content!.form!.debate!.served!;
      var state = await _submit(bloc, debate: served);
      expect(state.status, PostEditStatus.success);
      expect(harness.posts.last.$2['affirmpoint'], 'It\'s "q" a\\b & <x> 正方');
      expect(harness.posts.last.$2['endtime'], '2026-12-01 10:00');

      final changed = _Harness(form: _json('post_v16_edit_debate'), page: right(_page()));
      state = await _submit(
        await _load(changed),
        debate: DebateEdits(affirm: '${served.affirm}改', negate: served.negate, end: DateTime(2026, 12, 20, 12)),
      );
      expect(changed.posts.single.$2['affirmpoint'], 'It\'s "q" a\\b & <x> 正方改');
      expect(changed.posts.single.$2['endtime'], '2026-12-20 12:00');
      expect(state.status, PostEditStatus.success);
    });
  });
}
