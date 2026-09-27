/// Synthetic title shop pages (issue #123).
///
/// Markup follows the live `plugin.php?id=tsdmtitle:tsdmtitle&action=shop` page: intro heading and paragraph, a
/// `table.dt` with the five observed columns, a purchase POST form or the owned text in the last column, the pager
/// repeated above and below the table, and the account status box. Titles, ids, balance and tokens are fictional.
library;

const shopIntro = '称号牌子时效均为永久。可多个购买，在“我的称号”内随时切换佩戴。';

const shopReturn = 'plugin.php?id=tsdmtitle:tsdmtitle&amp;action=shop&amp;app=plugin';

/// The server confirmation sentence for [price].
String shopConfirm(String price) => '确定花费 $price 天使币购买这个称号吗？';

/// A purchasable row; every part of the form can be altered to build a tampered page.
String buyRow(
  int id,
  String name,
  String price, {
  String action = 'plugin.php?id=tsdmtitle:tsdmtitle&amp;action=buy',
  String method = 'post',
  String formHash = 'TEST_HASH',
  String returnPath = shopReturn,
  String? buyId,
  String extra = '',
  String button = '<button name="buysubmit" type="submit" value="true" class="pn pnc"><strong>购买</strong></button>',
  String? confirm,
}) =>
    '<tr><td>$id</td><td>$name</td><td>$price</td>'
    '<td><img src="https://img.tsdm39.com/img01/title/$name.gif" alt="" /></td>'
    '<td><form action="$action" method="$method" onsubmit="return confirm(this.getAttribute(\'data-c\'));" '
    'data-c="${confirm ?? shopConfirm(price)}">'
    '<input type="hidden" name="formhash" value="$formHash"/>'
    '<input type="hidden" name="tsdmtitle_return" value="$returnPath"/>'
    '<input type="hidden" name="buyid" value="${buyId ?? id}"/>$extra$button</form></td></tr>';

/// A row the account already owns.
String ownedRow(int id, String name, String price) =>
    '<tr><td>$id</td><td>$name</td><td>$price</td>'
    '<td><img src="https://img.tsdm39.com/img01/title/$name.gif" alt="" /></td><td>已拥有</td></tr>';

String _pager(int page, int? last) =>
    '<div class="pg">'
    '${page > 1 ? '<a href="plugin.php?id=tsdmtitle:tsdmtitle&amp;action=shop&amp;buyitem=0&amp;page=${page - 1}" class="prev">上一页</a>' : ''}'
    '<strong>$page</strong>'
    '${last != null && page < last ? '<a href="plugin.php?id=tsdmtitle:tsdmtitle&amp;action=shop&amp;buyitem=0&amp;page=${page + 1}" class="nxt">下一页</a>' : ''}'
    '</div>';

/// A shop page served to [uid] (0 for a guest).
String shopPage(List<String> rows, {int page = 1, int? last = 7, int uid = 1000, String balance = '12345'}) =>
    '''
<script>var discuz_uid = '$uid';</script>
<div id="ct" class="ct2_a wp cl"><div class="mn"><div class="bm bw0">
<h2>称号商店</h2>
<p>$shopIntro</p>
${_pager(page, last)}
<table class="dt"><thead><tr><th>称号ID</th><th>称号名称</th><th>称号价格</th><th>图片</th><th>购买</th></tr></thead>
<tbody>${rows.join('\n')}</tbody></table>
${_pager(page, last)}
</div></div>
<div class="appl"><div class="tbn"><h2 class="mt bbda">我的状态</h2><ul><li>天使币：$balance</li></ul></div></div>
</div>''';

/// A Discuz message page.
String messagePage(String text, {bool error = false}) =>
    '''
<script>var discuz_uid = '1000';</script>
<div id="messagetext" class="${error ? 'alert_error' : 'alert_right'}"><p>$text<script type="text/javascript">setTimeout("window.location.href ='plugin.php';", 3000);</script></p>
<p class="alert_btnleft"><a href="plugin.php?id=tsdmtitle:tsdmtitle&amp;action=shop">如果您的浏览器没有自动跳转，请点击此链接</a></p></div>''';
