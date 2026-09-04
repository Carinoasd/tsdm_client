import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/parsing.dart';

/// A trimmed real post floor from Discuz X5 (tid=1015110, pid=60191995, page 1, logged in as moderator).
///
/// Scripts removed, medals trimmed to 2 and post body replaced with a short one.
const _x5PostFloor = '''
<div id="post_60191995" ><table id="pid60191995" summary="pid60191995" cellspacing="0" cellpadding="0" class="tsdm_post_t" miku="0">
<tr>
<td id="userinfo_60191995" class="pls" >
  <!--userinfo block start. stay blank TD-->
 <div class="p_pop blk bui" id="userinfo60191995" style="display: none; ">
<div class="m z">
<div class="userinfo_float_side">
<div id="userinfo60191995_ma" class="userinfo_float_side_ma"></div>
</div>
</div>
<div class="i y">
<div>
<strong><a href="home.php?mod=space&amp;uid=1103" target="_blank" class="xi2">Grace</a></strong>
<em>当前离线</em>
</div>
<dl class="cl"></dl>
<div class="imicn">
                    <li class="buddy"><a href="home.php?mod=spacecp&amp;ac=friend&amp;op=add&amp;uid=1103&amp;handlekey=addfriendhk_1103" id="a_friend_li_60191995" onclick="showWindow(this.id, this.href, 'get', 1, {'ctrlid':this.id,'pos':'00'});" title="加好友" class="xi2">加好友</a></li>
<li class="pm2"><a href="home.php?mod=spacecp&amp;ac=pm&amp;op=showmsg&amp;handlekey=showmsg_1103&amp;touid=1103&amp;pmid=0&amp;daterange=2&amp;pid=60191995&amp;tid=1015110" onclick="showWindow('sendpm', this.href);" title="发消息" class="xi2">发消息</a></li>
<a href="home.php?mod=space&amp;uid=1103&amp;do=profile" target="_blank" title="查看详细资料"><img src="static/image/common/userinfo.gif" alt="查看详细资料" /></a>

<a href="home.php?mod=magic&amp;mid=checkonline&amp;idtype=user&amp;id=Grace" id="a_repent_60191995" class="xi2" onclick="showWindow(this.id, this.href)"><img src="static//image/magic/checkonline.small.gif" alt="" /> 狗仔卡</a>
<div class="somehead"></div>
</div>
<div id="avatarfeed"><span id="threadsortswait"></span></div>
</div>
</div>
<div id="ts_avatar_60191995">
<div class="post_nickname">☂ 2026 浮潛 ( 暫不回訊 )</div>
<!--
<div class="ts_h_hat"></div>
<div class="ts_h_bat"></div>
-->
<div class="avatar" onmouseover="showauthor(this, 'userinfo60191995')"><a class="userinfo_float_a" href="home.php?mod=space&amp;uid=1103" target="_blank"><img data-src="https://example.com/img/2.jpeg" class="_avt user_avatar" onerror="this.onerror=null;this.src='./data/avatar/noavatar.svg'"></a></div>
<!-- <div class="ts_h_pumpkin"></div> -->
<br />
<div class="tsdm_norm_title"><img src="data/attachment/common/group/永恒天使.gif" alt="" class="vm" style="width:auto;height:20px" /></div>
<div class="tsdm_medalbar">
<a href="home.php?mod=medal" target="_blank"><img id="md_60191995_1523" src="static/image/common//1月/2017春节.gif" alt="2017春节活动" title="" onmouseover="showMenu({'ctrlid':this.id, 'menuid':'md_1523_menu', 'pos':'12!'});" />
<img id="md_60191995_1177" src="static/image/common//1月/春节2015.gif" alt="2015春节活动" title="" onmouseover="showMenu({'ctrlid':this.id, 'menuid':'md_1177_menu', 'pos':'12!'});" />
</a>
</div>
</div>
<p></p>
<!--TSDM statbar-->
                        <div class="tsdm_statbar">
                                <!-- forum/viewthread_authortitle -->                
                <span class="tsstat_icn_1 tsstat_icn_c">UID:</span><span class="tsstat_txt_c">1103</span><br />
                               		<span class="tsstat_icn_8 tsstat_icn_c">头衔:</span><span class="tsstat_txt_c tsstat_txt_pink">【 2026 浮潛僅少量活動、不看訊息提醒、要事B站信箱 】</span><br />
                                <span class="tsstat_icn_2 tsstat_icn_c">精华:</span><span class="tsstat_txt_c tsstat_txt_red">0</span><br />
                <span class="tsstat_icn_3 tsstat_icn_c">主题:</span><span class="tsstat_txt_c tsstat_txt_green">47</span><br />
                <span class="tsstat_icn_4 tsstat_icn_c">帖子:</span><span class="tsstat_txt_c tsstat_txt_lblue">10179</span><br />
                <span class="tsstat_icn_5 tsstat_icn_c">威望:</span><span class="tsstat_txt_c tsstat_txt_purple">99763</span><br />
                <span class="tsstat_icn_5 tsstat_icn_c">天使币:</span><span class="tsstat_txt_c tsstat_txt_purple">129277</span><br />
                <span class="tsstat_icn_5 tsstat_icn_c">宣传度:</span><span class="tsstat_txt_c tsstat_txt_purple">420426</span><br />
                <span class="tsstat_icn_5 tsstat_icn_c">天然°:</span><span class="tsstat_txt_c tsstat_txt_purple">346180</span><br />
                <span class="tsstat_icn_5 tsstat_icn_c">腹黑°:</span><span class="tsstat_txt_c tsstat_txt_purple">346180</span><br />
                <span class="tsstat_icn_5 tsstat_icn_c">精灵:</span><span class="tsstat_txt_c tsstat_txt_purple">13</span><br />
                <span class="tsstat_icn_5 tsstat_icn_c">福袋:</span><span class="tsstat_txt_c tsstat_txt_purple">0</span><br />
<span class="tsstat_icn_5 tsstat_icn_c">通关文牒:</span><span class="tsstat_txt_c tsstat_txt_purple">31</span><br />
<!--<span class="tsstat_icn_5 tsstat_icn_c">通关文牒:</span><span class="tsstat_txt_c tsstat_txt_purple">31</span><br />-->
<!--<span class="tsstat_icn_5 tsstat_icn_c">通关文牒:</span><span class="tsstat_txt_c tsstat_txt_purple">31</span><br />-->
                                	<span class="tsstat_icn_1 tsstat_icn_c tsstat_txt_red">CP:</span><span class="tsstat_txt_c"><a href="home.php?mod=space&amp;uid=1112" target="_blank">Sybil</a></span><br />
                                <span class="tsstat_icn_7 tsstat_icn_c">阅读权限:</span><span class="tsstat_txt_c tsstat_txt_org">140</span><br />
                <span class="tsstat_icn_8 tsstat_icn_c">注册时间:</span><span class="tsstat_txt_c tsstat_txt_blue">2012-6-12</span><br />
                <!--<span class="tsstat_icn_3 tsstat_icn_c">在线时间:</span><span class="tsstat_txt_c tsstat_txt_green">65077 小时</span><br />-->
                                                	<span class="tsstat_icn_3 tsstat_icn_c">来自:</span><span class="tsstat_txt_c tsstat_txt_green">朔君家</span><br />
                                <span class="tsstat_icn_3 tsstat_icn_c">状态:</span>
                                    <a title="性别:ひみつ-当前离线"><span class="tsstat-secret_offline" title="不在线"></span><img src="static/tsdm/secret_offline.gif" alt="不在线"></A>
                                                    <br />
                                    <br />
                <!-- forum/viewthread_titleappend -->                                        <!--TSDM statbar ends-->
            </div>
                
                               
<div class="qdsmile"><li><center>TA的每日心情</center><table><tr><th><a href="forum.php?mod=forumdisplay&fid=4"><img onmouseover="showMenu({'ctrlid':this.id});" id="heart_60191995" src="https://img.tsdm39.com/img01/MP3/bq/fd.gif"></a><th><font size="5px">奋斗</font></tr></table><div style="display:none" id="heart_60191995_menu" class="p_pop h_pop tsqd">(((￣(￣(￣▽￣)￣)￣))) ... 2026 浮潛、不看訊息提醒</div><p style="margin:0">签到天数: 2232天[LV.Master]伴坛终老</p></li></div><div class="tsdmtitle-badges"><div class="tsdmtitle-title"><img src="https://img.tsdm39.com/img01/title/白圣女与黑牧师-塞西莉亚.gif" alt="白圣女与黑牧师 - 塞西莉亚" /></div></div><div class="tns xg2"><div style="padding:6px 0;text-align:center">
  <a href="plugin.php?id=pokemon:game" target="_blank">
    <img src="https://img.tsdm39.com/Pokemon/pm/546.gif" onerror="this.onerror=null;this.src='source/plugin/pokemon/images/pm/546.png';" style="width:auto;height:80px;padding:0 24px;" border="0">
  </a>
  <div style="margin-top:2px;font-size:12px"> ♡ Lv.100</div>
</div></div>            <!-- tales -->
                        <!-- PET -->
                        <!-- PETend -->
<!--tsdm ship-->
<!--tsdm ship ends-->
<p>
<a href="forum.php?mod=topicadmin&amp;action=getip&amp;fid=200&amp;tid=1015110&amp;pid=60191995" onclick="ajaxmenu(this, 0, 0, 2);doane(event)">IP</a>&nbsp;
<a href="forum.php?mod=modcp&action=member&op=edit&uid=1103" target="_blank">编辑</a>&nbsp;
<a href="forum.php?mod=modcp&amp;action=member&amp;op=ban&amp;uid=1103" target="_blank">禁止</a>&nbsp;
<a href="forum.php?mod=modcp&amp;action=thread&amp;op=post&amp;do=search&amp;searchsubmit=1&amp;users=Grace" target="_blank">帖子</a>
</p>
<!--items-->
    <!--userinfo block end-->
</td>

<td class="plc tsdm_ftc" name="tsdm_ft">
<div class="pi">
<strong>
<a href="forum.php?mod=redirect&goto=findpost&ptid=1015110&pid=60191995" title="您的朋友访问此链接后，您将获得相应的积分奖励" id="postnum60191995" onclick="setCopy(this.href, '帖子地址复制成功');return false;"><em>2</em><sup>#</sup></a>
</strong>
<div class="pti">
<div class="pdbt">
</div>
<div class="authi">
<img class="authicn vm" id="authicon60191995" src="static/image/common/sdonline_member.gif" />
<a href="home.php?mod=space&amp;uid=1103" target="_blank" class="xi2">Grace</a>

<em id="authorposton60191995">发表于 2020-10-1 05:30:15</em>
<span class="pipe">|</span><a href="forum.php?mod=viewthread&amp;tid=1015110&amp;page=1&amp;authorid=1103" rel="nofollow">只看该作者</a>
</div>
</div>
</div><div class="pct"><div class="pcb">
<div class="t_fsz"><table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_60191995">
PART1<br />
1.投稿原创新闻50贴<br />
<div class="quote"><blockquote>quoted text</blockquote></div>
<img id="aimg_x" class="zoom" file="https://example.com/a.jpg" onmouseover="img_onmouseoverfunc(this)" lazyloadthumb="1" border="0" alt="" />
</td></tr></table>

</div>
<div id="comment_60191995" class="cm">
</div>

<h3 class="psth xs1"><span class="icon_ring vm"></span>评分</h3>
<dl id="ratelog_60191995" class="rate">
<dd style="margin:0">
<div id="post_rate_60191995"></div>
<table class="ratl">
<tr>
<th class="xw1" width="120"><a href="forum.php?mod=misc&amp;action=viewratings&amp;tid=1015110&amp;pid=60191995" onclick="showWindow('viewratings', this.href)" title="查看全部评分"> 参与人数 <span class="xi1">1</span></a></th><th class="xw1" width="80">威望 <i><span class="xi1">+80</span></i></th>
<th class="xw1" width="80">天使币 <i><span class="xi1">+110</span></i></th>
<th class="xw1" width="80">天然 <i><span class="xi1">+5</span></i></th>
<th class="xw1" width="80">腹黑 <i><span class="xi1">+5</span></i></th>
<th class="xw1" width="80">福袋 <i><span class="xi1">+10</span></i></th>
<th>
<a href="javascript:;" onclick="toggleRatelogCollapse('ratelog_60191995', this);" class="y xi2 op">收起</a>
<i class="txt_h">理由</i>
</th>
</tr>
<tbody class="ratl_l"><tr id="rate_60191995_1107">
<td>
<a href="home.php?mod=space&amp;uid=1107" target="_blank"><img data-src="https://example.com/img/7.gif" class="_avt user_avatar" onerror="this.onerror=null;this.src='./data/avatar/noavatar.svg'"></a> <a href="home.php?mod=space&amp;uid=1107" target="_blank">Mallory</a>
</td><td class="xi1"> + 80</td>
<td class="xi1"> + 110</td>
<td class="xi1"> + 5</td>
<td class="xi1"> + 5</td>
<td class="xi1"> + 10</td>
<td class="xg1">part1客观题答案请看一楼~</td>
</tr>
</tbody>
</table>
<p class="ratc">
<a href="forum.php?mod=misc&amp;action=viewratings&amp;tid=1015110&amp;pid=60191995" onclick="showWindow('viewratings', this.href)" title="查看全部评分" class="xi2">查看全部评分</a>
</p>
</dd>
</dl>
</div>
</div>
</div>

</td></tr>

<tr>
<td class="pls"></td>
<td class="plc tsdm_replybar">
<div class="sign" style="max-height:400px;maxHeightIE:400px;"><div class="sign_inner">　<br />
<p align="center"><a href="https://www.tsdm39.com/forum.php?mod=viewthread&amp;tid=597977&amp;fromuid=1103" target="_blank"><img src="https://example.com/img/3.jpeg" border="0" alt="" /></a></p><br />
　</div></div>

<div class="po">
<span class="y">
<label for="manage60191995">
<input type="checkbox" id="manage60191995" class="pc" onclick="pidchecked(this);modclick(this, 60191995)" value="60191995" autocomplete="off" />
管理
</label>
</span>
<div class="pob cl">
<em>
<a class="cmmnt" href="forum.php?mod=misc&amp;action=comment&amp;tid=1015110&amp;pid=60191995&amp;extra=&amp;page=1" onclick="showWindow('comment', this.href, 'get', 0)">点评</a><a class="fastre" href="forum.php?mod=post&amp;action=reply&amp;fid=200&amp;tid=1015110&amp;repquote=60191995&amp;extra=&amp;page=1&amp;usesig=1&amp;replyuid=1103" onclick="showWindow('reply', this.href);return false;">回复</a>
<a class="editp" href="forum.php?mod=post&amp;action=edit&amp;fid=200&amp;tid=1015110&amp;pid=60191995&amp;page=1">编辑</a>
</em>

<p>
<a href="javascript:;" id="mgc_post_60191995" onmouseover="showMenu(this.id)" class="showmenu">使用道具</a>
<a href="javascript:;" onclick="showWindow('rate', 'forum.php?mod=misc&action=rate&tid=1015110&pid=60191995', 'get', -1);return false;">评分</a>
<a href="javascript:;" onclick="showWindow('rate', 'forum.php?mod=misc&action=removerate&tid=1015110&pid=60191995&page=1', 'get', -1)">撤销评分</a>
<a href="javascript:;" onclick="showWindow('miscreport60191995', 'misc.php?mod=report&rtype=post&rid=60191995&tid=1015110&fid=200', 'get', -1);return false;">举报</a>
</p>



</div>
</div>

</td>
</tr>
<tr class="ad">
<td class="pls"></td>
<td class="plc">
</td>
</tr>
</table>
</div>''';

