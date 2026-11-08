/// Roadmap: fewer requests.
///
/// * Poll card: the thread page already holds the poll form (`form#poll` in the first floor), the formhash of the
///   account the page was served to included. Every poll card asked the forum for the whole thread page again when it
///   was created (twice: the account status replayed to its new listener loaded it once more), and again on every
///   account status, although the thread page reloads for a new account since 1.37.0 and builds its floors afresh.
///   The card now shows the form of the page; it asks the forum only when the page does not hold it, holds it for
///   another account, was served as to a guest while an account is in use (its session had expired, or the floors a
///   failed reload puts back were read before a login), or was read before a vote of the account (such floors too).
///   A reload for another account failing at once puts its floors back without building them again: their card asks
///   for the poll of the account in use itself, once. Voting still asks once for the results, and so does a login of
///   the account in use while the card asks to log in, from the card or elsewhere, also one ending while the card was
///   asking (its session had expired; the account in use stays the same, nothing else reloads).
/// * The points pages are asked in the JSON mode of the forum's app API (`tsdmapp=json`, plugin 1.7.0); an older
///   plugin ignores the parameter and the web page comes back. Both give the same. An answer without a page is a failed
///   load. The bank pages stay web pages: plugin 1.7.0 does not handle the bank (`bank_ane`), the parameter would only
///   stay in the request the bank plugin reads.
///
/// The forum pages are synthetic (grounded in the Discuz templates), no real account or network.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/utils/account_changes.dart';
import 'package:tsdm_client/features/bank/models/bank_data.dart';
import 'package:tsdm_client/features/bank/repository/bank_repository.dart';
import 'package:tsdm_client/features/blocking/cubit/user_block_cubit.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/points/models/models.dart';
import 'package:tsdm_client/features/points/repository/model/models.dart';
import 'package:tsdm_client/features/points/repository/points_repository.dart';
import 'package:tsdm_client/features/points/utils/parse_points.dart';
import 'package:tsdm_client/features/poll/cubit/poll_cubit.dart';
import 'package:tsdm_client/features/poll/models/forum_poll.dart';
import 'package:tsdm_client/features/poll/repository/poll_repository.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/view/thread_page.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/poll_card.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

import 'tsdmapp_page_cut.dart';

const _alice = UserLoginInfo(username: 'Alice', uid: 1000);
const _bob = UserLoginInfo(username: 'Bob', uid: 1001);

const _tid = 1264975;

/// The check page of the account switch as served to a logged-in [user].
String _authedPage(UserLoginInfo user) =>
    '<html><body><div id="inner_stat"><strong><a href="home.php?mod=space&amp;uid=${user.uid}">${user.username}</a> '
    '</strong></div><input type="hidden" name="formhash" value="XXXXXXXX" /></body></html>';

/// Cookie row in the format the persistent cookie jar reads back: the auth cookie is sent with every request.
Map<String, String> _cookieOf(UserLoginInfo user) => {
  '.index': '["$baseHost"]',
  baseHost: '{"/":{"Ystv_2132_auth":"Ystv_2132_auth=${user.username!.toLowerCase()}; Path=/;_crt=1"}}',
};

/// The poll form of test 083 ([name]: `multiple` open for votes, `voted` with results) for the thread of this test,
/// with [formHash]; without the identity script of the fixture, the page declares it.
String _pollForm(String name, String formHash) =>
    File(
          'test/data/poll_${name}_x5.html',
        )
        .readAsStringSync()
        .replaceFirst(RegExp('<script>.*?</script>'), '')
        .replaceAll('XXXXXXXX', formHash)
        .replaceAll(
          'tid=1266029',
          'tid=$_tid',
        );

/// A thread page served to [uid] with the poll form [poll] in its first floor, open for replies.
String _threadHtml(int uid, String poll) =>
    '''
<!DOCTYPE html>
<html><head><title>Poll title - Powered by Discuz!</title>
<link href="$baseUrl/forum.php?mod=viewthread&amp;tid=$_tid" rel="canonical" />
<script type="text/javascript">var STYLEID = '2', STATICURL = 'static/', discuz_uid = '$uid', cookiepre = 'x_';</script>
</head><body>
<div id="wp" class="wp">
<div id="postlist"><h1 class="ts"><span id="thread_subject">Poll title</span></h1><div class="bm">
<div id="post_1"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&amp;goto=findpost&amp;pid=1"><em>1</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1000" class="xi2">Alice</a></div></div>
<div class="pct"><div class="pcb"><div class="pcbs">
<table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_1">floor 1 text</td></tr></table>
$poll
</div></div></div></td>
</tr></tbody></table></div>
</div></div>
<form method="post" autocomplete="off" name="modactions" id="modactions"></form>
<form method="post" id="fastpostform" action="forum.php?mod=post&amp;action=reply&amp;fid=4&amp;tid=$_tid&amp;replysubmit=yes">
<input type="hidden" name="formhash" value="${uid == 0 ? 'none' : 'hashOf$uid'}" />
<input type="hidden" name="posttime" value="1760000000" />
<input type="hidden" name="subject" value="" />
<div class="area"><textarea name="message"></textarea></div>
</form>
</div>
<div id="ft" class="wp cl">Footer</div>
</body></html>''';

/// The forum of the thread: its page for the account whose cookie came with the request, in JSON mode when [json] (as
/// the app API plugin answers it) and asked for; takes votes. Records every request.
final class _PollForum implements HttpClientAdapter {
  _PollForum({this.json = false});

  final bool json;

  /// The accounts that voted.
  final voted = <int>{};

  /// Every request, with the form it posted.
  final requests = <RequestOptions>[];
  final bodies = <String?>[];

  /// Holds the answers back while set.
  Completer<void>? gate;

  /// Accounts whose session the forum dropped: what their cookie asks for meanwhile gets the pages of a guest (issue
  /// #25), also when the answer comes after a new login.
  final guests = <int>{};

  /// Loads of the thread page itself fail (no connection) while set; the post of a poll card still answers.
  bool failThreadLoads = false;

  /// Thread page loads of the thread page itself.
  int get threadLoads =>
      requests.where((r) => r.method == 'GET' && r.uri.queryParameters['mod'] == 'viewthread').length;

  /// Thread pages asked for by a poll card (the `findpost` redirect of its floor).
  int get pollLoads => requests.where((r) => r.method == 'GET' && r.uri.queryParameters['goto'] == 'findpost').length;

  /// The votes posted, as their forms.
  List<Map<String, String>> get votes => [
    for (final (i, r) in requests.indexed)
      if (r.method == 'POST' && r.uri.queryParameters['action'] == 'votepoll') Uri.splitQueryString(bodies[i]!),
  ];

