/// The small forms asked of the forum's app API (plugin 3.0.0, `type: form`, `schema: 17`): the rate, report and buy
/// windows, the user group list and its switch window, the profile editor.
///
/// Each form is asked with `tsdmform=1` beside `tsdmapp=json` (the whole pages with `nodoc=1` too). A schema 17 answer
/// is read from its fields and posted as served (`submit.fields` and the controls, with the member's values over
/// them, to `submit.url`; a window with `inajax=1`), as the plugin's `tools/form300.py` rebuilds the browser's post
/// from the JSON. The forum's message instead of a form is shown as the forum wrote it, an answer served to another
/// account or to a guest is never used, and the answer of an older plugin (the write result of a window, the web page
/// of a whole page) is read as before from the one request; a form the plugin could not tell (`unknown`), or with
/// other plugins' fields, is asked again the old way. Only the groups the member can switch to are listed.
///
/// The structured answers are the plugin's `form_v17_*` fixtures (`tools/fixtures.py --group form`); the older
/// answers are the samples the readers' own tests use.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' hide Visibility;
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/post_report/models/post_report.dart';
import 'package:tsdm_client/features/post_report/repository/post_report_repository.dart';
import 'package:tsdm_client/features/profile/models/available_user_group.dart';
import 'package:tsdm_client/features/profile/models/birthday_info.dart';
import 'package:tsdm_client/features/profile/models/editable_user_profile.dart';
import 'package:tsdm_client/features/profile/models/profile_form_api.dart';
import 'package:tsdm_client/features/profile/repository/edit_user_profile_repository.dart';
import 'package:tsdm_client/features/profile/repository/switch_user_group_repository.dart';
import 'package:tsdm_client/features/purchase/repository/purchase_repository.dart';
import 'package:tsdm_client/features/rate/models/models.dart';
import 'package:tsdm_client/features/rate/repository/rate_repository.dart';
import 'package:tsdm_client/features/rate/repository/rate_window_cache.dart';
import 'package:tsdm_client/features/rate/view/rate_post_page.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart' show SettingsKeys;
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/debounce_buttons.dart';

import 'fixtures/post_report_fixtures.dart';

const _dir = 'test/data/tsdmapp';

Map<String, dynamic> _form(String name) =>
    jsonDecode(File('$_dir/form_v17_$name.json').readAsStringSync()) as Map<String, dynamic>;

SmallFormFields _fields(Map<String, dynamic> json) =>
    smallFormAnswerOf(
          json,
          SmallFormKind.values.byName(
            json['form'] == 'buy' ? 'buy' : json['form'] as String,
          ),
        )!
        as SmallFormFields;

/// The fields `tools/form300.py` (`json_body`) posts for a form answer [j] as served: `submit.fields`, then the
/// controls of the kind (a checkbox only when checked and not disabled, a select its value).
List<(String, String)> _form300Body(Map<String, dynamic> j) {
  final pairs = <(String, String)>[
    for (final MapEntry(:key, :value)
        in ((j['submit'] as Map<String, dynamic>)['fields'] as Map<String, dynamic>).entries)
      (key, '$value'),
  ];
  List<(String, String)> inp(Object? d) {
    if (d is! Map<String, dynamic>) {
      return const [];
    }
    final type = d['type'];
    if (type == 'checkbox' || type == 'radio') {
      return d['checked'] == 1 && d['disabled'] != 1 ? [(d['name'] as String, d['value'] as String)] : const [];
    }
    if (type == 'file') {
      return const [];
    }
    return [(d['name'] as String, d['value'] as String)];
  }

  switch (j['form']) {
    case 'rate':
      for (final c in j['credits'] as List) {
        pairs.addAll(inp((c as Map)['input']));
      }
      pairs
        ..addAll(inp(j['reason']))
        ..addAll(inp(j['notify']));
    case 'report':
      pairs.addAll(inp(j['message']));
    case 'profile':
      for (final f in j['fields'] as List) {
        for (final d in (f as Map)['inputs'] as List) {
          pairs.addAll(inp(d));
        }
        pairs.addAll(inp(f['privacy']));
      }
      pairs
        ..addAll(inp(j['customstatus']))
        ..addAll(inp((j['signature'] as Map?)?['input']))
        ..addAll(inp(j['timeoffset']));
  }
  return pairs;
}

Map<String, String> _asMap(List<(String, String)> pairs) => {for (final (k, v) in pairs) k: v};

typedef _Answer = ({String body, bool json, String contentType});

_Answer _api(Map<String, dynamic> json) => (body: jsonEncode(json), json: true, contentType: '');

_Answer _text(String body, {String type = 'text/html'}) => (body: body, json: false, contentType: type);

/// The write result (plugin 2.6.0, schema 13) of [kind] with [fields].
Map<String, dynamic> _result(String kind, Map<String, Object?> fields) => {
  'ok': 1,
  'api': 1,
  'time': 1700000000,
  'uid': 33,
  'formhash': 'f1f2f3f4',
  'type': 'result',
  'schema': 13,
  'kind': kind,
  'message': '',
  'message_key': '',
  'url': '',
  'handlekey': '',
  'values': <String, Object?>{},
  'login': 0,
  'alert': '',
  ...fields,
};

