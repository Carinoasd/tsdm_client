/// Roadmap item 3: more forum pages are asked in the JSON mode of the forum's app API (`tsdmapp=json`).
///
/// * Pages the plugin already answers (1.3.0 and later): the private message and broadcast lists of the notification
///   poll, a broadcast message, the thread page of a notice (`findpost` redirect), the poll card, a forum group page,
///   the "查看新帖" search. The chat history asked for it already but never got it: its url ends with `#last` and the
///   parameter was put after it, in the fragment, which is not sent.
/// * Pages plugin 1.6.0 adds: the notice page, the guide index and lists, my threads and replies, the draft box, the
///   friends list. Until then the forum answers them the web page, as before.
///
/// Every such request carries the parameter (never an AJAX request or a form post), and the parser gives the same from
/// the web page and from the JSON answer of plugin 1.5.0 and 1.6.0, whichever comes back. The JSON answers are cut from
/// the page fixtures the way the plugin cuts them (`tsdmapp_page_cut.dart`, checked against recorded answers below).
///
/// A thread page asked in JSON mode cannot carry the antitheft (防采集) challenge: the plugin wraps it in its JSON and
/// the script is lost. The page is asked again without the JSON mode, where the challenge is solved as before. The
/// thread cache a guest is served is answered `unknown` too, but with the posts: it is read as it is, asked once.
///
/// A JSON answer without a page (the plugin failed to build it, or an empty body) is a failed request for the pages
/// that would take an empty page for "nothing there": the notification poll, the draft box.
///
/// Checkin: the API's form hash (`status`, or the `checkin` answer itself with plugin 1.6.0) replaces reading the
/// checkin page; the form posted is the same.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/chat/repository/chat_repository.dart';
import 'package:tsdm_client/features/chat/utils/parse_chat.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/utils/do_checkin.dart';
import 'package:tsdm_client/features/draft_box/repository/draft_repository.dart';
import 'package:tsdm_client/features/editor/repository/mention_repository.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/friend/repository/friend_repository.dart';
import 'package:tsdm_client/features/homepage/repository/guide_index_repository.dart';
import 'package:tsdm_client/features/latest_thread/bloc/latest_thread_bloc.dart';
import 'package:tsdm_client/features/latest_thread/models/latest_thread.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/features/my_thread/bloc/my_thread_bloc.dart';
import 'package:tsdm_client/features/my_thread/repository/my_thread_repository.dart';
import 'package:tsdm_client/features/notification/bloc/broadcast_message_detail_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_detail_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/antitheft_interceptor.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/utils/antitheft/antitheft_decoder.dart';

import 'draft_fixtures.dart';
import 'tsdmapp_page_cut.dart';

String _read(String name) => File('test/data/$name').readAsStringSync();

/// The body of a page made by `draft_fixtures.dart`.
String _bodyOf(String html) => RegExp('<body>(.*)</body>', dotAll: true).firstMatch(html)!.group(1)!;

/// The frame of a Discuz X5 page around [main]: the head declaring `discuz_uid`, the header user node, the breadcrumb
/// and the footer, which the JSON answer drops. Synthetic names and ids only.
String _page(String main, {int uid = 1000, String head = ''}) =>
    '''
<!DOCTYPE html>
<html><head><meta charset="utf-8" /><title>Synthetic - Powered by Discuz!</title>$head
<script type="text/javascript">var STYLEID = '2', STATICURL = 'static/', discuz_uid = '$uid', cookiepre = 'x_';</script>
</head><body>
<div id="hd"><div class="wp"><div class="hdc cl"><div id="um">
<p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=$uid" target="_blank" title="访问我的空间">Alice</a></strong></p>
</div></div></div></div>
<div id="wp" class="wp">
<div id="pt" class="bm cl"><div class="z"><a href="./" class="nvhm" title="首页">首页</a></div></div>
$main
</div>
<div id="ft" class="wp cl">Footer<script src="home.php?mod=spacecp&amp;ac=pm&amp;op=checknewpm&amp;rand=1" type="text/javascript"></script></div>
</body></html>''';

/// A space page (`home.php?mod=space`) with [content] in its main column.
String _spacePage(String content, {int uid = 1000}) =>
    _page('<div id="ct" class="ct2_a wp cl"><div class="mn"><div class="bm bw0">$content</div></div></div>', uid: uid);

/// A thread page with [postList] (`div#postlist`), followed by the moderation form the plugin cuts the list before.
String _threadPage(String postList, {int uid = 1000, int tid = 123}) => _page(
  '$postList\n<form method="post" autocomplete="off" name="modactions" id="modactions"></form>\n'
  '<div class="pgs mtm mbm cl"><div class="pg"><strong>1</strong></div></div>',
  uid: uid,
  head: '<link href="$baseUrl/forum.php?mod=viewthread&amp;tid=$tid" rel="canonical" />',
);

/// What plugin 1.5.0 and 1.6.0 answer a thread page asked in JSON mode that the forum challenges (防采集): the script,
/// printed before the thread was built, is lost; a form hash is all the document holds.
const Map<String, Object?> _challengedAnswer = {
  'ok': 0,
  'error': 'unknown',
  'head': '',
  'document': '<input type="hidden" name="formhash" value="a1b2c3d4" />\n',
};

/// One answer of the fake forum.
typedef _Answer = ({String body, bool json, int status, String? redirectTo});

_Answer _html(String body, {String? redirectTo}) => (body: body, json: false, status: 200, redirectTo: redirectTo);

_Answer _json(Object answer, {int status = 200, String? redirectTo}) =>
    (body: answer is String ? answer : jsonEncode(answer), json: true, status: status, redirectTo: redirectTo);

/// The forum's clock in every answer.
const _date = 'Wed, 14 Oct 2026 08:00:00 GMT';

