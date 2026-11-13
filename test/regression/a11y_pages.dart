/// The pages of the accessibility tests (test_279, test_990, test_991): what their forum answers and how they are
/// built. Synthetic accounts and pages only.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_bbcode_editor/flutter_bbcode_editor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/admin_tools/models/admin_models.dart';
import 'package:tsdm_client/features/attachment_download/models/attachment_download.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_manager.dart';
import 'package:tsdm_client/features/attachment_download/repository/attachment_download_store.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_pages_repository.dart';
import 'package:tsdm_client/features/moderate/repository/modcp_repository.dart';
import 'package:tsdm_client/features/moderate/view/moderator_panel_page.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

import 'a11y_harness.dart';
import 'admin_tools_fakes.dart';

/// The thread of the pages.
const a11yTid = 1264975;

// ---------------------------------------------------------------------------------------------------------------------
// The forum.

/// A table wider than a phone, in the first floor: the button opening it in a page of its own is on the page.
final _wideTable = '<table><tr>${'<td>a wide table cell</td>' * 8}</tr></table>';

/// A floor of the synthetic thread (test_270), with a reply link so the floor has its own action row.
String _floor(int floor) {
  final pid = 9700000 + floor;
  return '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1000" class="xi2">Bob</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor text<br />${'line<br />' * 3}
${floor == 1 ? _wideTable : ''}
</div></div></div>
<div class="pob"><em><a class="fastre" href="forum.php?mod=post&amp;action=reply&amp;fid=8&amp;tid=$a11yTid&amp;repquote=$pid">回复</a></em></div>
</td>
</tr></tbody></table></div>''';
}

/// A thread of 3 pages, 10 floors each: page [page].
String _threadPage(int page) {
  final pager =
      '<div class="pg">${[
        for (var i = 1; i <= 3; i++) i == page ? '<strong>$i</strong>' : '<a href="forum.php?mod=viewthread&tid=$a11yTid&page=$i">$i</a>',
      ].join()}<label><input type="text" name="custompage"/><span title="共 3 页"> / 3 页</span></label></div>';
  return '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=$a11yTid" /></head><body>
$pager
<div id="postlist"><table><tr><td><span class="xi1">100</span><span class="xi1">29</span></td></tr></table>
<h1 class="ts"><span id="thread_subject">Thread title</span></h1><div class="bm">
${[for (var f = (page - 1) * 10 + 1; f <= page * 10; f++) _floor(f)].join('\n')}
</div></div>
</body></html>''';
}

/// The author link of a thread row of the homepage.
const _carol = '<a href="home.php?mod=space&amp;uid=1003" target="_blank"><em>Carol</em></a>';

/// `forum.php` of Alice: the status bar and the pinned thread groups (test_226), owner marks as in test_171.
String _forumHome() {
  String threads(List<(String, int)> rows) => [
    for (final (title, tid) in rows)
      '<div class="Kahrpba_threads"><a href="forum.php?mod=viewthread&amp;tid=$tid">$title</a>$_carol</div>',
  ].join('\n');
  String button(int id, String title) => '<button type="button" id="Kahrpba_$id"><em>$title</em></button>';
  return '''
<html><head>
<script type="text/javascript">var STYLEID = '42', discuz_uid = '1000', cookiepre = 'Ystv_2132_';</script>
</head><body>
<div id="hd"><div class="wp"><div class="hdc cl"><div id="um">
<div class="avt y"><a href="home.php?mod=space&amp;uid=1000"><img data-src="./data/avatar/000/00/10/00_avatar_middle.jpg" class="_avt user_avatar"></a></div>
<p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong></p>
</div></div></div></div>
<form><input type="hidden" name="formhash" value="XXXXXXXX" /></form>
<div id="chart" class="bm bw0 cl"><p class="chart z">今日: <em>1234</em> | 昨日: <em>5678</em> | 帖子: <em>9012345</em></p></div>
<table id="Kahrpba"><tr>
<td id="Kahrpba_nav">
${button(1, '最新活动')}${button(2, '见习天使')}${button(3, '动漫新闻')}${button(4, '最新主题')}
${button(6, '今日话题')}${button(7, '动漫讨论')}${button(5, '发帖排行')}
</td>
<td id="Kahrpba_show">
<div id="Kahrpba_c_1">${threads([('【活动】十月签到挑战赛开始报名', 2001), ('【活动】秋季同人绘画征集', 2002), ('【公告】活动专区兑换商店开放', 2003)])}</div>
<div id="Kahrpba_c_2"><div class="Kahrpba_threads"><a href="home.php?mod=space&amp;uid=1101">欢迎Momo加入~</a></div></div>
<div id="Kahrpba_c_3">${threads([('【新闻】十月新番播出时间表整理', 2004), ('【新闻】某长篇漫画宣布动画化', 2005)])}</div>
<div id="Kahrpba_c_4">${threads([('求推荐几部轻松的日常番', 2006), ('分享一下我的手办收藏', 2007)])}</div>
<div id="Kahrpba_c_5"><div class="Kahrpba_threads"><a href="home.php?mod=space&amp;uid=1003">Carol</a><a href="home.php?mod=space&amp;uid=1003" target="_blank"><em>今日共发128贴</em></a></div></div>
<div id="Kahrpba_c_6">${threads([('你最喜欢的片头曲是哪首？', 2008)])}</div>
<div id="Kahrpba_c_7">${threads([('第 3 集的伏笔是不是太明显了', 2009)])}</div>
</td></tr></table>
</body></html>''';
}

