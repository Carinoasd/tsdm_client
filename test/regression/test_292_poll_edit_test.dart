/// The first post of a poll edited in the app: the title and the post, the poll as served.
///
/// The edit form of the first post of a poll (plugin 2.9.0, `post_v16_edit_poll`) serves the options by id
/// (`polloptionid[ID]`, `displayorder[ID]`, `polloption[ID]`, `pollimage[ID]`) and the settings as the web page prints
/// them (`maxchoices`, `expiration` in days left, `visibilitypoll`, `overt`). The forum
/// (`extend_thread_poll::before_editpost`) keeps an option by its id with its votes, so the form posted back as served
/// ([PostForm.body]) changes nothing of the poll, as the website's form when the member changes none of it; a form
/// without options would drop the poll from the thread, and is left to the website. A poll that has ended prints its
/// days left as words, which the forum would store as no expiry (the poll reopened): the app posts a day before today,
/// which keeps it ended.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/post/bloc/post_edit_bloc.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// The fixture as a forum without a forms plugin serves it: no `hook_fields`.
Map<String, dynamic> _poll() => {..._json('post_v16_edit_poll'), 'hook_fields': <Object?>[]};

Map<String, dynamic> _withPoll(Map<String, dynamic> changes) => {
  ..._poll(),
  'poll': {...(_poll()['poll'] as Map<String, dynamic>), ...changes},
};

Response<dynamic> _response(Object? data) =>
    Response<dynamic>(requestOptions: RequestOptions(), data: data, statusCode: 200);

const _editUrl = 'https://www.tsdm39.com/forum.php?mod=post&action=edit&fid=2&tid=9600010&pid=9700012';

const Map<String, Object?> _edited = {
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
  'url': 'forum.php?mod=viewthread&tid=9600010&page=1&extra=#pid9700012',
  'handlekey': '',
  'values': <String, Object?>{},
  'login': 0,
  'alert': '',
};

