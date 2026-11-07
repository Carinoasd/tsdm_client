/// The first post of a reward thread edited in the app.
///
/// The edit form of the first post of a reward thread (plugin 2.9.0, `post_v16`) tells in its `reward` block what the
/// member may do with the price: `open` (the author, no best answer yet: `rewardprice` is a text field with the
/// thread's price), `resolved` (the author, the best answer chosen: a hidden `rewardprice` of the negative price) and
/// `readonly` (someone else, a moderator: no field). The forum (`extend_thread_reward::before_editpost`) checks a
/// changed price only: never lower than the thread's, within the group's range, and the raise with its tax
/// (`ceil(Δ + Δ * $creditstax)`) paid from what the author has. A kept price, a resolved one and a moderator's edit
/// post the form as served.
///
/// The fixtures `post_v16_edit_reward_{open,resolved,readonly}.json` are the plugin's 3.4.0 answers on the test forum,
/// scrubbed as the other `post_v16_*` fixtures; `result_reward_fall.json` is the forum's answer to a lowered price.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/post/bloc/post_edit_bloc.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/models/special_thread_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> _edit(String state) => _json('post_v16_edit_reward_$state');

PostForm _form(String state) => PostForm.fromJson(_edit(state))!;

Response<dynamic> _response(Object? data) =>
    Response<dynamic>(requestOptions: RequestOptions(), data: data, statusCode: 200);

const _editUrl = 'https://www.tsdm39.com/forum.php?mod=post&action=edit&fid=7&tid=9600030&pid=9700030';

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
  _Harness({required this.form, required this.answer});

  final Map<String, dynamic> form;
  final Object? answer;
  final posts = <(String, Map<String, String>)>[];

  late final repo = PostEditRepository.withTransport(
    currentUid: () => 31,
    getPage: (url) async => right(_response(form)),
    sendForm: (url, body) async {
      posts.add((url, body));
      return right(_response(answer));
    },
  );
}

Future<PostEditBloc> _load(_Harness harness) async {
  final bloc = PostEditBloc(postEditRepository: harness.repo);
  addTearDown(bloc.close);
  final settled = bloc.stream.firstWhere((s) => s.status != PostEditStatus.loading);
  bloc.add(const PostEditLoadDataRequested(_editUrl));
  await settled.timeout(const Duration(seconds: 3));
  return bloc;
}