/// Answers every request with [answer] and records it, with the form it posted.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  final _Answer Function(RequestOptions options) answer;
  final requests = <RequestOptions>[];
  final bodies = <String?>[];

  List<RequestOptions> get gets => requests.where((e) => e.method == 'GET').toList();

  List<RequestOptions> get apiRequests => requests.where((e) => e.uri.queryParameters['id'] == 'tsdmapp:api').toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    bodies.add(requestStream == null ? null : utf8.decode(await requestStream.expand((e) => e).toList()));
    final a = answer(options);
    final body = ResponseBody.fromString(
      a.body,
      a.status,
      headers: {
        Headers.contentTypeHeader: [if (a.json) 'application/json; charset=utf-8' else 'text/html; charset=utf-8'],
        'date': [_date],
      },
    );
    if (a.redirectTo != null) {
      body.redirects = [RedirectRecord(302, options.method, Uri.parse(a.redirectTo!))];
    }
    return body;
  }

  @override
  void close({bool force = false}) {}
}

NetClientProvider _client(_Forum forum) =>
    NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

/// Make [forum] the forum of the app's default client.
void _use(_Forum forum) => getIt.registerFactory<NetClientProvider>(() => _client(forum));

bool _asksJson(RequestOptions r) => r.uri.queryParameters['tsdmapp'] == 'json';

/// The app API plugin on the forum: none (or switched off), 1.5.0 (on the forum now), 1.6.0 (adds [pagesSince160] and
/// the page title).
enum _Plugin { none, v150, v160 }

/// The forum's answer to a request for the web page [html] of page [type] (in JSON mode) with [plugin]: the web page
/// when the plugin does not answer that page.
_Answer _answerOf(String html, String type, _Plugin plugin) => switch (plugin) {
  _Plugin.none => _html(html),
  _Plugin.v150 when pagesSince160.contains(type) => _html(html),
  _Plugin.v150 => _json(pageAnswerOf(html, type, v150: true)),
  _Plugin.v160 => _json(pageAnswerOf(html, type)),
};

/// Run [fetch] against a forum answering every page request with [html] of page [type], with each [_Plugin]: all
/// give the same [view] of the result, and every page is asked in JSON mode.
///
/// Returns the view, for the caller to check it holds what the page shows.
Future<Object?> _sameWithEachPlugin<T>(
  String html,
  String type,
  Future<T> Function() fetch,
  Object? Function(T value) view,
) async {
  final views = <Object?>[];
  for (final plugin in _Plugin.values) {
    final forum = _Forum((_) => _answerOf(html, type, plugin));
    _use(forum);
    views.add(view(await fetch()));
    expect(forum.requests, isNotEmpty);
    for (final r in forum.requests) {
      expect(_asksJson(r), isTrue, reason: '${r.uri}');
    }
  }
  for (final (i, v) in views.indexed.skip(1)) {
    expect(v, views.first, reason: '${_Plugin.values[i]}');
  }
  return views.first;
}

T _right<T>(Either<Object, T> v) => v.getOrElse((e) => fail('$e'));

/// Colors and font weights parsed from styles have no mapper of their own; the comparison only needs their value.
final class _ColorMapper extends SimpleMapper<Color> {
  const _ColorMapper();

  @override
  Color decode(Object value) => Color(value as int);

  @override
  Object? encode(Color self) => self.toARGB32();
}

final class _FontWeightMapper extends SimpleMapper<FontWeight> {
  const _FontWeightMapper();

  @override
  FontWeight decode(Object value) => FontWeight.values.firstWhere((e) => e.value == value);

  @override
  Object? encode(FontWeight self) => self.value;
}

final class _ThreadStateMapper extends SimpleMapper<ThreadStateModel> {
  const _ThreadStateMapper();

  @override
  ThreadStateModel decode(Object value) => ThreadStateModel.values.byName(value as String);

  @override
  Object? encode(ThreadStateModel self) => self.name;
}

final class _NoticeTypeMapper extends SimpleMapper<NoticeType> {
  const _NoticeTypeMapper();

  @override
  NoticeType decode(Object value) => NoticeType.values.byName(value as String);

  @override
  Object? encode(NoticeType self) => self.name;
}

/// The public message list page with one unread message (markup of test 185, 2026-10-01).
final String _announceList = _spacePage('''
<div class="pml">
<dl id="gpmlist_5" class="bbda cur1 cl newpm">
<dd class="y mtm pm_o"><a href="javascript:;" id="pm_g_5" class="o">菜单</a></dd>
<dd class="m avt"><div class="newpm_avt" title="有未读消息"></div>
<a href="home.php?mod=space&amp;do=pm&amp;subop=viewg&amp;pmid=5"><img src="static/image/common/systempm.png" alt="" /></a>
</dd>
<dd class="ptm pm_c">
<span id="p_gpmid_5">Synthetic broadcast message</span> &nbsp;
<span class="xg1"><span title="2026-10-1 11:16">9&nbsp;小时前</span></span>&nbsp;
<a href="home.php?mod=space&amp;do=pm&amp;subop=viewg&amp;pmid=5" id="gpmlist_5_a">查看</a>
</dd>
</dl>
</div>''', uid: 1001);

/// The notice page: a friend request (no notice of its own) and a reply notice.
final String _noticePage = _read('notice_friend_request_x5.html').replaceFirst(
  '<div class="nts">',
  '<div class="nts">${RegExp('<dl.*</dl>', dotAll: true).firstMatch(_read('notice_unread_x5.html'))![0]}',
);

/// A thread row of "my threads", and of "my replies" with the reply quoted under it.
String _myThreadRow(int tid, {String? reply}) =>
    '''
<tr${reply == null ? '' : ' class="bw0_all"'}>
<td class="icn"><a href="forum.php?mod=viewthread&amp;tid=$tid" target="_blank"></a></td>
<th><a href="forum.php?mod=viewthread&amp;tid=$tid" target="_blank">Synthetic thread $tid</a></th>
<td><a href="forum.php?mod=forumdisplay&amp;fid=4" target="_blank" class="xg1">Test forum</a></td>
<td class="num"><a href="forum.php?mod=viewthread&amp;tid=$tid" class="xi2">3</a><em>45</em></td>
<td class="by"><cite><a href="home.php?mod=space&amp;uid=1001" c="1">Bob</a></cite>
<em><a href="forum.php?mod=redirect&amp;tid=$tid&amp;goto=lastpost#lastpost"><span title="2026-10-1 12:00">13 天前</span></a></em></td>
</tr>${reply == null ? '' : '''
<tr><td colspan="2"></td><td colspan="3" class="xg1"><a href="forum.php?mod=redirect&amp;goto=findpost&amp;ptid=$tid&amp;pid=${tid}0" target="_blank">$reply</a></td></tr>'''}''';

