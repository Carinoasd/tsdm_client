// Synthetic identities, tokens and private content only.
String draftPage(String body, {int uid = 1000}) =>
    '<html><head><script>var discuz_uid = \'$uid\';</script></head><body>$body</body></html>';

String draftList({String tid = '123', int uid = 1000, bool empty = false, int? next}) => draftPage('''
<a class="a" href="home.php?mod=space&amp;do=thread&amp;view=me&amp;type=thread&amp;filter=save">草稿箱</a>
<form id="delform"><table><tr class="th"><th>主题</th></tr>
${empty ? '<tr><td><p class="emp">还没有相关的帖子</p></td></tr>' : '''
<tr><td></td><th><a href="forum.php?mod=viewthread&amp;tid=$tid">Synthetic draft $tid</a></th>
<td><a href="forum.php?mod=forumdisplay&amp;fid=4">Test forum</a></td></tr>'''}
</table></form>
${next == null ? '' : '<div class="pg"><a class="nxt" href="home.php?mod=space&amp;do=thread&amp;view=me&amp;type=thread&amp;filter=save&amp;page=$next">Next</a></div>'}
''', uid: uid);

String draftPost({int pid = 456, int floor = 1, String marker = '', bool edit = true}) =>
    '''
<div id="post_$pid"><table><tr><td class="pls"></td><td class="plc">
<div class="pi"><strong><a><em>$floor</em></a></strong><div class="authi">
<a href="home.php?mod=space&amp;uid=1000">Test author</a>
<em id="authorposton$pid">发表于 2026-09-01 12:00:00</em></div></div>
<div class="pcb">Synthetic body</div>$marker
${edit ? '<div id="fj"><a href="forum.php?mod=post&amp;action=edit&amp;fid=4&amp;tid=123&amp;pid=$pid&amp;page=1">编辑</a></div>' : ''}
</td></tr></table></div>''';

String draftThread({bool draft = true, bool edit = true, bool secondPost = false, int uid = 1000}) => draftPage('''
<div id="postlist"><div><h1 class="ts"><span id="thread_subject">Synthetic subject</span></h1>
${draft ? '<span class="xg1">(草稿)<a class="psave" href="forum.php?mod=misc&amp;action=pubsave&amp;tid=123">发布</a></span>' : ''}
</div><div></div>${draftPost(edit: edit)}${secondPost ? draftPost(pid: 457, floor: 2) : ''}</div>
''', uid: uid);

String draftEditForm({String extra = '', int uid = 1000}) => draftPage('''
<div id="ct"><form id="postform">
<input name="formhash" value="synthetic-token"><input name="posttime" value="100">
<input name="wysiwyg" value="0"><input name="delattachop" value="0">
<input name="fid" value="4"><input name="tid" value="123"><input name="pid" value="456"><input name="page" value="1">
<input type="hidden" id="postsave" name="save" value="">
<button type="button" onclick="\$('postsave').value = 1;\$('postsubmit').click();">Save draft</button>
$extra<div id="postbox"><div class="area"><textarea>Synthetic private body</textarea></div></div>
</form></div>''', uid: uid);