  static int _uidOf(RequestOptions options) {
    final cookie = '${options.headers['cookie'] ?? options.headers['Cookie'] ?? ''}';
    return cookie.contains('auth=bob') ? _bob.uid! : (cookie.contains('auth=alice') ? _alice.uid! : 0);
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    bodies.add(requestStream == null ? null : utf8.decode(await requestStream.expand((e) => e).toList()));
    // The session the request carried decides, also when its answer is held back.
    final uid = guests.contains(_uidOf(options)) ? 0 : _uidOf(options);
    if (gate != null) {
      await gate!.future;
    }
    if (failThreadLoads && options.method == 'GET' && options.uri.queryParameters['mod'] == 'viewthread') {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    if (options.method == 'POST') {
      expect(options.uri.queryParameters['action'], 'votepoll', reason: 'the only form posted here is the vote');
      // A form asks the forum's app API for its result (plugin 2.6.0); the vote itself is posted as before.
      expect(options.uri.queryParameters['tsdmapp'], 'json', reason: 'a form asks for its result');
      voted.add(uid);
      return ResponseBody.fromString(
        '<html><body>Accepted</body></html>',
        200,
        headers: {
          Headers.contentTypeHeader: ['text/html; charset=utf-8'],
        },
      );
    }
    final poll = uid == 0 ? 'guest' : (voted.contains(uid) ? 'voted' : 'multiple');
    final html = _threadHtml(uid, _pollForm(poll, 'hashOf$uid'));
    final asJson = json && options.uri.queryParameters['tsdmapp'] == 'json';
    return ResponseBody.fromString(
      asJson ? pageAnswerOf(html, 'viewthread') : html,
      200,
      headers: {
        Headers.contentTypeHeader: [if (asJson) 'application/json; charset=utf-8' else 'text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The forum as seen by the isolated client of the account switch: the check page of Bob.
final class _SwitchAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    _authedPage(_bob),
    200,
    headers: {
      Headers.contentTypeHeader: ['text/html; charset=utf-8'],
    },
  );

  @override
  void close({bool force = false}) {}
}

/// Avatars are not downloaded in tests.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// Notification bloc holding a fixed state; the thread page only reads it.
final class _Notifications extends Fake implements NotificationBloc {
  @override
  void add(NotificationEvent event) {}

  @override
  NotificationState get state => const NotificationState(status: NotificationStatus.success);

  @override
  Stream<NotificationState> get stream => const Stream.empty();

  @override
  bool get isClosed => false;

  @override
  Future<void> close() async {}
}

/// Frames with real time in between: the database and its streams answer on the real event loop.
Future<void> _settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Lets the snack bar and the database stream timers fire before the framework checks for pending timers.
Future<void> _dispose(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

/// The frame of a Discuz X5 page served to [uid] around [main] (`#pt`, `#ct`…): the head declaring `discuz_uid`, the
/// header user node and the footer, which the JSON answer drops.
String _framed(String main, {int uid = 1000}) =>
    '''
<!DOCTYPE html>
<html><head><meta charset="utf-8" /><title>Synthetic - Powered by Discuz!</title>
<script type="text/javascript">var STYLEID = '2', STATICURL = 'static/', discuz_uid = '$uid', cookiepre = 'x_';</script>
</head><body>
<div id="hd"><div class="wp"><div class="hdc cl"><div id="um">
<p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=$uid" target="_blank" title="访问我的空间">Alice</a></strong></p>
<p><a href="plugin.php?id=bank_ane:bank">银行</a> <a href="home.php?mod=spacecp&amp;ac=credit&amp;showcredit=1">积分: 31669</a></p>
</div></div></div></div>
<div id="wp" class="wp">
$main
</div>
<div id="ft" class="wp cl">Footer<script src="home.php?mod=spacecp&amp;ac=pm&amp;op=checknewpm&amp;rand=1" type="text/javascript"></script></div>
</body></html>''';

/// The settings column of a `home.php?mod=spacecp` page (the template `spacecp_footer`), beside the main column.
const _spacecpSide = '''
<div class="appl"><div class="tbn"><h2 class="mt bbda">设置</h2><ul>
<li><a href="home.php?mod=spacecp&amp;ac=profile">个人资料</a></li>
<li class="a"><a href="home.php?mod=spacecp&amp;ac=credit">积分</a></li>
</ul></div></div>''';

/// A row of the credit log table: [operation], [change] of 天使币, [time].
String _creditRow(String operation, String change, String time) =>
    '''
<tr><td><a href="home.php?mod=spacecp&amp;ac=credit&amp;op=log&amp;optype=RPC">$operation</a></td>
<td>天使币 <span class="${change.startsWith('-') ? 'xg1' : 'xi1'}">$change</span></td><td>天使币 105</td>
<td><a href="forum.php?mod=redirect&amp;goto=findpost&amp;pid=1&amp;ptid=$_tid" target="_blank">Synthetic thread</a></td>
<td>$time</td></tr>''';

/// The credit page `op=base` (templates `spacecp_header`, `spacecp_credit_header`, `spacecp_credit_base`).
final String _creditBase = _framed('''
<div id="pt" class="bm cl"><div class="z"><a href="./" class="nvhm" title="首页">Synthetic</a> <em>&rsaquo;</em>
<a href="home.php?mod=spacecp">设置</a> <em>&rsaquo;</em> 积分</div></div>
<div id="ct" class="ct2_a wp cl">
<div class="mn"><div class="bm bw0">
<h1 class="mt">积分</h1>
<ul class="tb cl"><li class="a"><a href="home.php?mod=spacecp&amp;ac=credit&amp;op=base">我的积分</a></li>
<li><a href="home.php?mod=spacecp&amp;ac=credit&amp;op=log">积分记录</a></li></ul>
<ul class="creditl mtm bbda cl">
<li class="xi1 cl"><em> 天使币: </em>10532  &nbsp; </li>
<li><em> 威望: </em>3 </li>
<li class="cl"><em>积分: </em>31669 <span class="xg1">( <u>总积分</u>=<u>威望</u> )</span></li>
</ul>
<table summary="积分记录" cellspacing="0" cellpadding="0" class="dt mtm">
<caption><h2 class="mbm xs2"><a href="home.php?mod=spacecp&amp;ac=credit&amp;op=log" class="xi2 xs1 xw0 y">查看更多&raquo;</a>积分记录</h2></caption>
<tr><th width="80">操作</th><th width="80">积分变更</th><th width="80">变更后积分</th><th>详情</th><th width="110">变更时间</th></tr>
${_creditRow('评分', '+5', '2026-10-14 08:00')}
${_creditRow('评分', '-2', '2026-10-13 21:30')}
</table>
</div></div>
$_spacecpSide
</div>''');

/// The credit page `op=log` (template `spacecp_credit_log`), page [page] of 3.
String _creditLog({int page = 1}) => _framed('''
<div id="pt" class="bm cl"><div class="z"><a href="./" class="nvhm" title="首页">Synthetic</a> <em>&rsaquo;</em>
<a href="home.php?mod=spacecp">设置</a> <em>&rsaquo;</em> 积分</div></div>
<div id="ct" class="ct2_a wp cl">
<div class="mn"><div class="bm bw0">
<h1 class="mt">积分</h1>
<ul class="tb cl"><li><a href="home.php?mod=spacecp&amp;ac=credit&amp;op=base">我的积分</a></li>
<li class="a"><a href="home.php?mod=spacecp&amp;ac=credit&amp;op=log">积分记录</a></li></ul>
<form method="post" action="home.php?mod=spacecp&amp;ac=credit&amp;op=log">
<div class="exfm" style="margin-top: 0;"><table cellspacing="0" cellpadding="0">
<tr><th>积分:</th><td><span class="ftid"><select id="exttype" name="exttype" class="ps" width="168">
<option value="0">不限</option><option value="1">威望</option><option value="2">天使币</option></select></span></td></tr>
<tr><th>收支:</th><td><span class="ftid"><select id="income" name="income" class="ps" width="168">
<option value="0">不限</option><option value="-1">支出</option><option value="1">收入</option></select></span></td>
<th>操作:</th><td><span class="ftid"><select id="optype" name="optype" class="ps" width="168">
<option value="">不限</option><option value="RPC">评分</option><option value="TRC">任务奖励</option></select></span></td></tr>
</table></div>
<table summary="积分收支" cellspacing="0" cellpadding="0" class="dt">
<tr><th width="80">操作</th><th width="80">积分变更</th><th width="80">变更后积分</th><th>详情</th><th width="110">变更时间</th></tr>
${_creditRow('评分', '+$page', '2026-10-14 08:00')}
${_creditRow('任务奖励', '+10', '2026-10-12 09:15')}
</table>
<input type="hidden" name="op" value="log" /><input type="hidden" name="ac" value="credit" />
<input type="hidden" name="mod" value="spacecp" />
</form>
<div class="pgs cl mtm"><div class="pg">${page == 1 ? '' : '<a href="home.php?mod=spacecp&amp;op=log&amp;ac=credit&amp;page=${page - 1}" class="prev">&nbsp;&nbsp;</a>'}
<strong>$page</strong><a href="home.php?mod=spacecp&amp;op=log&amp;ac=credit&amp;page=${page + 1}">${page + 1}</a>
<label><input type="text" name="custompage" class="px" size="2" title="输入页码，按回车快速跳转" value="$page" /><span title="共 3 页"> / 3 页</span></label>
<a href="home.php?mod=spacecp&amp;op=log&amp;ac=credit&amp;page=${page + 1}" class="nxt">下一页</a></div></div>
</div></div>
$_spacecpSide
</div>''');

/// A bank page (`plugin.php?id=bank_ane:bank…`) of the bank plugin around [content] (its tables and forms, as in tests
/// 120 to 125), with its account column (`div.tbn`: the wallet in the bank's currency).
String _bankPage(String content, {int uid = 1000}) => _framed('''
<div id="pt" class="bm cl"><div class="z"><a href="./" class="nvhm" title="首页">Synthetic</a> <em>&rsaquo;</em>
<a href="plugin.php?id=bank_ane:bank">银行</a></div></div>
<div id="ct" class="wp cl">
<div class="tbn"><h2>账户信息</h2><ul><li><span><b>4321</b> (银行货币)</span><font color="red">示例币:</font></li></ul></div>
$content
</div>''', uid: uid);

const _bankForm = '''
<form method="post" action="plugin.php?id=bank_ane:bank">
<input type="hidden" name="bankid" value="1">
<input type="hidden" name="action" value="cur">
<input type="hidden" name="formhash" value="hashOf1000">
<input type="text" name="banknum">
<input type="radio" name="op" value="in"><input type="radio" name="op" value="out">
<input type="password" name="bankpass">
<button type="submit" name="banksubmit" value="true">提交</button>
</form>''';

final String _bankDirectory = _bankPage('''
<table id="ttt"><thead class="colplural"><tr><td colspan="3"><h2>银行列表</h2></td></tr></thead>
<tbody>
<tr><td>logo</td><td><span>银行名称</span>: <span>Example Bank</span><br>
<span>银行行长</span>: <span>Example Manager</span>,<br><span>银行简介</span>: Example description</td>
<td><a href="plugin.php?id=bank_ane:bank&amp;bankid=1"><em>进入银行</em></a><br><span>(已开户)</span></td></tr>
<tr><td>logo</td><td>银行名称: Another Bank<br>银行行长: Example<br>银行简介: Second description</td>
<td><a href="plugin.php?id=bank_ane:bank&amp;bankid=2">进入银行</a></td></tr>
</tbody></table>''');

final String _bankSavings = _bankPage('''
<table id="ttt"><thead class="colplural"><tr><td><h2>活期储蓄</h2></td></tr></thead><tbody>
<tr><td class="footoperation">您当前的存款金额为 200 ，活期利率为0.1‰，计息时间从2026-01-01开始。</td></tr>
<tr><td>$_bankForm</td></tr>
<tr><td><form><p>您当前可得利息 3 <a href="plugin.php?id=bank_ane:bank&amp;action=unknown">手动结息</a></p></form></td></tr>
<tr><td class="footoperation">注意事项</td></tr><tr><td><p>利率可能变化。</p><p>存取款时自动结息。</p></td></tr>
</tbody></table>''');

/// The own records of bank 1, page 1, with the link to page 2.
final String _bankLogs = _bankPage('''
<table id="ttt"><thead class="colplural"><tr><td><h2>理财日志</h2></td></tr></thead><tbody>
<tr><td>My and received tabs</td></tr><tr><td>Filters</td></tr><tr><td>
<table id="ttt"><tbody>
<tr><td>Info: 示例存款 10 示例币</td><td>Time: 2026-01-01 12:34:56</td><td>Ip: 192.0.2.123</td></tr>
<tr><td>Info: 示例取款 2 示例币</td><td>Time: 2026-01-02 12:34:56</td><td>Ip: 2001:db8::1</td></tr>
</tbody></table>
</td></tr><tr><td><div class="pg">
<a class="nxt" href="plugin.php?id=bank_ane:bank&amp;bankid=1&amp;action=log&amp;show=0&amp;page=2">下一页</a></div></td></tr>
</tbody></table>''');

/// A service page of bank 1 (the remittance), with its form.
final String _bankRemittance = _bankPage('''
<table id="ttt"><thead><tr><td><h2>账户汇款</h2></td></tr></thead><tbody>
<tr><td class="footoperation">当前汇款手续费率为2‰，欢迎使用本行汇款业务。</td></tr>
<tr><td><form method="post" action="plugin.php?id=bank_ane:bank">
<input type="hidden" name="bankid" value="1"><input type="hidden" name="action" value="chg">
<input type="hidden" name="op" value="ok"><input type="hidden" name="formhash" value="hashOf1000">
<input type="text" name="banknum"><input type="text" name="touser"><input type="password" name="bankpass">
<button type="button" name="taxcheck" value="true">费用计算</button>
<button type="submit" name="banksubmit" value="true">提 交</button></form></td></tr>
<tr><td class="footoperation">账户记录</td></tr>
<tr><td><table id="ttt"><tr><td><br><center>还没有相关数据。</center><br></td></tr></table></td></tr>
<tr><td class="footoperation">注意事项</td></tr><tr><td>请核对操作，提交后查看记录。</td></tr>
</tbody></table>''');

/// The forum of the points and bank pages: answers every GET with [page] for the url asked, as the web page, or, when
/// the app API plugin 1.7.0 handles the page ([json]), as it answers it in JSON mode (page type [type]); a form post
/// with "accepted".
final class _PageForum implements HttpClientAdapter {
  _PageForum(this.page, {this.json = false, this.type});

  final String Function(Uri uri) page;
  final bool json;
  final String? type;

  /// Answer every GET with this body instead, as JSON.
  String? jsonAnswer;

  final requests = <RequestOptions>[];

  List<RequestOptions> get gets => requests.where((r) => r.method == 'GET').toList();

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final String body;
    final bool asJson;
    if (options.method == 'POST') {
      (body, asJson) = ('<html><body>Accepted</body></html>', false);
    } else if (jsonAnswer != null) {
      (body, asJson) = (jsonAnswer!, true);
    } else {
      final html = page(options.uri);
      asJson = json && options.uri.queryParameters['tsdmapp'] == 'json';
      body = asJson ? pageAnswerOf(html, type!) : html;
    }
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: [if (asJson) 'application/json; charset=utf-8' else 'text/html; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

NetClientProvider _pageClient(_PageForum forum) =>
    NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum);

/// Run [fetch] against the web page and the JSON answer of plugin 1.7.0 of [page]: both give the same [view], every
/// GET asks the JSON mode. Returns the view.
Future<Object?> _sameFromBoth<T>(
  String Function(Uri uri) page,
  String type,
  Future<T> Function(NetClientProvider client) fetch,
  Object? Function(T value) view,
) async {
  final views = <Object?>[];
  for (final json in [false, true]) {
    final forum = _PageForum(page, json: json, type: type);
    views.add(view(await fetch(_pageClient(forum))));
    expect(forum.gets, isNotEmpty);
    for (final r in forum.gets) {
      expect(r.uri.queryParameters['tsdmapp'], 'json', reason: '${r.uri}');
    }
  }
  expect(views.last, views.first, reason: 'the JSON answer gives what the web page gives');
  return views.first;
}

/// What a points page shows of [change].
String _change(PointsChange change) =>
    '${change.operation}|${change.operationFilterUrl}|${change.pointsChangeType.name}|${change.changeMap}|'
    '${change.detail}|${change.redirectUrl}|${change.time}';

/// What the plugin answers when it failed to build the page.
const _withoutPage = '{"ok":0,"error":"internal"}';

/// Choose the first option of the card and send the vote.
Future<void> _vote(WidgetTester tester) async {
  await tester.tap(_inCard(find.byType(CheckboxListTile)).first);
  await tester.pump();
  await tester.tap(_inCard(find.byType(FilledButton)));
  await _settle(tester);
}

/// A forum of the thread for the app's default client, bound to the account in use like the app's.
_PollForum _useForum({bool json = false}) {
  final forum = _PollForum(json: json);
  getIt.registerFactory<NetClientProvider>(
    () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
  );
  return forum;
}

/// The poll of the first floor of the thread page served to [uid], as the thread parser keeps it.
PostPoll _pagePoll(int uid, {String name = 'multiple'}) => parseThreadDocument(
  parseHtmlDocument(_threadHtml(uid, _pollForm(name, 'hashOf$uid'))),
  1,
).postList.single.poll!;

final Finder _card = find.byType(PollCard);

Finder _inCard(Finder matching) => find.descendant(of: _card, matching: matching);

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late AuthenticationRepository auth;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.en);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<ImageCacheProvider>(
        ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
      );
    await settings.init();
    // Alice is logged in on this device, Bob is saved too.
    for (final user in [_alice, _bob]) {
      await storage.saveCookie(username: user.username!, uid: user.uid!, cookie: _cookieOf(user));
    }
    await settings.setValue<int>(SettingsKeys.loginUid, 1000);
    await settings.setValue<String>(SettingsKeys.loginUsername, 'Alice');
    getIt.registerSingleton<CookieProvider>(CookieProvider(_alice, _cookieOf(_alice)));
    auth = AuthenticationRepository(
      user: _alice,
      clientFactory: (cookie) => NetClientProvider.buildNoCookie(
        dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _SwitchAdapter(),
        cookie: cookie,
      ),
    );
    // The account status of a running app: a new listener gets it at once.
    final login = await auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run();
    expect(login.isRight(), isTrue, reason: '$login');
  });

  tearDown(() async {
    // The tests vote as the same accounts in the same posts: the vote of one test is not one of the next.
    PollCubit.forgetVotesSent();
    await auth.dispose();
    await getIt.get<ImageCacheProvider>().dispose();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  group('poll card in the thread page', () {
    late SettingsBloc settingsBloc;
    late UserBlockRepository blocks;

    setUp(() {
      settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
      blocks = UserBlockRepository(storage);
      ThreadAuthorCache.clear();
    });

    tearDown(() async {
      await settingsBloc.close();
      await blocks.dispose();
    });

    /// The thread page; `/other` is a plain page to push above it. Returns the router.
    Future<GoRouter> pumpThread(WidgetTester tester, _PollForum forum) async {
      // Tall enough for the floor and the whole card.
      tester.view
        ..physicalSize = const Size(1000, 3000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final info = NotificationInfoRepository();
      final counts = NotificationStateCubit(info);
      final cubit = UserBlockCubit(
        repository: blocks,
        currentUid: () => auth.effectiveCurrentUid,
        authStatus: auth.status,
      );
      final history = ThreadVisitHistoryBloc(ThreadVisitHistoryRepo(storage));
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const ThreadPage(
              threadID: '$_tid',
              findPostID: null,
              pageNumber: '1',
              overrideReverseOrder: false,
              overrideWithExactOrder: null,
            ),
          ),
          GoRoute(
            path: '/other',
            builder: (_, _) => const Scaffold(body: Center(child: Text('other page'))),
          ),
          GoRoute(
            path: ScreenPaths.login,
            name: ScreenPaths.login,
            builder: (_, _) => const Scaffold(body: Center(child: Text('login page'))),
          ),
        ],
      );
      addTearDown(() async {
        router.dispose();
        await cubit.close();
        await history.close();
        await info.dispose();
        await counts.close();
      });
      await tester.pumpWidget(
        TranslationProvider(
          child: MultiRepositoryProvider(
            providers: [
              RepositoryProvider<AuthenticationRepository>.value(value: auth),
              RepositoryProvider<FavoriteRepository>(create: (_) => FavoriteRepository()),
            ],
            child: MultiBlocProvider(
              providers: [
                BlocProvider<SettingsBloc>.value(value: settingsBloc),
                BlocProvider<UserBlockCubit>.value(value: cubit),
                BlocProvider<NotificationBloc>.value(value: _Notifications()),
                BlocProvider<NotificationStateCubit>.value(value: counts),
                BlocProvider<ThreadVisitHistoryBloc>.value(value: history),
              ],
              child: MaterialApp.router(routerConfig: router, scaffoldMessengerKey: snackbarKey),
            ),
          ),
        ),
      );
      await _settle(tester);
      expect(forum.threadLoads, 1, reason: 'opening the page loads it once');
      return router;
    }

    Future<void> switchToBob(WidgetTester tester) async {
      final result = await tester.runAsync(() => auth.switchUser(_bob).run());
      expect(result!.isRight(), isTrue, reason: '$result');
      await _settle(tester);
    }

    for (final json in [false, true]) {
      final mode = json ? 'JSON answer' : 'web page';
      testWidgets('$mode: the card shows the form of the page, no request of its own; a vote asks once', (
        tester,
      ) async {
        final forum = _useForum(json: json);
        await pumpThread(tester, forum);
        expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5), reason: 'the form of the page, open');
        expect(_inCard(find.text('Selected 0 / 2')), findsOneWidget);
        expect(forum.pollLoads, 0, reason: 'the page holds the form, the card asks nothing');

        await _vote(tester);
        expect(forum.votes, hasLength(1));
        expect(forum.votes.single['formhash'], 'hashOf1000', reason: 'the formhash of the page, served to Alice');
        expect(forum.votes.single['pollanswers[0]'], '40028');
        expect(forum.pollLoads, 1, reason: 'the results are asked once after the vote');
        expect(_inCard(find.text('1 · 50%')), findsNWidgets(2), reason: 'the results of the answer');
        expect(_inCard(find.text(t.pollVoting.voted)), findsOneWidget);
        expect(_inCard(find.text(t.pollVoting.unconfirmed)), findsNothing);
        expect(forum.threadLoads, 1);
        await _dispose(tester);
      });
    }

    testWidgets('an account switch reloads the thread page only: the card shows its form, no request of its own', (
      tester,
    ) async {
      final forum = _useForum(json: true);
      await pumpThread(tester, forum);
      expect(forum.pollLoads, 0);

      await switchToBob(tester);
      expect(forum.threadLoads, 2, reason: 'the thread page reloads for Bob');
      expect(forum.pollLoads, 0, reason: 'no card asks for the page the thread page just loaded');
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));

      await _vote(tester);
      expect(forum.votes.single['formhash'], 'hashOf1001', reason: "Bob's vote goes out with Bob's formhash");
      expect(forum.voted, {_bob.uid});
      expect(forum.pollLoads, 1);
      expect(_inCard(find.text('1 · 50%')), findsNWidgets(2));
      await _dispose(tester);
    });

