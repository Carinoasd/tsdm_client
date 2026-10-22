/// The forum's app API, plugin 2.9.0: the forms of a new thread, a reply (the page and the reply window) and an edit,
/// asked in the JSON mode, answer `type: post`, `schema: 16`: the url the form posts to and its hidden fields
/// (`submit`), the title and the post as served, the type selector, the options, the read permission, the price, the
/// blocks the app does not edit (`replycredit`, `rushreply`, `cronpublish`, the special threads), the attachments'
/// fields, the draft, the captcha (`seccheck`), the fields of other plugins (`hook_fields`) and what to leave to the
/// website (`unsupported`).
///
/// The editor ([PostEditRepository], [PostEditBloc]), the poll creator ([PollCreateRepository]) and the reply to a floor
/// ([ReplyRepository.replyToPost]) read it instead of the web page and post the form as the website would
/// ([PostForm.body]: the served values, a checkbox only when checked and enabled, the blocks and the attachments as
/// served) with the member's edits over it; an older plugin, or none, answers the page and it is read as before. A
/// form asking for a captcha or a security question is never posted: the app says so and offers the browser, for the
/// web page too.
///
/// The fixtures `post_v16_*.json` are the plugin's 2.9.0 answers on the Discuz X5 test forum (the plugin's fixture
/// script `postfix290.php`: forms of a new thread, a poll, a typed forum, a moderated forum, a thread sort, a forum
/// another plugin adds fields to; a reply, a quoting reply, the reply window; the edits of a first post, a reply, a
/// post with attachments, a draft, a poll, a jsonEditor post; three messages), fetched and scrubbed by the plugin's
/// contract tool (`tools/fixtures.py --group post`): ids of the fixture made constant, `posttime`, `noticeauthor` and
/// `formhash` fixed. The plugin's acceptance (`post290.py`) compared the body these fields make with what the browser
/// posts for the same page, field by field, and posted both on the test forum.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/editor/utils/mention.dart';
import 'package:tsdm_client/features/post/bloc/post_edit_bloc.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/poll_create.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/repository/poll_create_repository.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/post/utils/discuz_text.dart';
import 'package:tsdm_client/features/post/utils/verification.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';
import 'package:universal_html/parsing.dart';

import 'draft_fixtures.dart';
import 'poll_fixtures.dart';

const _dir = 'test/data/tsdmapp';

/// The fixture `post_v16_[name].json`.
Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/post_v16_$name.json').readAsStringSync()) as Map<String, dynamic>;

/// The fixture [name] with the top level fields [changes] put over it.
Map<String, dynamic> _with(String name, Map<String, Object?> changes) => {..._json(name), ...changes};

PostForm _form(String name) => PostForm.fromJson(_json(name))!;

/// The fixture [name] (a form of fid 2, where the test forum's form plugin prints fields of its own on the forms of a
/// new thread and of a first post) as a forum without such a plugin serves it: no `hook_fields`.
Map<String, dynamic> _unhooked(String name) => _with(name, {'hook_fields': <Object?>[]});

/// Every form fixture (the messages left out).
final List<String> _forms =
    Directory(_dir)
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .where((e) => e.startsWith('post_v16_') && !e.startsWith('post_v16_msg_'))
        .map((e) => e.substring('post_v16_'.length, e.length - '.json'.length))
        .toList()
      ..sort();

Response<dynamic> _response(Object? data, {int status = 200, String? location}) => Response<dynamic>(
  requestOptions: RequestOptions(),
  data: data,
  statusCode: status,
  headers: Headers.fromMap({
    if (location != null) 'location': [location],
  }),
);

/// A write result of plugin 2.6.0: the forum redirected to thread [tid].
Map<String, dynamic> _redirectTo(int tid, {int uid = 31}) => {
  'ok': 1,
  'api': 1,
  'time': 1792705300,
  'uid': uid,
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

/// What a fake forum saw and answers: the GET urls and the POSTs (url and body).
final class _Harness {
  _Harness({required this.page, this.post, this.uid = 31});

  /// Answer of a GET of a url.
  final Object? Function(String url) page;

  /// Answer of a POST; none by default (a test that must not post).
  final Object? Function(String url, Map<String, String> body)? post;

  int uid;
  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];

  late final repo = PostEditRepository.withTransport(
    currentUid: () => uid,
    getPage: (url) async {
      gets.add(url);
      return right(_response(page(url)));
    },
    sendForm: (url, body) async {
      posts.add((url, body));
      final answer = post?.call(url, body);
      if (answer == null) throw StateError('no post expected');
      return right(_response(answer));
    },
  );
}

/// Send [event] to a new [PostEditBloc] of [harness] and wait for its first settled state.
Future<PostEditBloc> _load(_Harness harness, PostEditEvent event) async {
  final bloc = PostEditBloc(postEditRepository: harness.repo);
  addTearDown(bloc.close);
  final settled = bloc.stream.firstWhere((s) => s.status != PostEditStatus.loading);
  bloc.add(event);
  await settled.timeout(const Duration(seconds: 3));
  return bloc;
}

const _editUrl = '$baseUrl/forum.php?mod=post&action=edit&fid=2&tid=9600001&pid=9700001';

// ---- the reply window through the global client (as the reply bar does)

typedef _Answer = ({String body, int status, Map<String, List<String>> headers});

typedef _Request = ({String method, Uri uri, Map<String, dynamic> headers, String body});

_Answer _api(Map<String, dynamic> json) => (
  body: jsonEncode(json),
  status: 200,
  headers: {
    Headers.contentTypeHeader: ['application/json; charset=utf-8'],
  },
);

_Answer _xml(String xml) => (
  body: xml,
  status: 200,
  headers: {
    Headers.contentTypeHeader: ['text/xml; charset=utf-8'],
  },
);

/// A forum answering every request with [answer] and recording it.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  final _Answer Function(_Request request) answer;
  final requests = <_Request>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var body = '';
    if (requestStream != null) {
      body = utf8.decode(await requestStream.fold<List<int>>([], (a, b) => a..addAll(b)), allowMalformed: true);
    }
    final request = (method: options.method, uri: options.uri, headers: options.headers, body: body);
    requests.add(request);
    final a = answer(request);
    return ResponseBody.fromString(a.body, a.status, headers: a.headers);
  }

  @override
  void close({bool force = false}) {}
}

void _use(_Forum forum) => getIt.registerFactory<NetClientProvider>(
  () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
);

const _replyAction = 'forum.php?mod=post&action=reply&fid=2&tid=9600001&repquote=9700002&extra=page%3D1&page=1';

const _replyParameters = ReplyParameters(
  fid: '2',
  tid: '9600001',
  postTime: '1700000000',
  formHash: 'f1f2f3f4',
  subject: '',
  viewerUid: 31,
);

Future<Either<AppException, PostedReply>> _replyToPost({
  ReplyParameters parameters = _replyParameters,
  int? stand,
}) => const ReplyRepository()
    .replyToPost(replyParameters: parameters, replyAction: _replyAction, replyMessage: '回覆內容 [b]x[/b]', stand: stand)
    .run();

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