/// The poll's fields of the fixture as the website's form posts them unchanged.
const Map<String, String> _servedPoll = {
  'polls': 'yes',
  'fid': '2',
  'polloptionid[1001]': '1001',
  'displayorder[1001]': '0',
  'polloption[1001]': '選項甲 & "乙" 000000',
  'pollimage[1001]': '',
  'polloptionid[1002]': '1002',
  'displayorder[1002]': '1',
  'polloption[1002]': '選項二',
  'pollimage[1002]': '',
  'polloptionid[1003]': '1003',
  'displayorder[1003]': '2',
  'polloption[1003]': '選項三',
  'pollimage[1003]': '',
  'maxchoices': '2',
  'expiration': '3',
  'visibilitypoll': '1',
  'overt': '1',
};

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });
  setUp(TsdmAppApi.reset);

  group('the form', () {
    test('the first post of a poll with its options is taken', () {
      final form = PostForm.fromJson(_poll())!;
      expect(form.special, 1);
      expect(form.first, isTrue);
      expect(form.editsPollAsServed, isTrue);
      expect(form.editorSupport('edit'), PostFormSupport.supported);
    });

    test('the poll goes back as served, whatever else the member changed', () {
      final form = PostForm.fromJson(_poll())!;
      final body = form.bodyWith(const PostFormEdits(message: '新內文', subject: '新標題')).toMap()!;
      expect(body['subject'], '新標題');
      expect(body['message'], '新內文');
      expect(body['special'], '1');
      for (final MapEntry(:key, :value) in _servedPoll.entries) {
        expect(body[key], value, reason: key);
      }
      // No field of a new poll (`polloption[]`, `tpolloption`, `polloptions`).
      expect(body.keys.where((k) => k.startsWith('polloption[') && !k.endsWith(']')), isEmpty);
      expect(body.containsKey('polloption[]'), isFalse);
      expect(body.containsKey('tpolloption'), isFalse);
    });

    test('a poll without options, or an option without its fields, is left to the website', () {
      expect(
        PostForm.fromJson(_withPoll({'options': <Object?>[]}))!.editorSupport('edit'),
        PostFormSupport.unsupported,
      );
      final inputs = (_poll()['poll'] as Map<String, dynamic>)['inputs'] as List<dynamic>;
      final missing = PostForm.fromJson(
        _withPoll({
          'inputs': [
            for (final input in inputs)
              if ((input as Map<String, dynamic>)['name'] != 'polloptionid[1002]') input,
          ],
        }),
      )!;
      expect(missing.editorSupport('edit'), PostFormSupport.unsupported);
      // The options of a new poll (`polloption[]`) are not the ones of an edit.
      expect(
        PostForm.fromJson(_withPoll({'option_field': 'polloption[]'}))!.editorSupport('edit'),
        PostFormSupport.unsupported,
      );
      expect(PostForm.fromJson({..._poll(), 'poll': null})!.editorSupport('edit'), PostFormSupport.unsupported);
      // Without `polls` the forum reads no poll edit; the option ids are numbers in the plugin's answer.
      final noPolls = PostForm.fromJson(
        _withPoll({
          'inputs': [
            for (final input in inputs)
              if ((input as Map<String, dynamic>)['name'] != 'polls') input,
          ],
        }),
      )!;
      expect(noPolls.editorSupport('edit'), PostFormSupport.unsupported);
      final textIds = PostForm.fromJson(
        _withPoll({
          'options': [
            for (final option in (_poll()['poll'] as Map<String, dynamic>)['options'] as List<dynamic>)
              {...option as Map<String, dynamic>, 'id': '${option['id']}'},
          ],
        }),
      )!;
      expect(textIds.editorSupport('edit'), PostFormSupport.unsupported);
    });

    test('an ended or closed poll stays ended: a day before today, not the words the page prints', () {
      List<dynamic> inputs(String expiration) => [
        for (final input in (_poll()['poll'] as Map<String, dynamic>)['inputs'] as List<dynamic>)
          if ((input as Map<String, dynamic>)['name'] == 'expiration') {...input, 'value': expiration} else input,
      ];
      for (final words in ['已结束', '已关闭']) {
        final form = PostForm.fromJson(_withPoll({'inputs': inputs(words)}))!;
        expect(form.body().toMap()!['expiration'], words, reason: 'as the page serves it');
        expect(form.bodyWith(const PostFormEdits(message: 'm')).toMap()!['expiration'], '-1', reason: words);
      }
      // No expiry, or days left: as served. `0` is also what a poll with less than half a day left prints (the days
      // rounded): stored without expiry, as the website's form does.
      for (final days in ['0', '3']) {
        final form = PostForm.fromJson(_withPoll({'inputs': inputs(days)}))!;
        expect(form.bodyWith(const PostFormEdits(message: 'm')).toMap()!['expiration'], days);
      }
    });

    test('a reply of a poll thread is no poll edit', () {
      final reply = PostForm.fromJson({..._poll(), 'first': 0})!;
      expect(reply.editsPollAsServed, isFalse);
    });
  });

  test('the editor posts the title and the post with the poll as served', () async {
    final posts = <Map<String, String>>[];
    final repo = PostEditRepository.withTransport(
      currentUid: () => 31,
      getPage: (url) async => right(_response(_poll())),
      sendForm: (url, body) async {
        posts.add(body);
        return right(_response(_edited));
      },
    );
    final bloc = PostEditBloc(postEditRepository: repo);
    addTearDown(bloc.close);
    final loaded = bloc.stream.firstWhere((s) => s.status != PostEditStatus.loading);
    bloc.add(const PostEditLoadDataRequested(_editUrl));
    expect((await loaded.timeout(const Duration(seconds: 3))).status, PostEditStatus.editing);
    final content = bloc.state.content!;
    final sent = bloc.stream.firstWhere((s) => s.status != PostEditStatus.uploading);
    bloc.add(
      PostEditCompleteEditRequested(
        formHash: content.formHash,
        postTime: content.postTime,
        delattachop: '0',
        page: content.page ?? '',
        wysiwyg: content.wysiwyg,
        fid: '2',
        tid: '9600010',
        pid: '9700012',
        threadType: null,
        threadTitle: '投票標題改過',
        data: '投票內文改過',
        options: const [],
        save: '',
        perm: null,
        price: null,
      ),
    );
    expect((await sent.timeout(const Duration(seconds: 3))).status, PostEditStatus.success);
    final body = posts.single;
    expect(body['subject'], '投票標題改過');
    expect(body['message'], '投票內文改過');
    for (final MapEntry(:key, :value) in _servedPoll.entries) {
      expect(body[key], value, reason: key);
    }
  });
}
