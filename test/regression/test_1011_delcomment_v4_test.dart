/// The moderators' window deleting a comment of a floor read from the forum's app API (plugin 4.0.0, `tsdmv=4`, small
/// form `delcomment`; G2).
///
/// * Asked as a small form only once `status` lists `delcomment`; otherwise exactly as before, one request.
/// * The recorded answer and fragment of the same window (an administrator, uid 32, on the test forum) give the same
///   form: the same fields sent back (`topiclist` one value), posted to the same target, the API's with `tsdmv=4`.
/// * The forum's refusal in its words; an answer that is not the form asks the window as before and forgets the flag.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsdm_client/features/post_comment/repository/post_comment_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';

import 'tsdmapp_v4_fake.dart';

const _tid = '9202953';
const _comment = 30;

final class _Forum {
  _Forum({this.api, this.web, this.answer, this.uid});

  final Object? api;
  final Object? web;
  final Object? answer;
  final int? uid;
  final reads = <String>[];
  final sent = <(String, Map<String, String>)>[];

  PostCommentRepository get repository => PostCommentRepository(
    get: (url) async {
      reads.add(url);
      final data = Uri.parse(url).queryParameters['tsdmv'] == '4' ? api : web;
      if (data == null) {
        throw Exception('offline');
      }
      return data;
    },
    post: (url, fields) async {
      sent.add((url, fields));
      if (answer == null) {
        throw Exception('connection reset');
      }
      return answer;
    },
    currentUid: uid == null ? null : () => uid!,
  );
}

String _withoutV4(String url) {
  final uri = Uri.parse(url);
  return uri
      .replace(
        queryParameters: Map.of(uri.queryParametersAll)
          ..remove('tsdmv')
          ..remove('tsdmapp'),
      )
      .toString();
}

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  test("the answer and the fragment give the same form; the API's is posted with tsdmv=4", () async {
    knowV4Status();
    final forum = _Forum(
      api: v4Json('g2_delcomment.json'),
      web: v4Raw('g2_delcomment.xml'),
      answer: {'ok': 1, 'type': 'result', 'schema': 13, 'kind': 'handle', 'uid': 32, 'message_key': 'admin_succeed'},
    );
    final api = (await forum.repository.openDelete(tid: _tid, commentId: _comment)) as PostCommentWindowForm;
    expect(forum.reads, hasLength(1));
    expect(Uri.parse(forum.reads.single).queryParameters, containsPair('tsdmv', '4'));

    TsdmAppApi.reset();
    final before = _Forum(web: v4Raw('g2_delcomment.xml'));
    final web = (await before.repository.openDelete(tid: _tid, commentId: _comment)) as PostCommentWindowForm;
    expect(Uri.parse(before.reads.single).queryParameters, isNot(contains('tsdmv')));

    expect(api.form.fields, web.form.fields);
    expect(api.form.fields, containsPair('topiclist', '$_comment'));
    expect(api.form.uid, 32);
    expect(Uri.parse(api.form.action).queryParameters, allOf(containsPair('tsdmv', '4'), containsPair('inajax', '1')));
    expect(_withoutV4(api.form.action), _withoutV4(web.form.action));

    final outcome = await forum.repository.sendDelete(api.form, '广告/SPAM');
    expect(outcome, isA<PostCommentDone>());
    expect(forum.sent.single.$1, api.form.action);
    expect(forum.sent.single.$2, containsPair('reason', '广告/SPAM'));
  });

  test("the forum's refusal in its words", () async {
    knowV4Status();
    final forum = _Forum(
      api: {
        'ok': 0,
        'error': 'message',
        'message': '抱歉，您没有权限删除点评',
        'message_key': 'no_privilege_delcomment',
        'login': 0,
        'uid': 32,
        'form': 'delcomment',
      },
    );
    final window = await forum.repository.openDelete(tid: _tid, commentId: _comment);
    expect((window as PostCommentWindowRefused).message, '抱歉，您没有权限删除点评');
    expect(forum.reads, hasLength(1));
  });

  test('an answer that is not the form: the window asked as before, the stale flag forgotten', () async {
    knowV4Status();
    final forum = _Forum(api: v4Raw('g2_delcomment.xml'), web: v4Raw('g2_delcomment.xml'));
    final window = await forum.repository.openDelete(tid: _tid, commentId: _comment);
    expect(window, isA<PostCommentWindowForm>());
    expect(forum.reads, hasLength(2));
    expect(TsdmAppApi.pluginInfo.value?.v4, isNull);
  });

  test("another comment's window is not taken: asked as before", () async {
    knowV4Status();
    final forum = _Forum(api: v4Json('g2_delcomment.json'), web: v4Raw('g2_delcomment.xml'));
    await forum.repository.openDelete(tid: _tid, commentId: 31);
    expect(forum.reads, hasLength(2));
    expect(Uri.parse(forum.reads.last).queryParameters, isNot(contains('tsdmv')));
  });

  test("another account's form is never used", () async {
    knowV4Status();
    final forum = _Forum(api: v4Json('g2_delcomment.json'), web: v4Raw('g2_delcomment.xml'), uid: 31);
    final window = await forum.repository.openDelete(tid: _tid, commentId: _comment);
    expect(window, isA<PostCommentWindowRefused>());
    expect(forum.reads, hasLength(1));
  });
}