AppException _left<T>(Either<AppException, T> either) => either.fold((e) => e, (v) => throw StateError('right: $v'));

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    getIt.allowReassignment = true;
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(TsdmAppApi.reset);
  tearDown(() async {
    if (getIt.isRegistered<NetClientProvider>()) {
      await getIt.unregister<NetClientProvider>();
    }
  });

  group('A. the answer', () {
    test('every form fixture is a post form of its action, served to its account', () {
      expect(_forms, hasLength(16));
      for (final name in _forms) {
        final json = _json(name);
        expect(postFormAnswerOf(json), same(json), reason: name);
        final form = PostForm.fromJson(json)!;
        expect(form.action, name.startsWith('newthread') ? 'newthread' : name.split('_').first, reason: name);
        expect(form.uid, name == 'reply' ? 35 : 31, reason: name);
        // A JSON answer as text (a body dio did not decode) is read the same.
        expect(postFormAnswerOf(jsonEncode(json)), isNotNull, reason: name);
      }
    });

    test('the fixtures carry nothing of the test forum: no address, no member data', () {
      for (final name in [..._forms, 'msg_guest', 'msg_noperm', 'msg_passwd']) {
        final raw = File('$_dir/post_v16_$name.json').readAsStringSync();
        expect(raw, isNot(matches(RegExp(r'\b\d{1,3}(\.\d{1,3}){3}\b'))), reason: '$name: an IPv4 address');
        expect(raw, isNot(contains('http://')), reason: name);
        for (final marker in ['"head"', '"password"', '"email"', '"loginname"']) {
          expect(raw, isNot(contains(marker)), reason: '$name: $marker');
        }
      }
    });

    test('the forum message instead of the form: a message answer, no form', () {
      for (final (name, login, uid, text) in [
        ('msg_guest', 1, 0, '抱歉，您尚未登录，没有权限在该版块发帖'),
        ('msg_noperm', 0, 35, '抱歉，您没有权限编辑他人发表的帖子'),
        ('msg_passwd', 0, 31, '本版块需要密码'),
      ]) {
        final json = _json(name);
        expect(postFormAnswerOf(json), same(json), reason: name);
        expect(PostForm.fromJson(json), isNull, reason: name);
        expect((json['login'], json['uid'], json['message']), (login, uid, text), reason: name);
      }
    });

    test('anything else is no post form: the web page, a write result, a thread page, unknown, an older schema', () {
      expect(postFormAnswerOf('<html><body><form id="postform"></form></body></html>'), isNull);
      expect(postFormAnswerOf(null), isNull);
      expect(postFormAnswerOf(jsonDecode(File('$_dir/write_v13_reply_ok.json').readAsStringSync())), isNull);
      expect(postFormAnswerOf(jsonDecode(File('$_dir/thread_v3_plain.json').readAsStringSync())), isNull);
      expect(postFormAnswerOf({'ok': 0, 'error': 'unknown', 'document': '<form id="postform"></form>'}), isNull);
      expect(postFormAnswerOf(_with('newthread', {'schema': 15})), isNull);
      expect(postFormAnswerOf(_with('newthread', {'type': 'result'})), isNull);
      // A message without `login` is not this plugin's message shape.
      expect(postFormAnswerOf({'ok': 0, 'error': 'message', 'message': 'x'}), isNull);
      // A later schema only adds fields.
      expect(PostForm.fromJson(_with('newthread', {'schema': 17})), isNotNull);
    });
  });

  group('B. the body, as the website posts the form', () {
    List<(String, String)> body(String name) => _form(name).body().pairs;

    test('a new thread: hidden fields, title, post, the checked enabled options, the reply rewards as served', () {
      expect(body('newthread'), const [
        ('formhash', 'f1f2f3f4'),
        ('posttime', '1700000000'),
        ('wysiwyg', '1'),
        ('topicsubmit', 'true'),
        ('save', ''),
        ('subject', ''),
        ('message', ''),
        ('allownoticeauthor', '1'),
        ('usesig', '1'),
        ('adddynamic', 'true'),
        ('replycredit_times', '1'),
        ('replycredit_extcredits', '0'),
        ('replycredit_membertimes', '1'),
        ('replycredit_random', '100'),
      ]);
      // The disabled options (html, image content) are never posted, checked or not.
      expect(body('newthread').map((e) => e.$1), isNot(contains('htmlon')));
      expect(body('newthread').map((e) => e.$1), isNot(contains('imgcontent')));
    });

    test('the type selector posts its served choice', () {
      expect(body('newthread_types').where((e) => e.$1 == 'typeid'), const [('typeid', '0')]);
    });

    test('the reply window: its hidden fields (the encrypted author note and the quote) as served', () {
      expect(body('reply_float'), [
        ('formhash', 'f1f2f3f4'),
        ('handlekey', 'reply'),
        ('noticeauthor', 'NOTICEAUTHOR'),
        (
          'noticetrimstr',
          '[quote][size=2][url=forum.php?mod=redirect&goto=findpost&pid=9700002&ptid=9600001][color=#999999]'
              'ag_low2 发表于 2023-11-15 06:13[/color][/url][/size]\nN1 二樓（ag_low2）000000 斜體[/quote]',
        ),
        ('noticeauthormsg', 'N1 二樓（ag_low2）000000 斜體'),
        ('usesig', '1'),
        ('reppid', '9700002'),
        ('reppost', '9700002'),
        ('replysubmit', 'true'),
        ('subject', ''),
        ('message', ''),
      ]);
      // A quoting reply: the post is empty, the quote goes in noticetrimstr, which the forum puts in front of it.
      expect(_form('reply_quote').message, isEmpty);
      expect(_form('reply_quote').submitFields['noticetrimstr'], startsWith('[quote]'));
    });

    test('an edit: the thread fields, the original post as written (entities of the text kept), the options', () {
      final pairs = body('edit_first');
      expect(pairs.take(10), const [
        ('formhash', 'f1f2f3f4'),
        ('posttime', '1700000000'),
        ('delattachop', '0'),
        ('wysiwyg', '1'),
        ('fid', '2'),
        ('tid', '9600001'),
        ('pid', '9700001'),
        ('page', '1'),
        ('editsubmit', 'true'),
        ('save', ''),
      ]);
      expect(Map.fromEntries(pairs.map((e) => MapEntry(e.$1, e.$2)))['message'], '''
N1_BODY_000000 & "引號" 'single' <b>不是標籤</b> &amp; [b]粗體[/b]
第二行

第四行''');
    });

    test('an edit with attachments: the image as [attachimg] in the post, the descriptions posted back as served', () {
      final pairs = body('edit_attach');
      expect(pairs.firstWhere((e) => e.$1 == 'message').$2, contains('[attachimg]9800001[/attachimg]'));
      expect(pairs.firstWhere((e) => e.$1 == 'message').$2, contains('[attach]9800002[/attach]'));
      expect(pairs.skip(pairs.length - 4), const [
        ('attachupdate[9800001]', ''),
        ('attachnew[9800001][description]', '圖的說明 & <x> AT1'),
        ('attachupdate[9800002]', ''),
        ('attachnew[9800002][description]', '檔案的說明 AT1'),
      ]);
    });

    test("the member's edits over the served values", () {
      final form = _form('edit_first');
      final pairs = form
          .bodyWith(
            const PostFormEdits(
              message: 'new body',
              subject: 'new title',
              options: {'usesig': false, 'smileyoff': true, 'htmlon': true, 'unknown': true},
              save: '1',
            ),
          )
          .pairs;
      final map = Map.fromEntries(pairs.map((e) => MapEntry(e.$1, e.$2)));
      expect(map['subject'], 'new title');
      expect(map['message'], 'new body');
      expect(map.containsKey('usesig'), isFalse, reason: 'unchecked');
      expect(map['smileyoff'], '1', reason: 'checked, with its value');
      expect(map.containsKey('htmlon'), isFalse, reason: 'disabled: never posted');
      expect(map.containsKey('unknown'), isFalse, reason: 'not an option of the form');
      expect(map['save'], '', reason: 'this form may not save a draft');
      expect(map['allownoticeauthor'], '1', reason: 'not edited: as served');
      // A draft form takes the draft switch.
      expect(_form('edit_draft').bodyWith(const PostFormEdits(message: 'x', save: '1')).valueOf('save'), '1');
      expect(_form('edit_draft').bodyWith(const PostFormEdits(message: 'x', save: '')).valueOf('save'), '');
    });

    test('the type: a served choice replaces it, anything else does not; a locked type is never posted', () {
      final types = _form('newthread_types');
      expect(types.bodyWith(const PostFormEdits(message: 'x', typeId: '5')).valueOf('typeid'), '5');
      expect(types.bodyWith(const PostFormEdits(message: 'x', typeId: '4')).valueOf('typeid'), '0');
      final locked = PostForm.fromJson(
        _with('edit_first', {
          'types': {
            'list': <Object?>[],
            'selected': 4,
            'selected_name': '版主專用',
            'required': 1,
            'locked': 1,
            'input': null,
          },
        }),
      )!;
      expect(locked.typeInput, isNull);
      expect(locked.bodyWith(const PostFormEdits(message: 'x', typeId: '4')).valueOf('typeid'), isNull);
      expect(PostEditContent.fromPostForm(locked)!.threadTypeList, isNull);
    });

    test("the read permission and the price: served, then the member's", () {
      final form = PostForm.fromJson(
        _with('edit_first', {
          'readperm': {
            'name': 'readperm',
            'type': 'select',
            'value': '10',
            'choices': [
              {'value': '', 'label': '不限'},
              {'value': '10', 'label': '新手上路'},
              {'value': '255', 'label': '最高权限'},
            ],
          },
          'price': {
            'max': 30,
            'credit': {'id': 2, 'title': '天使币', 'unit': ''},
            'maxincperthread': 0,
            'maxchargespan': 0,
            'free_hours': 0,
            'input': {'name': 'price', 'type': 'text', 'value': '5'},
          },
        }),
      )!;
      expect(form.body().valueOf('readperm'), '10');
      expect(form.body().valueOf('price'), '5');
      final edited = form.bodyWith(const PostFormEdits(message: 'x', perm: '255', price: 7));
      expect(edited.valueOf('readperm'), '255');
      expect(edited.valueOf('price'), '7');
      final content = PostEditContent.fromPostForm(form)!;
      expect(content.permList!.map((e) => (e.perm, e.groupName, e.selected)), [
        ('', '不限', false),
        ('10', '新手上路', true),
        ('255', '最高权限', false),
      ]);
      expect((content.price, content.maxPrice), (5, 30));
    });

    test('a map carries the body: the last value of a plain name; a list field sent twice cannot be carried', () {
      final body = PostFormBody(const [('a', '1'), ('a', '2'), ('b[]', 'x')]);
      expect(body.toMap(), {'a': '2', 'b[]': 'x'});
      expect(PostFormBody(const [('b[]', 'x'), ('b[]', 'y')]).toMap(), isNull);
    });
  });

  group('C. what the editor takes', () {
    test("ordinary forms are taken; special ones, other plugins' fields and other editors go to the website", () {
      final expected = {
        'newthread': ('newthread', PostFormSupport.supported),
        'newthread_types': ('newthread', PostFormSupport.supported),
        'newthread_moderated': ('newthread', PostFormSupport.supported),
        'newthread_hook': ('newthread', PostFormSupport.unsupported),
        'newthread_sort': ('newthread', PostFormSupport.unsupported),
        'newthread_poll': ('newthread', PostFormSupport.unsupported),
        // fid 2: another plugin prints its fields on the form of a first post (`hook_fields`).
        'edit_first': ('edit', PostFormSupport.unsupported),
        'edit_reply': ('edit', PostFormSupport.supported),
        'edit_attach': ('edit', PostFormSupport.supported),
        'edit_draft': ('edit', PostFormSupport.unsupported),
        'edit_poll': ('edit', PostFormSupport.unsupported),
        'edit_json': ('edit', PostFormSupport.unsupported),
        'reply': ('reply', PostFormSupport.supported),
        'reply_quote': ('reply', PostFormSupport.supported),
        'reply_anonymous': ('reply', PostFormSupport.supported),
        'reply_float': ('reply', PostFormSupport.supported),
      };
      expect(expected.keys.toSet(), _forms.toSet());
      for (final MapEntry(key: name, value: (action, support)) in expected.entries) {
        expect(_form(name).editorSupport(action), support, reason: name);
      }
      // The same forms where no other plugin prints fields are taken.
      for (final name in ['edit_first', 'edit_draft']) {
        expect(PostForm.fromJson(_unhooked(name))!.editorSupport('edit'), PostFormSupport.supported, reason: name);
      }
      expect(_form('newthread_hook').hookFields, ['fpbt_book', 'fpbt_author']);
      expect(_form('newthread_sort').unsupported, ['threadsort']);
      expect(_form('edit_json').unsupported, ['jsoneditor']);
      expect(_form('edit_json').message, isNull);
      // Asked for one action, answered another: not taken.
      expect(_form('newthread').editorSupport('edit'), PostFormSupport.unsupported);
    });

    test('a reply to an anonymous thread: no author named, an ordinary form', () {
      final json = _json('reply_anonymous');
      expect((json['thread'] as Map<String, dynamic>)['authorid'], 0);
      expect((json['thread'] as Map<String, dynamic>)['anonymous'], 1);
      expect(PostForm.fromJson(json)!.editorSupport('reply'), PostFormSupport.supported);
      expect(PostForm.fromJson(json)!.body().pairs.map((e) => e.$1), isNot(contains('authorid')));
    });

    test('a post of a trade thread is left to the website; a reply of another special thread is not', () {
      Map<String, dynamic> special(int current) => {
        'current': current,
        'specialextra': '',
        'sortid': 0,
        'allowed': null,
        'threadplugins': null,
        'threadsorts': null,
      };
      expect(
        PostForm.fromJson(_with('edit_reply', {'special': special(2)}))!.editorSupport('edit'),
        PostFormSupport.unsupported,
      );
      expect(
        PostForm.fromJson(_with('edit_reply', {'special': special(5)}))!.editorSupport('edit'),
        PostFormSupport.supported,
      );
      expect(
        PostForm.fromJson(_with('edit_first', {'special': special(3)}))!.editorSupport('edit'),
        PostFormSupport.unsupported,
      );
    });

    test('a captcha or a security question: never posted, whatever else the form is', () {
      const seccheck = {
        'seccode': 1,
        'secqaa': 0,
        'seccode_hash': 'cSA0000',
        'secqaa_hash': null,
        'modid': 'forum::post',
      };
      for (final name in ['newthread', 'newthread_poll', 'reply_float']) {
        final listed = PostForm.fromJson(
          _with(name, {
            'seccheck': seccheck,
            'unsupported': ['seccheck'],
          }),
        )!;
        expect(listed.asksVerification, isTrue, reason: name);
        expect(listed.editorSupport(listed.action), PostFormSupport.verification, reason: name);
        // Either sign is enough.
        expect(PostForm.fromJson(_with(name, {'seccheck': seccheck}))!.asksVerification, isTrue, reason: name);
        expect(
          PostForm.fromJson(
            _with(name, {
              'unsupported': ['seccheck'],
            }),
          )!.asksVerification,
          isTrue,
          reason: name,
        );
      }
    });

    test('a form posting elsewhere than a post url of this site, or of another action, is not taken', () {
      for (final url in [
        'https://example.com/forum.php?mod=post&action=newthread&fid=7&extra=&topicsubmit=yes',
        'forum.php?mod=post&action=edit&extra=&editsubmit=yes',
        'forum.php?mod=post&action=newthread&fid=7&extra=',
        'plugin.php?id=x&mod=post&action=newthread&topicsubmit=yes',
      ]) {
        final form = PostForm.fromJson(
          _with('newthread', {
            'submit': {...(_json('newthread')['submit'] as Map<String, dynamic>), 'url': url},
          }),
        )!;
        expect(form.submitUrl, isNull, reason: url);
        expect(form.editorSupport('newthread'), PostFormSupport.unsupported, reason: url);
      }
      expect(_form('newthread').submitUrl, '$baseUrl/forum.php?mod=post&action=newthread&fid=7&extra=&topicsubmit=yes');
      expect(
        _form('reply_float').submitUrl,
        '$baseUrl/forum.php?mod=post&infloat=yes&action=reply&fid=2&extra=&tid=9600001&replysubmit=yes',
      );
    });

    test('the content of a new thread: forum, options, draft, no type, the title limit', () {
      final form = _form('newthread');
      final content = PostEditContent.fromPostForm(form)!;
      expect(form.forumName, '神作殿堂');
      expect(content.formHash, 'f1f2f3f4');
      expect(content.postTime, '1700000000');
      expect(content.data, isEmpty);
      expect(content.threadTitle, isEmpty);
      expect(content.threadTypeList, isNull);
      expect(content.threadTitleMaxLength, 80);
      expect(content.canSaveDraft, isTrue);
      expect(content.moderated, isFalse);
      expect(content.options!.map((e) => (e.name, e.value, e.checked, e.disabled)), const [
        ('hiddenreplies', '1', false, false),
        ('ordertype', '1', false, false),
        ('allownoticeauthor', '1', true, false),
        ('usesig', '1', true, false),
        ('htmlon', '0', false, true),
        ('parseurloff', '1', false, false),
        ('smileyoff', '1', false, false),
        ('bbcodeoff', '1', false, false),
        ('imgcontent', '0', false, true),
        ('adddynamic', 'true', true, false),
      ]);
      expect(content.options!.firstWhere((e) => e.name == 'usesig').readableName, '使用个人签名');
      expect(content.postForm, same(form.json));
    });

    test("a typed forum: the choices as served (moderators' types left out), the type required", () {
      final form = _form('newthread_types');
      final content = PostEditContent.fromPostForm(form)!;
      expect(content.threadTypeList!.map((e) => e.typeID), ['0', '3', '5']);
      expect(content.threadTypeList!.skip(1).map((e) => e.name), ['年度分享', '其他']);
      expect(content.threadType!.typeID, '0');
      expect(form.typeRequired, isTrue);
      expect(form.typeLocked, isFalse);
    });

    test('a moderated forum: said before posting; no draft there', () {
      expect(PostEditContent.fromPostForm(_form('newthread_moderated'))!.moderated, isTrue);
      expect(PostEditContent.fromPostForm(_form('newthread_moderated'))!.canSaveDraft, isFalse);
      // The edit page does not tell (null): nothing is said.
      expect(_form('edit_first').moderated, isNull);
      expect(PostEditContent.fromPostForm(_form('edit_first'))!.moderated, isFalse);
    });

    test('the edits: the thread fields, the title, the draft', () {
      final first = PostEditContent.fromPostForm(_form('edit_first'))!;
      expect((first.fid, first.tid, first.pid, first.page, first.delattachop), ('2', '9600001', '9700001', '1', '0'));
      expect(first.threadTitle, 'tsdmapp 2.9.0 N1 一般 000000');
      expect(first.canSaveDraft, isFalse);
      final reply = PostEditContent.fromPostForm(_form('edit_reply'))!;
      expect(reply.threadTitle, isEmpty);
      expect(reply.data, 'N1 三樓（ag_low 自己）000000');
      expect(PostEditContent.fromPostForm(_form('edit_draft'))!.canSaveDraft, isTrue);
      // An edit without its thread fields is not taken.
      final broken = PostForm.fromJson(
        _with('edit_first', {
          'submit': {
            'url': 'forum.php?mod=post&action=edit&extra=&editsubmit=yes',
            'fields': {'formhash': 'f1f2f3f4', 'posttime': '1700000000'},
          },
        }),
      )!;
      expect(PostEditContent.fromPostForm(broken), isNull);
    });
  });

  group('D. lengths, as the forum counts them', () {
    test('the title: trimmed, escaped, then dstrlen (ASCII 1, anything else 2, & 5)', () {
      expect(discuzSubjectLength('abc'), 3);
      expect(discuzSubjectLength('  標題 '), 4);
      expect(discuzSubjectLength('a&b'), 7);
      expect(discuzSubjectLength('"<>'), 14);
      expect(discuzSubjectLength('😀'), 2);
      final content = PostEditContent.fromPostForm(_form('newthread'))!;
      expect(content.titleLength('中' * 40), 80);
      expect(content.titleTooLong('中' * 40, 210), isFalse);
      expect(content.titleTooLong('中' * 40 + 'a', 210), isTrue);
      expect(content.titleTooLong('&' * 16, 210), isFalse);
      expect(content.titleTooLong('&' * 17, 210), isTrue);
      expect(content.titleTooShort(''), isFalse, reason: 'an empty title is not too short (min 1)');
    });

    test('the web page: the editor counts UTF-8 bytes against the page limit, as it always did', () {
      final content = PostEditContent.fromDocument(parseHtmlDocument(draftEditForm()))!;
      expect(content.postForm, isNull);
      expect(content.titleLength('中'), 3);
      expect(content.titleTooLong('a' * 10, 10), isTrue);
      expect(content.titleTooLong('a' * 9, 10), isFalse);
      expect(content.messageTooShort(''), isFalse);
      expect(content.messageTooLong('x' * 100000), isFalse);
    });

    test('the post: UTF-8 bytes, the minimum without quotes; no limit the forum does not check', () {
      final content = PostEditContent.fromPostForm(_form('newthread'))!;
      expect(content.messageTooShort('123456789'), isTrue);
      expect(content.messageTooShort('1234567890'), isFalse);
      expect(content.messageTooShort('中文字'), isTrue, reason: '9 bytes');
      expect(content.messageTooShort('中文字四'), isFalse, reason: '12 bytes');
      expect(content.messageTooShort('[quote]a long quote here[/quote]abc'), isTrue);
      expect(content.messageTooLong('x' * 10000), isFalse);
      expect(content.messageTooLong('x' * 10001), isTrue);
      expect(discuzMessageTooShort('[postbg]bg.png[/postbg]short', 10), isTrue);
      // A form the forum does not check (the first post of a special thread, of a thread sort, a group free of the post
      // limits) gives none: never refused here, and the title keeps the limit every submission has (`hard_max`).
      final free = _form('newthread_poll');
      expect((free.subjectMax, free.subjectMin, free.messageMin, free.messageMax), (null, null, null, null));
      expect(free.subjectHardMax, 255);
      expect(free.subjectLimit, discuzSubjectServerLimit);
      final freeContent = PostEditContent.fromPostForm(free)!;
      expect(freeContent.threadTitleMaxLength, 255);
      expect(freeContent.messageTooShort(''), isFalse);
      expect(freeContent.messageTooLong('x' * 100000), isFalse);
      expect(_form('newthread_sort').subjectMax, isNull);
      // The minimum counts the quote when the forum says so.
      final counted = PostEditContent.fromPostForm(
        PostForm.fromJson(
          _with('newthread', {
            'message': {'value': '', 'min': 10, 'max': 10000, 'unit': 'bytes', 'min_excludes_quote': 0, 'json': 0},
          }),
        )!,
      )!;
      expect(counted.messageTooShort('[quote]a long quote here[/quote]abc'), isFalse);
      expect(content.messageTooShort('[quote]a long quote here[/quote]abc'), isTrue);
      // A limit counted another way than the app knows is not applied.
      final other = PostForm.fromJson(
        _with('newthread', {
          'subject': {'shown': 1, 'value': '', 'max': 40, 'min': 1, 'reply_default': null, 'unit': 'chars'},
          'message': {'value': '', 'min': 10, 'max': 10000, 'json': 0, 'unit': 'chars'},
        }),
      )!;
      expect(other.subjectMax, isNull);
      expect(other.subjectLimit, 255);
      expect(other.messageMin, isNull);
      expect(other.messageMax, isNull);
    });
  });

  group('E. the editor (PostEditRepository, PostEditBloc)', () {
    test('asks the form in the JSON mode and takes the structured form', () async {
      final harness = _Harness(page: (_) => _json('edit_first'));
      final answer = _right(await harness.repo.fetchForm(_editUrl).run());
      expect(answer, isA<PostEditFormApi>());
      expect(harness.gets.single, withTsdmAppJson(_editUrl));
      expect(Uri.parse(harness.gets.single).queryParameters, containsPair('nodoc', '1'));
      expect(TsdmAppApi.knowsPostForm, isTrue, reason: 'a post form came back');
    });

    test('the forum message instead of the form, of the same account: refused with its text', () async {
      final harness = _Harness(page: (_) => _json('msg_passwd'));
      final answer = _right(await harness.repo.fetchForm(_editUrl).run());
      expect(answer, isA<PostEditFormRefused>().having((e) => e.message, 'message', '本版块需要密码'));
    });

    test('an answer served to another account or a guest is never used', () async {
      for (final (answer, owner) in [
        (_json('edit_first'), 35),
        (_json('msg_guest'), 31),
        (_json('msg_noperm'), 31),
      ]) {
        final harness = _Harness(page: (_) => answer, uid: owner);
        expect(_left(await harness.repo.fetchForm(_editUrl).run()), isA<IdentityChangedException>());
      }
    });

    test('the web page (no plugin, an older one): read as it always was', () async {
      final harness = _Harness(page: (_) => draftEditForm())..uid = 1000;
      final answer = _right(await harness.repo.fetchForm(_editUrl).run());
      expect(answer, isA<PostEditFormPage>());
      expect(harness.gets, [withTsdmAppJson(_editUrl)]);
      expect(
        _left(await (_Harness(page: (_) => draftEditForm(uid: 1001))..uid = 1000).repo.fetchForm(_editUrl).run()),
        isA<IdentityChangedException>(),
      );
    });

    test('an answer the plugin could not tell the form of: the web page itself, asked again', () async {
      final harness = _Harness(
        page: (url) => url.contains('tsdmapp=json')
            ? {'ok': 0, 'error': 'unknown', 'document': '<form id="postform"></form>'}
            : draftEditForm(uid: 31),
      );
      final answer = _right(await harness.repo.fetchForm(_editUrl).run());
      expect(answer, isA<PostEditFormPage>());
      expect(harness.gets, [withTsdmAppJson(_editUrl), _editUrl]);
    });

    test('a new thread: loaded from the form, posted to its url with the edits over every served value', () async {
      final harness = _Harness(page: (_) => _json('newthread'), post: (_, _) => _redirectTo(9600099));
      final bloc = await _load(harness, const ThreadPubFetchInfoRequested(fid: '7'));
      expect(bloc.state.status, PostEditStatus.editing);
      expect(bloc.state.forumName, '神作殿堂');
      expect(harness.gets.single, withTsdmAppJson('$homePage?mod=post&action=newthread&fid=7'));
      final content = bloc.state.content!;
      final done = bloc.stream.firstWhere((s) => s.status == PostEditStatus.success);
      bloc.add(
        ThreadPubPostThread(
          ThreadPublishInfo(
            formHash: content.formHash,
            postTime: content.postTime,
            delAttachOp: '0',
            wysiwyg: content.wysiwyg,
            fid: '7',
            threadType: null,
            checkbox: '0',
            subject: '新帖標題',
            message: '新帖內文 [@]ag_low2[/@]',
            price: null,
            perm: null,
            save: '',
            options: content.options!.map((e) => e.name == 'usesig' ? e.copyWith(checked: false) : e).toList(),
          ),
        ),
      );
      await done.timeout(const Duration(seconds: 3));
      expect(bloc.state.redirectTid, '9600099');
      final (url, body) = harness.posts.single;
      expect(url, '$baseUrl/forum.php?mod=post&action=newthread&fid=7&extra=&topicsubmit=yes');
      expect(body, {
        'formhash': 'f1f2f3f4',
        'posttime': '1700000000',
        'wysiwyg': '1',
        'topicsubmit': 'true',
        'save': '',
        'subject': '新帖標題',
        'message': toOfficialMentions('新帖內文 [@]ag_low2[/@]'),
        'allownoticeauthor': '1',
        'adddynamic': 'true',
        'replycredit_times': '1',
        'replycredit_extcredits': '0',
        'replycredit_membertimes': '1',
        'replycredit_random': '100',
      });
    });

    test("an edit: posted to its url, the attachments' fields kept, the thread confirmed", () async {
      final harness = _Harness(page: (_) => _json('edit_attach'), post: (_, _) => _redirectTo(9600003));
      final bloc = await _load(
        harness,
        const PostEditLoadDataRequested('$baseUrl/forum.php?mod=post&action=edit&fid=7&tid=9600003&pid=9700005'),
      );
      expect(bloc.state.status, PostEditStatus.editing);
      final content = bloc.state.content!;
      final done = bloc.stream.firstWhere((s) => s.status == PostEditStatus.success);
      bloc.add(
        PostEditCompleteEditRequested(
          formHash: content.formHash,
          postTime: content.postTime,
          delattachop: content.delattachop!,
          wysiwyg: content.wysiwyg,
          fid: '7',
          tid: '9600003',
          pid: '9700005',
          page: content.page!,
          threadType: null,
          threadTitle: content.threadTitle,
          data: '${content.data}\n已編輯',
          options: content.options!,
          save: '',
          perm: null,
          price: null,
        ),
      );
      await done.timeout(const Duration(seconds: 3));
      final (url, body) = harness.posts.single;
      expect(url, '$baseUrl/forum.php?mod=post&action=edit&extra=&editsubmit=yes');
      expect(body['message'], endsWith('[attach]9800002[/attach]\n後文\n已編輯'));
      expect(body['message'], contains('[attachimg]9800001[/attachimg]'));
      expect(body['attachnew[9800001][description]'], '圖的說明 & <x> AT1');
      expect(body['attachupdate[9800002]'], '');
      expect(body['subject'], 'tsdmapp 2.9.0 AT1 附件 000000');
      expect((body['tid'], body['pid'], body['editsubmit']), ('9600003', '9700005', 'true'));
    });

    test('an edit redirected to another thread is no success', () async {
      final harness = _Harness(page: (_) => _unhooked('edit_first'), post: (_, _) => _redirectTo(1));
      final bloc = await _load(harness, const PostEditLoadDataRequested(_editUrl));
      final content = bloc.state.content!;
      final failed = bloc.stream.firstWhere((s) => s.status == PostEditStatus.failedToUpload);
      bloc.add(
        PostEditCompleteEditRequested(
          formHash: content.formHash,
          postTime: content.postTime,
          delattachop: '0',
          wysiwyg: content.wysiwyg,
          fid: '2',
          tid: '9600001',
          pid: '9700001',
          page: '1',
          threadType: null,
          threadTitle: content.threadTitle,
          data: content.data,
          options: content.options!,
          save: '',
          perm: null,
          price: null,
        ),
      );
      await failed.timeout(const Duration(seconds: 3));
      expect(harness.posts, hasLength(1));
    });

    test("a captcha: the website, nothing typed or posted; the web page's too", () async {
      final seccheck = _Harness(
        page: (_) => _with('newthread', {
          'seccheck': {
            'seccode': 0,
            'secqaa': 1,
            'seccode_hash': null,
            'secqaa_hash': 'qSA0000',
            'modid': 'forum::post',
          },
          'unsupported': ['seccheck'],
        }),
      );
      final bloc = await _load(seccheck, const ThreadPubFetchInfoRequested(fid: '7'));
      expect(bloc.state.status, PostEditStatus.verificationRequired);
      expect(bloc.state.content, isNull);
      expect(bloc.canSubmit, isFalse);

      const challenge =
          '<div id="seccheck"><span id="seccode_cSA0000"></span> '
          '<script type="text/javascript" reload="1">updateseccode(\'cSA0000\', \'\', \'forum::post\');</script></div>';
      final page = _Harness(page: (_) => draftEditForm(extra: challenge, uid: 31));
      final pageBloc = await _load(page, const ThreadPubFetchInfoRequested(fid: '4'));
      expect(pageBloc.state.status, PostEditStatus.verificationRequired);
      expect(documentAsksVerification(parseHtmlDocument(draftEditForm(extra: challenge))), isTrue);
      expect(documentAsksVerification(parseHtmlDocument(draftEditForm())), isFalse);
      expect(
        documentAsksVerification(parseHtmlDocument(draftEditForm(extra: '<input name="secanswer" value="">'))),
        isTrue,
      );
    });

    test("other plugins' fields, a thread sort, another editor, a special thread: the website", () async {
      for (final (name, event) in [
        ('newthread_hook', const ThreadPubFetchInfoRequested(fid: '2')),
        ('newthread_sort', const ThreadPubFetchInfoRequested(fid: '25')),
        ('newthread_poll', const ThreadPubFetchInfoRequested(fid: '2')),
        ('edit_json', const PostEditLoadDataRequested(_editUrl)),
        ('edit_poll', const PostEditLoadDataRequested(_editUrl)),
      ]) {
        final bloc = await _load(_Harness(page: (_) => _json(name)), event);
        expect(bloc.state.status, PostEditStatus.unsupported, reason: name);
      }
    });

    test('the forum message: a failure that says it', () async {
      final bloc = await _load(_Harness(page: (_) => _json('msg_passwd')), const ThreadPubFetchInfoRequested(fid: '9'));
      expect(bloc.state.status, PostEditStatus.failedToLoad);
      expect(bloc.state.errorText, '本版块需要密码');
    });

    test('the web page: posted as it always was, to the fixed edit url with the old fields', () async {
      final harness = _Harness(page: (_) => draftEditForm(), post: (_, _) => '')..uid = 1000;
      final bloc = await _load(harness, const PostEditLoadDataRequested(_editUrl));
      expect(bloc.state.status, PostEditStatus.editing);
      expect(bloc.state.content!.postForm, isNull);
      final failed = bloc.stream.firstWhere((s) => s.status == PostEditStatus.failedToUpload);
      bloc.add(
        const PostEditCompleteEditRequested(
          formHash: 'synthetic-token',
          postTime: '100',
          delattachop: '0',
          wysiwyg: '0',
          fid: '4',
          tid: '123',
          pid: '456',
          page: '1',
          threadType: null,
          threadTitle: 'Synthetic subject',
          data: 'Synthetic body',
          options: [],
          save: '',
          perm: null,
          price: null,
        ),
      );
      await failed.timeout(const Duration(seconds: 3));
      final (url, body) = harness.posts.single;
      expect(url, '$baseUrl/forum.php?mod=post&action=edit&extra=&editsubmit=yes');
      expect(body['checkbox'], '0', reason: 'the old fields');
      expect(body['formhash'], 'synthetic-token');
    });
  });

  group('F. the poll creator', () {
    const draft = PollDraft(
      subject: '投票標題',
      message: '',
      options: ['甲', '乙', '丙'],
      maxChoices: '2',
      expiry: '3',
      visibleAfterVote: true,
      publicVoters: false,
      threadType: null,
      extraOptions: [],
    );

    PollCreateRepository repo(Object? Function(String url) page, {int uid = 31, List<String>? gets}) =>
        PollCreateRepository.withTransport(
          currentUid: () => uid,
          getPage: (url) async {
            gets?.add(url);
            return right(_response(page(url)));
          },
          sendForm: (_, _) async => throw StateError('no post'),
        );

    test('the form from the answer: the limit is poll.max_options, no page script read', () async {
      final gets = <String>[];
      final load = await repo((_) => _unhooked('newthread_poll'), gets: gets).fetchForm('2');
      expect(load.kind, PollFormLoadKind.ready);
      final form = load.form!;
      expect(gets.single, withTsdmAppJson(PollCreateRepository.formUrl('2')));
      expect(form.postForm, isNotNull);
      expect(form.maxOptions, 20);
      expect(form.actionUrl, '$baseUrl/forum.php?mod=post&action=newthread&fid=2&extra=&topicsubmit=yes');
      expect((form.initialMaxChoices, form.initialExpiration), (1, ''));
      expect(form.visibility!.initiallyChecked, isFalse);
      expect(form.overt!.name, 'overt');
      expect(form.forumName, '📢 公告 & 新手報到');
      // The forum checks no title limit of its own for a poll: only the one of every submission.
      expect(form.subjectLimit, 255);
      expect(form.extraOptions.map((e) => e.name), contains('adddynamic'));
    });

    test('the poll posted over every served field, one choice per line', () async {
      final form = (await repo((_) => _unhooked('newthread_poll')).fetchForm('2')).form!;
      final submission = validatePollDraft(draft, form).submission!;
      final payload = submission.toPayload(form);
      expect(payload, {
        'formhash': 'f1f2f3f4',
        'posttime': '1700000000',
        'wysiwyg': '1',
        'special': '1',
        'topicsubmit': 'true',
        'save': '',
        'subject': '投票標題',
        'message': '',
        'replycredit_times': '1',
        'replycredit_extcredits': '0',
        'replycredit_membertimes': '1',
        'replycredit_random': '100',
        'polls': 'yes',
        'fid': '2',
        'tpolloption': '2',
        'polloptions': '甲\n乙\n丙',
        'maxchoices': '2',
        'expiration': '3',
        'visibilitypoll': '1',
      });
      // The served options the member did not check are not posted, as the website does.
      expect(payload.containsKey('usesig'), isFalse);
      expect(payload.keys.where((k) => k.startsWith('polloption[')), isEmpty);
    });

    test('messages, guests, other accounts', () async {
      expect((await repo((_) => _json('msg_passwd')).fetchForm('9')).kind, PollFormLoadKind.denied);
      expect((await repo((_) => _json('msg_passwd')).fetchForm('9')).message, '本版块需要密码');
      expect((await repo((_) => _json('msg_guest')).fetchForm('2')).kind, PollFormLoadKind.loginRequired);
      expect(
        (await repo((_) => _unhooked('newthread_poll'), uid: 35).fetchForm('2')).kind,
        PollFormLoadKind.identityChanged,
      );
    });

    test('a form the poll creator cannot take: the browser', () async {
      Map<String, dynamic> poll(List<Map<String, dynamic>> Function(List<Map<String, dynamic>>) change) {
        final json = _unhooked('newthread_poll');
        final block = json['poll'] as Map<String, dynamic>;
        block['inputs'] = change((block['inputs'] as List).cast<Map<String, dynamic>>());
        return json;
      }

      for (final (reason, answer) in [
        (
          'a captcha',
          _with('newthread_poll', {
            'hook_fields': <Object?>[],
            'seccheck': {'seccode': 1},
            'unsupported': ['seccheck'],
          }),
        ),
        ('an ordinary form', _json('newthread')),
        (
          'a read-only limit',
          poll(
            (i) => [
              for (final e in i) e['name'] == 'maxchoices' ? {...e, 'readonly': 1} : e,
            ],
          ),
        ),
        (
          'an unknown poll field',
          poll(
            (i) => [
              ...i,
              {'name': 'pollplus', 'type': 'text', 'value': '1'},
            ],
          ),
        ),
        (
          'no bulk field',
          poll(
            (i) => [
              for (final e in i)
                if (e['name'] != 'polloptions') e,
            ],
          ),
        ),
        (
          'another forum',
          _with('newthread_poll', {
            'hook_fields': <Object?>[],
            'submit': {
              ..._unhooked('newthread_poll')['submit'] as Map<String, dynamic>,
              'url': 'forum.php?mod=post&action=newthread&fid=3&extra=&topicsubmit=yes',
            },
          }),
        ),
      ]) {
        expect((await repo((_) => answer).fetchForm('2')).kind, PollFormLoadKind.unsupported, reason: reason);
      }
    });

    test("other plugins' fields: the web page itself, whose parser knows the site's poll plugin", () async {
      final gets = <String>[];
      final load = await repo(
        (url) => url.contains('tsdmapp=json')
            ? _with('newthread_poll', {
                'hook_fields': [
                  {
                    'hook': 'post_poll_extra',
                    'names': ['pollplusviewcredit', 'pollpluslockday'],
                  },
                ],
              })
            : pollForm(
                uid: 31,
                fid: '2',
                plugin: pollPluginNeutral,
                action: 'forum.php?mod=post&amp;action=newthread&amp;fid=2&amp;extra=&amp;topicsubmit=yes',
              ),
        gets: gets,
      ).fetchForm('2');
      expect(load.kind, PollFormLoadKind.ready);
      expect(load.form!.postForm, isNull);
      expect(load.form!.neutralPluginFields, {'pollplusviewcredit': '0', 'pollpluslockday': '0'});
      expect(gets, [withTsdmAppJson(PollCreateRepository.formUrl('2')), PollCreateRepository.formUrl('2')]);
      // The test forum's form plugin on fid 2 (the real answer): the web page too.
      gets.clear();
      await repo(
        (url) => url.contains('tsdmapp=json') ? _json('newthread_poll') : pollForm(uid: 31),
        gets: gets,
      ).fetchForm('2');
      expect(gets, hasLength(2));
    });

    test("the web page (no plugin, an older one): parsed as it always was, with its script's limit", () async {
      final gets = <String>[];
      final load = await repo((_) => pollForm(uid: 31), gets: gets).fetchForm('4');
      expect(load.kind, PollFormLoadKind.ready);
      expect(load.form!.maxOptions, 100);
      expect(load.form!.postForm, isNull);
      expect(gets, hasLength(1));
    });
  });

  group('G. the reply to a floor', () {
    Map<String, dynamic> stored() =>
        jsonDecode(File('$_dir/write_v13_reply_ok.json').readAsStringSync()) as Map<String, dynamic>;

    bool asksJson(_Request r) => r.uri.queryParameters['tsdmapp'] == 'json';

    test('a forum not known to answer post forms: the window asked and posted the way it always was', () async {
      final window = File('test/data/reply_window_x5.xml').readAsStringSync();
      final forum = _Forum((r) => r.method == 'GET' ? _xml(window) : _api(stored()));
      _use(forum);
      _right(await _replyToPost());
      expect(forum.requests.map((r) => r.method), ['GET', 'POST']);
      expect(forum.requests.first.uri.queryParameters['inajax'], '1');
    });

    test('known: the window as the post form, posted with its served fields to its url with inajax', () async {
      TsdmAppApi.notePostForm();
      final forum = _Forum((r) => r.method == 'GET' ? _api(_json('reply_float')) : _api(stored()));
      _use(forum);
      final posted = _right(await _replyToPost(stand: 1));
      expect(posted, (pid: '4750', page: 1));
      expect(forum.requests.map((r) => r.method), ['GET', 'POST']);
      final window = forum.requests.first.uri;
      expect(window.queryParameters, containsPair('infloat', 'yes'));
      expect(window.queryParameters, containsPair('handlekey', 'reply'));
      expect(window.queryParameters.containsKey('inajax'), isFalse);
      expect((window.queryParameters['tsdmapp'], window.queryParameters['nodoc']), ('json', '1'));
      expect(window.queryParameters['repquote'], '9700002');
      final post = forum.requests.last;
      expect(post.uri.path, '/forum.php');
      // `mobile=no` is the desktop layout every request of the app asks for.
      expect({...post.uri.queryParameters}..remove('mobile'), {
        'mod': 'post',
        'infloat': 'yes',
        'action': 'reply',
        'fid': '2',
        'extra': '',
        'tid': '9600001',
        'replysubmit': 'yes',
        'inajax': '1',
        'tsdmapp': 'json',
      });
      expect(post.headers['X-Requested-With'], 'XMLHttpRequest');
      final body = Uri.splitQueryString(post.body);
      expect(body, {
        'formhash': 'f1f2f3f4',
        'handlekey': 'reply',
        'noticeauthor': 'NOTICEAUTHOR',
        'noticetrimstr': _form('reply_float').submitFields['noticetrimstr'],
        'noticeauthormsg': 'N1 二樓（ag_low2）000000 斜體',
        'usesig': '1',
        'reppid': '9700002',
        'reppost': '9700002',
        'replysubmit': 'true',
        'subject': '',
        'message': '回覆內容 [b]x[/b]',
        'stand': '1',
      });
    });

    test('known from the version the plugin named', () async {
      TsdmAppApi.pluginInfo.value = const TsdmAppPluginInfo(version: '2.9.0', api: 1, nodoc: true);
      expect(TsdmAppApi.knowsPostForm, isTrue);
      TsdmAppApi.pluginInfo.value = const TsdmAppPluginInfo(version: '2.8.4', api: 1, nodoc: true);
      expect(TsdmAppApi.knowsPostForm, isFalse);
      TsdmAppApi.pluginInfo.value = const TsdmAppPluginInfo(version: '2.10.0', api: 1, nodoc: true);
      expect(TsdmAppApi.knowsPostForm, isTrue);
    });

    test('known, but the window came back otherwise: asked again the way it always was', () async {
      TsdmAppApi.notePostForm();
      final window = File('test/data/reply_window_x5.xml').readAsStringSync();
      final forum = _Forum(
        (r) => r.method == 'POST'
            ? _api(stored())
            : (r.uri.queryParameters['inajax'] == '1'
                  ? _xml(window)
                  : _api({'ok': 1, 'type': 'result', 'schema': 13, 'kind': 'page', 'document': ''})),
      );
      _use(forum);
      _right(await _replyToPost());
      expect(forum.requests.map((r) => (r.method, r.uri.queryParameters['inajax'])), [
        ('GET', null),
        ('GET', '1'),
        ('POST', '1'),
      ]);
      expect(forum.requests.every(asksJson), isTrue);
    });

    test("a captcha, other plugins' fields: the browser, nothing posted", () async {
      TsdmAppApi.notePostForm();
      for (final (answer, verification) in [
        (
          _with('reply_float', {
            'seccheck': {
              'seccode': 1,
              'secqaa': 0,
              'seccode_hash': 'cSA0000',
              'secqaa_hash': null,
              'modid': 'forum::post',
            },
            'unsupported': ['seccheck'],
          }),
          true,
        ),
        (
          _with('reply_float', {
            'hook_fields': [
              {
                'hook': 'post_infloat_middle',
                'names': ['extra_field'],
              },
            ],
          }),
          false,
        ),
      ]) {
        final forum = _Forum((r) => _api(answer));
        _use(forum);
        final failure = _left(await _replyToPost());
        expect(
          failure,
          isA<ReplyNeedsBrowserException>()
              .having((e) => e.verification, 'verification', verification)
              .having((e) => e.url, 'url', '$baseUrl/$_replyAction'),
        );
        expect(forum.requests.map((r) => r.method), ['GET']);
        await getIt.unregister<NetClientProvider>();
      }
    });

    test('the web window asking for a captcha: the browser, nothing posted', () async {
      final window = File('test/data/reply_window_x5.xml').readAsStringSync().replaceFirst(
        '<div id="seccheck_reply">',
        '<div id="seccheck_reply"><span id="secqaa_qSA0000"></span>',
      );
      final forum = _Forum((r) => _xml(window));
      _use(forum);
      expect(_left(await _replyToPost()), isA<ReplyNeedsBrowserException>().having((e) => e.verification, 'v', isTrue));
      expect(forum.requests.map((r) => r.method), ['GET']);
    });

    test("a window served to another account or a guest, the forum's message: refused, nothing posted", () async {
      TsdmAppApi.notePostForm();
      for (final (answer, parameters, message) in [
        (_json('reply_float'), _replyParameters.copyWith(viewerUid: 35), null),
        (_json('msg_guest'), _replyParameters, '抱歉，您尚未登录，没有权限在该版块发帖'),
        (
          {..._json('msg_noperm'), 'uid': 31, 'message': '抱歉，本主题已关闭，不再接受新内容'},
          _replyParameters,
          '抱歉，本主题已关闭，不再接受新内容',
        ),
      ]) {
        final forum = _Forum((r) => _api(answer));
        _use(forum);
        final failure = _left(await _replyToPost(parameters: parameters));
        expect(failure, isA<ReplyToPostFetchParameterFailedException>());
        if (message != null) expect(failure.message, message);
        expect(forum.requests.map((r) => r.method), ['GET']);
        await getIt.unregister<NetClientProvider>();
      }
      // The account of the global cookie too.
      getIt.registerSingleton<CookieProvider>(CookieProvider(const UserLoginInfo(uid: 35, username: 'other'), {}));
      addTearDown(() => getIt.unregister<CookieProvider>());
      final forum = _Forum((r) => _api(_json('reply_float')));
      _use(forum);
      expect(_left(await _replyToPost()), isA<ReplyToPostFetchParameterFailedException>());
      expect(forum.requests.map((r) => r.method), ['GET']);
    });

    test('the reply bar: the reason, and the page to reply on in the browser', () async {
      TsdmAppApi.notePostForm();
      _use(
        _Forum(
          (r) => _api(
            _with('reply_float', {
              'seccheck': {'secqaa': 1},
              'unsupported': ['seccheck'],
            }),
          ),
        ),
      );
      final bloc = ReplyBloc(replyRepository: const ReplyRepository());
      addTearDown(bloc.close);
      final failed = bloc.stream.firstWhere((s) => s.status == ReplyStatus.failure);
      bloc.add(
        const ReplyToPostRequested(replyParameters: _replyParameters, replyAction: _replyAction, replyMessage: 'hi'),
      );
      final state = await failed.timeout(const Duration(seconds: 3));
      expect(state.browserUrl, '$baseUrl/$_replyAction');
      expect(state.failedReason, t.threadPage.replyNeedsVerification);
      expect(state.networkFailure, isFalse);
    });
  });
}