const _profile = '''
<html><body>
<div id="um"><p><strong class="vwmy"><a href="home.php?mod=space&amp;uid=1000">Alice</a></strong></p></div>
<div id="uhd"><div class="icn avt"><a href="home.php?mod=space&amp;uid=1000"><img data-src="./data/avatar/000/00/10/00_avatar_middle.jpg"></a></div></div>
</body></html>''';

/// The forum of test_279: the homepage, the profile, a forum (JSON of the app plugin), a thread and a search; an empty page
/// otherwise.
(String, bool)? a11yMainForum(Uri uri, String method) {
  final q = uri.queryParameters;
  return switch (uri.pathSegments.lastOrNull) {
    'forum.php' when q['mod'] == null => (_forumHome(), false),
    'forum.php' when q['mod'] == 'forumdisplay' => (a11yData('tsdmapp/preview_v2_forum.json'), true),
    'forum.php' when q['mod'] == 'viewthread' => (_threadPage(int.tryParse(q['page'] ?? '') ?? 1), false),
    'home.php' when q['mod'] == 'space' => (_profile, false),
    'search.php' => (a11yData('tsdmapp/preview_v6_search.json'), true),
    _ => null,
  };
}

/// The login: the form hash comes at once, a login is refused.
final class A11yLoginRepository extends AuthenticationRepository {
  @override
  AsyncEither<LoginHash> fetchHash() =>
      AsyncEither(() async => right(const LoginHash(formHash: 'hash', loginHash: 'login')));

  @override
  AsyncVoidEither loginWithPassword(UserCredential credential) =>
      AsyncVoidEither(() async => left(LoginInvalidCredentialException()));
}

/// The floor of the fixture `locked_purchase_x5.html` as a post with a plain body (test_267).
Post a11yFixturePost() {
  final doc = parseHtmlDocument(a11yData('locked_purchase_x5.html'));
  final original = doc.querySelector('div#post_77983102')!;
  final floor = original.clone(true) as uh.Element;
  original.parent!.append(floor);
  final post = Post.fromPostNode(floor, 1)!;
  return post.copyWith(data: '<p>floor body</p>', locked: const [], signature: null, pokemon: null, checkin: null);
}

/// A floor of a thread that takes replies, with a reply link, so the floor has its own action row.
String _replyFloor(int floor) {
  final pid = 9700000 + floor;
  return '''
<div id="post_$pid"><table><tbody><tr>
<td class="pls"></td>
<td class="plc"><div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&pid=$pid"><em>$floor</em></a>
</strong><div class="authi"><a href="home.php?mod=space&amp;uid=1001" class="xi2">Bob</a></div></div>
<div class="pct"><div class="pcb"><div class="t_f" id="postmessage_$pid">floor $floor text</div></div></div>
<div class="pob"><em><a class="fastre" href="forum.php?mod=post&amp;action=reply&amp;fid=8&amp;tid=$a11yTid&amp;repquote=$pid">回复</a></em></div>
</td>
</tr></tbody></table></div>''';
}

String _replyThread() =>
    '''
<html><head><link rel="canonical" href="forum.php?mod=viewthread&tid=$a11yTid" /></head><body>
<div id="postlist"><table><tr><td><span class="xi1">100</span><span class="xi1">3</span></td></tr></table>
<h1 class="ts"><span id="thread_subject">Thread title</span></h1><div class="bm">
${[for (var f = 1; f <= 3; f++) _replyFloor(f)].join('\n')}
</div></div>
<form id="fastpostform" action="forum.php?mod=post&action=reply&fid=8&tid=$a11yTid&extra=&replysubmit=yes">
<input type="hidden" name="formhash" value="f1f2f3f4" /><textarea name="message"></textarea></form>
</body></html>''';

/// The forum of test_990: the forum list, a thread that takes replies, the form of a new thread, a conversation; an
/// empty page otherwise.
(String, bool)? a11yMoreForum(Uri uri, String method) {
  final q = uri.queryParameters;
  return switch (uri.pathSegments.lastOrNull) {
    'forum.php' when q['mod'] == null => (a11yData('forum_index_x5.html'), false),
    'forum.php' when q['mod'] == 'viewthread' => (_replyThread(), false),
    // The form of the test forum, answered to Alice.
    'forum.php' when q['mod'] == 'post' && q['action'] == 'newthread' => (
      jsonEncode({...jsonDecode(a11yData('tsdmapp/post_v16_newthread.json')) as Map<String, dynamic>, 'uid': 1000}),
      true,
    ),
    // A conversation: its window, its whole history (as Alice's).
    'home.php' when q['op'] == 'showmsg' => (a11yData('chat_dialog_x5.xml'), false),
    'home.php' when q['subop'] == 'view' => (
      a11yData('chat_history_bare_url_x5.html').replaceAll("discuz_uid = '1001'", "discuz_uid = '1000'"),
      false,
    ),
    _ => null,
  };
}