    testWidgets('a thread page under another page: no request while covered, the reload once shown again', (
      tester,
    ) async {
      final forum = _useForum(json: true);
      final router = await pumpThread(tester, forum);
      unawaited(router.push('/other'));
      await _settle(tester);

      await switchToBob(tester);
      expect(forum.threadLoads, 1, reason: 'not reloaded while covered');
      expect(forum.pollLoads, 0, reason: 'nor the poll');

      router.pop();
      await _settle(tester);
      expect(forum.threadLoads, 2);
      expect(forum.pollLoads, 0);
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));
      await _dispose(tester);
    });

    testWidgets('floors put back after a failed reload: the poll stays voted, not open for a second vote', (
      tester,
    ) async {
      final forum = _useForum(json: true);
      await pumpThread(tester, forum);
      await _vote(tester);
      expect(_inCard(find.text(t.pollVoting.voted)), findsOneWidget);
      expect(forum.pollLoads, 1);

      // The reload fails after a while: the floors read before the vote go back on screen, their poll form still open.
      final bloc = tester.element(_card).read<ThreadBloc>();
      forum
        ..failThreadLoads = true
        ..gate = Completer<void>();
      bloc.add(ThreadRefreshRequested());
      await _settle(tester);
      expect(_card, findsNothing, reason: 'no floors while the page reloads');
      forum.gate!.complete();
      forum.gate = null;
      await _settle(tester);
      expect(forum.threadLoads, 2);
      expect((bloc.state.status, bloc.state.postList.length), (ThreadStatus.failure, 1), reason: 'the floor is back');
      expect(_inCard(find.byType(CheckboxListTile)), findsNothing, reason: 'the form read before the vote');
      expect(_inCard(find.byType(FilledButton)), findsNothing);
      expect(_inCard(find.text(t.pollVoting.voted)), findsOneWidget);
      expect(forum.pollLoads, 2, reason: 'the card asks for the poll once instead');
      expect(forum.votes, hasLength(1));
      await _dispose(tester);
    });

    // Integration review of the fewer-requests branch: the card showed the form of a page served to a guest to the
    // account now in use, "log in to vote" for an account logged in, and asked nothing. Since the offline threads
    // review (6fc17b2e+f40ce252) a failed reload for another account never puts the floors of the previous one back:
    // no card at all until the page of Bob is loaded, then his form.
    for (final (name, dropped) in [
      ('read as a guest, then Bob logged in', false),
      ('read with the session of Alice the forum dropped, then switched to Bob', true),
    ]) {
      testWidgets('guest floors after a failed reload for Bob ($name): not put back, then the form of Bob', (
        tester,
      ) async {
        final forum = _useForum(json: true);
        if (dropped) {
          forum.guests.add(_alice.uid!);
        } else {
          final forgot = await tester.runAsync(() => auth.forgetCurrentUser().run());
          expect(forgot!.isRight(), isTrue, reason: '$forgot');
        }
        await pumpThread(tester, forum);
        expect(_inCard(find.widgetWithText(TextButton, t.pollVoting.loginRequired)), findsOneWidget);
        final asked = forum.pollLoads;
        final bloc = tester.element(_card).read<ThreadBloc>();

        // The reload for Bob fails after a while: the floors read before are of another account, not put back.
        forum
          ..failThreadLoads = true
          ..gate = Completer<void>();
        await switchToBob(tester);
        expect(_card, findsNothing, reason: 'no floors while the page reloads');
        forum.gate!.complete();
        forum.gate = null;
        await _settle(tester);
        expect((bloc.state.status, bloc.state.postList.length), (ThreadStatus.failure, 0), reason: 'not put back');
        expect(_card, findsNothing);
        expect(forum.threadLoads, 2);
        expect(forum.pollLoads, asked, reason: 'no card, nothing asked');

        // Retried: the page of Bob, his form.
        forum.failThreadLoads = false;
        await tester.tap(find.text(t.general.retry));
        await _settle(tester);
        expect(forum.threadLoads, 3);
        expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5), reason: 'open for the vote of Bob');
        expect(_inCard(find.widgetWithText(TextButton, t.pollVoting.loginRequired)), findsNothing);
        await _vote(tester);
        expect(forum.votes.single['formhash'], 'hashOf1001', reason: "Bob's vote goes out with Bob's formhash");
        await _dispose(tester);
      });
    }

    // Review of 3e788556: a reload failing at once (no connection) ends before the frame that would show the page
    // loading. The floors went back on screen without being built again: the card kept the poll of Alice for Bob, five
    // options that did nothing (the account in use is not the one of the form). Since the offline threads review the
    // floors of Alice are not put back at all for Bob.
    testWidgets('a failed reload for Bob at once: the floors of Alice are not put back, the retry loads his form', (
      tester,
    ) async {
      final forum = _useForum(json: true);
      await pumpThread(tester, forum);
      final card = tester.state(_card);
      final bloc = tester.element(_card).read<ThreadBloc>();
      forum.failThreadLoads = true;

      // No account change: the floor is back, the card keeps the form of the page of Alice and asks nothing.
      bloc.add(ThreadRefreshRequested());
      await _settle(tester);
      expect((bloc.state.status, bloc.state.postList.length), (ThreadStatus.failure, 1), reason: 'the floor is back');
      expect(tester.state(_card), same(card), reason: 'failed at once: the floor was not built again');
      expect(forum.threadLoads, 2);
      expect(forum.pollLoads, 0, reason: 'the form of the account in use, nothing to ask');
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));

      await switchToBob(tester);
      expect(forum.threadLoads, 3, reason: 'the thread page reloads for Bob, and fails at once');
      expect((bloc.state.status, bloc.state.postList.length), (ThreadStatus.failure, 0), reason: 'not put back');
      expect(_card, findsNothing);
      expect(forum.pollLoads, 0);

      forum.failThreadLoads = false;
      await tester.tap(find.text(t.general.retry));
      await _settle(tester);
      expect(forum.threadLoads, 4);
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5), reason: 'open for the vote of Bob');
      await _vote(tester);
      expect(forum.votes.single['formhash'], 'hashOf1001', reason: "Bob's vote goes out with Bob's formhash");
      expect(_inCard(find.text(t.pollVoting.voted)), findsOneWidget);
      await _dispose(tester);
    });

    testWidgets('switched to Bob under another page, the reload once shown again fails at once: nothing of Alice', (
      tester,
    ) async {
      final forum = _useForum(json: true);
      final router = await pumpThread(tester, forum);
      unawaited(router.push('/other'));
      await _settle(tester);
      forum.failThreadLoads = true;
      await switchToBob(tester);
      expect((forum.threadLoads, forum.pollLoads), (1, 0), reason: 'nothing asked while covered');

      router.pop();
      await _settle(tester);
      expect(forum.threadLoads, 2, reason: 'the reload for Bob once shown again, failed at once');
      expect(_card, findsNothing, reason: 'the floor of the page of Alice is not put back for Bob');
      expect(forum.pollLoads, 0);

      forum.failThreadLoads = false;
      await tester.tap(find.text(t.general.retry));
      await _settle(tester);
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5), reason: 'open for the vote of Bob');
      await _vote(tester);
      expect(forum.votes.single['formhash'], 'hashOf1001', reason: "Bob's vote goes out with Bob's formhash");
      await _dispose(tester);
    });

    testWidgets('a session the forum dropped: signed in again as the same account, the card asks once', (
      tester,
    ) async {
      final forum = _useForum(json: true)..guests.add(_alice.uid!);
      final router = await pumpThread(tester, forum);
      expect(_inCard(find.byType(CheckboxListTile)), findsNothing, reason: 'the page of a guest');
      expect(forum.pollLoads, 1, reason: 'a guest page for an account in use: the card asks, as the forum says');
      await tester.tap(_inCard(find.widgetWithText(TextButton, t.pollVoting.loginRequired)));
      await _settle(tester);
      expect(find.text('login page'), findsOneWidget);

      // Alice signs in again: the forum knows her cookie again, the account in use is the same.
      forum.guests.clear();
      final login = await tester.runAsync(() => auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run());
      expect(login!.isRight(), isTrue, reason: '$login');
      await _settle(tester);
      expect(forum.pollLoads, 1, reason: 'not while the login page of the card is open, the card loads once it closes');
      router.pop();
      await _settle(tester);
      expect(forum.threadLoads, 1, reason: 'the same account: the thread page does not reload');
      expect(forum.pollLoads, 2, reason: 'the card asks once after the login, not twice');
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5), reason: 'open for the vote of Alice');
      await _dispose(tester);
    });

    testWidgets('a session the forum dropped, signed in again elsewhere (manage accounts): the card asks once', (
      tester,
    ) async {
      final forum = _useForum(json: true)..guests.add(_alice.uid!);
      final router = await pumpThread(tester, forum);
      expect(_inCard(find.widgetWithText(TextButton, t.pollVoting.loginRequired)), findsOneWidget);
      expect(forum.pollLoads, 1);

      // "Login again" of Alice in the manage accounts page, above the thread page: no change of the account in use.
      unawaited(router.push('/other'));
      await _settle(tester);
      forum.guests.clear();
      final login = await tester.runAsync(() => auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run());
      expect(login!.isRight(), isTrue, reason: '$login');
      await _settle(tester);
      router.pop();
      await _settle(tester);
      expect(forum.threadLoads, 1, reason: 'the same account: the thread page does not reload');
      expect(forum.pollLoads, 2, reason: 'the card asks once after the login');
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5), reason: 'open for the vote of Alice');
      expect(_inCard(find.widgetWithText(TextButton, t.pollVoting.loginRequired)), findsNothing);

      // The card shows the form now: the account reported again asks nothing more.
      for (var i = 0; i < 2; i++) {
        await tester.runAsync(() => auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run());
        await _settle(tester);
      }
      expect(forum.pollLoads, 2);
      expect(forum.threadLoads, 1);
      await _dispose(tester);
    });

    // Review of 3e788556: the card does not listen to logins while it asks. A login of Alice done meanwhile was taken
    // for the status replayed to the listener of the card once the answer to the request sent with the dropped session
    // asked to log in again, and the card stayed on "log in to vote".
    testWidgets('a session the forum dropped, signed in again elsewhere while the card asks: it asks once more', (
      tester,
    ) async {
      final forum = _useForum(json: true)..guests.add(_alice.uid!);
      await pumpThread(tester, forum);
      expect(_inCard(find.widgetWithText(TextButton, t.pollVoting.loginRequired)), findsOneWidget);
      expect(forum.pollLoads, 1);

      // Asked again with no login meanwhile: still the page of a guest, the card asks nothing more.
      await tester.tap(_inCard(find.text(t.pollVoting.refresh)));
      await _settle(tester);
      expect(forum.pollLoads, 2);
      expect(_inCard(find.widgetWithText(TextButton, t.pollVoting.loginRequired)), findsOneWidget);

      // Asked again, the answer slow: Alice signs in again elsewhere (manage accounts) before it comes.
      forum.gate = Completer<void>();
      await tester.tap(_inCard(find.text(t.pollVoting.refresh)));
      await _settle(tester);
      expect(forum.pollLoads, 3);
      forum.guests.clear();
      final login = await tester.runAsync(() => auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run());
      expect(login!.isRight(), isTrue, reason: '$login');
      await _settle(tester);
      expect(forum.pollLoads, 3, reason: 'the card waits for its answer');
      forum.gate!.complete();
      forum.gate = null;
      await _settle(tester);
      expect(forum.threadLoads, 1, reason: 'the same account: the thread page does not reload');
      expect(forum.pollLoads, 4, reason: 'the page of a guest for the request sent before the login: asked once more');
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5), reason: 'open for the vote of Alice');
      expect(_inCard(find.widgetWithText(TextButton, t.pollVoting.loginRequired)), findsNothing);

      await tester.runAsync(() => auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run());
      await _settle(tester);
      expect(forum.pollLoads, 4, reason: 'the card shows the form: the account reported again asks nothing more');
      await _dispose(tester);
    });

    testWidgets('the same account reported again: no request, the card keeps the form of the page', (tester) async {
      final forum = _useForum(json: true);
      await pumpThread(tester, forum);
      for (var i = 0; i < 3; i++) {
        final login = await tester.runAsync(() => auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run());
        expect(login!.isRight(), isTrue, reason: '$login');
        await _settle(tester);
      }
      expect(forum.threadLoads, 1);
      expect(forum.pollLoads, 0, reason: 'a card showing the form does not ask again on each status');
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));
      await _dispose(tester);
    });

    testWidgets('signed in as another account from the card: the thread page reloads, the card asks nothing more', (
      tester,
    ) async {
      final forum = _useForum(json: true)..guests.add(_alice.uid!);
      final router = await pumpThread(tester, forum);
      expect(forum.pollLoads, 1, reason: 'a guest page for an account in use');
      await tester.tap(_inCard(find.widgetWithText(TextButton, t.pollVoting.loginRequired)));
      await _settle(tester);
      await switchToBob(tester);
      router.pop();
      await _settle(tester);
      expect(forum.threadLoads, 2, reason: 'the thread page reloads for Bob once shown again');
      expect(
        forum.pollLoads,
        1,
        reason: 'no other than the first one: the floors of the new page hold the form of Bob',
      );
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));
      await _dispose(tester);
    });
  });

  group('poll form of the page', () {
    test('the thread parser keeps the form of the floor and the account the page was served to', () {
      final html = _threadHtml(_alice.uid!, _pollForm('multiple', 'hashOf1000'));
      for (final document in [parseHtmlDocument(html), tsdmAppPageDocument(pageAnswerOf(html, 'viewthread'))]) {
        final post = parseThreadDocument(document, 1).postList.single;
        expect(post.hasPoll, isTrue);
        expect(post.poll!.viewerUid, _alice.uid, reason: 'the JSON answer keeps the discuz_uid script of the head');
        expect(post.poll!.form, startsWith('<form id="poll"'));
        expect(post.poll!.form, contains('value="hashOf1000"'));
      }
      expect(parseThreadDocument(parseHtmlDocument(_threadHtml(0, '')), 1).postList.single.poll, isNull);
    });

    test('the form of a page served to another account is not shown, its formhash is not that of the account', () {
      final cubit = PollCubit(
        url: 'poll',
        currentUid: () => _bob.uid,
        repository: () => PollRepository(getPage: (_) async => fail('no request'), postForm: (_, _) async => ''),
      );
      addTearDown(cubit.close);
      final page = _pagePoll(_alice.uid!);
      expect(cubit.adopt(page.form, servedUid: page.viewerUid), isFalse);
      expect(cubit.state.poll, isNull);
      final own = _pagePoll(_bob.uid!);
      expect(cubit.adopt(own.form, servedUid: own.viewerUid), isTrue);
      expect(cubit.state.poll!.availability, PollAvailability.available);
      expect(cubit.state.poll!.formHash, 'hashOf1001');
      expect(cubit.state.uid, _bob.uid);
    });

    test('a guest page for an account in use is not shown, the caller asks; a guest gets the page of a guest', () {
      PollCubit cubitOf(int? uid) {
        final cubit = PollCubit(
          url: 'poll',
          currentUid: () => uid,
          repository: () => PollRepository(getPage: (_) async => fail('no request'), postForm: (_, _) async => ''),
        );
        addTearDown(cubit.close);
        return cubit;
      }

      final guestPage = _pagePoll(0, name: 'guest');
      expect(guestPage.viewerUid, isNull, reason: 'a guest page names no account');
      // Read before a login of the account, or with its session the forum dropped (issue #25) and renewed since: the
      // floors a failed reload of the thread page puts back, for example.
      final alice = cubitOf(_alice.uid);
      expect(alice.adopt(guestPage.form, servedUid: guestPage.viewerUid), isFalse, reason: 'the caller loads instead');
      expect(alice.state.poll, isNull);
      expect(alice.adopt(_pollForm('multiple', 'none'), servedUid: null), isFalse, reason: 'a page that does not say');
      expect(alice.state.poll, isNull);
      final guest = cubitOf(null);
      expect(guest.adopt(guestPage.form, servedUid: guestPage.viewerUid), isTrue, reason: 'no request for a guest');
      expect(guest.state.poll!.availability, PollAvailability.loginRequired);
    });

    test('a vote from the form of the page is posted once, then the results are asked once', () async {
      var gets = 0;
      final sent = <Map<String, String>>[];
      final cubit = PollCubit(
        url: 'poll',
        currentUid: () => _alice.uid,
        repository: () => PollRepository(
          getPage: (_) async {
            gets++;
            return File('test/data/poll_voted_x5.html').readAsStringSync();
          },
          postForm: (_, body) async {
            sent.add(body);
            return '';
          },
        ),
      );
      addTearDown(cubit.close);
      final page = _pagePoll(_alice.uid!);
      expect(cubit.adopt(page.form, servedUid: page.viewerUid), isTrue);
      expect(gets, 0);
      cubit.select('40029', selected: true);
      await cubit.submit();
      expect(sent.single, {'formhash': 'hashOf1000', 'pollsubmit': 'true', 'pollanswers[0]': '40029'});
      expect(gets, 1);
      expect(cubit.state.poll!.availability, PollAvailability.voted);
      expect(cubit.state.submissionUnconfirmed, isFalse);
    });

    test('a form still open for a poll the account voted in since was read before the vote: not shown', () async {
      PollCubit cubitOf(int uid) {
        final cubit = PollCubit(
          url: 'poll',
          currentUid: () => uid,
          repository: () => PollRepository(
            getPage: (_) async => File('test/data/poll_voted_x5.html').readAsStringSync(),
            postForm: (_, _) async => '',
          ),
        );
        addTearDown(cubit.close);
        return cubit;
      }

      final page = _pagePoll(_alice.uid!);
      final voter = cubitOf(_alice.uid!);
      expect(voter.adopt(page.form, servedUid: page.viewerUid), isTrue);
      voter.select('40029', selected: true);
      await voter.submit();
      expect(voter.state.poll!.availability, PollAvailability.voted);

      // Another card of the post, built from the page read before the vote (a floor put back on screen).
      final again = cubitOf(_alice.uid!);
      expect(again.adopt(page.form, servedUid: page.viewerUid), isFalse, reason: 'the caller loads instead');
      expect(again.state.poll, isNull);
      final after = _pagePoll(_alice.uid!, name: 'voted');
      expect(again.adopt(after.form, servedUid: after.viewerUid), isTrue, reason: 'a page read after the vote');
      final bob = _pagePoll(_bob.uid!);
      expect(cubitOf(_bob.uid!).adopt(bob.form, servedUid: bob.viewerUid), isTrue, reason: 'Bob did not vote');
    });
  });

  group('logins of an account', () {
    test('each one from now on, also of the account in use again, not the status replayed to the listener', () async {
      var logins = 0;
      final subscription = listenLoginsOf(auth, _alice.uid!, onLogin: () => logins++);
      addTearDown(subscription.cancel);
      await Future<void>.delayed(Duration.zero);
      expect(logins, 0, reason: 'the status a new listener gets is the login of setUp, before');
      for (var i = 1; i <= 2; i++) {
        final login = await auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run();
        expect(login.isRight(), isTrue, reason: '$login');
        await Future<void>.delayed(Duration.zero);
        expect(logins, i, reason: 'Alice logged in again, the account in use is the same');
      }
      final result = await auth.switchUser(_bob).run();
      expect(result.isRight(), isTrue, reason: '$result');
      await Future<void>.delayed(Duration.zero);
      expect(logins, 2, reason: 'a login of another account');
    });
  });

  group('poll card outside the thread page (the post of a notice)', () {
    /// The card; returns the router, whose login page is a plain page.
    Future<GoRouter> pumpCard(WidgetTester tester, PostPoll? fromPage) async {
      tester.view
        ..physicalSize = const Size(1000, 3000)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: SingleChildScrollView(child: PollCard('1', fromPage: fromPage)),
            ),
          ),
          GoRoute(
            path: ScreenPaths.login,
            name: ScreenPaths.login,
            builder: (_, _) => const Scaffold(body: Center(child: Text('login page'))),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        TranslationProvider(
          child: RepositoryProvider<AuthenticationRepository>.value(
            value: auth,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      await _settle(tester);
      return router;
    }

    testWidgets('the form of the page: no request, also not for the account status a new listener gets', (
      tester,
    ) async {
      final forum = _useForum();
      await pumpCard(tester, _pagePoll(_alice.uid!));
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));
      expect(forum.requests, isEmpty);
      await _dispose(tester);
    });

    testWidgets('nothing reloads the post here: the card loads once for a new account, with its form', (
      tester,
    ) async {
      final forum = _useForum();
      await pumpCard(tester, _pagePoll(_alice.uid!));
      final result = await tester.runAsync(() => auth.switchUser(_bob).run());
      expect(result!.isRight(), isTrue, reason: '$result');
      await _settle(tester);
      expect(forum.pollLoads, 1, reason: 'one load for Bob');
      expect(forum.requests, hasLength(1));
      await _vote(tester);
      expect(forum.votes.single['formhash'], 'hashOf1001');
      expect(forum.pollLoads, 2, reason: 'and once for the results');
      await _dispose(tester);
    });

    testWidgets('the same account reported again loads nothing', (tester) async {
      final forum = _useForum();
      await pumpCard(tester, _pagePoll(_alice.uid!));
      await tester.runAsync(() => auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run());
      await _settle(tester);
      expect(forum.requests, isEmpty);
      await _dispose(tester);
    });

    for (final (name, page) in [
      ('a page served to another account', () => _pagePoll(_bob.uid!)),
      ('no form of the page', () => null),
    ]) {
      testWidgets('$name: the card asks the forum once', (tester) async {
        final forum = _useForum();
        await pumpCard(tester, page());
        expect(forum.pollLoads, 1, reason: 'once, not again for the account status a new listener gets');
        expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));
        await _dispose(tester);
      });
    }

    testWidgets('a session the forum dropped: signed in again as the same account, the card asks once', (
      tester,
    ) async {
      final forum = _useForum()..guests.add(_alice.uid!);
      final router = await pumpCard(tester, _pagePoll(0, name: 'guest'));
      expect(forum.pollLoads, 1, reason: 'a guest page for an account in use: the card asks, as the forum says');
      await tester.tap(_inCard(find.widgetWithText(TextButton, t.pollVoting.loginRequired)));
      await _settle(tester);
      expect(find.text('login page'), findsOneWidget);
      forum.guests.clear();
      final login = await tester.runAsync(() => auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run());
      expect(login!.isRight(), isTrue, reason: '$login');
      await _settle(tester);
      expect(forum.pollLoads, 1, reason: 'not while the login page of the card is open, the card loads once it closes');
      router.pop();
      await _settle(tester);
      expect(forum.pollLoads, 2, reason: 'once after the login: the account in use did not change, nothing else loads');
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));
      await _dispose(tester);
    });

    testWidgets('a session the forum dropped, signed in again elsewhere: the card asks once', (tester) async {
      final forum = _useForum()..guests.add(_alice.uid!);
      await pumpCard(tester, _pagePoll(0, name: 'guest'));
      expect(forum.pollLoads, 1);
      expect(_inCard(find.widgetWithText(TextButton, t.pollVoting.loginRequired)), findsOneWidget);
      forum.guests.clear();
      final login = await tester.runAsync(() => auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run());
      expect(login!.isRight(), isTrue, reason: '$login');
      await _settle(tester);
      expect(forum.pollLoads, 2, reason: 'once after the login');
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));
      await tester.runAsync(() => auth.loginWithDocument(parseHtmlDocument(_authedPage(_alice))).run());
      await _settle(tester);
      expect(forum.pollLoads, 2, reason: 'the card shows the form: the account reported again asks nothing more');
      await _dispose(tester);
    });

    testWidgets('a session the forum dropped, another account switched to elsewhere: the card loads once for it', (
      tester,
    ) async {
      final forum = _useForum()..guests.add(_alice.uid!);
      await pumpCard(tester, _pagePoll(0, name: 'guest'));
      expect(forum.pollLoads, 1);
      final result = await tester.runAsync(() => auth.switchUser(_bob).run());
      expect(result!.isRight(), isTrue, reason: '$result');
      await _settle(tester);
      expect(forum.pollLoads, 2, reason: 'the load for the new account only: no login of Alice');
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));
      await _vote(tester);
      expect(forum.votes.single['formhash'], 'hashOf1001');
      await _dispose(tester);
    });

    testWidgets('signed in as another account from the card: it loads once, for the new account', (tester) async {
      final forum = _useForum()..guests.add(_alice.uid!);
      final router = await pumpCard(tester, _pagePoll(0, name: 'guest'));
      expect(forum.pollLoads, 1, reason: 'a guest page for an account in use');
      await tester.tap(_inCard(find.widgetWithText(TextButton, t.pollVoting.loginRequired)));
      await _settle(tester);
      final result = await tester.runAsync(() => auth.switchUser(_bob).run());
      expect(result!.isRight(), isTrue, reason: '$result');
      router.pop();
      await _settle(tester);
      expect(forum.pollLoads, 2, reason: 'the load for the new account, not another one after the login page');
      expect(_inCard(find.byType(CheckboxListTile)), findsNWidgets(5));
      await _dispose(tester);
    });
  });

  group('points pages in JSON mode', () {
    Future<T> withClient<T>(NetClientProvider client, Future<T> Function() run) async {
      getIt.registerFactory<NetClientProvider>(() => client);
      try {
        return await run();
      } finally {
        getIt.unregister<NetClientProvider>();
      }
    }

    Object? statistics(Either<AppException, uh.Document> page) {
      final (points, changes) = parseStatisticsDocument(page.getOrElse((e) => fail('$e')))!;
      return [points, changes.map(_change).toList()];
    }

    test('statistics: the same points and recent changes', () async {
      final view = await _sameFromBoth(
        (_) => _creditBase,
        'credit',
        (client) => withClient(client, () => PointsRepository().fetchStatisticsPage().run()),
        statistics,
      );
      final [points, changes] = view! as List<Object?>;
      expect(points, {'天使币': '10532', '威望': '3', '积分': '31669'});
      expect(changes, hasLength(2));
    });

    test('changelog: the same changes, filters and pages, the filter and page in the url as before', () async {
      const parameter = ChangelogParameter(
        extType: '2',
        operation: 'RPC',
        changeType: '1',
        startTime: '',
        endTime: '',
        pageNumber: 2,
      );
      final asked = <Uri>[];
      final view = await _sameFromBoth(
        (uri) {
          asked.add(uri);
          return _creditLog(page: int.parse(uri.queryParameters['page']!));
        },
        'credit',
        (client) => withClient(client, () => PointsRepository().fetchChangelogPage(parameter).run()),
        (page) {
          // The web page, and the answer of plugin 1.7.0 (no schema), are the document parsed as before (since
          // test_220 the repository hands the structured answer of plugin 2.5.0 over as a TsdmAppStructuredPage).
          final answer = page.getOrElse((e) => fail('$e'));
          expect(answer, isA<TsdmAppWebPage>());
          final document = (answer as TsdmAppWebPage).document;
          return [
            buildChangeListFromTable(document.querySelector('table.dt')!).map(_change).toList(),
            document.currentPage(),
            document.totalPages(),
            parseAllParameters(document),
          ];
        },
      );
      final [changes, current, total, filters] = view! as List<Object?>;
      expect(changes, hasLength(2));
      expect((current, total), (2, 3));
      expect((filters! as ChangelogAllParameters).operationTypeList, hasLength(3));
      for (final uri in asked) {
        expect(uri.queryParameters, containsPair('mod', 'spacecp'));
        expect(uri.queryParameters, containsPair('op', 'log'));
        expect(uri.queryParameters, containsPair('exttype', '2'));
        expect(uri.queryParameters, containsPair('optype', 'RPC'));
        expect(uri.queryParameters, containsPair('income', '1'));
        expect(uri.queryParameters, containsPair('page', '2'));
      }
    });

    test('an answer without a page is a failed load, not a page without points', () async {
      final forum = _PageForum((_) => _creditBase, json: true, type: 'credit')..jsonAnswer = _withoutPage;
      final result = await withClient(_pageClient(forum), () => PointsRepository().fetchStatisticsPage().run());
      expect(result.isLeft(), isTrue);
      final log = await withClient(
        _pageClient(forum),
        () => PointsRepository().fetchChangelogPage(const ChangelogParameter.empty()).run(),
      );
      expect(log.isLeft(), isTrue);
    });
  });

  group('bank pages', () {
    String bankPageOf(Uri uri) => switch ((uri.queryParameters['bankid'], uri.queryParameters['action'])) {
      (null, _) => _bankDirectory,
      (_, 'cur') => _bankSavings,
      (_, 'log') => _bankLogs,
      (_, 'chg') => _bankRemittance,
      final other => fail('unexpected bank page $other'),
    };

    test('stay web pages, forms are posted as before: plugin 1.7.0 does not handle the bank', () async {
      // The parameter would stay in the request the bank plugin reads, for nothing (the plugin skips the page).
      final forum = _PageForum(bankPageOf);
      final repo = BankRepository.network(_pageClient(forum));
      expect((await repo.fetchDirectory(1000)).banks, hasLength(2));
      final savings = await repo.fetchSavings(1, 1000);
      expect((savings.currency, savings.walletBalance), ('示例币', '4321'));
      final logs = await repo.fetchLogs(1, 1000);
      expect((logs.entries.length, logs.hasNext), (2, true));
      expect((await repo.fetchService(BankService.remittance, 1000, bankId: 1)).forms, hasLength(1));
      await repo.submit(savings.form!, BankOperation.deposit, '10', 'synthetic-password');
      expect([for (final r in forum.requests) r.method], ['GET', 'GET', 'GET', 'GET', 'POST']);
      for (final r in forum.requests) {
        // The pages are read as web pages; the form asks the forum's app API for its result (plugin 2.6.0), which
        // an older plugin ignores: the bank's own page comes back as before.
        expect(r.uri.queryParameters['tsdmapp'], r.method == 'POST' ? 'json' : isNull, reason: '${r.method} ${r.uri}');
      }
    });
  });
}
