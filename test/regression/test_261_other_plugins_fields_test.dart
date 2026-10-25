/// GitHub #239 (a follow-up after 1.48.1): a moderator editing the first post of a thread was sent to the browser
/// ("这份内容包含 App 尚未支持的特殊主题或编辑格式"). The forum's moderator scheduling plugin prints its panel into the forms
/// of a new thread and of the first post's edit for the forum's moderators, a forum's tag plugin its tag fields; the
/// app's API names such fields (`hook_fields`) without their values, and every such form was left to the website.
///
/// They are now posted back as the web page of the form serves them, as the browser does when the member changes
/// nothing ([hookValuesOf], [PostForm.withHookValues]): leaving them out is no answer, the tag plugin refuses a first
/// post without its required tag and clears the tags of a thread whose optional fields are missing. A form whose web
/// page cannot give one of them (a field a script builds) is still left to the website.
///
/// Synthetic pages and the fixtures `post_v16_*.json` (plugin 2.9.0 answers on the test forum); nothing is sent.
// HTML pieces written as adjacent strings.
// ignore_for_file: missing_whitespace_between_adjacent_strings
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/post/bloc/post_edit_bloc.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/post_v16_$name.json').readAsStringSync()) as Map<String, dynamic>;

/// A web page of the account [uid] whose `form#postform` holds [form]; [outside] goes after the form.
String _page(String form, {int uid = 31, String outside = ''}) =>
    "<html><head><script>var discuz_uid = '$uid';</script></head><body>"
    '<form id="postform" method="post"><input type="hidden" name="formhash" value="f1f2f3f4">$form</form>$outside'
    '</body></html>';

/// The tag fields the test forum's tag plugin prints on the edit of a tagged thread's first post (`post_top`).
const _tagFields =
    '<div class="fpbt-form" id="fpbt_form"><input type="text" name="fpbt_book" id="fpbt_book" value="測試書">'
    '<input type="text" name="fpbt_author" id="fpbt_author" value="測試作者"></div>';

Response<dynamic> _response(Object? data) =>
    Response<dynamic>(requestOptions: RequestOptions(), data: data, statusCode: 200);

/// A write result of plugin 2.6.0: the forum redirected to thread [tid].
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
  'message_key': 'post_edit_succeed',
  'url': 'forum.php?mod=viewthread&tid=$tid&extra=',
  'handlekey': '',
  'values': <String, Object?>{},
  'login': 0,
  'alert': '',
};

const _editUrl = '$baseUrl/forum.php?mod=post&action=edit&fid=2&tid=9600001&pid=9700001';

/// The editor's repository over a forum answering the JSON mode with [api] and the web page with [web] (null: the
/// request fails), recording what is asked and posted.
final class _Harness {
  _Harness({required this.api, required this.web});

