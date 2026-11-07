/// New reward threads and red packet threads from the editor.
///
/// A reward thread is the forum's `special=3` form: the app API (plugin 2.9.0, `post_v16`) gives its settings in the
/// `reward` block (the group's price range, the credit, what the member has, the tax); the editor asks the price and
/// posts `rewardprice` with the form ([PostForm.bodyWith]). A red packet thread is the site's `hongbao` thread
/// plugin's form (`specialextra=hongbao`, stored as `special` 127): the API gives no thread plugin's fields
/// (`unsupported: threadplugin`), so the repository reads the plugin's box from the web page of the form
/// ([HongbaoFormInfo.parse]) and the editor posts its `hb_*` fields. The forum takes such a thread and may then show
/// the plugin's notice instead of going to it (the packet was not made): published, told
/// ([ThreadPostedWithNoticeException], [PostEditState.notice]).
///
/// The fixtures `post_v16_newthread_reward.json` and `post_v16_newthread_hongbao.json` are the plugin's 3.4.0 answers
/// on the test forum, scrubbed as the other `post_v16_*` fixtures; `post_hongbao_box.html` is the plugin's box of the
/// same page; `result_hongbao_notice.json` and `result_reward_refused.json` are the forum's answers to the posts.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/post/bloc/post_edit_bloc.dart';
import 'package:tsdm_client/features/post/models/models.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/models/special_thread_form.dart';
import 'package:tsdm_client/features/post/repository/post_edit_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:universal_html/parsing.dart';

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _json(String name) =>
    jsonDecode(File('$_dir/$name.json').readAsStringSync()) as Map<String, dynamic>;

/// The form fixture [name] as a forum without a forms plugin serves it: no `hook_fields`.
Map<String, dynamic> _form(String name) => {..._json('post_v16_newthread_$name'), 'hook_fields': <Object?>[]};

final String _boxPage = File('$_dir/post_hongbao_box.html').readAsStringSync();

/// The web page of the red packet form with the plugin's [notice] instead of the form.
String _noticePage(String notice) =>
    "<html><head><script>var discuz_uid = '31';</script></head><body>"
    ' <form method="post" id="postform" action="forum.php?mod=post&amp;action=newthread&amp;fid=7&amp;topicsubmit=yes">'
    ' <div class="specialpost s_clear"><div class="hb-postbox">$notice</div></div></form></body></html>';

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

final class _Harness {
  _Harness({required this.page, this.post});

  final Object? Function(String url) page;
  final Object? Function(String url, Map<String, String> body)? post;
  final gets = <String>[];
  final posts = <(String, Map<String, String>)>[];