/// A forum answering every request with [answer], recording the requests.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  final _Answer Function(RequestOptions options) answer;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final a = answer(options);
    return ResponseBody.fromString(
      a.body,
      200,
      headers: {
        Headers.contentTypeHeader: [
          if (a.json) 'application/json; charset=utf-8' else '${a.contentType}; charset=utf-8',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void _use(_Forum forum) => getIt.registerFactory<NetClientProvider>(
  () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
);

T _right<T>(Either<AppException, T> either) => either.fold((e) => throw e, (v) => v);

AppException _left<T>(Either<AppException, T> either) =>
    either.fold((e) => e, (v) => throw StateError('expected a failure, got $v'));

/// The query of a request without the `mobile=no` every request of the app's client carries.
Map<String, String> _query(RequestOptions r) => {...r.uri.queryParameters}..remove('mobile');

bool _asksForm(RequestOptions r) => _query(r)['tsdmapp'] == 'json' && _query(r)['tsdmform'] == '1';

/// The form-urlencoded body the app posted.
Map<String, String> _posted(RequestOptions r) => {
  for (final MapEntry(:key, :value) in (r.data as Map).entries) '$key': '$value',
};

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
  setUp(() {
    TsdmAppApi.reset();
    RateWindowCache.clear();
  });
  tearDown(() async {
    if (getIt.isRegistered<NetClientProvider>()) {
      await getIt.unregister<NetClientProvider>();
    }
  });

  group('A. asking and telling the answers apart', () {
    test('withTsdmAppForm adds tsdmapp=json and tsdmform=1 once, nodoc=1 for a page, before the fragment', () {
      expect(
        withTsdmAppForm('$baseUrl/forum.php?mod=misc&action=rate&tid=1&pid=2&infloat=yes&inajax=1'),
        '$baseUrl/forum.php?mod=misc&action=rate&tid=1&pid=2&infloat=yes&inajax=1&tsdmapp=json&tsdmform=1',
      );
      expect(
        withTsdmAppForm('$baseUrl/home.php?mod=spacecp', page: true),
        '$baseUrl/home.php?mod=spacecp&tsdmapp=json&tsdmform=1&nodoc=1',
      );
      expect(withTsdmAppForm('home.php#x'), 'home.php?tsdmapp=json&tsdmform=1#x');
      final twice = withTsdmAppForm(withTsdmAppForm('a.php?b=1', page: true), page: true);
      expect(twice, 'a.php?b=1&tsdmapp=json&tsdmform=1&nodoc=1');
      expect(withSmallFormInAjax('forum.php?mod=misc&action=pay&paysubmit=yes&infloat=yes'), endsWith('&inajax=1'));
      expect(withSmallFormInAjax('misc.php?mod=report&inajax=1'), 'misc.php?mod=report&inajax=1');
    });

    test('every fixture: the form or the message of its kind, never of another kind', () {
      for (final name in [
        'rate',
        'report',
        'buy',
        'buy_anonymous',
        'usergroup',
        'usergroup_none',
        'usergroup_switch',
        'profile',
        'profile_info',
      ]) {
        final json = _form(name);
        final kind = SmallFormKind.values.byName(json['form'] as String);
        expect(smallFormAnswerOf(json, kind), isA<SmallFormFields>(), reason: name);
        expect(smallFormAnswerOf(jsonEncode(json), kind), isA<SmallFormFields>(), reason: '$name as text');
        for (final other in SmallFormKind.values.where((k) => k != kind)) {
          expect(smallFormAnswerOf(json, other), isNull, reason: '$name as $other');
        }
      }
      for (final name in [
        'rate_msg_duplicate',
        'rate_msg_noperm',
        'rate_msg_guest',
        'report_msg_guest',
        'buy_msg_poor',
        'usergroup_msg_notfound',
        'profile_msg_guest',
      ]) {
        final json = _form(name);
        expect(
          smallFormAnswerOf(json, SmallFormKind.values.byName(json['form'] as String)),
          isA<SmallFormMessage>(),
          reason: name,
        );
      }
    });

    test('an older answer is not one: the write result, the web page, a schema 16 form; unknown is told apart', () {
      expect(smallFormAnswerOf(_result('page', {'document': '<div></div>'}), SmallFormKind.rate), isNull);
      expect(smallFormAnswerOf('<html></html>', SmallFormKind.profile), isNull);
      expect(smallFormAnswerOf({..._form('rate'), 'schema': 16}, SmallFormKind.rate), isNull);
      expect(smallFormAnswerOf({..._form('rate'), 'type': 'post'}, SmallFormKind.rate), isNull);
      final unknown = {'ok': 0, 'error': 'unknown', 'form': 'rate', 'uid': 33};
      expect(smallFormAnswerOf(unknown, SmallFormKind.rate), isNull);
      expect(isSmallFormUnknown(unknown), isTrue);
      expect(isSmallFormUnknown(_result('page', {})), isFalse);
      expect(smallFormAnswerOf({..._form('rate'), 'schema': 18}, SmallFormKind.rate), isA<SmallFormFields>());
    });

    test('the identity fence: served to the account that asked, or the login prompt, or the account changed', () {
      final form = _fields(_form('rate'));
      expect(form.identityProblem(33), isNull);
      expect(form.identityProblem(35), t.general.accountChangedRetry);
      expect(form.identityProblem(0), t.general.accountChangedRetry);
      final guest = smallFormAnswerOf(_form('rate_msg_guest'), SmallFormKind.rate)!;
      expect(guest.identityProblem(33), t.general.needLogin, reason: 'a guest window: the message is empty');
      final guestPage = smallFormAnswerOf(_form('profile_msg_guest'), SmallFormKind.profile)!;
      expect(guestPage.identityProblem(35), '您需要先登录才能继续本操作');
    });

    test("usable: nothing unsupported and no other plugins' fields", () {
      expect(_fields(_form('profile')).usable, isTrue);
      expect(
        _fields({
          ..._form('profile'),
          'unsupported': ['district'],
        }).usable,
        isFalse,
      );
      expect(
        _fields({
          ..._form('profile'),
          'hook_fields': [
            {
              'hook': 'spacecp_profile_extra',
              'names': ['styleid'],
            },
          ],
        }).usable,
        isFalse,
      );
    });
  });

  group('B. the rate', () {
    const rateAction = '$baseUrl/forum.php?mod=misc&action=rate&tid=9900001&pid=9910002';

    test("the window from the fields: range, today's remaining, choices, reasons, the notice preset", () {
      final info = RateWindowInfo.fromApi(_fields(_form('rate')))!;
      expect(info.isFromApi, isTrue);
      expect(info.tid, '9900001');
      expect(info.pid, '9910002');
      expect(info.formHash, 'f1f2f3f4');
      final score = info.scoreList.single;
      expect(score.id, 'score6');
      expect(score.name, '精灵');
      expect((score.min, score.max), (-20, 100));
      expect(score.allowedRangeDescription, '-20 ~ 100');
      expect(score.remaining, '494');
      expect(score.todayLeft, 494);
      expect(score.allowedRange, ['100', '88', '76', '64', '52', '40', '28', '16', '4', '-8', '-20']);
      expect(info.defaultReasonList, ['很给力!', '神马都是浮云', '赞一个!', '山寨', '淡定']);
      expect(info.submitUrl, '$baseUrl/forum.php?mod=misc&action=rate&ratesubmit=yes&infloat=yes');
      expect(info.noticeAuthorName, 'sendreasonpm');
      expect(info.noticeAuthorPreset, isTrue, reason: 'checked by the site ratenotify plugin, as on the website');
      expect(info.noticeAuthorForced, isFalse);
      expect(info.selfDeduct, isFalse);
    });

    test("the body: what form300 rebuilds from the JSON, with the member's values over it", () {
      final json = _form('rate');
      final info = RateWindowInfo.fromApi(_fields(json))!;
      final expected = _asMap(_form300Body(json))
        ..['score6'] = '4'
        ..['reason'] = 'tsdmapp 300';
      expect(info.body(scores: {'score6': '4'}, reason: 'tsdmapp 300', noticeAuthor: true), expected);
      expect(
        info.body(scores: {'score6': '4'}, reason: 'x', noticeAuthor: false),
        isNot(contains('sendreasonpm')),
        reason: 'an unchecked checkbox is not posted',
      );
      // Locked by the user group (reasonpm 2/3): checked and disabled, never posted; the forum notifies anyway.
      final locked = RateWindowInfo.fromApi(
        _fields({
          ...json,
          'notify': {...json['notify'] as Map<String, dynamic>, 'disabled': 1},
        }),
      )!;
      expect(locked.noticeAuthorForced, isTrue);
      expect(locked.body(scores: const {}, reason: '', noticeAuthor: true), isNot(contains('sendreasonpm')));
    });

    test('a window parsed from the web page posts as it always did', () {
      final info = RateWindowInfo.fromApi(_fields(_form('rate')))!.copyWith(submitFields: null, submitUrl: null);
      expect(info.isFromApi, isFalse);
      expect(info.body(scores: {'score6': ''}, reason: 'r', noticeAuthor: false), {
        'formhash': 'f1f2f3f4',
        'tid': '9900001',
        'pid': '9910002',
        'referer': '$baseUrl/forum.php?mod=viewthread&tid=9900001&page=0#pid9910002',
        'handlekey': 'rate',
        'reason': 'r',
        'score6': '',
      });
    });

    test('a window missing what a rate needs is not taken', () {
      final json = _form('rate');
      expect(RateWindowInfo.fromApi(_fields({...json, 'credits': <Object>[]})), isNull);
      expect(
        RateWindowInfo.fromApi(
          _fields({
            ...json,
            'submit': {
              ...json['submit'] as Map<String, dynamic>,
              'url': 'https://evil.example/forum.php?mod=misc&action=rate&ratesubmit=yes',
            },
          }),
        ),
        isNull,
      );
      expect(RateWindowInfo.fromApi(_fields({...json, 'pid': 1})), isNull, reason: 'another post than the fields');
    });

    test('the kept window of the thread takes the next post into its served fields', () {
      final info = RateWindowInfo.fromApi(_fields(_form('rate')))!;
      final next = RateWindowCache.forPost(info, '9910003');
      expect(next.submitFields!['pid'], '9910003');
      expect(next.submitFields!['referer'], endsWith('#pid9910003'));
      expect(next.body(scores: const {}, reason: '', noticeAuthor: false)['pid'], '9910003');
    });

    test('one request asks the form; the rate goes to submit.url with inajax=1, as served', () async {
      final forum = _Forum(
        (r) => r.method == 'GET'
            ? _api(_form('rate'))
            : _api(_result('handle', {'ok': 1, 'handlekey': 'rate', 'message_key': 'thread_rate_succeed'})),
      );
      _use(forum);
      final repo = RateRepository(currentUid: () => 33);
      final info = _right(await repo.fetchInfo(pid: '9910002', rateTarget: rateAction).run());
      expect(info.isFromApi, isTrue);
      final get = forum.requests.single;
      expect(_asksForm(get), isTrue);
      expect(_query(get), containsPair('inajax', '1'));
      expect(_query(get), containsPair('infloat', 'yes'));
      expect(_query(get), isNot(contains('nodoc')), reason: 'a window, not a page');

      final body = info.body(scores: {'score6': '4'}, reason: 'tsdmapp 300', noticeAuthor: true);
      _right(await repo.rate(body, target: info.submitUrl).run());
      final post = forum.requests.last;
      expect(post.method, 'POST');
      expect(post.uri.path, '/forum.php');
      expect(_query(post), {
        'mod': 'misc',
        'action': 'rate',
        'ratesubmit': 'yes',
        'infloat': 'yes',
        'inajax': '1',
        'tsdmapp': 'json',
      });
      expect(_posted(post), body);
    });

    test("the forum's message instead of the window, as the forum wrote it", () async {
      for (final (name, uid, reason) in [
        ('rate_msg_duplicate', 33, '抱歉，您不能对同一个帖子重复评分'),
        ('rate_msg_noperm', 31, '抱歉，您所在的用户组(AG低權組)无法进行此操作'),
        ('rate_msg_guest', 33, t.general.needLogin),
      ]) {
        final forum = _Forum((_) => _api(_form(name)));
        _use(forum);
        final failure = _left(
          await RateRepository(currentUid: () => uid).fetchInfo(pid: '1', rateTarget: rateAction).run(),
        );
        expect(failure, isA<RateInfoWithErrorException>().having((e) => e.message, 'message', reason), reason: name);
        expect(forum.requests, hasLength(1), reason: name);
        await getIt.unregister<NetClientProvider>();
      }
    });

    test('a window served to another account is never used', () async {
      final forum = _Forum((_) => _api(_form('rate')));
      _use(forum);
      final failure = _left(
        await RateRepository(currentUid: () => 35).fetchInfo(pid: '1', rateTarget: rateAction).run(),
      );
      expect(
        failure,
        isA<RateInfoWithErrorException>().having((e) => e.message, 'message', t.general.accountChangedRetry),
      );
      expect(forum.requests, hasLength(1));
    });

    test('an older plugin: its write result of the same request, parsed as before', () async {
      final xml = File('test/data/rate_window_x5.xml').readAsStringSync();
      final html = RegExp(r'<!\[CDATA\[([\s\S]*)\]\]>').firstMatch(xml)!.group(1)!;
      final forum = _Forum((_) => _api(_result('page', {'document': html})));
      _use(forum);
      final info = _right(
        await RateRepository(currentUid: () => 33).fetchInfo(pid: '77983792', rateTarget: rateAction).run(),
      );
      expect(info.isFromApi, isFalse);
      expect(info.pid, '77983792');
      expect(forum.requests, hasLength(1));
      // Without the plugin: the AJAX fragment itself.
      await getIt.unregister<NetClientProvider>();
      final bare = _Forum((_) => _text(xml, type: 'text/xml'));
      _use(bare);
      expect(
        _right(
          await RateRepository(currentUid: () => 33).fetchInfo(pid: '77983792', rateTarget: rateAction).run(),
        ).isFromApi,
        isFalse,
      );
      expect(bare.requests, hasLength(1));
    });

    test("a form the plugin could not tell, or with other plugins' fields: asked again the old way", () async {
      final xml = File('test/data/rate_window_x5.xml').readAsStringSync();
      for (final first in [
        <String, dynamic>{'ok': 0, 'error': 'unknown', 'form': 'rate', 'uid': 33},
        {
          ..._form('rate'),
          'hook_fields': [
            {
              'hook': 'x',
              'names': ['y'],
            },
          ],
        },
      ]) {
        final forum = _Forum((r) => _asksForm(r) ? _api(first) : _text(xml, type: 'text/xml'));
        _use(forum);
        final info = _right(
          await RateRepository(currentUid: () => 33).fetchInfo(pid: '77983792', rateTarget: rateAction).run(),
        );
        expect(info.isFromApi, isFalse);
        expect(forum.requests, hasLength(2));
        expect(_query(forum.requests.last), isNot(contains('tsdmform')));
        expect(_query(forum.requests.last), containsPair('tsdmapp', 'json'));
        await getIt.unregister<NetClientProvider>();
      }
    });
  });

  group('C. the report', () {
    /// The report fixture as served for the floor of [reportTarget].
    Map<String, dynamic> served({int uid = viewerUid}) {
      final json = _form('report');
      final submit = json['submit'] as Map<String, dynamic>;
      return {
        ...json,
        'uid': uid,
        'rid': reportPid,
        'fid': reportFid,
        'submit': {
          ...submit,
          'fields': {
            ...submit['fields'] as Map<String, dynamic>,
            'rid': '$reportPid',
            'fid': '$reportFid',
            'handlekey': 'miscreport$reportPid',
          },
        },
      };
    }

    PostReportRepository repository(
      List<Uri> gets,
      List<(Uri, Map<String, String>)> posts,
      Object Function(Uri) dialog,
    ) => PostReportRepository(
      get: (url, {required ajax}) async {
        gets.add(url);
        final answer = url.path == '/misc.php' ? dialog(url) : threadPage();
        return PostReportResponse(200, answer is String ? answer : jsonEncode(answer));
      },
      post: (url, body) async {
        posts.add((url, body));
        return PostReportResponse(200, successAjax());
      },
    );

    test('the form from the fields: the hidden fields as served, the reasons, posted to misc.php with inajax=1', () {
      final json = served();
      final form = postReportFormFromApi(_fields(json), target: reportTarget);
      expect(form.reasons, ['广告垃圾', '违规内容', '恶意灌水', '重复发帖', '其他']);
      expect(form.action.toString(), 'https://www.tsdm39.com/misc.php?mod=report&inajax=1');
      expect(form.body('广告垃圾'), _asMap(_form300Body(json))..['message'] = '广告垃圾');
      // Another floor, forum or handle key, or an unknown hidden field, refuses the form.
      for (final bad in [
        {...json, 'fid': 7},
        {...json, 'rid': 1},
        {
          ...json,
          'submit': {
            ...json['submit'] as Map<String, dynamic>,
            'fields': {...(json['submit'] as Map)['fields'] as Map<String, dynamic>, 'seccodeverify': ''},
          },
        },
        {
          ...json,
          'submit': {...json['submit'] as Map<String, dynamic>, 'url': 'home.php?mod=spacecp'},
        },
      ]) {
        expect(
          () => postReportFormFromApi(_fields(bad), target: reportTarget),
          throwsA(isA<PostReportFailure>().having((e) => e.problem, 'problem', PostReportProblem.unsupported)),
        );
      }
    });

    test('prepare: the floor page, then the dialog asked as a small form; one request for it', () async {
      final gets = <Uri>[];
      final posts = <(Uri, Map<String, String>)>[];
      final form = await repository(gets, posts, (_) => served()).prepare(reportTarget, uid: viewerUid);
      expect(gets, hasLength(2));
      expect(gets.last.queryParameters, containsPair('tsdmform', '1'));
      expect(gets.last.queryParameters, containsPair('inajax', '1'));
      expect(form.hidden.map((e) => e.$1), containsAll(['formhash', 'reportsubmit', 'rid', 'fid', 'handlekey']));
      expect(posts, isEmpty);
    });

    test("the forum's message, a guest's or another account's answer: nothing to send", () async {
      for (final (answer, problem, message) in [
        (served(uid: otherUid), PostReportProblem.accountChanged, null),
        ({..._form('report_msg_guest'), 'uid': 0}, PostReportProblem.notLoggedIn, null),
        (
          {
            'ok': 0,
            'error': 'message',
            'message': '抱歉，您已经举报过',
            'message_key': 'x',
            'login': 0,
            'uid': viewerUid,
            'form': 'report',
          },
          PostReportProblem.forumMessage,
          '抱歉，您已经举报过',
        ),
      ]) {
        final gets = <Uri>[];
        await expectLater(
          repository(gets, [], (_) => answer).prepare(reportTarget, uid: viewerUid),
          throwsA(
            isA<PostReportFailure>()
                .having((e) => e.problem, 'problem', problem)
                .having((e) => e.message, 'message', message),
          ),
        );
        expect(gets, hasLength(2));
      }
    });

    test('an older plugin, or none: the dialog of the same request parsed as before; unknown asked again', () async {
      final gets = <Uri>[];
      final form = await repository(gets, [], (_) => reportFormAjax()).prepare(reportTarget, uid: viewerUid);
      expect(form.reasons, hasLength(5));
      expect(gets, hasLength(2));

      final again = <Uri>[];
      final second = await repository(
        again,
        [],
        (url) => url.queryParameters['tsdmform'] == '1'
            ? {'ok': 0, 'error': 'unknown', 'form': 'report', 'uid': viewerUid}
            : reportFormAjax(),
      ).prepare(reportTarget, uid: viewerUid);
      expect(second.reasons, hasLength(5));
      expect(again, hasLength(3));
      expect(again.last.queryParameters, isNot(contains('tsdmform')));
    });
  });

  group('D. buying a paid thread', () {
    const tid = '9900002';

    test('the price, what the author gets and the balance after, as the JSON gives them', () {
      final info = PurchaseRepository.purchaseConfirmInfoFromApi(_fields(_form('buy')), tid: tid)!;
      expect(info.author, 'ag_admin');
      expect((info.price, info.authorProfit, info.coinsLast), ('5', '4', '995'));
      expect(info.submitUrl, '$baseUrl/forum.php?mod=misc&action=pay&paysubmit=yes&infloat=yes');
      expect(info.submitFields, _asMap(_form300Body(_form('buy'))));
      final anonymous = PurchaseRepository.purchaseConfirmInfoFromApi(_fields(_form('buy_anonymous')), tid: '9900003')!;
      expect(anonymous.author, '匿名');
      expect(anonymous.coinsLast, '997');
      final negative = PurchaseRepository.purchaseConfirmInfoFromApi(
        _fields({..._form('buy'), 'balance': -3}),
        tid: tid,
      )!;
      expect(negative.coinsLast, '-3', reason: 'a negative balance stays negative');
      expect(PurchaseRepository.purchaseConfirmInfoFromApi(_fields(_form('buy')), tid: '1'), isNull);
    });

    test('one request asks the window; the purchase posts the served fields to submit.url with inajax=1', () async {
      final forum = _Forum(
        (r) => r.method == 'GET'
            ? _api(_form('buy'))
            : _api(_result('handle', {'ok': 1, 'handlekey': 'pay', 'message_key': 'thread_pay_succeed'})),
      );
      _use(forum);
      final repo = PurchaseRepository(currentUid: () => 35);
      final info = _right(await repo.fetchPurchaseConfirmInfo(tid: tid, pid: '0').run());
      expect(_asksForm(forum.requests.single), isTrue);
      _right(await repo.purchase(info).run());
      final post = forum.requests.last;
      expect(_query(post), {
        'mod': 'misc',
        'action': 'pay',
        'paysubmit': 'yes',
        'infloat': 'yes',
        'inajax': '1',
        'tsdmapp': 'json',
      });
      expect(_posted(post), _asMap(_form300Body(_form('buy'))));
    });

    test("not enough credits, bought already: the forum's words; another account's window is not used", () async {
      for (final (answer, uid, reason) in [
        (_form('buy_msg_poor'), 31, '抱歉，天使币不足 5，请【充值】'),
        (
          {
            'ok': 0,
            'error': 'message',
            'message': '您已经购买过本帖',
            'message_key': 'credits_buy_thread',
            'login': 0,
            'uid': 35,
            'form': 'buy',
            'url': 'forum.php?mod=viewthread&tid=9900002',
          },
          35,
          '您已经购买过本帖',
        ),
        (_form('buy'), 31, t.general.accountChangedRetry),
      ]) {
        final forum = _Forum((_) => _api(answer));
        _use(forum);
        final failure = _left(
          await PurchaseRepository(currentUid: () => uid).fetchPurchaseConfirmInfo(tid: tid, pid: '0').run(),
        );
        expect(failure, isA<PurchaseRefusedException>().having((e) => e.reason, 'reason', reason));
        expect(forum.requests, hasLength(1));
        await getIt.unregister<NetClientProvider>();
      }
    });

    test("a refused purchase carries the forum's message", () async {
      final forum = _Forum(
        (r) => r.method == 'GET'
            ? _api(_form('buy'))
            : _api(_result('handle', {'ok': 0, 'handlekey': 'pay', 'message': '抱歉，您的天使币不足', 'alert': 'error'})),
      );
      _use(forum);
      final repo = PurchaseRepository(currentUid: () => 35);
      final info = _right(await repo.fetchPurchaseConfirmInfo(tid: tid, pid: '0').run());
      expect(
        _left(await repo.purchase(info).run()),
        isA<PurchaseActionFailedException>().having((e) => e.reason, 'reason', '抱歉，您的天使币不足'),
      );
    });

    test('an older plugin, or none: the window of the same request parsed as before, posted as before', () async {
      final xml = File('test/data/pay_dialog_x5.xml').readAsStringSync();
      final forum = _Forum(
        (r) => r.method == 'GET'
            ? _text(xml, type: 'text/xml')
            : _text('<root><![CDATA[购买成功<script>succeedhandle_pay()</script>]]></root>', type: 'text/xml'),
      );
      _use(forum);
      final repo = PurchaseRepository(currentUid: () => 35);
      final info = _right(await repo.fetchPurchaseConfirmInfo(tid: '1264966', pid: '0').run());
      expect(info.submitFields, isNull);
      expect((info.price, info.coinsLast), ('15', '1987'));
      expect(forum.requests, hasLength(1));
      _right(await repo.purchase(info).run());
      expect(_query(forum.requests.last), containsPair('inajax', '1'));
      expect(_posted(forum.requests.last), {
        'formhash': 'XXXXXXXX',
        'referer': 'forum.php',
        'tid': '1264966',
        'handlekey': 'pay',
      });
    });
  });

  group('E. switching the user group', () {
    test('only the groups whose row offers switch; a group only to buy is not one', () {
      final (current, groups) = AvailableUserGroup.parseApi(_fields(_form('usergroup')))!;
      expect(current, 'AG低權組');
      expect(groups.map((e) => (e.gid, e.name)), [(22, '字幕組'), (24, 'AG效能組')]);
      expect(groups.first.switchUrl, 'home.php?mod=spacecp&ac=usergroup&do=switch&groupid=22&handlekey=switchgrouphk');
      final (_, none) = AvailableUserGroup.parseApi(_fields(_form('usergroup_none')))!;
      expect(none, isEmpty, reason: 'three groups listed, every one only to buy');
      expect(AvailableUserGroup.parseApi(_fields(_form('usergroup_switch'))), isNull);
    });

    test('the list in one request (lean), and the switch through the window, posted as served', () async {
      final forum = _Forum((r) {
        if (r.method == 'POST') {
          return _api(
            _result('handle', {'ok': 1, 'handlekey': 'switchgrouphk', 'message_key': 'usergroups_switch_succeed'}),
          );
        }
        return _query(r)['do'] == 'switch' ? _api(_form('usergroup_switch')) : _api(_form('usergroup'));
      });
      _use(forum);
      final repo = SwitchUserGroupRepository(currentUid: () => 35);
      final list = _right(await repo.fetchAvailableGroups().run());
      expect(list.currentUserGroup, 'AG低權組');
      expect(list.availableGroups.map((e) => e.gid), [22, 24]);
      expect(_asksForm(forum.requests.single), isTrue);
      expect(_query(forum.requests.single), containsPair('nodoc', '1'));

      final to = _right(await repo.switchTo(list.availableGroups.first, list.formHash).run());
      expect(to, '字幕組');
      final window = forum.requests[1];
      expect(_asksForm(window), isTrue);
      expect(_query(window), containsPair('groupid', '22'));
      expect(_query(window), containsPair('infloat', 'yes'));
      expect(_query(window), containsPair('inajax', '1'));
      final post = forum.requests[2];
      expect(post.uri.path, '/home.php');
      expect(_query(post), {
        'mod': 'spacecp',
        'ac': 'usergroup',
        'do': 'switch',
        'groupid': '22',
        'inajax': '1',
        'tsdmapp': 'json',
      });
      final switchForm = _form('usergroup_switch');
      expect(_posted(post), _asMap(_form300Body(switchForm)));
    });

    test("not in the group: the forum's words; a list served to another account is not used", () async {
      final forum = _Forum(
        (r) => _query(r)['do'] == 'switch' ? _api(_form('usergroup_msg_notfound')) : _api(_form('usergroup')),
      );
      _use(forum);
      final repo = SwitchUserGroupRepository(currentUid: () => 35);
      final failure = _left(
        await repo
            .switchTo(
              const AvailableUserGroup(
                name: 'x',
                gid: 20,
                infoUrl: '',
                switchUrl: 'home.php?mod=spacecp&ac=usergroup&do=switch&groupid=20&handlekey=switchgrouphk',
              ),
              'f',
            )
            .run(),
      );
      expect(failure, isA<SwitchUserGroupFailed>().having((e) => e.reason, 'reason', '用户组未找到'));
      expect(forum.requests.where((r) => r.method == 'POST'), isEmpty);

      final other = _left(await SwitchUserGroupRepository(currentUid: () => 31).fetchAvailableGroups().run());
      expect(other, isA<SwitchUserGroupFailed>().having((e) => e.reason, 'reason', t.general.accountChangedRetry));
    });

    test('an older plugin, or none: the web page of the same request, switched by the fixed url', () async {
      const page = '''
<html><body><div id="ct"><p class="tbmu"><span class="y">您目前有 <span class="xi1">10 天使币</span></span>
当前用户组: <font color="Red">AG低權組</font></p>
<input type="hidden" name="formhash" value="f1f2f3f4" />
<table class="dt"><tbody class="th"><tr><th>用户组</th></tr></tbody>
<tr><td><a href="home.php?mod=spacecp&amp;ac=usergroup&amp;gid=22" class="xi2">字幕組</a></td><td></td><td></td><td></td>
<td><a href="home.php?mod=spacecp&amp;ac=usergroup&amp;do=switch&amp;groupid=22&amp;handlekey=switchgrouphk">切换</a></td></tr>
</table></div></body></html>''';
      final forum = _Forum(
        (r) => r.method == 'POST'
            ? _text('<root><![CDATA[<script>succeedhandle_switchgrouphk()</script>]]></root>', type: 'text/xml')
            : _text(page),
      );
      _use(forum);
      final repo = SwitchUserGroupRepository(currentUid: () => 35);
      final list = _right(await repo.fetchAvailableGroups().run());
      expect(list.currentUserGroup, 'AG低權組');
      expect(list.availableGroups.single.switchUrl, isNull);
      expect(forum.requests, hasLength(1));
      expect(_right(await repo.switchTo(list.availableGroups.single, list.formHash).run()), '字幕組');
      expect(forum.requests, hasLength(2), reason: 'no window: posted to the fixed url');
      expect(_posted(forum.requests.last), containsPair('formhash', 'f1f2f3f4'));
    });
  });

  group('F. the profile editor', () {
    test('only the fields the page printed, the unchangeable one locked, values and privacy as served', () {
      final api = ProfileApiForm.fromApi(_fields(_form('profile')))!;
      final p = api.profile;
      expect(api.submitUrl, '$baseUrl/home.php?mod=spacecp&ac=profile&op=base');
      expect(p.usernameReadonly, 'ag_low2');
      expect(p.apiKeys, containsAll(['gender', 'birthday', 'field1', 'field2', 'field4', 'field5', 'field6']));
      for (final absent in [
        'qq',
        'msn',
        'site',
        'bio',
        'interest',
        'styleid',
        'sightml',
        'customstatus',
        'timeoffset',
      ]) {
        expect(p.shows(absent), isFalse, reason: absent);
      }
      expect(p.lockedKeys, ['field4']);
      expect(p.canEdit('field4'), isFalse);
      expect(p.favoriteBangumi, 'tsdmapp 3.0.0 不可修改的值 &');
      expect(p.gender, Gender.private);
      expect(p.genderVisibility, Visibility.friendsOnly);
      expect(p.nicknameVisibility, Visibility.private);
      expect((p.birthdayYear, p.birthdayMonth, p.birthdayDay), (2000, 10, 11));
      expect(p.birthdayAvailableYears.first, 2026);
      expect(p.availablePageStyles, isEmpty);
      // The info tab is another form: not the one the app edits.
      expect(ProfileApiForm.fromApi(_fields(_form('profile_info'))), isNull);
    });

    test('unchanged, the body is the page as served (form300); a change goes over its own field only', () {
      final json = _form('profile');
      final api = ProfileApiForm.fromApi(_fields(json))!;
      final served = _asMap(_form300Body(json));
      expect(api.bodyWith(api.profile), served);
      final edited = api.profile.copyWith(
        nickname: 'tsdmapp 300',
        nicknameVisibility: Visibility.friendsOnly,
        gender: Gender.female,
        birthdayYear: 2001,
      );
      final body = api.bodyWith(edited)!;
      expect(body, {
        ...served,
        UserProfileKeys.nickname: 'tsdmapp 300',
        UserProfileKeys.nickname.visibility(): '1',
        UserProfileKeys.gender: '2',
        UserProfileKeys.birthYear: '2001',
      });
      expect(body.keys, isNot(contains('styleid')));
      expect(body.keys, isNot(contains('qq')));
      expect(body['field3'], '', reason: 'a field the app does not edit is posted as served');
      expect(body.keys, isNot(contains('field4')), reason: 'unchangeable: the page prints no control');
    });

    test('a select value is posted as the JSON gives it, a carriage return included', () {
      final json = _form('profile');
      final fields = [
        for (final f in json['fields'] as List)
          if ((f as Map)['id'] == 'bloodtype')
            {
              ...f as Map<String, dynamic>,
              'inputs': [
                {...((f['inputs'] as List).single as Map<String, dynamic>), 'value': 'A\r'},
              ],
            }
          else
            f,
      ];
      final api = ProfileApiForm.fromApi(_fields({...json, 'fields': fields}))!;
      expect(api.bodyWith(api.profile)!['bloodtype'], 'A\r');
    });

    test('the editor in one request (lean); saved to submit.url with the served fields', () async {
      final forum = _Forum(
        (r) => r.method == 'GET'
            ? _api(_form('profile'))
            : _api(_result('page', {'document': "<script>parent.show_success('');</script>"})),
      );
      _use(forum);
      final repo = EditUserProfileRepository(currentUid: () => 35);
      final profile = _right(await repo.loadProfile().run());
      expect(profile.apiKeys, isNotNull);
      expect(_asksForm(forum.requests.single), isTrue);
      expect(_query(forum.requests.single), containsPair('nodoc', '1'));
      _right(await repo.uploadProfile(profile.copyWith(skill: 'x')).run());
      final post = forum.requests.last;
      expect(post.method, 'POST');
      expect(_query(post), {'mod': 'spacecp', 'ac': 'profile', 'op': 'base', 'tsdmapp': 'json'});
      final sent = {for (final e in (post.data as FormData).fields) e.key: e.value};
      expect(sent, {..._asMap(_form300Body(_form('profile'))), 'field5': 'x'});
    });

    test("a refused field is named by its title; the forum's message; a guest's page is not used", () async {
      final forum = _Forum(
        (r) => r.method == 'GET'
            ? _api(_form('profile'))
            : _api(_result('page', {'ok': 0, 'document': '<script>parent.show_error("field3");</script>'})),
      );
      _use(forum);
      final repo = EditUserProfileRepository(currentUid: () => 35);
      final profile = _right(await repo.loadProfile().run());
      expect(
        _left(await repo.uploadProfile(profile).run()),
        isA<EditUserProfileUploadFailed>().having(
          (e) => e.reason,
          'reason',
          t.editUserProfilePage.fieldRefused(field: '年龄'),
        ),
      );
      await getIt.unregister<NetClientProvider>();

      _use(_Forum((_) => _api(_form('profile_msg_guest'))));
      expect(
        _left(await EditUserProfileRepository(currentUid: () => 35).loadProfile().run()),
        isA<EditUserProfileFormNotFound>().having((e) => e.reason, 'reason', '您需要先登录才能继续本操作'),
      );
      await getIt.unregister<NetClientProvider>();

      _use(_Forum((_) => _api(_form('profile'))));
      expect(
        _left(await EditUserProfileRepository(currentUid: () => 31).loadProfile().run()),
        isA<EditUserProfileFormNotFound>().having((e) => e.reason, 'reason', t.general.accountChangedRetry),
      );
    });

    test(
      "an older plugin, or none: the web page of the same request; other plugins' fields: the page again",
      () async {
        final page = File('test/data/profile_edit_form_x5.html').readAsStringSync();
        final forum = _Forum((_) => _text(page));
        _use(forum);
        final repo = EditUserProfileRepository(currentUid: () => 35);
        final profile = _right(await repo.loadProfile().run());
        expect(profile.apiKeys, isNull);
        expect(repo.apiForm, isNull);
        expect(forum.requests, hasLength(1));
        await getIt.unregister<NetClientProvider>();

        final hooked = _Forum(
          (r) => _asksForm(r)
              ? _api({
                  ..._form('profile'),
                  'hook_fields': [
                    {
                      'hook': 'spacecp_profile_extra',
                      'names': ['styleid'],
                    },
                  ],
                })
              : _text(page),
        );
        _use(hooked);
        final again = EditUserProfileRepository(currentUid: () => 35);
        expect(_right(await again.loadProfile().run()).apiKeys, isNull);
        expect(hooked.requests, hasLength(2));
        expect(_query(hooked.requests.last), isNot(contains('tsdmapp')), reason: 'the web page as before');
      },
    );
  });

  group('G. the rate page on a window of the app API', () {
    late AppDatabase db;
    late SettingsRepository settings;

    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings);
      await settings.init();
      await settings.setValue(SettingsKeys.loginUid, 33);
    });

    tearDown(() async {
      await getIt.unregister<SettingsRepository>();
      await getIt.unregister<StorageProvider>();
      await settings.dispose();
      await db.close();
    });

    Future<void> openPage(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2340);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            scaffoldMessengerKey: snackbarKey,
            home: const RatePostPage(
              username: 'ag_low',
              pid: '9910002',
              floor: '2',
              rateAction: '$baseUrl/forum.php?mod=misc&action=rate&tid=9900001&pid=9910002',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets("the range and today's remaining are shown and checked before sending; posted as served", (
      tester,
    ) async {
      final json = _form('rate');
      final credit = {...(json['credits'] as List).single as Map<String, dynamic>, 'today_left': 10};
      final served = {
        ...json,
        'credits': [credit],
        'self_deduct': 1,
      };
      final forum = _Forum(
        (r) => r.method == 'GET'
            ? _api(served)
            : _api(_result('handle', {'ok': 1, 'handlekey': 'rate', 'message_key': 'thread_rate_succeed'})),
      );
      _use(forum);
      await openPage(tester);
      final tr = t.ratePostPage;
      expect(find.text('-20 ~ 100 '), findsOneWidget);
      expect(find.text(tr.scoreTodayRemaining(score: '10')), findsOneWidget);
      expect(find.text(tr.selfDeduct), findsOneWidget);

      Future<void> send(String value) async {
        await tester.enterText(find.widgetWithText(TextFormField, '精灵'), value);
        await tester.tap(find.byType(DebounceFilledButton));
        await tester.pumpAndSettle();
      }

      await send('101');
      expect(find.text(tr.notInAllowedRange(range: '-20 ~ 100')), findsOneWidget);
      await send('-11');
      expect(find.text(tr.overTodayRemaining(score: '10')), findsOneWidget);
      expect(forum.requests.where((r) => r.method == 'POST'), isEmpty, reason: 'checked before sending');

      await send('8');
      final post = forum.requests.lastWhere((r) => r.method == 'POST');
      expect(_query(post), containsPair('inajax', '1'));
      // The switch starts as served: checked by the site's ratenotify plugin.
      expect(_posted(post), _asMap(_form300Body(served))..['score6'] = '8');
      expect(find.text(tr.success), findsOneWidget);
    });
  });
}