  final Map<String, dynamic> api;
  final String? web;
  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];

  late final repo = PostEditRepository.withTransport(
    currentUid: () => 31,
    getPage: (url) async {
      gets.add(url);
      if (url.contains('tsdmapp=json')) return right(_response(api));
      final page = web;
      return page == null ? left(HttpRequestFailedException(502)) : right(_response(page));
    },
    sendForm: (url, body) async {
      posts.add((url, body));
      return right(_response(_redirectTo(9600001)));
    },
  );

  Future<PostForm?> form() async => switch (await repo.fetchForm(_editUrl).run()) {
    Right(value: PostEditFormApi(:final form)) => form,
    _ => null,
  };
}

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('A. the values of the web page, as the browser posts them', () {
    List<(String, String)>? read(String form, List<String> names, {String outside = ''}) =>
        hookValuesOf(parseHtmlDocument(_page(form, outside: outside)), names);

    test('text and hidden inputs give their value, in page order', () {
      expect(read(_tagFields, ['fpbt_book', 'fpbt_author']), [('fpbt_book', '測試書'), ('fpbt_author', '測試作者')]);
      expect(read('<input name="b" value="2"><input type="hidden" name="a">', ['a', 'b']), [('b', '2'), ('a', '')]);
    });

    test('a checkbox or a radio button only when checked, `on` without a value', () {
      const form =
          '<input type="checkbox" name="ms[form]" value="1" checked>'
          '<input type="checkbox" name="ms[hl_on]" value="1">'
          '<input type="checkbox" name="ms[flag]" checked>'
          '<input type="radio" name="ms[kind]" value="a"><input type="radio" name="ms[kind]" value="b" checked>';
      expect(read(form, ['ms[form]', 'ms[hl_on]', 'ms[flag]', 'ms[kind]']), [
        ('ms[form]', '1'),
        ('ms[flag]', 'on'),
        ('ms[kind]', 'b'),
      ]);
    });

    test(
      'a select gives its last selected option or else its first, a multiple one every selected; a textarea its text',
      () {
        const form =
            '<select name="s1"><option value="x">X</option><option value="y" selected>Y</option></select>'
            '<select name="s2"><option value="p">P</option><option value="q">Q</option></select>'
            '<select name="s3"><option>  text value </option></select>'
            '<select name="s4" multiple><option value="1" selected>1</option><option value="2">2</option>'
            '<option value="3" selected>3</option></select>'
            '<select name="s5"></select>'
            '<textarea name="t">\nfirst line\nsecond</textarea>';
        expect(read(form, ['s1', 's2', 's3', 's4', 's5', 't']), [
          ('s1', 'y'),
          ('s2', 'p'),
          ('s3', 'text value'),
          ('s4', '1'),
          ('s4', '3'),
          ('t', 'first line\r\nsecond'),
        ]);
      },
    );

    test('a select as the browser: a disabled option is never posted, a list box only its selected options', () {
      const form =
          '<select name="p1"><option value="" disabled>请选择</option><option value="a">A</option></select>'
          '<select name="p2"><option value="" disabled selected>请选择</option><option value="b">B</option></select>'
          '<select name="p3" size="4"><option value="x">X</option><option value="y">Y</option></select>'
          '<select name="p4" multiple><option value="1" selected disabled>1</option><option value="2" selected>2</option>'
          '</select>'
          '<select name="p5"><option value="z" disabled>Z</option></select>';
      expect(read(form, ['p1', 'p2', 'p3', 'p4', 'p5']), [('p1', 'a'), ('p4', '2')]);
    });

    test('a disabled fieldset disables its controls; the form attribute decides the form', () {
      const form =
          '<fieldset disabled><div><input name="f1" value="1"></div></fieldset>'
          '<fieldset><input name="f2" value="2"></fieldset>'
          '<input name="f3" value="3" form="otherform">';
      expect(read(form, ['f1', 'f2']), [('f2', '2')]);
      // Given to another form: not a control of this one.
      expect(read(form, ['f3']), isNull);
      // Outside the form but given to it.
      expect(read('', ['f4'], outside: '<input name="f4" value="4" form="postform">'), [('f4', '4')]);
    });

    test('disabled controls, buttons and files are not posted', () {
      const form =
          '<input name="a" value="1" disabled><input type="submit" name="b" value="go">'
          '<input type="file" name="c"><button name="d">x</button><input name="e" value="5">';
      expect(read(form, ['a', 'b', 'c', 'e']), [('e', '5')]);
    });

    test('a name that is no control of the form: none, the form goes to the website', () {
      expect(read(_tagFields, ['fpbt_book', 'built_by_a_script']), isNull);
      expect(read('', ['outside'], outside: '<input name="outside" value="1">'), isNull);
      expect(hookValuesOf(parseHtmlDocument('<html><body><form id="other"></form></body></html>'), ['a']), isNull);
    });
  });

  group('B. the post form carries them', () {
    test('taken by the editor with the values, posted after every served field', () {
      final form = PostForm.fromJson(_json('edit_first'))!;
      expect(form.hookFields, ['fpbt_book', 'fpbt_author']);
      expect(form.hookValues, isNull);
      expect(form.editorSupport('edit'), PostFormSupport.unsupported);

      final read = form.withHookValues(const [('fpbt_book', '測試書'), ('fpbt_author', '測試作者')]);
      expect(read.editorSupport('edit'), PostFormSupport.supported);
      final pairs = read.body().pairs;
      expect(pairs.sublist(pairs.length - 2), [('fpbt_book', '測試書'), ('fpbt_author', '測試作者')]);
      expect(read.bodyWith(const PostFormEdits(message: 'edited')).pairs, contains(('fpbt_author', '測試作者')));
      expect(form.body().pairs, isNot(contains(('fpbt_book', '測試書'))));
    });

    test('kept in the answer: the form the editor rebuilds from its content still has them', () {
      final read = PostForm.fromJson(_json('edit_first'))!.withHookValues(const [('fpbt_book', '測試書')]);
      final content = PostEditContent.fromPostForm(read)!;
      expect(content.form!.hookValues, [('fpbt_book', '測試書')]);
      expect(content.form!.editorSupport('edit'), PostFormSupport.supported);
      expect(read.json.containsKey(PostForm.hookValuesKey), isTrue);
      expect(_json('edit_first').containsKey(PostForm.hookValuesKey), isFalse, reason: 'never a field of the plugin');
    });
  });

  group('C. the editor asks the web page for them', () {
    test('the page gives every field: the form is edited in the app and posts them back', () async {
      final harness = _Harness(api: _json('edit_first'), web: _page(_tagFields));
      final form = await harness.form();
      expect(harness.gets, [contains('tsdmapp=json'), _editUrl]);
      expect(form?.hookValues, [('fpbt_book', '測試書'), ('fpbt_author', '測試作者')]);
      expect(form?.editorSupport('edit'), PostFormSupport.supported);

      final sent = await harness.repo
          .submitForm(form!, const PostFormEdits(message: 'edited'), expectedTid: '9600001')
          .run();
      expect(sent.isRight(), isTrue);
      expect(harness.posts.single.$2, containsPair('fpbt_book', '測試書'));
      expect(harness.posts.single.$2, containsPair('fpbt_author', '測試作者'));
    });

    test('a form without fields of other plugins asks nothing more', () async {
      final api = _json('edit_first')..['hook_fields'] = <Object?>[];
      final harness = _Harness(api: api, web: null);
      final form = await harness.form();
      expect(harness.gets, hasLength(1));
      expect(form?.editorSupport('edit'), PostFormSupport.supported);
    });

    test('a field the page does not hold, or a page that failed: left to the website as before', () async {
      for (final web in [_page('<input name="fpbt_book" value="測試書">'), null]) {
        final harness = _Harness(api: _json('edit_first'), web: web);
        final form = await harness.form();
        expect(form?.hookValues, isNull, reason: '$web');
        expect(form?.editorSupport('edit'), PostFormSupport.unsupported, reason: '$web');
      }
    });

    test("a page served to another account is no page of this editor's", () async {
      final harness = _Harness(api: _json('edit_first'), web: _page(_tagFields, uid: 32));
      final answer = await harness.repo.fetchForm(_editUrl).run();
      expect(answer.getLeft().toNullable(), isA<IdentityChangedException>());
    });
  });

  group('D. a refusal the website can answer', () {
    PostEditContent content(Map<String, dynamic> json) => PostEditContent.fromPostForm(PostForm.fromJson(json)!)!;
    const tagRefusal = '本版发帖要填写分类标签「专辑」（在发帖页最上方）。';

    test('the forum refuses a form with fields of other plugins the editor does not show: the browser is offered', () {
      final state = PostEditState(
        status: PostEditStatus.failedToUpload,
        content: content(_json('newthread_hook')),
        errorText: tagRefusal,
      );
      expect(state.offersBrowser, isTrue);
    });

    test('not for a form without such fields, nor without the reason, nor before a refusal', () {
      final unhooked = _json('newthread_hook')..['hook_fields'] = <Object?>[];
      for (final state in [
        PostEditState(status: PostEditStatus.failedToUpload, content: content(unhooked), errorText: tagRefusal),
        PostEditState(status: PostEditStatus.failedToUpload, content: content(_json('newthread_hook'))),
        PostEditState(status: PostEditStatus.editing, content: content(_json('newthread_hook')), errorText: tagRefusal),
      ]) {
        expect(state.offersBrowser, isFalse, reason: '$state');
      }
      // Sent too soon after the previous post: the editor counts the interval down itself.
      expect(
        PostEditState(
          status: PostEditStatus.failedToUpload,
          content: content(_json('newthread_hook')),
          errorText: '抱歉，您两次发表间隔少于 15 秒，请稍候再发表',
        ).offersBrowser,
        isFalse,
      );
      // A captcha the app cannot show still offers it, whatever the form.
      expect(const PostEditState(status: PostEditStatus.failedToUpload, needsBrowser: true).offersBrowser, isTrue);
    });
  });
}