String _myThreadPage(String type) => _spacePage(
  '''
<ul class="tb cl"><li${type == 'thread' ? ' class="a"' : ''}><a href="home.php?mod=space&amp;do=thread&amp;view=me&amp;type=thread">主题</a></li>
<li${type == 'reply' ? ' class="a"' : ''}><a href="home.php?mod=space&amp;do=thread&amp;view=me&amp;type=reply">回复</a></li></ul>
<div class="tl"><form method="post" autocomplete="off" name="delform" id="delform" action="home.php?mod=spacecp&amp;ac=thread"><table cellspacing="0" cellpadding="0">
<tr class="th"><td class="icn">&nbsp;</td><th>主题</th><td>版块</td><td class="num">回复/查看</td><td class="by">最后发表</td></tr>
${type == 'thread' ? _myThreadRow(123) + _myThreadRow(124) : _myThreadRow(125, reply: 'Synthetic reply')}
</table></form></div>
<div class="pgs cl mtm"><div class="pg"><strong>1</strong><a href="home.php?mod=space&amp;do=thread&amp;view=me&amp;type=$type&amp;page=2">2</a><a href="home.php?mod=space&amp;do=thread&amp;view=me&amp;type=$type&amp;page=2" class="nxt">下一页</a></div></div>''',
);

/// A `checkin` answer: not checked in today and open now; [formHash] as plugin 1.6.0 may add it.
Map<String, Object?> _checkinAnswer({String? formHash}) => {
  'ok': 1,
  'api': 1,
  'time': 1791950400,
  'installed': 1,
  'checked_today': 0,
  'can_checkin': 1,
  'window': {'enabled': 1, 'start_hour': 1, 'end_hour': 23, 'open_now': 1},
  'day_start': 1791907200,
  'last_time': 0,
  'days': 3,
  'month_days': 1,
  'formhash': ?formHash,
};

Map<String, Object?> _statusAnswer({int uid = 1000, String? formHash = 'a1b2c3d4'}) => {
  'ok': 1,
  'api': 1,
  'version': '1.5.0',
  'time': 1791950400,
  'uid': uid,
  'formhash': ?formHash,
  'actions': ['status', 'notify', 'checkin'],
};

const _checkinPage = '''
<html><body><div id="um"><p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong></p></div>
<div id="qdmsgt"><p>【<span class=gray>今天未签到</span>】</p></div>
<form id="qiandao" method="post" action="plugin.php?id=dsu_paulsign:sign&amp;operation=qiandao&amp;infloat=1&amp;inajax=1">
<input type="hidden" name="formhash" value="a1b2c3d4" /></form></body></html>''';

const _checkinSuccess =
    '<?xml version="1.0" encoding="utf-8"?>\n<root><![CDATA[<div class="c">恭喜你签到成功!获得随机奖励 天使币 10 .</div>]]></root>';