  late final repo = PostEditRepository.withTransport(
    currentUid: () => 31,
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

/// A forum serving the red packet form: the API answer on the JSON request, the web page with the plugin's box
/// (or [notice]) otherwise.
_Harness _hongbaoForum({String? notice, Object? Function(String url, Map<String, String> body)? post}) => _Harness(
  page: (url) => url.contains('tsdmapp=json') ? _form('hongbao') : (notice == null ? _boxPage : _noticePage(notice)),
  post: post,
);

Future<PostEditBloc> _load(_Harness harness, PostEditEvent event) async {
  final bloc = PostEditBloc(postEditRepository: harness.repo);
  addTearDown(bloc.close);
  final settled = bloc.stream.firstWhere((s) => s.status != PostEditStatus.loading);
  bloc.add(event);
  await settled.timeout(const Duration(seconds: 3));
  return bloc;
}

Future<PostEditState> _post(PostEditBloc bloc, ThreadPubPostThread event) async {
  final settled = bloc.stream.firstWhere((s) => s.status != PostEditStatus.uploading);
  bloc.add(event);
  return settled.timeout(const Duration(seconds: 3));
}

ThreadPublishInfo _info(PostEditContent content, {String subject = '標題'}) => ThreadPublishInfo(
  formHash: content.formHash,
  postTime: content.postTime,
  delAttachOp: '0',
  wysiwyg: content.wysiwyg,
  fid: '7',
  threadType: null,
  checkbox: '0',
  subject: subject,
  message: '內文內文內文',
  price: null,
  perm: null,
  save: '',
  options: const [],
);

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });
  setUp(TsdmAppApi.reset);

  group('reward form', () {
    final form = PostForm.fromJson(_form('reward'))!;

    test('the settings of the reward block', () {
      final reward = form.reward!;
      expect(form.special, 3);
      expect(form.specialExtra, '');
      expect(reward.min, 1);
      expect(reward.max, 0);
      expect(reward.creditTitle, '天使币');
      expect(reward.creditLabel, '天使币');
      expect(reward.have, 834);
      expect(reward.tax, 0.2);
      expect(reward.expirationDays, 30);
      expect(reward.served, 1);
      expect(reward.inputName, 'rewardprice');
      expect(form.specialAllowed, [0, 1, 3]);
      expect(form.threadPlugins, [('hongbao', '紅包')]);
      expect(form.isHongbao, isFalse);
      expect(form.hongbao, isNull);
    });

    test('the price is checked as the forum checks it', () {
      final reward = form.reward!;
      // `$rewardprice + ceil($rewardprice * $creditstax)`.
      expect(reward.realPrice(5), 6);
      expect(reward.realPrice(10), 12);
      expect(reward.check(null), RewardPriceIssue.empty);
      expect(reward.check(0), RewardPriceIssue.empty);
      expect(reward.check(40000), RewardPriceIssue.overflow);
      expect(reward.check(834), RewardPriceIssue.shortage, reason: '834 + 167 > 834');
      expect(reward.check(695), isNull, reason: '695 + 139 = 834');
      expect(reward.check(696), RewardPriceIssue.shortage, reason: '696 + 140 > 834');
      final limited = RewardFormInfo.fromJson({
        ..._form('reward')['reward'] as Map<String, dynamic>,
        'min': 10,
        'max': 500,
      })!;
      expect(limited.check(9), RewardPriceIssue.belowMin);
      expect(limited.check(501), RewardPriceIssue.aboveMax);
      expect(limited.check(500), isNull);
    });

    test('the editor takes the form and posts the price with it', () {
      expect(form.editorSupport('newthread'), PostFormSupport.supported);
      final served = form.body().toMap()!;
      expect(served['special'], '3');
      expect(served['rewardprice'], '1');
      final edited = form.bodyWith(const PostFormEdits(message: 'm', rewardPrice: 7)).toMap()!;
      expect(edited['special'], '3');
      expect(edited['rewardprice'], '7');
      expect(edited.containsKey('specialextra'), isFalse);
    });

    test('a reward form without the reward block is left to the website', () {
      final without = PostForm.fromJson({..._form('reward'), 'reward': null})!;
      expect(without.reward, isNull);
      expect(without.editorSupport('newthread'), PostFormSupport.unsupported);
      final resolved = PostForm.fromJson({
        ..._form('reward'),
        'reward': {...(_form('reward')['reward'] as Map<String, dynamic>), 'state': 'none'},
      })!;
      expect(resolved.reward, isNull);
    });

    test('the ordinary form offers the kinds without being one', () {
      final ordinary = PostForm.fromJson({..._json('post_v16_newthread'), 'hook_fields': <Object?>[]})!;
      expect(ordinary.reward, isNull);
      expect(ordinary.specialAllowed, [0, 1]);
      expect(ordinary.threadPlugins, [('hongbao', '紅包')]);
      // The price is only posted on a reward form.
      expect(ordinary.bodyWith(const PostFormEdits(message: 'm', rewardPrice: 7)).toMap()!['rewardprice'], isNull);
    });
  });

  group('red packet form', () {
    test('the box of the web page', () {
      final info = HongbaoFormInfo.parse(parseHtmlDocument(_boxPage))!;
      // The plugin prints the balance from `$_G['member']`, which lacks the credit on the test forum: 0 printed.
      expect(info.balance, 0);
      expect(info.creditLabel, '威望');
      expect(info.maxShares, 100);
      expect(info.minShare, 1);
      expect(info.expireChoices.map((e) => e.$1), ['1', '6', '12', '24', '72', '168']);
      expect(info.expireChoices[3].$2, '1 天');
      expect(info.expireDefault, '24');
      expect(info.blessingMax, 50);
      expect(info.blessingDefault, '恭喜發財,大吉大利');
      expect(info.passwordMax, 64);
      expect(HongbaoFormInfo.noticeOf(parseHtmlDocument(_boxPage)), isNull);
      final again = HongbaoFormInfo.fromJson(jsonDecode(jsonEncode(info.toJson())))!;
      expect(again.toJson(), info.toJson());
      expect(info.initial.shares, 1);
      expect(info.initial.expire, '24');
      expect(info.initial.blessing, '恭喜發財,大吉大利');
    });

    test('the notice instead of the form, and a page without the box', () {
      final notice = parseHtmlDocument(_noticePage('您所在的用戶組未開放發紅包。'));
      expect(HongbaoFormInfo.parse(notice), isNull);
      expect(HongbaoFormInfo.noticeOf(notice), '您所在的用戶組未開放發紅包。');
      final plain = parseHtmlDocument('<html><body><form id="postform"></form></body></html>');
      expect(HongbaoFormInfo.parse(plain), isNull);
      expect(HongbaoFormInfo.noticeOf(plain), isNull);
    });

    test('the packet is checked as the plugin checks it', () {
      final printed = HongbaoFormInfo.parse(parseHtmlDocument(_boxPage))!;
      // A printed 0 proves nothing (the box may lack the credit): no shortage, whatever the amount.
      expect(const HongbaoEdits(total: 835, shares: 2).check(printed), isNull);
      final info = HongbaoFormInfo.fromJson({...printed.toJson(), 'balance': 834})!;
      HongbaoIssue? check(HongbaoEdits e) => e.check(info);
      expect(check(const HongbaoEdits(total: null, shares: 1)), HongbaoIssue.totalRequired);
      expect(check(const HongbaoEdits(total: 0, shares: 1)), HongbaoIssue.totalRequired);
      expect(check(const HongbaoEdits(total: 5, shares: null)), HongbaoIssue.sharesRequired);
      expect(check(const HongbaoEdits(total: 500, shares: 101)), HongbaoIssue.sharesAboveMax);
      expect(check(const HongbaoEdits(total: 2, shares: 3)), HongbaoIssue.totalBelowShares);
      expect(check(const HongbaoEdits(total: 3, shares: 2, split: HongbaoSplit.even)), HongbaoIssue.notDivisible);
      expect(check(const HongbaoEdits(total: 4, shares: 2, split: HongbaoSplit.even)), isNull);
      expect(check(const HongbaoEdits(total: 835, shares: 2)), HongbaoIssue.shortage);
      expect(check(HongbaoEdits(total: 5, shares: 2, blessing: '福' * 51)), HongbaoIssue.blessingTooLong);
      expect(check(HongbaoEdits(total: 5, shares: 2, password: 'p' * 65)), HongbaoIssue.passwordTooLong);
      expect(check(const HongbaoEdits(total: 5, shares: 2)), isNull);
    });

    test('the fields the packet posts', () {
      expect(const HongbaoEdits(total: 5, shares: 2, expire: '24', blessing: '福').toFields(), {
        'hb_total': '5',
        'hb_shares': '2',
        'hb_split': '1',
        'hb_password': '',
        'hb_appoint': '',
        'hb_expire': '24',
        'hb_blessing': '福',
      });
      expect(
        const HongbaoEdits(
          total: 6,
          shares: 3,
          split: HongbaoSplit.even,
          condReply: true,
          password: 'pw',
          appoint: 'a, b',
          expire: '72',
          blessing: 'b',
        ).toFields(),
        {
          'hb_total': '6',
          'hb_shares': '3',
          'hb_split': '2',
          'hb_cond': '1',
          'hb_password': 'pw',
          'hb_appoint': 'a, b',
          'hb_expire': '72',
          'hb_blessing': 'b',
        },
      );
    });

    test('the editor takes the form only with the box read, and posts the packet with it', () {
      final form = PostForm.fromJson(_form('hongbao'))!;
      expect(form.special, 127);
      expect(form.specialExtra, 'hongbao');
      expect(form.isHongbao, isTrue);
      expect(form.unsupported, ['threadplugin']);
      expect(form.hongbao, isNull);
      // The API alone: the plugin's fields are unknown.
      expect(form.editorSupport('newthread'), PostFormSupport.unsupported);
      final read = form.withHongbao(HongbaoFormInfo.parse(parseHtmlDocument(_boxPage))!);
      expect(read.hongbao, isNotNull);
      expect(read.editorSupport('newthread'), PostFormSupport.supported);
      // Rebuilt from its answer (the content keeps the json), the box is still there.
      expect(PostForm.fromJson(read.json)!.hongbao!.maxShares, 100);
      final served = read.body().toMap()!;
      expect(served['special'], '127');
      expect(served['specialextra'], 'hongbao');
      expect(served.keys.where((k) => k.startsWith('hb_')), isEmpty);
      final edited = read
          .bodyWith(
            const PostFormEdits(
              message: 'm',
              hongbao: HongbaoEdits(total: 5, shares: 2, condReply: true, expire: '24', blessing: '福'),
            ),
          )
          .toMap()!;
      expect(edited['special'], '127');
      expect(edited['specialextra'], 'hongbao');
      expect(edited['hb_total'], '5');
      expect(edited['hb_shares'], '2');
      expect(edited['hb_split'], '1');
      expect(edited['hb_cond'], '1');
      expect(edited['hb_expire'], '24');
      expect(edited['hb_blessing'], '福');
      // Without the box the packet is not posted.
      expect(
        form
            .bodyWith(const PostFormEdits(message: 'm', hongbao: HongbaoEdits(total: 5, shares: 2)))
            .toMap()!['hb_total'],
        isNull,
      );
    });
  });

  group('repository', () {
    test('the form of each kind is asked with its query', () async {
      final harness = _Harness(page: (_) => _form('reward'));
      await harness.repo.prepareForm('7', kind: ThreadKind.reward).run();
      expect(harness.gets.single, contains('action=newthread&fid=7&special=3'));
      harness.gets.clear();
      await harness.repo.prepareForm('7').run();
      expect(harness.gets.single, isNot(contains('special')));
      expect(
        PostEditRepository.newThreadPageUrl('7', kind: ThreadKind.hongbao),
        endsWith('fid=7&specialextra=hongbao'),
      );
      expect(ThreadKind.fromQuery('reward'), ThreadKind.reward);
      expect(ThreadKind.fromQuery('hongbao'), ThreadKind.hongbao);
      expect(ThreadKind.fromQuery(null), ThreadKind.normal);
      expect(ThreadKind.fromQuery('other'), ThreadKind.normal);
      expect(ThreadKind.reward.query, 'reward');
      expect(ThreadKind.normal.query, isNull);
    });

    test('the red packet form reads the box from the web page', () async {
      final harness = _hongbaoForum();
      final answer = await harness.repo.prepareForm('7', kind: ThreadKind.hongbao).run();
      expect(harness.gets, hasLength(2));
      expect(harness.gets.first, contains('specialextra=hongbao'));
      expect(harness.gets.first, contains('tsdmapp=json'));
      expect(harness.gets.last, contains('specialextra=hongbao'));
      expect(harness.gets.last, isNot(contains('tsdmapp=json')));
      final form = (answer.unwrap() as PostEditFormApi).form;
      expect(form.hongbao?.creditLabel, '威望');
      expect(form.hongbao?.maxShares, 100);
      expect(form.editorSupport('newthread'), PostFormSupport.supported);
    });

    test('the plugin notice instead of the form is the forum refusing it', () async {
      final harness = _hongbaoForum(notice: '您所在的用戶組未開放發紅包。');
      final answer = await harness.repo.prepareForm('7', kind: ThreadKind.hongbao).run();
      expect((answer.unwrap() as PostEditFormRefused).message, '您所在的用戶組未開放發紅包。');
    });

    test('a web page without the box leaves the form to the website', () async {
      final harness = _Harness(
        page: (url) => url.contains('tsdmapp=json')
            ? _form('hongbao')
            : '<html><head><script>var discuz_uid = \'31\';</script></head><body><form id="postform"></form></body></html>',
      );
      final bloc = await _load(harness, const ThreadPubFetchInfoRequested(fid: '7', kind: ThreadKind.hongbao));
      expect(bloc.state.status, PostEditStatus.unsupported);
    });
  });

  group('editor', () {
    test('a reward thread is posted with its price', () async {
      final harness = _Harness(page: (_) => _form('reward'), post: (_, _) => _redirectTo(9202749));
      final bloc = await _load(harness, const ThreadPubFetchInfoRequested(fid: '7', kind: ThreadKind.reward));
      expect(bloc.state.status, PostEditStatus.editing);
      expect(bloc.state.content!.form!.reward, isNotNull);
      final state = await _post(bloc, ThreadPubPostThread(_info(bloc.state.content!), rewardPrice: 7));
      expect(state.status, PostEditStatus.success);
      expect(state.redirectTid, '9202749');
      expect(state.notice, isNull);
      final (url, body) = harness.posts.single;
      expect(url, contains('topicsubmit=yes'));
      expect(body['special'], '3');
      expect(body['rewardprice'], '7');
      expect(body['subject'], '標題');
    });

    test('the forum refusing the reward is a failed upload with its words', () async {
      final harness = _Harness(page: (_) => _form('reward'), post: (_, _) => _json('result_reward_refused'));
      final bloc = await _load(harness, const ThreadPubFetchInfoRequested(fid: '7', kind: ThreadKind.reward));
      final state = await _post(bloc, ThreadPubPostThread(_info(bloc.state.content!), rewardPrice: 0));
      expect(state.status, PostEditStatus.failedToUpload);
      expect(state.errorText, '抱歉，悬赏积分不能为空');
      expect(state.maybeSent, isFalse);
    });

    test('a red packet thread is posted with its packet', () async {
      final harness = _hongbaoForum(post: (_, _) => _redirectTo(9202750));
      final bloc = await _load(harness, const ThreadPubFetchInfoRequested(fid: '7', kind: ThreadKind.hongbao));
      expect(bloc.state.status, PostEditStatus.editing);
      final state = await _post(
        bloc,
        ThreadPubPostThread(
          _info(bloc.state.content!),
          hongbao: const HongbaoEdits(total: 2, shares: 1, expire: '24', blessing: '恭喜發財'),
        ),
      );
      expect(state.status, PostEditStatus.success);
      expect(state.redirectTid, '9202750');
      final (_, body) = harness.posts.single;
      expect(body['special'], '127');
      expect(body['specialextra'], 'hongbao');
      expect(body['hb_total'], '2');
      expect(body['hb_shares'], '1');
      expect(body['hb_split'], '1');
      expect(body['hb_expire'], '24');
      expect(body['hb_blessing'], '恭喜發財');
      expect(body.containsKey('hb_cond'), isFalse);
    });

    test('the thread taken and the packet refused is published with the notice', () async {
      final harness = _hongbaoForum(post: (_, _) => _json('result_hongbao_notice'));
      final bloc = await _load(harness, const ThreadPubFetchInfoRequested(fid: '7', kind: ThreadKind.hongbao));
      final state = await _post(
        bloc,
        ThreadPubPostThread(
          _info(bloc.state.content!),
          hongbao: const HongbaoEdits(total: 3, shares: 2, split: HongbaoSplit.even, expire: '24'),
        ),
      );
      expect(state.status, PostEditStatus.success);
      expect(state.redirectTid, isNull);
      expect(state.notice, '均分模式：總金額須能被份數整除');
      expect(state.maybeSent, isFalse);
    });

    test('the same answer to an ordinary thread is still a refusal', () async {
      // Only a red packet thread reads the plugin's notice as "taken": any other form has no plugin after the post.
      final harness = _Harness(
        page: (_) => {..._json('post_v16_newthread'), 'hook_fields': <Object?>[]},
        post: (_, _) => _json('result_hongbao_notice'),
      );
      final bloc = await _load(harness, const ThreadPubFetchInfoRequested(fid: '7'));
      final state = await _post(bloc, ThreadPubPostThread(_info(bloc.state.content!)));
      expect(state.status, PostEditStatus.failedToUpload);
      expect(state.notice, isNull);
    });

    test('a red packet thread posted without a packet goes without the fields', () async {
      final harness = _hongbaoForum(post: (_, _) => _redirectTo(9202752));
      final bloc = await _load(harness, const ThreadPubFetchInfoRequested(fid: '7', kind: ThreadKind.hongbao));
      final state = await _post(bloc, ThreadPubPostThread(_info(bloc.state.content!)));
      expect(state.status, PostEditStatus.success);
      expect(harness.posts.single.$2.keys.where((k) => k.startsWith('hb_')), isEmpty);
    });
  });

  test('the forum base url of the browser page', () {
    expect(PostEditRepository.newThreadPageUrl('7'), '$baseUrl/forum.php?mod=post&action=newthread&fid=7');
  });
}