Map<String, dynamic> _api390(String name) => {
  ...jsonDecode(File('test/data/tsdmapp_390/$name.json').readAsStringSync()) as Map<String, dynamic>,
  'uid': 33,
};

typedef _Answer = Either<AppException, ({int statusCode, Object? data})>;

/// The moderator's panel with all its entries: the counts of its first page, the medal and title tools, the
/// backgrounds and the reports, the admin actions and the batch rates.
Widget a11yModeratorPanel() {
  Future<_Answer> get(String url) async => right((
    statusCode: 200,
    data: url.contains('tsdmapp=json')
        ? {
            ..._api390('modcp_home'),
            'counts': {'moderate': 4, 'notes': 2, 'forums': 20},
          }
        : "<script>var discuz_uid = '33';</script><div class=\"appl\"><ul>\n"
              '<li><a href="forum.php?mod=modcp&action=home">x</a></li>\n'
              '<li><a href="forum.php?mod=modcp&action=forumaccess">x</a></li></ul></div>',
  ));
  Future<_Answer> post(String url, Map<String, String> body) async => right((statusCode: 200, data: null));
  final panel = ModcpRepository(get: get, post: post, currentUid: () => 33);
  return ModeratorPanelPage(
    repository: panel,
    staffTools: () async => (grant: true, issue: true),
    panelTools: () async => (background: true, modcpReport: true),
    adminAccess: () async => AdminAccess.fromJson(adminFixture('admin_founder')),
    batchRate: () async => null,
    modcpPages: () async => {'home', 'thread', 'forumaccess'},
    pagesRepository: ModcpPagesRepository(panel: panel, get: get, post: post, currentUid: () => 33),
  );
}

/// The downloads of Alice: one done, one refused, one running.
AttachmentDownloadManager a11yDownloads(Directory dir) => AttachmentDownloadManager(
  store: AttachmentDownloadStore.memory({
    AttachmentDownloadStore.rowKeyOf(a11yAlice.uid!): jsonEncode([
      AttachmentDownload(
        id: 'failed',
        uid: a11yAlice.uid!,
        url: 'https://forum.test/forum.php?mod=attachment&aid=38',
        filename: 'refused.zip',
        createdAt: DateTime(2026, 11, 10, 9),
        status: AttachmentDownloadStatus.failed,
        message: 'refused',
        tid: '1000',
        threadTitle: 'a thread with attachments',
      ).toJson(),
      AttachmentDownload(
        id: 'done',
        uid: a11yAlice.uid!,
        url: 'https://forum.test/forum.php?mod=attachment&aid=36',
        filename: 'done.zip',
        createdAt: DateTime(2026, 11, 10, 8),
        status: AttachmentDownloadStatus.completed,
        path: '${dir.path}/done.zip',
        total: 4,
        received: 4,
        tid: '1000',
      ).toJson(),
    ]),
  }),
  directory: () async => dir,
  partDirectory: () async => Directory('${dir.path}/parts'),
);

const a11yEmojiGroups = [
  EmojiGroup(
    name: 'group one',
    id: '1',
    routeName: 'one',
    emojiList: [
      Emoji(id: '1', code: '{:1_1:}', url: 'https://forum.test/smiley/1.gif'),
      Emoji(id: '2', code: '{:1_2:}', url: 'https://forum.test/smiley/2.gif'),
    ],
  ),
];

/// The name of the author of a floor opens the author card like the 48 wide avatar before it does: the equivalent
/// control is there, the name stays the height of its line (test_279). The gesture detectors right around a name
/// only (no other one between): the ones around the floor and the whole list hold it too.
Finder floorAuthorName(String name) => find.byElementPredicate((element) {
  if (element.widget is! GestureDetector) {
    return false;
  }
  var found = false;
  void visit(Element child) {
    if (found || child.widget is GestureDetector) {
      return;
    }
    if (child.widget case Text(:final data) when data == name) {
      found = true;
      return;
    }
    child.visitChildren(visit);
  }

  element.visitChildren(visit);
  return found;
});

/// The buttons the bbcode editor package builds (the style toggles, undo, redo, lists, alignment ...): the package
/// puts their tooltip on a node of its own around the button instead of on the button (test_279). The package is a
/// submodule, not changed here; the app's own buttons are checked.
Finder packageToolbarButtons() => find.descendant(
  of: find.byType(BBCodeEditorToolbar),
  matching: find.byWidgetPredicate((w) => w is IconButton && w.tooltip == null),
);