/// The same floor in guest view: the user info column is empty and no actions available.
const _x5PostFloorGuest = '''
<div id="post_60191995" ><table id="pid60191995" summary="pid60191995" cellspacing="0" cellpadding="0" class="tsdm_post_t" miku="0">
<tr>
<td id="userinfo_60191995" class="pls" style="width:1px">
    <div class="temp_test"></div>
    <!--userinfo block end-->
</td>

<td class="plc tsdm_ftc" name="tsdm_ft">
<div class="pi">
<strong>
<a href="forum.php?mod=redirect&goto=findpost&ptid=1015110&pid=60191995" title="您的朋友访问此链接后，您将获得相应的积分奖励" id="postnum60191995" onclick="setCopy(this.href, '帖子地址复制成功');return false;"><em>2</em><sup>#</sup></a>
</strong>
<div class="pti">
<div class="pdbt">
</div>
<div class="authi">
<img class="authicn vm" id="authicon60191995" src="static/image/common/sdonline_member.gif" />
<a href="home.php?mod=space&amp;uid=1103" target="_blank" class="xi2">Grace</a>

<em id="authorposton60191995">发表于 2020-10-1 05:30:15</em>
<span class="pipe">|</span><a href="forum.php?mod=viewthread&amp;tid=1015110&amp;page=1&amp;authorid=1103" rel="nofollow">只看该作者</a>
</div>
</div>
</div><div class="pct"><div class="pcb">
<div class="t_fsz"><table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_60191995">
PART1<br />
1.投稿原创新闻50贴<br />
<div class="quote"><blockquote>quoted text</blockquote></div>
<img id="aimg_x" class="zoom" file="https://example.com/a.jpg" onmouseover="img_onmouseoverfunc(this)" lazyloadthumb="1" border="0" alt="" />
</td></tr></table>

</div>
<div id="comment_60191995" class="cm">
</div>

<h3 class="psth xs1"><span class="icon_ring vm"></span>评分</h3>
<dl id="ratelog_60191995" class="rate">
<dd style="margin:0">
<div id="post_rate_60191995"></div>
<table class="ratl">
<tr>
<th class="xw1" width="120"><a href="forum.php?mod=misc&amp;action=viewratings&amp;tid=1015110&amp;pid=60191995" onclick="showWindow('viewratings', this.href)" title="查看全部评分"> 参与人数 <span class="xi1">1</span></a></th><th class="xw1" width="80">威望 <i><span class="xi1">+80</span></i></th>
<th class="xw1" width="80">天使币 <i><span class="xi1">+110</span></i></th>
<th class="xw1" width="80">天然 <i><span class="xi1">+5</span></i></th>
<th class="xw1" width="80">腹黑 <i><span class="xi1">+5</span></i></th>
<th class="xw1" width="80">福袋 <i><span class="xi1">+10</span></i></th>
<th>
<a href="javascript:;" onclick="toggleRatelogCollapse('ratelog_60191995', this);" class="y xi2 op">收起</a>
<i class="txt_h">理由</i>
</th>
</tr>
<tbody class="ratl_l"><tr id="rate_60191995_1107">
<td>
<a href="home.php?mod=space&amp;uid=1107" target="_blank"><img data-src="https://example.com/img/7.gif" class="_avt user_avatar" onerror="this.onerror=null;this.src='./data/avatar/noavatar.svg'"></a> <a href="home.php?mod=space&amp;uid=1107" target="_blank">Mallory</a>
</td><td class="xi1"> + 80</td>
<td class="xi1"> + 110</td>
<td class="xi1"> + 5</td>
<td class="xi1"> + 5</td>
<td class="xi1"> + 10</td>
<td class="xg1">part1客观题答案请看一楼~</td>
</tr>
</tbody>
</table>
<p class="ratc">
<a href="forum.php?mod=misc&amp;action=viewratings&amp;tid=1015110&amp;pid=60191995" onclick="showWindow('viewratings', this.href)" title="查看全部评分" class="xi2">查看全部评分</a>
</p>
</dd>
</dl>
</div>
</div>
</div>

</td></tr>

<tr>
<td class="pls"></td>
<td class="plc tsdm_replybar">

<div class="po">
<span class="y">
<label for="manage60191995">
<input type="checkbox" id="manage60191995" class="pc" onclick="pidchecked(this);modclick(this, 60191995)" value="60191995" autocomplete="off" />
管理
</label>
</span>
<div class="pob cl">
<em>
</em>

<p>
<a href="javascript:;" id="mgc_post_60191995" onmouseover="showMenu(this.id)" class="showmenu">使用道具</a>
<a href="javascript:;" onclick="showWindow('miscreport60191995', 'misc.php?mod=report&rtype=post&rid=60191995&tid=1015110&fid=200', 'get', -1);return false;">举报</a>
</p>



</div>
</div>

</td>
</tr>
<tr class="ad">
<td class="pls"></td>
<td class="plc">
</td>
</tr>
</table>
</div>''';

