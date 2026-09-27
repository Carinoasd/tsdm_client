// Synthetic pages of the post report flow (#127).
//
// Structure (ids, classes, field names, the showWindow call, the ajax envelope and the callbacks) follows the forum's
// observed markup and template source; every value (uids, ids, tokens, texts) is made up. No real report was sent.

import 'package:tsdm_client/shared/models/models.dart';

const reportPid = 60191995;
const reportTid = 1015110;
const reportFid = 200;
const viewerUid = 2000;
const otherUid = 3000;
const authorUid = 1103;

const reportTarget = PostReportTarget(pid: reportPid, tid: reportTid, fid: reportFid, viewerUid: viewerUid);

const pageContext = PostReportPageContext(tid: reportTid, fid: reportFid, viewerUid: viewerUid);

/// The report link exactly as the thread page renders it.
String reportOnclickLink({int pid = reportPid, int tid = reportTid, int fid = reportFid, String handlePid = ''}) =>
    '<a href="javascript:;" onclick="showWindow(\'miscreport${handlePid.isEmpty ? pid : handlePid}\', '
    "'misc.php?mod=report&rtype=post&rid=$pid&tid=$tid&fid=$fid', 'get', -1);return false;\">举报</a>";

/// One floor: `div#post_PID > table#pidPID`, body in `div.pcb`, operation row `div.po > div.pob > p`.
String postFloor({
  int pid = reportPid,
  int author = authorUid,
  String? operations,
  String body = 'Synthetic body',
  String signature = '',
}) =>
    '''
<div id="post_$pid"><table id="pid$pid" summary="pid$pid" cellspacing="0" cellpadding="0" class="tsdm_post_t">
<tr><td id="userinfo_$pid" class="pls"></td>
<td class="plc tsdm_ftc">
<div class="pi"><strong><a href="forum.php?mod=redirect&goto=findpost&ptid=$reportTid&pid=$pid" id="postnum$pid"><em>2</em><sup>#</sup></a></strong>
<div class="pti"><div class="authi"><a href="home.php?mod=space&amp;uid=$author" class="xi2">Synthetic author</a>
<em id="authorposton$pid">发表于 2020-10-1 05:30:15</em></div></div></div>
<div class="pct"><div class="pcb"><div class="t_fsz"><table cellspacing="0" cellpadding="0"><tr><td class="t_f" id="postmessage_$pid">$body</td></tr></table></div></div></div>
</td></tr>
<tr><td class="pls"></td><td class="plc tsdm_replybar">
${signature.isEmpty ? '' : '<div class="sign"><div class="sign_inner">$signature</div></div>'}
<div class="po"><div class="pob cl"><em></em><p>
<a href="javascript:;" id="mgc_post_$pid" class="showmenu">使用道具</a>
${operations ?? reportOnclickLink(pid: pid)}
</p></div></div>
</td></tr></table></div>''';

/// A full thread page served to [uid] (0: guest).
String threadPage({
  int uid = viewerUid,
  int tid = reportTid,
  int fid = reportFid,
  String? floors,
  bool fastPost = true,
  String? fastPostFid,
}) =>
    '''
<!DOCTYPE html><html><head><title>Synthetic thread</title>
<link href="https://www.tsdm39.com/forum.php?mod=viewthread&tid=$tid" rel="canonical" />
<script type="text/javascript">var STYLEID = '1', discuz_uid = '$uid', cookiepre = 'x_';</script>
</head><body>
<input type="hidden" name="srhfid" value="$fid" />
<div id="postlist"><div class="bm">
${floors ?? postFloor()}
</div></div>
${fastPost ? '<form method="post" id="fastpostform" action="forum.php?mod=post&amp;action=reply&amp;fid=${fastPostFid ?? fid}&amp;tid=$tid&amp;extra=&amp;replysubmit=yes"><input type="hidden" name="formhash" value="synthetic0page" /></form>' : ''}
</body></html>''';

const defaultReasonsScript = "var reasons = ['广告垃圾', '违规内容', '恶意灌水', '重复发帖', '其他'];";

const defaultHidden = <(String, String)>[
  ('referer', 'https://www.tsdm39.com/forum.php?mod=viewthread&tid=1015110'),
  ('reportsubmit', 'true'),
  ('rtype', 'post'),
  ('rid', '$reportPid'),
  ('fid', '$reportFid'),
  ('url', ''),
  ('inajax', '1'),
  ('handlekey', 'miscreport$reportPid'),
  ('formhash', 'synthetic0hash'),
];

String _hiddenInputs(List<(String, String)> fields) =>
    fields.map((f) => '<input type="hidden" name="${f.$1}" value="${f.$2.replaceAll('&', '&amp;')}" />').join('\n');

/// The ajax report dialog, `form#form_miscreportPID` posting to `misc.php?mod=report`.
String reportFormAjax({
  int pid = reportPid,
  List<(String, String)> hidden = defaultHidden,
  String action = 'misc.php?mod=report',
  String method = 'post',
  String? formId,
  String extraFields = '',
  String? script = defaultReasonsScript,
  String textarea =
      '<textarea id="report_message" name="message" class="reasonarea pt mtn xg1" rows="4">'
      'Synthetic placeholder</textarea>',
  String extraForms = '',
}) =>
    '''
<?xml version="1.0" encoding="utf-8"?>
<root><![CDATA[<h3 class="flb"><em>举报</em><span><a href="javascript:;" class="flbc" onclick="hideWindow('miscreport$pid')">关闭</a></span></h3>
<form method="$method" autocomplete="off" id="${formId ?? 'form_miscreport$pid'}" action="$action" onsubmit="if(\$('report_message').value) {ajaxpost(this.id, 'form_miscreport$pid');} return false;">
<div class="c">
${_hiddenInputs(hidden)}
<p id="report_reasons"></p>
$textarea
$extraFields
</div>
<p class="o pns"><button id="report_submit" type="submit" value="true" class="pn pnc"><strong>举报</strong></button></p>
</form>
$extraForms
${script == null ? '' : '<script type="text/javascript" reload="1">$script</script>'}
]]></root>''';

/// `report_succeed` as the forum's `showmessage` builds it: only the script, with the handle's callback with `{}`,
/// `hideWindow` and the `right` dialog of the same text.
String successAjax({String handle = 'miscreport$reportPid', String text = '合成的成功提示', String dialogText = ''}) => '''
<?xml version="1.0" encoding="UTF-8"?><root><![CDATA[<script type="text/javascript" reload="1">if(typeof errorhandle_$handle=='function') {errorhandle_$handle('$text', {});}hideWindow('$handle');showDialog('${dialogText.isEmpty ? text : dialogText}', 'right', null, null, 0, null, null, null, null, 3, null);</script>]]></root>''';

/// A refusal: the handle's callback only.
String rejectionAjax({String handle = 'miscreport$reportPid', String text = '合成的拒绝提示'}) => '''
<?xml version="1.0" encoding="utf-8"?>
<root><![CDATA[$text<script type="text/javascript" reload="1">if(typeof errorhandle_$handle=='function') {errorhandle_$handle('$text', {});}</script>]]></root>''';
