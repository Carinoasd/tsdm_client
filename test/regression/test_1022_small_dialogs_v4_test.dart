/// The small dialogs read from the forum's app API (plugin 4.0.0, small forms with `tsdmv=4`): adding a friend and
/// approving a request (`friendadd`, `mode` add or approve), a favorite with a note (`favorite`), a greeting
/// (`poke`) and putting a thread in a collection (`collection`).
///
/// * Asked as small forms (`tsdmapp=json&tsdmv=4&tsdmform=1&nodoc=1`, the window's `inajax` kept) only once `status`
///   listed the form in `forms`; otherwise, and for any answer that is not that form (an approval asked as an add, a
///   form for another member), the window is read as before.
/// * The same window read either way gives the same choices.
/// * The form goes back with its own fields as served (`submit.fields`, `submit.lists`), once, with the result
///   parameters (`tsdmapp=json&tsdmv=4`); it is done only for its success key (`request_has_been_sent`,
///   `friends_add`, `favorite_do_success`, `poke_success`, `collection_collect_succ`), never on `ok` alone.
/// * The favorite window is never asked with a `formhash` (the forum would add the favorite on that GET).
/// * The forum's refusal is shown as it is; the login prompt and another account's answer are refused.
///
/// Fixtures: the windows and answers of the test forum (cleaned); the favorite form (favorites are switched off on the
/// test forum) and the write results synthetic, shaped as the spec of 4.0.0 (3.6–3.9) gives them.
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/collection/repository/collection_repository.dart';
import 'package:tsdm_client/features/collection/utils/collection_answer.dart';
import 'package:tsdm_client/features/collection/utils/parse_collection.dart';
import 'package:tsdm_client/features/favorite/models/models.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/favorite/utils/parse_favorite.dart';
import 'package:tsdm_client/features/friend/models/add_friend.dart';
import 'package:tsdm_client/features/friend/models/approve_friend.dart';
import 'package:tsdm_client/features/friend/repository/approve_friend_repository.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/features/friend/utils/parse_add_friend.dart';
import 'package:tsdm_client/features/friend/utils/parse_approve_friend.dart';
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/space/repository/space_social_repository.dart';
import 'package:tsdm_client/features/space/repository/space_write_repository.dart';
import 'package:tsdm_client/features/space/utils/parse_space.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/parsing.dart';

import 'tsdmapp_v4_fake.dart';

const _uid = 31;
const _admin = 32;
const _tid = 9202952;

/// A write result (`schema` 13) of account [uid].
Map<String, dynamic> _result({
  String kind = 'handle',
  int ok = 1,
  String messageKey = '',
  String message = '',
  Map<String, String> values = const {},
  int uid = _uid,
  String alert = '',
}) => {
  'ok': ok,
  'api': 1,
  'time': 1700000000,
  'uid': uid,
  'formhash': 'f1f2f3f4',
  'type': 'result',
  'schema': 13,
  'kind': kind,
  'message': message,
  'message_key': messageKey,
  'url': '',
  'handlekey': '',
  'values': values,
  'login': 0,
  'alert': alert,
};

/// The forum's message instead of a small form [form].
Map<String, dynamic> _message(String form, String key, String message, {int uid = _uid, int login = 0}) => {
  'ok': 0,
  'error': 'message',
  'message': message,
  'message_key': key,
  'login': login,
  'uid': uid,
  'form': form,
};

bool _form(Uri u) => u.queryParameters['tsdmform'] == '1' && u.queryParameters['tsdmv'] == '4';

bool _write(Uri u) => u.queryParameters['tsdmv'] == '4' && !u.queryParameters.containsKey('tsdmform');

Map<String, String> _body(String body) => Uri.splitQueryString(body);

/// The html of an AJAX window [xml].
String _payload(String xml) => RegExp(r'<!\[CDATA\[([\s\S]*)\]\]>').firstMatch(xml)!.group(1)!;

/// The single post of [forum]: its url and its fields.
(Uri, Map<String, String>) _post(V4Forum forum) {
  final i = forum.requests.indexWhere((r) => r.method == 'POST');
  expect(forum.requests.where((r) => r.method == 'POST'), hasLength(1), reason: 'sent once');
  return (forum.requests[i].uri, _body(forum.bodies[i]));
}