void main() {
  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    // Each test serves its own forum to the app's default client.
    getIt.allowReassignment = true;
    MapperContainer.globals.useAll([
      const _ColorMapper(),
      const _FontWeightMapper(),
      const _ThreadStateMapper(),
      const _NoticeTypeMapper(),
    ]);
    getIt
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
  });
  tearDownAll(() async {
    await getIt.reset();
    getIt.allowReassignment = false;
  });
  setUp(TsdmAppApi.reset);

  group('the page cut of the tests', () {
    // The recorded pairs were fetched a few seconds apart: counters, times and random ids may differ; the files of the
    // web pages lost their CR.
    String norm(String s) => s.replaceAll('\r', '').replaceAll(RegExp(r'\d+'), '0');

    for (final (name, type) in [('thread_hide', 'viewthread'), ('s3_search', 'search'), ('s3_index', 'index')]) {
      test('$name: cut like the plugin did', () {
        final html = _read('tsdmapp/$name.html');
        final recorded = jsonDecode(_read('tsdmapp/$name.json')) as Map<String, dynamic>;
        final cut = jsonDecode(pageAnswerOf(html, type, v150: true)) as Map<String, dynamic>;
        expect(norm(cut['document'] as String), norm(recorded['document'] as String));
        expect(cut['head'], recorded['head']);
      });
    }
  });

  group('withTsdmAppJson', () {
    test('adds the parameter to the query, or starts one', () {
      expect(
        withTsdmAppJson('$baseUrl/home.php?mod=space&do=notice'),
        '$baseUrl/home.php?mod=space&do=notice&tsdmapp=json',
      );
      expect(withTsdmAppJson('$baseUrl/forum.php'), '$baseUrl/forum.php?tsdmapp=json');
      expect(withTsdmAppJson('$baseUrl/forum.php?'), '$baseUrl/forum.php?tsdmapp=json');
    });

    test('before the fragment, which is never sent: the chat history url ends with #last', () {
      for (final page in [null, 2]) {
        final url = withTsdmAppJson(formatChatFullHistoryUrl('1001', page: page));
        expect(
          url,
          '$baseUrl/home.php?mod=space&do=pm&subop=view&touid=1001${page == null ? '' : '&page=$page'}&tsdmapp=json#last',
        );
        final uri = Uri.parse(url);
        expect(uri.queryParameters['tsdmapp'], 'json');
        expect(uri.fragment, 'last');
      }
      expect(withTsdmAppJson('$baseUrl/forum.php#top'), '$baseUrl/forum.php?tsdmapp=json#top');
    });

    test('an AJAX url is left as it is', () {
      for (final url in [formatChatUrl('1001'), '$baseUrl/misc.php?mod=getatuser&inajax=1#x']) {
        expect(withTsdmAppJson(url), url);
      }
    });

    test('asked twice, added once', () {
      for (final url in [
        '$baseUrl/forum.php?gid=1',
        '$baseUrl/forum.php',
        formatChatFullHistoryUrl('1001', page: 3),
        '$baseUrl/forum.php?mod=guide&view=index&tsdmapp=json',
      ]) {
        final once = withTsdmAppJson(url);
        expect(withTsdmAppJson(once), once);
        expect('tsdmapp=json'.allMatches(once), hasLength(1));
      }
    });
  });

  test('chat history: asked in JSON mode for real now, parses the same', () async {
    final view = await _sameWithEachPlugin(
      _read('chat_history_bare_url_x5.html'),
      'pm',
      () async => _right(await const ChatRepository().fetchChatHistory('1001').run()),
      (doc) {
        final info = parseChatHistory(doc);
        return info == null
            ? null
            : {
                'username': info.username,
                'count': info.messageCount,
                'pages': [info.previousPage, info.nextPage],
                'send': info.sendTarget?.toMap(),
                'messages': info.messages.map((e) => e.toMap()).toList(),
              };
      },
    );
    final info = view! as Map<String, Object?>;
    expect(info['messages'], isNotEmpty);
    expect(info['send'], isNotNull, reason: 'the reply form is in the blocks');
  });

  group('notifications', () {
    _Answer page(RequestOptions o, {_Plugin plugin = _Plugin.v160}) {
      final q = o.uri.queryParameters;
      final (html, type) = switch ((q['do'], q['filter'])) {
        ('notice', _) => (_noticePage, 'notice'),
        ('pm', 'privatepm') => (_read('pm_list_bare_url_x5.html'), 'pm'),
        ('pm', 'announcepm') => (_announceList, 'pm'),
        _ => fail('unexpected request ${o.uri}'),
      };
      return _answerOf(html, type, plugin);
    }

    test('the three pages, each in JSON mode, parse the same', () async {
      final views = <Object?>[];
      for (final plugin in _Plugin.values) {
        final forum = _Forum((o) => page(o, plugin: plugin));
        _use(forum);
        final repo = NotificationRepository();
        final notices = _right(await repo.fetchNotice().run());
        final pms = _right(await repo.fetchPersonalMessage().run());
        final announces = _right(await repo.fetchBroadMessage().run());
        expect(forum.requests, hasLength(3));
        expect(forum.requests.every(_asksJson), isTrue);
        expect(notices, isNotEmpty);
        expect(pms, isNotEmpty);
        expect(announces, hasLength(1));
        views.add([
          for (final e in notices) e.toMap(),
          for (final e in pms) e.toMap(),
          for (final e in announces) e.toMap(),
        ]);
      }
      for (final (i, v) in views.indexed.skip(1)) {
        expect(v, views.first, reason: '${_Plugin.values[i]}');
      }
    });

    test('polling (and the sync of every account, which passes its own client): the forum clock still read', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final notify = {
        'ok': 1,
        'api': 1,
        'time': now,
        'uid': 1001,
        'counts': {'notice': 1, 'pm': 0, 'announce': 0},
        'notices': [
          {'id': 1, 'new': 1, 'type': 'post', 'dateline': now - 10},
        ],
        'pms': <Object>[],
        'announces': <Object>[],
      };
      final forum = _Forum(
        (o) => o.uri.queryParameters['id'] == 'tsdmapp:api' ? _json(notify) : page(o),
      );
      final result = await NotificationRepository().fetchNotificationWith(_client(forum), timestamp: now - 60).run();
      final value = _right(result);
      expect(value.serverTime, DateTime.utc(2026, 10, 14, 8));
      expect(forum.apiRequests, hasLength(1));
      expect(_asksJson(forum.apiRequests.single), isFalse, reason: 'the API is not a page');
      final pages = forum.requests.where((e) => !forum.apiRequests.contains(e)).toList();
      expect(pages, hasLength(3));
      expect(pages.every(_asksJson), isTrue);
    });

    test('a JSON answer without a page is a failed fetch, not an empty list nor an expired session', () async {
      // dio reads an empty `application/json` body as null, and fails on a blank one.
      for (final (label, answer) in [
        ('a failed build', _json({'ok': 0, 'error': 'internal'})),
        ('an empty body', _json('')),
        ('a blank body', _json(' \n')),
      ]) {
        final forum = _Forum((o) => o.uri.queryParameters['do'] == 'notice' ? answer : page(o));
        final result = await NotificationRepository().fetchNotificationWith(_client(forum)).run();
        expect(result.isLeft(), isTrue, reason: label);
        expect(result.getLeft().toNullable(), isNot(isA<NotificationUserNotFound>()), reason: label);
        expect(forum.requests, hasLength(3), reason: label);
      }
      expect(tsdmAppAnswerWithoutPage('{"ok":0,"error":"internal"}'), isTrue);
      expect(tsdmAppAnswerWithoutPage(null), isTrue);
      expect(tsdmAppAnswerWithoutPage(pageAnswerOf(_noticePage, 'notice')), isFalse);
      expect(tsdmAppAnswerWithoutPage(_noticePage), isFalse);
    });

    test('an expired session is told apart in the JSON answer too', () async {
      final guest = _read('favorite_list_guest_x5.html');
      for (final json in [false, true]) {
        final forum = _Forum((_) => json ? _json(pageAnswerOf(guest, 'notice')) : _html(guest));
        final result = await NotificationRepository().fetchNotificationWith(_client(forum)).run();
        expect(result.getLeft().toNullable(), isA<NotificationUserNotFound>(), reason: 'json: $json');
      }
    });
  });

  group('notice and broadcast message details', () {
    test('only thread pages and private message pages are asked in JSON mode', () {
      for (final url in [
        '$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=1&pid=2',
        'forum.php?mod=viewthread&tid=1',
        '$baseUrl/home.php?mod=space&do=pm&subop=viewg&pmid=5',
      ]) {
        expect(Uri.parse(NotificationRepository.jsonModeDetailUrl(url)).queryParameters['tsdmapp'], 'json');
      }
      for (final url in [
        '$baseUrl/home.php?mod=space&do=blog&id=1',
        '$baseUrl/plugin.php?id=some:page',
        '$baseUrl/forum.php?mod=misc&action=rate&tid=1&pid=2&inajax=1',
        'https://example.com/forum.php?mod=viewthread&tid=1',
      ]) {
        expect(NotificationRepository.jsonModeDetailUrl(url), url);
      }
    });

    test('the post of a notice: same post, reply form and page through the findpost redirect', () async {
      const tid = 9199345;
      const pid = 3954;
      final html = _read('tsdmapp/thread_plain.html');
      final states = <Map<String, dynamic>>[];
      for (final plugin in _Plugin.values) {
        final answer = _answerOf(html, 'viewthread', plugin);
        // The plugin carries the JSON mode through the redirect.
        final to = '$baseUrl/forum.php?mod=viewthread&tid=$tid&page=1${answer.json ? '&tsdmapp=json' : ''}#pid$pid';
        final forum = _Forum((_) => (body: answer.body, json: answer.json, status: 200, redirectTo: to));
        _use(forum);
        final cubit = NotificationDetailCubit(notificationRepository: NotificationRepository());
        await cubit.fetchDetail('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=$tid&pid=$pid');
        expect(cubit.state.status, NotificationDetailStatus.success);
        expect(forum.requests.single.uri.queryParameters, containsPair('tsdmapp', 'json'));
        final state = cubit.state;
        states.add({
          'status': state.status.name,
          'post': state.post?.toMap(),
          'replyParameters': state.replyParameters?.toMap(),
          'tid': state.tid,
          'pid': state.pid,
          'page': state.page,
          'threadClosed': state.threadClosed,
        });
        await cubit.close();
      }
      expect(states.skip(1), everyElement(states.first));
      expect(states.first['page'], '1');
      expect(states.first['post'], isNotNull);
    });

    test('the recorded JSON answer of the same thread gives the post too', () async {
      _use(_Forum((_) => _json(_read('tsdmapp/thread_plain.json'))));
      final cubit = NotificationDetailCubit(notificationRepository: NotificationRepository());
      await cubit.fetchDetail('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=9199345&pid=3954');
      expect(cubit.state.status, NotificationDetailStatus.success);
      expect(cubit.state.post?.postID, '3954');
      await cubit.close();
    });

    test('a broadcast message: same time and text', () async {
      final html = _spacePage('''
<div id="pm_ul" class="xld xlda mbm pml">
<dl class="cl">
<dd class="m avt"><a href="home.php?mod=space&amp;uid=1"><img src="static/image/common/systempm.png" /></a></dd>
<dd class="ptm">
<a href="home.php?mod=space&amp;uid=1" class="xw1">Admin</a>
<span class="xg1"><span title="2026-10-1 11:16">13 天前</span></span><br />
<p class="pm_smry">Synthetic <b>broadcast</b> message</p>
</dd></dl></div>''', uid: 1001);
      final view = await _sameWithEachPlugin(html, 'pm', () async {
        final cubit = BroadcastMessageDetailCubit(NotificationRepository());
        await cubit.fetchDetail('5');
        final state = cubit.state;
        await cubit.close();
        return state;
      }, (state) => [state.status.name, state.dateTime?.toIso8601String(), state.messageNode?.innerHtml]);
      expect((view! as List).first, 'success');
    });
  });

  group('poll card', () {
    String pollPage() => _threadPage(
      '<div id="postlist"><div id="post_78025860"><table><tr><td class="plc">'
      '${_read('poll_voted_x5.html')}</td></tr></table></div></div>',
      tid: 1266029,
    );

    test('the poll of the post: same options, results and form', () async {
      const url = '$baseUrl/forum.php?mod=redirect&goto=findpost&pid=78025860';
      final view = await _sameWithEachPlugin(
        pollPage(),
        'viewthread',
        () => PollRepository.network(getIt.get<NetClientProvider>()).fetch(url, 1000),
        (p) => [
          p.availability.name,
          p.summary,
          p.deadline,
          p.notice,
          p.maxChoices,
          p.action,
          p.formHash,
          [for (final o in p.options) '${o.id}|${o.label}|${o.result}'],
        ],
      );
      final poll = view! as List<Object?>;
      expect(poll.first, PollAvailability.voted.name);
      expect(poll[7], hasLength(5));
    });

    test('the vote is posted as before, not in JSON mode', () async {
      final page = _read('poll_multiple_x5.html');
      final forum = _Forum(
        (o) => o.method == 'GET'
            ? _json(
                pageAnswerOf(
                  _threadPage(
                    '<div id="postlist"><div id="post_1"><table><tr><td class="plc">$page</td></tr></table></div></div>',
                  ),
                  'viewthread',
                ),
              )
            : _html('<html><body>Accepted</body></html>'),
      );
      final repo = PollRepository.network(_client(forum));
      final poll = await repo.fetch('$baseUrl/forum.php?mod=redirect&goto=findpost&pid=1', 1000);
      expect(poll.availability, PollAvailability.available);
      await repo.vote(poll, {poll.options.first.id!});
      expect(forum.requests.last.method, 'POST');
      expect(_asksJson(forum.requests.last), isFalse);
    });
  });

  test('forum group page: the same group (the forum serves it as its board index)', () async {
    final view = await _sameWithEachPlugin(
      _read('forum_index_x5.html'),
      'index',
      () async => _right(await ForumRepository().fetchForumGroup('1').run()),
      (group) => group?.toMap(),
    );
    expect((view! as Map)['forumList'], isNotEmpty);
  });

  group('latest threads', () {
    Future<Object?> load(String url) async {
      final bloc = LatestThreadBloc(latestThreadRepository: LatestThreadRepository())
        ..add(LatestThreadRefreshRequested(url));
      final state = await bloc.stream.firstWhere(
        (s) => s.status == LatestThreadStatus.success || s.status == LatestThreadStatus.failed,
      );
      await bloc.close();
      return state;
    }

    Object? view(Object? state) {
      final s = state! as LatestThreadState;
      return [
        s.status.name,
        s.nextPageUrl,
        for (final LatestThread t in s.threadList)
          [
            t.title,
            t.url,
            t.threadID,
            t.forumName,
            t.forumUrl,
            t.latestReplyAuthor?.toMap(),
            t.latestReplyTime?.toIso8601String(),
            t.replyCount,
            t.viewCount,
            t.quotedMessage,
            t.threadAuthor?.toMap(),
          ],
      ];
    }

    test('查看新帖 (forum search since a time): same threads', () async {
      final v = await _sameWithEachPlugin(
        _read('tsdmapp/s3_search.html'),
        'search',
        () => load('$baseUrl/search.php?mod=forum&srchfrom=86400&searchsubmit=yes'),
        view,
      );
      expect((v! as List).length, greaterThan(2));
    });

    test('guide list (plugin 1.6.0): same threads and next page', () async {
      final v = await _sameWithEachPlugin(
        _read('guide_hot_x5.html'),
        'guide',
        () => load('$baseUrl/forum.php?mod=guide&view=hot'),
        view,
      );
      expect((v! as List).length, greaterThan(2));
    });
  });

  test('guide index (plugin 1.6.0): the same modules', () async {
    final view = await _sameWithEachPlugin(
      _read('guide_index_x5.html'),
      'guide',
      () async => _right(await const GuideIndexRepository().fetchGuideIndex().run()),
      (modules) => modules.map((e) => e.toMap()).toList(),
    );
    expect(view, hasLength(4));
  });

  test('my threads and replies (plugin 1.6.0): same rows and next pages', () async {
    final views = <Object?>[];
    for (final plugin in _Plugin.values) {
      final forum = _Forum((o) => _answerOf(_myThreadPage(o.uri.queryParameters['type']!), 'mythread', plugin));
      _use(forum);
      final bloc = MyThreadBloc(myThreadRepository: MyThreadRepository())..add(MyThreadLoadInitialDataRequested());
      final state = await bloc.stream.firstWhere((s) => s.status != MyThreadStatus.loading);
      await bloc.close();
      expect(state.status, MyThreadStatus.success);
      expect(forum.requests, hasLength(2));
      expect(forum.requests.every(_asksJson), isTrue);
      views.add([
        state.threadList.map((e) => e.toMap()).toList(),
        state.replyList.map((e) => e.toMap()).toList(),
        state.nextThreadPageUrl,
        state.nextReplyPageUrl,
      ]);
    }
    for (final (i, v) in views.indexed.skip(1)) {
      expect(v, views.first, reason: '${_Plugin.values[i]}');
    }
    final first = views.first! as List;
    expect(first[0], hasLength(2));
    expect(first[1], hasLength(1));
    expect(first[2], '$baseUrl/home.php?mod=space&do=thread&view=me&type=thread&page=2');
  });

  group('draft box', () {
    test('the list (plugin 1.6.0): same drafts, the account checked through discuz_uid', () async {
      final view = await _sameWithEachPlugin(
        _spacePage(_bodyOf(draftList(next: 2))),
        'mythread',
        () => DraftRepository.network(getIt.get<NetClientProvider>()).load(1000),
        (page) => [for (final e in page.entries) '${e.tid}|${e.fid}|${e.title}|${e.forumName}', page.nextPage],
      );
      expect(view, ['123|4|Synthetic draft 123|Test forum', 2]);
    });

    test('opening a draft reads its thread in JSON mode too', () async {
      final list = DraftRepository((_) async => _spacePage(_bodyOf(draftList())));
      final draft = (await list.load(1000)).entries.single;
      final view = await _sameWithEachPlugin(
        _threadPage(_bodyOf(draftThread())),
        'viewthread',
        () => DraftRepository.network(getIt.get<NetClientProvider>()).resolve(draft, 1000),
        (target) => target,
      );
      expect(view, (fid: '4', tid: '123', pid: '456'));
    });

    test('a JSON answer without a page is a failed read, not an expired session', () async {
      for (final (label, answer, failure) in [
        ('a failed build', _json({'ok': 0, 'error': 'internal'}), isA<HttpRequestFailedException>()),
        ('an empty body', _json(''), isA<HttpRequestFailedException>()),
        ('a blank body', _json(' \n'), isNot(isA<FormatException>())),
      ]) {
        final forum = _Forum((_) => answer);
        await expectLater(DraftRepository.network(_client(forum)).load(1000), throwsA(failure), reason: label);
        expect(forum.requests, hasLength(1), reason: label);
      }
    });
  });

  group('a thread page the forum challenges (防采集)', () {
    // Recorded challenges of the forum, a thread each: the interceptor keeps the solved signs for the whole run.

    /// A forum guarding thread [tid] with its recorded challenge, as the real one with the plugin does: without the
    /// sign the challenge, lost in the plugin's answer in JSON mode ([_challengedAnswer]); with it, [thread]. A
    /// findpost redirect ends on the thread page.
    _Forum guarded(String tid, String thread) => _Forum((o) {
      final q = o.uri.queryParameters;
      final json = _asksJson(o);
      final to = q['mod'] == 'redirect'
          ? '$baseUrl/forum.php?mod=viewthread&tid=$tid&page=1${json ? '&tsdmapp=json' : ''}'
          : null;
      if (!q.containsKey(AntitheftDecoder.dsignKey)) {
        return json ? _json(_challengedAnswer, redirectTo: to) : _html(_read('antitheft/$tid.html'), redirectTo: to);
      }
      return json ? _json(pageAnswerOf(thread, 'viewthread'), redirectTo: to) : _html(thread, redirectTo: to);
    });

    /// [forum] solved the challenge of [tid]: the page in JSON mode, the same page as the web page (the challenge),
    /// the page with the sign. GETs only.
    void expectSolved(_Forum forum, String tid) {
      final sign = AntitheftDecoder.decode(_read('antitheft/$tid.html'))!.dsign;
      expect(forum.requests.map((e) => e.method), ['GET', 'GET', 'GET']);
      expect(forum.requests.map(_asksJson), [true, false, false]);
      expect(forum.requests[1].uri.queryParameters, Map.of(forum.requests[0].uri.queryParameters)..remove('tsdmapp'));
      expect(forum.requests.map((e) => e.uri.queryParameters[AntitheftDecoder.dsignKey]), [null, null, sign]);
    }

    test('the post of a notice', () async {
      const tid = '1253561';
      final forum = guarded(tid, _read('tsdmapp/thread_plain.html').replaceAll('9199345', tid));
      _use(forum);
      final cubit = NotificationDetailCubit(notificationRepository: NotificationRepository());
      addTearDown(cubit.close);
      await cubit.fetchDetail('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=$tid&pid=3954');
      expect(cubit.state.status, NotificationDetailStatus.success);
      expect(cubit.state.post?.postID, '3954');
      expectSolved(forum, tid);
    });

    test('the poll card', () async {
      const tid = '1253566';
      final page = _threadPage(
        '<div id="postlist"><div id="post_78025860"><table><tr><td class="plc">'
        '${_read('poll_voted_x5.html')}</td></tr></table></div></div>',
        tid: int.parse(tid),
      );
      final forum = guarded(tid, page.replaceAll('1266029', tid));
      _use(forum);
      final poll = await PollRepository.network(
        getIt.get<NetClientProvider>(),
      ).fetch('$baseUrl/forum.php?mod=redirect&goto=findpost&pid=78025860', 1000);
      expect(poll.availability, PollAvailability.voted);
      expect(poll.options, hasLength(5));
      expectSolved(forum, tid);
    });

    test('opening a draft', () async {
      const tid = '1207901';
      final draft = (await DraftRepository((_) async => draftList(tid: tid)).load(1000)).entries.single;
      final thread = _threadPage(_bodyOf(draftThread()).replaceAll('tid=123', 'tid=$tid'), tid: int.parse(tid));
      final forum = guarded(tid, thread);
      _use(forum);
      final target = await DraftRepository.network(getIt.get<NetClientProvider>()).resolve(draft, 1000);
      expect(target, (fid: '4', tid: tid, pid: '456'));
      expectSolved(forum, tid);
    });

    test('the thread page itself; later JSON mode requests carry the sign and get the thread', () async {
      const tid = '1183160';
      final forum = guarded(tid, _read('tsdmapp/thread_plain.html').replaceAll('9199345', tid));
      _use(forum);
      final first = _right(await ThreadRepository().fetchThread(tid: tid).run());
      expect(first.querySelector('#post_3954'), isNotNull);
      expectSolved(forum, tid);

      final again = _right(await ThreadRepository().fetchThread(tid: tid).run());
      expect(again.querySelector('#post_3954'), isNotNull);
      expect(forum.requests, hasLength(4));
      expect(_asksJson(forum.requests.last), isTrue);
      expect(
        forum.requests.last.uri.queryParameters[AntitheftDecoder.dsignKey],
        forum.requests[2].uri.queryParameters[AntitheftDecoder.dsignKey],
      );
    });

    test('a thread answer without the posts: the web page instead (challenge, failed build, empty body)', () async {
      final html = _read('tsdmapp/thread_plain.html');
      for (final (label, answer) in [
        ('the challenge', _json(_challengedAnswer)),
        (
          'the challenge, a script left',
          _json({
            ..._challengedAnswer,
            'document': '${_challengedAnswer['document']}<script type="text/javascript">var x = 1;</script>',
          }),
        ),
        ('a failed build', _json({'ok': 0, 'error': 'internal'})),
        ('an empty body', _json('')),
      ]) {
        final forum = _Forum((o) => _asksJson(o) ? answer : _html(html));
        _use(forum);
        final doc = _right(await ThreadRepository().fetchThread(tid: '9199345').run());
        expect(doc.querySelector('#post_3954'), isNotNull, reason: label);
        expect(forum.requests.map(_asksJson), [true, false], reason: label);
      }
    });

    test('a guest served the thread cache: the posts of the answer are read, the thread asked once', () async {
      // `viewthread_loadcache` prints the cached page and ends the request before the thread is built, as the
      // challenge does: the plugin answers `unknown`, but its document holds the whole post list.
      final html = _read('tsdmapp/thread_plain.html').replaceAll("discuz_uid = '31'", "discuz_uid = '0'");
      final cached = <String, Object?>{
        'ok': 0,
        'error': 'unknown',
        'head': pageHeadOf(html, title: true),
        'document': pageDocumentOf(html, 'viewthread'),
      };
      expect(tsdmAppAnswerWithoutContent(cached), isFalse);
      expect(tsdmAppAnswerWithoutContent(_challengedAnswer), isTrue);

      final forum = _Forum((o) => _asksJson(o) ? _json(cached) : _html(html));
      _use(forum);
      final doc = _right(await ThreadRepository().fetchThread(tid: '9199345').run());
      final info = parseThreadDocument(doc, 1);
      expect(info.tid, '9199345');
      expect(info.postList.map((e) => e.postID), contains('3954'));
      expect(forum.requests, hasLength(1));
      expect(_asksJson(forum.requests.single), isTrue);

      // The post of a notice, through the findpost redirect.
      final redirected = _Forum(
        (_) => _json(cached, redirectTo: '$baseUrl/forum.php?mod=viewthread&tid=9199345&page=1&tsdmapp=json#pid3954'),
      );
      _use(redirected);
      final cubit = NotificationDetailCubit(notificationRepository: NotificationRepository());
      addTearDown(cubit.close);
      await cubit.fetchDetail('$baseUrl/forum.php?mod=redirect&goto=findpost&ptid=9199345&pid=3954');
      expect(cubit.state.status, NotificationDetailStatus.success);
      expect(cubit.state.post?.postID, '3954');
      expect(redirected.requests, hasLength(1));
    });

    test('a forum message, the thread or another page is the answer: not asked again', () async {
      final denied = _threadPage('<div id="messagetext" class="alert_error"><p>Synthetic notice</p></div>');
      for (final (url, answer) in [
        ('$baseUrl/forum.php?mod=viewthread&tid=1', _json(pageAnswerOf(denied, 'viewthread'))),
        (
          '$baseUrl/forum.php?mod=viewthread&tid=1',
          _json(pageAnswerOf(_read('tsdmapp/thread_plain.html'), 'viewthread')),
        ),
        ('$baseUrl/home.php?mod=space&do=notice', _json({'ok': 0, 'error': 'unknown', 'document': ''})),
      ]) {
        final forum = _Forum((_) => answer);
        await _client(forum).get(withTsdmAppJson(url)).run();
        expect(forum.requests, hasLength(1), reason: url);
      }

      RequestOptions get(String url) => RequestOptions(path: withTsdmAppJson(url));
      const thread = '$baseUrl/forum.php?mod=viewthread&tid=1';
      expect(AntitheftInterceptor.hidesChallenge(get(thread), _challengedAnswer), isTrue);
      expect(AntitheftInterceptor.hidesChallenge(get(thread), jsonEncode(_challengedAnswer)), isTrue);
      expect(
        AntitheftInterceptor.hidesChallenge(
          get('$baseUrl/forum.php?mod=redirect&goto=findpost&pid=2'),
          _challengedAnswer,
        ),
        isTrue,
      );
      expect(AntitheftInterceptor.hidesChallenge(RequestOptions(path: thread), _challengedAnswer), isFalse);
      expect(
        AntitheftInterceptor.hidesChallenge(
          RequestOptions(path: withTsdmAppJson(thread), method: 'POST'),
          _challengedAnswer,
        ),
        isFalse,
      );
      expect(
        AntitheftInterceptor.hidesChallenge(
          get('https://example.com/forum.php?mod=viewthread&tid=1'),
          _challengedAnswer,
        ),
        isFalse,
      );
      expect(AntitheftInterceptor.hidesChallenge(get(thread), _read('antitheft/1253561.html')), isFalse);
    });
  });

  group('friends (plugin 1.6.0)', () {
    for (final (name, owner) in [
      ('friend_list_x5.html', 'Bob'),
      ('friend_list_last_x5.html', 'Bob'),
      ('friend_list_empty_x5.html', 'Alice'),
      ('friend_list_privacy_x5.html', null),
    ]) {
      test('$name: same list, count, next page, owner and notice', () async {
        final view = await _sameWithEachPlugin(
          _read(name),
          'friend',
          () async => _right(await const FriendRepository().fetchPage(FriendRepository.listUrl(uid: '1001')).run()),
          (p) => [
            p.items.map((e) => e.toMap()).toList(),
            p.nextPageUrl,
            p.totalCount,
            p.ownerName,
            p.message,
            p.needLogin,
          ],
        );
        final page = view! as List<Object?>;
        expect(page[3], owner);
        if (name != 'friend_list_privacy_x5.html' && name != 'friend_list_empty_x5.html') {
          expect(page[0], isNotEmpty);
        }
      });
    }

    test('the @ candidates read the own list in JSON mode; the add-friend dialog stays AJAX', () async {
      final html = _read('friend_list_last_x5.html');
      final forum = _Forum(
        (o) => o.method == 'GET' && !o.uri.query.contains('inajax')
            ? _json(pageAnswerOf(html, 'friend'))
            : _html('<?xml version="1.0" encoding="utf-8"?><root><![CDATA[]]></root>'),
      );
      _use(forum);
      final friends = _right(await MentionRepository().loadOwnFriends(selfUid: '1000').run());
      expect(friends.friends, isNotEmpty);
      expect(forum.requests.every(_asksJson), isTrue);

      await const FriendRepository().fetchAddFriendForm('1001').run();
      expect(forum.requests.last.uri.queryParameters, containsPair('inajax', '1'));
      expect(_asksJson(forum.requests.last), isFalse);
    });
  });

  group('checkin', () {
    /// The forum: the API's [checkin] and [status] answers (null: an older plugin without `status`), the checkin
    /// page and the result of the post.
    _Forum forum(Map<String, Object?> checkin, {Object? status, int statusCode = 200}) => _Forum((o) {
      final q = o.uri.queryParameters;
      if (q['id'] == 'tsdmapp:api') {
        return switch (q['action']) {
          'checkin' => _json(checkin),
          'status' => _json(status ?? {'ok': 0, 'error': 'action'}, status: statusCode),
          _ => fail('unexpected action ${q['action']}'),
        };
      }
      return o.method == 'POST' ? _html(_checkinSuccess) : _html(_checkinPage);
    });

    Future<CheckinResult> run(_Forum f) => doCheckin(_client(f), CheckinFeeling.happy, 'hi').run();

    bool readsPage(_Forum f) => f.gets.any((e) => e.uri.queryParameters['id'] == 'dsu_paulsign:sign');

    test('status tells the form hash: the form is posted without reading the checkin page', () async {
      final f = forum(_checkinAnswer(), status: _statusAnswer());
      expect(await run(f), isA<CheckinResultSuccess>());
      expect(readsPage(f), isFalse);
      expect(f.apiRequests.map((e) => e.uri.queryParameters['action']), ['checkin', 'status']);
      expect(f.requests.last.method, 'POST');
      expect(Uri.splitQueryString(f.bodies.last!)['formhash'], 'a1b2c3d4');
    });

    test('the checkin answer tells it (plugin 1.6.0): status is not asked', () async {
      final f = forum(_checkinAnswer(formHash: '0f0e0d0c'));
      expect(await run(f), isA<CheckinResultSuccess>());
      expect(readsPage(f), isFalse);
      expect(f.apiRequests, hasLength(1));
      expect(Uri.splitQueryString(f.bodies.last!)['formhash'], '0f0e0d0c');
    });

    test('the form posted is the one the checkin page path posts', () async {
      final direct = forum(_checkinAnswer(), status: _statusAnswer());
      final viaPage = forum(_checkinAnswer(), status: _statusAnswer(formHash: null));
      await run(direct);
      expect(await run(viaPage), isA<CheckinResultSuccess>());
      expect(readsPage(viaPage), isTrue);
      final (a, b) = (direct.requests.last, viaPage.requests.last);
      expect(a.method, b.method);
      expect(a.uri, b.uri);
      expect(a.contentType, b.contentType);
      expect(direct.bodies.last, viaPage.bodies.last);
      expect(_asksJson(a), isFalse);
      expect(Uri.splitQueryString(a.uri.query), containsPair('inajax', '1'));
    });

    test('no usable hash from the API: the checkin page is read as before', () async {
      for (final (label, status, code) in [
        ('a plugin without status', null, 200),
        ('a guest session', _statusAnswer(uid: 0), 200),
        ('too soon', {'ok': 0, 'error': 'busy', 'retry_after': 3}, 429),
        ('a malformed hash', _statusAnswer(formHash: '<script>'), 200),
      ]) {
        final f = forum(_checkinAnswer(), status: status, statusCode: code);
        expect(await run(f), isA<CheckinResultSuccess>(), reason: label);
        expect(readsPage(f), isTrue, reason: label);
        expect(Uri.splitQueryString(f.bodies.last!)['formhash'], 'a1b2c3d4', reason: label);
      }
    });
  });
}