Future<PostEditState> _submit(PostEditBloc bloc, {int? rewardPrice}) async {
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
      tid: '9600030',
      pid: '9700030',
      threadType: null,
      threadTitle: content.threadTitle,
      data: '懸賞內文，改過',
      options: const [],
      save: '',
      perm: null,
      price: null,
      rewardPrice: rewardPrice,
    ),
  );
  return settled.timeout(const Duration(seconds: 3));
}

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });
  setUp(TsdmAppApi.reset);

  group('the reward block of an edit', () {
    test('open: the author may raise the price of the thread', () {
      final form = _form('open');
      final reward = form.reward!;
      expect(form.action, 'edit');
      expect(form.first, isTrue);
      expect(reward.state, RewardFormState.open);
      expect(reward.editable, isTrue);
      expect(reward.raising, isTrue);
      expect(reward.current, 3);
      expect(reward.served, 3);
      expect(reward.have, 835);
      expect(reward.floor, 3);
      expect(form.editorSupport('edit'), PostFormSupport.supported);
    });

    test('resolved and readonly: the price is kept, the post edited', () {
      final resolved = _form('resolved').reward!;
      expect(resolved.state, RewardFormState.resolved);
      expect(resolved.editable, isFalse);
      expect(resolved.current, -1);
      expect(resolved.have, isNull);
      expect(_form('resolved').editorSupport('edit'), PostFormSupport.supported);

      final readonly = _form('readonly').reward!;
      expect(readonly.state, RewardFormState.readonly);
      expect(readonly.editable, isFalse);
      expect(readonly.current, 3);
      expect(readonly.served, isNull);
      expect(_form('readonly').editorSupport('edit'), PostFormSupport.supported);
    });

    test('a first post of a reward thread without the block is left to the website', () {
      expect(PostForm.fromJson({..._edit('open'), 'reward': null})!.editorSupport('edit'), PostFormSupport.unsupported);
      final none = PostForm.fromJson({
        ..._edit('open'),
        'reward': {...(_edit('open')['reward'] as Map<String, dynamic>), 'state': 'none'},
      })!;
      expect(none.reward, isNull);
      expect(none.editorSupport('edit'), PostFormSupport.unsupported);
      // An open block whose price field is gone, or not a text field: the price cannot be posted as the website does.
      final hidden = PostForm.fromJson({
        ..._edit('open'),
        'reward': {
          ...(_edit('open')['reward'] as Map<String, dynamic>),
          'inputs': [
            {'name': 'rewardprice', 'type': 'hidden', 'value': '3'},
          ],
        },
      })!;
      expect(hidden.editorSupport('edit'), PostFormSupport.unsupported);
    });

    test('the price is checked as before_editpost checks it', () {
      final reward = _form('open').reward!;
      // Kept: neither checked nor charged.
      expect(reward.check(3), isNull);
      expect(reward.check(2), RewardPriceIssue.fall);
      expect(reward.check(0), RewardPriceIssue.empty);
      expect(reward.check(null), RewardPriceIssue.empty);
      expect(reward.check(40000), RewardPriceIssue.overflow);
      // The raise with its tax: `ceil(Δ + Δ * 0.2)`; 3 → 699 is 696 + 140 = 836 > 835.
      expect(reward.cost(4), 2);
      expect(reward.cost(5), 3);
      expect(reward.check(698), isNull, reason: '695 + 139 = 834');
      expect(reward.check(699), RewardPriceIssue.shortage);
      final limited = RewardFormInfo.fromJson({
        ..._edit('open')['reward'] as Map<String, dynamic>,
        'min': 10,
        'max': 500,
      })!;
      // The thread's price below a minimum raised since: kept is fine, a raise must reach the minimum.
      expect(limited.check(3), isNull);
      expect(limited.floor, 10);
      expect(limited.check(9), RewardPriceIssue.belowMin);
      expect(limited.check(501), RewardPriceIssue.aboveMax);
      expect(limited.check(10), isNull);
    });
  });

  group('the body of an edit', () {
    test('open: the served price, or the raised one', () {
      final form = _form('open');
      expect(form.body().toMap()!['rewardprice'], '3');
      final raised = form.bodyWith(const PostFormEdits(message: 'm', rewardPrice: 5)).toMap()!;
      expect(raised['rewardprice'], '5');
      expect(raised['special'], '3');
      expect(raised['editsubmit'], 'true');
    });

    test('resolved: the hidden negative price goes back as served, whatever is asked', () {
      final body = _form('resolved').bodyWith(const PostFormEdits(message: 'm', rewardPrice: 9)).toMap()!;
      expect(body['rewardprice'], '-1');
    });

    test('readonly: no price is posted', () {
      final body = _form('readonly').bodyWith(const PostFormEdits(message: 'm', rewardPrice: 9)).toMap()!;
      expect(body.containsKey('rewardprice'), isFalse);
    });
  });

  group('the editor', () {
    test('posts the raised price and goes to the thread', () async {
      final harness = _Harness(form: _edit('open'), answer: _edited(9600030, 9700030));
      final bloc = await _load(harness);
      expect(bloc.state.status, PostEditStatus.editing);
      final state = await _submit(bloc, rewardPrice: 5);
      expect(state.status, PostEditStatus.success);
      expect(harness.posts.single.$2['rewardprice'], '5');
      expect(harness.posts.single.$2['message'], '懸賞內文，改過');
    });

    test('keeps the price when none is asked', () async {
      final harness = _Harness(form: _edit('open'), answer: _edited(9600030, 9700030));
      final state = await _submit(await _load(harness));
      expect(state.status, PostEditStatus.success);
      expect(harness.posts.single.$2['rewardprice'], '3');
    });

    test("shows the forum's refusal of a lowered price", () async {
      final harness = _Harness(form: _edit('open'), answer: _json('result_reward_fall'));
      final state = await _submit(await _load(harness), rewardPrice: 2);
      expect(state.status, PostEditStatus.failedToUpload);
      expect(state.errorText, '抱歉，悬赏积分不能减少');
      expect(state.maybeSent, isFalse);
    });

    test('edits a resolved reward thread with its price as served', () async {
      final harness = _Harness(form: _edit('resolved'), answer: _edited(9600030, 9700030));
      final bloc = await _load(harness);
      expect(bloc.state.status, PostEditStatus.editing);
      final state = await _submit(bloc, rewardPrice: 7);
      expect(state.status, PostEditStatus.success);
      expect(harness.posts.single.$2['rewardprice'], '-1');
    });
  });
}