void main() {
  setUpAll(registerV4TestServices);
  tearDownAll(resetV4TestServices);
  setUp(TsdmAppApi.reset);

  group('adding a friend (friendadd, mode add)', () {
    test('the answer and the window give the same form', () {
      final api = addFriendFormFromApi(v4Json('g3_friendadd_add.json'), uid: '35', viewer: _uid)! as AddFriendForm;
      final web = parseAddFriendForm(v4Raw('g3_friendadd_add_web.xml')) as AddFriendForm;
      expect((api.formHash, api.targetName, api.selectedGid), (web.formHash, web.targetName, web.selectedGid));
      expect([for (final g in api.groups) (g.gid, g.name)], [for (final g in web.groups) (g.gid, g.name)]);
      expect(api.submitUrl, '$baseUrl/home.php?mod=spacecp&ac=friend&op=add&uid=35');
      expect(api.submitFields, containsPair('addsubmit', 'true'));
    });

    test('an approval window, a form of another member, another account: not this form', () {
      expect(addFriendFormFromApi(v4Json('g3_friendadd_approve.json'), uid: '35', viewer: _admin), isNull);
      expect(addFriendFormFromApi(v4Json('g3_friendadd_add.json'), uid: '36', viewer: _uid), isNull);
      expect(
        addFriendFormFromApi(v4Json('g3_friendadd_add.json'), uid: '35', viewer: 35),
        isA<AddFriendRefused>().having((e) => e.fromForum, 'fromForum', isFalse),
      );
      final self = addFriendFormFromApi(v4Json('g3_friendadd_self.json'), uid: '31', viewer: _uid);
      expect(self, isA<AddFriendRefused>().having((e) => (e.message, e.fromForum), 'message', ('抱歉，您不能加自己为好友', true)));
    });

    test('sent with the fields as served, once; done only for request_has_been_sent', () async {
      knowV4Status();
      var answer = _result(messageKey: 'request_has_been_sent', message: '好友请求已发送，请等待对方验证');
      final forum = V4Forum((o) => o.method == 'POST' ? V4Reply(answer) : V4Reply(v4Json('g3_friendadd_add.json')));
      useV4Forum(forum);
      final repo = FriendRepository(currentUid: () => _uid);
      final form = (await repo.fetchAddFriendForm('35').run()).getOrElse((e) => throw e) as AddFriendForm;
      expect(_form(forum.requests.single.uri), isTrue);
      expect(forum.requests.single.uri.queryParameters, containsPair('inajax', '1'));
      final sent = (await repo.addFriend(uid: '35', formHash: form.formHash, note: 'hi', gid: '3', form: form).run())
          .getOrElse((e) => throw e);
      expect((sent.success, sent.message, sent.fromForum), (true, '好友请求已发送，请等待对方验证', true));
      final (url, body) = _post(forum);
      expect(_write(url), isTrue);
      expect(url.queryParameters, containsPair('inajax', '1'));
      expect(body, {
        'referer': 'https://www.tsdm39.com/./',
        'addsubmit': 'true',
        'handlekey': 'addfriendhk_35',
        'formhash': 'f1f2f3f4',
        'note': 'hi',
        'gid': '3',
      });
      answer = _result(message: '完成');
      expect(addFriendResultFromApi(answer).success, isFalse, reason: 'ok without the key is not done');
      expect(
        addFriendResultFromApi(
          _result(ok: 0, messageKey: 'waiting_for_the_other_test', message: '正在等待验证', alert: 'error'),
        ).success,
        isFalse,
      );
    });

    test('not listed in forms: the window as before', () async {
      knowV4Status(
        v4Status({
          'forms': <String>['rate'],
        }),
      );
      final forum = V4Forum((o) => V4Reply(v4Raw('g3_friendadd_add_web.xml')));
      useV4Forum(forum);
      final form = (await const FriendRepository().fetchAddFriendForm('35').run()).getOrElse((e) => throw e);
      expect(form, isA<AddFriendForm>().having((e) => e.submitFields, 'fields', isNull));
      expect(forum.requests.where((r) => _form(r.uri)), isEmpty);
    });
  });

  group('approving a request (friendadd, mode approve)', () {
    test('the answer and the window give the same form', () {
      final api =
          approveFriendFormFromApi(v4Json('g3_friendadd_approve.json'), targetUid: 35, viewerUid: _admin)!
              as ApproveFriendForm;
      final web = parseApproveFriendForm(v4Raw('g3_friendadd_approve_web.xml'), targetUid: 35) as ApproveFriendForm;
      expect((api.targetName, api.selectedGid), (web.targetName, web.selectedGid));
      expect([for (final g in api.groups) (g.gid, g.name)], [for (final g in web.groups) (g.gid, g.name)]);
      expect(api.fields.toSet(), web.fields.toSet());
      expect(api.fromApi, isTrue);
    });

    test('an add window (no request pending): read as before; the guest and another account refused', () {
      expect(approveFriendFormFromApi(v4Json('g3_friendadd_add.json'), targetUid: 35, viewerUid: _uid), isNull);
      expect(
        () => approveFriendFormFromApi(v4Json('g3_friendadd_approve.json'), targetUid: 35, viewerUid: _uid),
        throwsA(isA<ApproveFriendRejected>().having((e) => e.failure, 'failure', ApproveFriendFailure.accountMismatch)),
      );
      expect(
        () => approveFriendFormFromApi(
          _message('friendadd', 'to_login', '', uid: 0, login: 1),
          targetUid: 35,
          viewerUid: _admin,
        ),
        throwsA(isA<ApproveFriendRejected>().having((e) => e.failure, 'failure', ApproveFriendFailure.notLoggedIn)),
      );
      expect(
        approveFriendFormFromApi(
          _message('friendadd', 'you_have_friends', '你们已成为好友', uid: _admin),
          targetUid: 35,
          viewerUid: _admin,
        ),
        isA<ApproveFriendRefused>(),
      );
    });

    test('approved once with the fields as served; done only for friends_add', () async {
      knowV4Status();
      final forum = V4Forum(
        (o) => o.method == 'POST'
            ? V4Reply(
                _result(
                  uid: _admin,
                  messageKey: 'friends_add',
                  message: '你和 ag_low2 成为好友了',
                  values: {'uid': '35', 'username': 'ag_low2'},
                ),
              )
            : V4Reply(v4Json('g3_friendadd_approve.json')),
      );
      const repo = ApproveFriendRepository();
      final client = v4Client(forum);
      final form =
          (await repo.fetchForm(client, targetUid: 35, viewerUid: _admin)).getOrElse((e) => fail('$e'))
              as ApproveFriendForm;
      final done = (await repo.approve(client, form: form, gid: '4')).getOrElse((e) => fail('$e'));
      expect(done.success, isTrue);
      final (url, body) = _post(forum);
      expect(_write(url), isTrue);
      expect(body, containsPair('add2submit', 'true'));
      expect(body, containsPair('gid', '4'));
      expect(approveFriendResultFromApi(_result(uid: _admin, message: '完成'), targetUid: 35).isLeft(), isTrue);
      expect(
        approveFriendResultFromApi(
          _result(uid: _admin, messageKey: 'friends_add', values: {'uid': '36'}),
          targetUid: 35,
        ).isLeft(),
        isTrue,
        reason: 'the approval of another member',
      );
    });
  });

  group('favorite (favorite)', () {
    Map<String, dynamic> window({String type = 'thread', Object id = _tid}) => {
      'ok': 1,
      'api': 1,
      'time': 1700000000,
      'uid': _uid,
      'formhash': 'f1f2f3f4',
      'type': 'form',
      'schema': 17,
      'form': 'favorite',
      'float': 1,
      'ajax': 1,
      'favtype': type,
      'id': id,
      'spaceuid': 0,
      'count': 3,
      'submit': {
        'url': 'home.php?mod=spacecp&ac=favorite&type=$type&id=$id&spaceuid=0',
        'method': 'POST',
        'enctype': 'application/x-www-form-urlencoded',
        'fields': {
          'favoritesubmit': 'true',
          'referer': 'https://www.tsdm39.com/./',
          'formhash': 'f1f2f3f4',
          'handlekey': 'k_favorite',
        },
      },
      'description': {'name': 'description', 'type': 'textarea', 'value': ''},
      'hook_fields': <Object>[],
      'unsupported': <Object>[],
    };

    test('added once with the fields as served and the note; the window without formhash', () async {
      knowV4Status();
      final forum = V4Forum(
        (o) => o.method == 'POST'
            ? V4Reply(_result(messageKey: 'favorite_do_success', message: '信息收藏成功', values: {'favid': '9'}))
            : V4Reply(window()),
      );
      useV4Forum(forum);
      final repo = FavoriteRepository(currentUid: () => _uid);
      addTearDown(repo.dispose);
      final added = (await repo.addFavorite(tid: '$_tid', description: 'note').run()).getOrElse((e) => throw e);
      expect(added, isA<FavoriteAdded>().having((e) => e.favid, 'favid', '9'));
      final dialog = forum.requests.first.uri.queryParameters;
      expect(_form(forum.requests.first.uri), isTrue);
      expect(dialog, isNot(contains('formhash')));
      final (url, body) = _post(forum);
      expect(_write(url), isTrue);
      expect(url.queryParameters, allOf(containsPair('spaceuid', '0'), containsPair('inajax', '1')));
      expect(body, containsPair('description', 'note'));
      expect(body, containsPair('favoritesubmit', 'true'));
    });

    test('the dialog refused: switched off, favorited already, another account', () {
      expect(
        favoriteFormFromApi(v4Json('g3_favorite_off.json'), type: FavoriteType.thread, id: '$_tid', viewer: _uid),
        isA<Left<FavoriteAddResult, Object?>>().having(
          (e) => e.value,
          'value',
          isA<FavoriteAddFailed>().having((e) => e.message, 'message', '抱歉，收藏功能尚未开启'),
        ),
      );
      expect(
        favoriteFormFromApi(
          _message('favorite', 'favorite_repeat', '抱歉，您已收藏，请勿重复收藏'),
          type: FavoriteType.thread,
          id: '$_tid',
          viewer: _uid,
        ).getLeft().toNullable(),
        isA<FavoriteAlreadyExists>(),
      );
      expect(
        favoriteFormFromApi(window(), type: FavoriteType.thread, id: '$_tid', viewer: 35).getLeft().toNullable(),
        isA<FavoriteAddFailed>(),
      );
      expect(
        favoriteFormFromApi(window(id: 1), type: FavoriteType.thread, id: '$_tid', viewer: _uid),
        const Right<FavoriteAddResult, Object?>(null),
        reason: 'a form of another target is read as before',
      );
      expect(favoriteAddResultFromApi(_result(message: '完成')), isA<FavoriteAddFailed>());
      expect(favoriteAddResultFromApi(_result(ok: 0, messageKey: 'favorite_repeat')), isA<FavoriteAlreadyExists>());
    });
  });

  group('greeting (poke)', () {
    SpaceSocialRepository repo(V4Forum forum, {int uid = _uid}) {
      final client = v4Client(forum);
      useV4Forum(forum);
      return SpaceSocialRepository.withTransport(
        currentUid: () => uid,
        getPage: (url) => client.get(url).run(),
        sendForm: (url, body) => client.postForm(url, data: body, singleAttempt: true).run(),
      );
    }

    test('the answer and the window give the same greetings', () {
      final api = pokeFormFromApi(v4Json('g3_poke_send.json'), viewer: _uid, targetUid: 35, reply: false)!.form!;
      final page = parseHtmlDocument(
        "<html><head><script>var discuz_uid = '31';</script></head><body>"
        '${_payload(v4Raw('g3_poke_send_web.xml'))}</body></html>',
      );
      final web = parsePokeForm(page, reply: false).form!;
      expect(
        (api.targetUid, api.targetName, api.formHash, api.selected),
        (
          web.targetUid,
          web.targetName,
          web.formHash,
          web.selected,
        ),
      );
      expect([for (final i in api.icons) (i.id, i.label)], [for (final i in web.icons) (i.id, i.label)]);
    });

    test('sent once with the fields as served; done only for poke_success', () async {
      knowV4Status();
      var answer = _result(messageKey: 'poke_success', message: '已打招呼');
      final forum = V4Forum((o) => o.method == 'POST' ? V4Reply(answer) : V4Reply(v4Json('g3_poke_send.json')));
      final r = repo(forum);
      final load = await r.loadPokeForm(35);
      expect(load.kind, SpaceFormLoadKind.ready);
      expect(_form(forum.requests.single.uri), isTrue);
      expect(forum.requests.single.uri.queryParameters, allOf(containsPair('inajax', '1'), containsPair('op', 'send')));
      final sent = await r.sendPoke(load.form!, '5', ' hi ');
      expect(sent.outcome, SpaceWriteOutcome.done);
      final (url, body) = _post(forum);
      expect(_write(url), isTrue);
      expect(body, {
        'referer': 'https://www.tsdm39.com/./',
        'pokesubmit': 'true',
        'formhash': 'f1f2f3f4',
        'from': '',
        'handlekey': 'propokehk_35',
        'iconid': '5',
        'note': 'hi',
      });
      answer = _result(ok: 0, messageKey: 'no_privilege_poke', message: '没有权限', alert: 'error');
      expect(
        pokeOutcomeFromApi(
          Right(Response(requestOptions: RequestOptions(), data: answer)),
          uid: _uid,
        )?.outcome,
        SpaceWriteOutcome.rejected,
      );
    });

    test('the forum refusing to oneself; the guest; another account', () {
      expect(
        pokeFormFromApi(v4Json('g3_poke_self.json'), viewer: _uid, targetUid: _uid, reply: false),
        isA<SpaceFormLoad<PokeForm>>()
            .having((e) => e.kind, 'kind', SpaceFormLoadKind.denied)
            .having((e) => e.message, 'message', '不能向自己打招呼'),
      );
      expect(
        pokeFormFromApi(
          _message('poke', 'to_login', '', uid: 0, login: 1),
          viewer: _uid,
          targetUid: 35,
          reply: false,
        )?.kind,
        SpaceFormLoadKind.loginRequired,
      );
      expect(
        pokeFormFromApi(v4Json('g3_poke_send.json'), viewer: 35, targetUid: 35, reply: false)?.kind,
        SpaceFormLoadKind.identityChanged,
      );
      expect(
        pokeFormFromApi(v4Json('g3_poke_send.json'), viewer: _uid, targetUid: 35, reply: true),
        isNull,
        reason: 'a greeting window, not one back',
      );
    });
  });

  group('collection (collection)', () {
    CollectionRepository repo(V4Forum forum) {
      final client = v4Client(forum);
      useV4Forum(forum);
      return CollectionRepository(
        get: (url, {write = false}) async => switch (await client.get(url).run()) {
          Left(:final value) => left(value),
          Right(:final value) => right(value.data),
        },
        post: (url, body) async => switch (await client.postForm(url, data: body, singleAttempt: true).run()) {
          Left(:final value) => left(value),
          Right(:final value) => right(value.data),
        },
        currentUid: () => _uid,
      );
    }

    test('the answer and the window give the same choices', () {
      final api = collectThreadFormFromApi(
        v4Json('g3_collection_addthread.json'),
        tid: _tid,
        viewerUid: _uid,
      )!.getOrElse((e) => fail('$e'));
      final web = parseCollectThreadForm(
        collectionDialogHtml(v4Raw('g3_collection_addthread_web.xml')),
        tid: _tid,
        viewerUid: _uid,
      )!;
      expect(api.choices, web.choices);
      expect((api.remainingCreate, api.formHash), (web.remainingCreate, web.formHash));
    });

    test('put in once with the fields and lists as served; done only for collection_collect_succ', () async {
      knowV4Status();
      var answer = _result(messageKey: 'collection_collect_succ', message: '淘帖成功');
      final forum = V4Forum(
        (o) => o.method == 'POST' ? V4Reply(answer) : V4Reply(v4Json('g3_collection_addthread.json')),
      );
      final r = repo(forum);
      final form = (await r.fetchCollectForm(_tid)).getOrElse((e) => fail('$e'));
      expect(_form(forum.requests.single.uri), isTrue);
      expect(await r.collect(form, [1], 'why'), isA<CollectionDone>());
      final (url, body) = _post(forum);
      expect(_write(url), isTrue);
      expect(body, {
        'inajax': '1',
        'handlekey': 'k_collect',
        'formhash': 'f1f2f3f4',
        'addthread': '1',
        'tids[0]': '$_tid',
        'reason': 'why',
        'ctid[0]': '1',
      });
      answer = _result(message: '完成');
      expect(collectOutcomeFromApi(answer), isA<CollectionUnknown>());
      expect(
        collectOutcomeFromApi(
          _result(ok: 0, messageKey: 'collection_thread_exists', message: '该主题已经在淘专辑中', alert: 'error'),
        ),
        isA<CollectionRefused>(),
      );
    });

    test('the guest, another account, a form of another thread', () {
      expect(
        collectThreadFormFromApi(
          v4Json('g3_collection_guest.json'),
          tid: _tid,
          viewerUid: _uid,
        )?.getLeft().toNullable(),
        isA<CollectionNeedLogin>(),
      );
      expect(
        collectThreadFormFromApi(
          v4Json('g3_collection_addthread.json'),
          tid: _tid,
          viewerUid: 35,
        )?.getLeft().toNullable(),
        isA<CollectionAccountChanged>(),
      );
      expect(collectThreadFormFromApi(v4Json('g3_collection_addthread.json'), tid: 1, viewerUid: _uid), isNull);
    });

    test('not listed in forms: the window as before', () async {
      knowV4Status(
        v4Status({
          'forms': <String>['rate'],
        }),
      );
      final forum = V4Forum((o) => V4Reply(v4Raw('g3_collection_addthread_web.xml')));
      final form = (await repo(forum).fetchCollectForm(_tid)).getOrElse((e) => fail('$e'));
      expect(form.submitFields, isNull);
      expect(forum.requests.where((r) => _form(r.uri)), isEmpty);
    });
  });

  test('a failed request of the account changing is never read as another account', () async {
    knowV4Status();
    useV4Forum(V4Forum((o) => null));
    final result = await const FriendRepository().fetchAddFriendForm('35').run();
    expect(result.getLeft().toNullable(), isA<AppException>());
  });
}