void main() {
  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
  });

  group('ParseX5PostFloor', () {
    test('logged in', () {
      final document = parseHtmlDocument(_x5PostFloor);
      final post = Post.fromPostNode(document.body!.querySelector('div#post_60191995')!, 1);
      expect(post, isNotNull);
      post!;
      expect(post.postID, '60191995');
      expect(post.postFloor, 2);
      expect(post.author.name, 'Grace');
      expect(post.author.uid, '1103');
      expect(post.author.url, 'https://www.tsdm39.com/home.php?mod=space&uid=1103');
      expect(post.author.avatarUrl, 'https://example.com/img/2.jpeg');
      expect(post.publishTime, DateTime(2020, 10, 1, 5, 30, 15));
      expect(post.data.contains('1.投稿原创新闻50贴'), true);
      expect(post.shareLink, 'https://www.tsdm39.com/forum.php?mod=redirect&goto=findpost&ptid=1015110&pid=60191995');
      expect(
        post.replyAction,
        'forum.php?mod=post&action=reply&fid=200&tid=1015110&repquote=60191995&extra=&page=1&usesig=1&replyuid=1103',
      );
      expect(post.rateAction, 'https://www.tsdm39.com/forum.php?mod=misc&action=rate&tid=1015110&pid=60191995');
      expect(
        post.editUrl,
        'https://www.tsdm39.com/forum.php?mod=post&action=edit&fid=200&tid=1015110&pid=60191995&page=1',
      );
      expect(post.locked, isEmpty);
      expect(post.hasPoll, false);
      expect(post.isDraft, false);
      expect(post.badge, 'https://www.tsdm39.com/data/attachment/common/group/永恒天使.gif');
      expect(post.secondBadge, 'https://img.tsdm39.com/img01/title/白圣女与黑牧师-塞西莉亚.gif');
      expect(post.signature, isNotNull);
      expect(post.signature!.contains('tid=597977'), true);

      // Medals.
      expect(post.postMedals?.length, 2);
      expect(post.postMedals?.first.id, 'md_60191995_1523');
      expect(post.postMedals?.first.menuItemId, 'md_1523_menu');
      expect(post.postMedals?.first.alter, '2017春节活动');
      expect(post.postMedals?.first.image, 'https://www.tsdm39.com/static/image/common//1月/2017春节.gif');

      // Pokemon.
      expect(post.pokemon, isNotNull);
      expect(post.pokemon!.primaryPokemon.name, '♡ Lv.100');
      expect(post.pokemon!.primaryPokemon.image, 'https://img.tsdm39.com/Pokemon/pm/546.gif');

      // Checkin.
      expect(post.checkin, isNotNull);
      expect(post.checkin!.feelingName, '奋斗');
      expect(post.checkin!.feelingImage, 'https://img.tsdm39.com/img01/MP3/bq/fd.gif');
      expect(post.checkin!.statistics, '签到天数: 2232天[LV.Master]伴坛终老');

      // Rate.
      final rate = post.rate;
      expect(rate, isNotNull);
      expect(rate!.userCount, 1);
      expect(rate.detailUrl, 'https://www.tsdm39.com/forum.php?mod=misc&action=viewratings&tid=1015110&pid=60191995');
      expect(rate.attrList, ['威望', '天使币', '天然', '腹黑', '福袋', '理由']);
      expect(rate.rateStatus, '威望 +80 天使币 +110 天然 +5 腹黑 +5 福袋 +10');
      expect(rate.records.length, 1);
      expect(rate.records.first.user.name, 'Mallory');
      expect(rate.records.first.user.uid, '1107');
      expect(rate.records.first.user.avatarUrl, 'https://example.com/img/7.gif');
      expect(rate.records.first.attrValueList, ['+ 80', '+ 110', '+ 5', '+ 5', '+ 10', 'part1客观题答案请看一楼~']);

      // Brief profile.
      final profile = post.userBriefProfile;
      expect(profile, isNotNull);
      expect(profile!.username, 'Grace');
      expect(profile.uid, '1103');
      expect(profile.nickname, '☂ 2026 浮潛 ( 暫不回訊 )');
      expect(profile.avatarUrl, 'https://example.com/img/2.jpeg');
      expect(profile.userGroup, '永恒天使');
      expect(profile.title, '【 2026 浮潛僅少量活動、不看訊息提醒、要事B站信箱 】');
      expect(profile.recommended, '0');
      expect(profile.threadCount, '47');
      expect(profile.postCount, '10179');
      expect(profile.famous, '99763');
      expect(profile.coins, '129277');
      expect(profile.publicity, '420426');
      expect(profile.natural, '346180');
      expect(profile.scheming, '346180');
      expect(profile.spirit, '13');
      expect(profile.specialAttrName, '福袋');
      expect(profile.specialAttr, '0');
      expect(profile.specialAttrName2, '通关文牒');
      expect(profile.specialAttr2, '31');
      expect(profile.couple, 'Sybil');
      expect(profile.privilege, '140');
      expect(profile.registrationDate, '2012-6-12');
      expect(profile.comeFrom, '朔君家');
      expect(profile.online, false);
    });

    test('guest', () {
      final document = parseHtmlDocument(_x5PostFloorGuest);
      final post = Post.fromPostNode(document.body!.querySelector('div#post_60191995')!, 1);
      expect(post, isNotNull);
      post!;
      expect(post.postID, '60191995');
      expect(post.postFloor, 2);
      expect(post.author.name, 'Grace');
      expect(post.author.uid, '1103');
      expect(post.author.avatarUrl, isNull);
      expect(post.publishTime, DateTime(2020, 10, 1, 5, 30, 15));
      expect(post.data.contains('1.投稿原创新闻50贴'), true);
      expect(post.replyAction, isNull);
      expect(post.rateAction, isNull);
      expect(post.editUrl, isNull);
      expect(post.userBriefProfile, isNull);
      expect(post.postMedals, isEmpty);
      expect(post.pokemon, isNull);
      expect(post.checkin, isNull);
      expect(post.badge, isNull);
      expect(post.rate?.records.length, 1);
    });
  });
}
