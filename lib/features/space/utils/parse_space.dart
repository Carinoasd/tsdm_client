import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/authentication/utils/logged_user_parser.dart';
import 'package:tsdm_client/features/red_packet/utils/parse_red_packet.dart' show parseFormHash;
import 'package:tsdm_client/features/space/models/space_models.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/html.dart' as uh;

/// The forum's url [url] as an absolute url (`./data/…`, `home.php?…`, or already absolute).
String spaceAbsoluteUrl(String url) {
  var s = url.trim();
  if (s.startsWith('./')) {
    s = s.substring(2);
  }
  return s.prependHost();
}

/// The picture of the thumbnail url [thumbUrl] of an album: Discuz! names the thumbnail of `x.png` `x.png.thumb.jpg`
/// next to it; a picture too small for a thumbnail is shown as it is.
String spacePhotoImageUrl(String thumbUrl) {
  const suffix = '.thumb.jpg';
  return thumbUrl.endsWith(suffix) ? thumbUrl.substring(0, thumbUrl.length - suffix.length) : thumbUrl;
}

/// [text] as the content of a blog posted as plain text (`plaintext=1`, the forum turns its line breaks into `<br />`
/// and keeps the html it allows): `&`, `<` and `>` as entities, so the blog shows what was typed.
String spaceBlogPlainText(String text) =>
    text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('\r\n', '\n');

final _idRe = RegExp(r'[?&;]id=(-?\d+)');
final _uidRe = RegExp(r'[?&;]uid=(\d+)');
final _picIdRe = RegExp(r'[?&;]picid=(\d+)');
final _digitsRe = RegExp(r'\d+');
final _timeRe = RegExp(r'^\d{4}-\d{1,2}-\d{1,2}\b');
final _viewsRe = RegExp(r'(\d+)\s*次阅读');
final _albumCountRe = RegExp(r'\((\d+)\)');
final _photoTotalRe = RegExp(r'共\s*(\d+)\s*张图片');
final _albumTitleRe = RegExp('^(.*) - [^-]*的相册 -', dotAll: true);

int? _intOf(RegExp re, String? s) => s == null ? null : int.tryParse(re.firstMatch(s)?.group(1) ?? '');

String? _textOf(uh.Element? e) {
  final s = e?.text?.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s == null || s.isEmpty ? null : s;
}

/// What the forum printed instead of the page asked for, null when it is the page: the privacy notice of a member's
/// space, the password form of a protected blog or album, the 提示信息 of a missing blog or a switched off module, the
/// login prompt.
({String message, bool needLogin, bool passwordRequired})? _noticeOf(uh.Document document) {
  final password = document.querySelector('form#invalueform');
  if (password != null) {
    final text = _textOf(password.querySelector('div.c')) ?? _textOf(password.querySelector('h1')) ?? '';
    return (message: text.replaceAll(RegExp(r'[:：]\s*$'), ''), needLogin: false, passwordRequired: true);
  }
  final privacy = _textOf(document.querySelector('div.nfl h2.xs2'));
  if (privacy != null) {
    return (message: privacy, needLogin: false, passwordRequired: false);
  }
  final messageText = document.querySelector('div#messagetext');
  if (messageText != null) {
    final text = _textOf(messageText.querySelector('p')) ?? _textOf(messageText) ?? '';
    // The login box, or the forum's "您需要先登录才能继续本操作"; a message merely naming the login is shown as it is.
    final needLogin =
        document.querySelector('div#messagelogin') != null || text.contains('先登录') || text.contains('先登入');
    return (message: text, needLogin: needLogin, passwordRequired: false);
  }
  return null;
}

String? _nextPageUrl(uh.Element? root) {
  final href = root?.querySelector('div.pg a.nxt')?.attributes['href'];
  return href == null || href.isEmpty ? null : spaceAbsoluteUrl(href);
}

/// A blog list page of a member (`home.php?mod=space&uid=N&do=blog&view=me`).
///
/// ```html
/// <div class="xld xlda">
///   <dl class="bbda">
///     <dd class="m">…avatar…</dd>
///     <dt class="xs2"><a href="home.php?mod=space&uid=N&do=blog&id=M">TITLE</a></dt>
///     <dd><span class="y"><a class="xg1">仅自己可见</a></span><a href="home.php?mod=space&uid=N">NAME</a>
///       <span class="xg1">2026-11-9 01:05</span></dd>
///     <dd class="cl" id="blog_article_M">SUMMARY</dd>
///     <dd class="xg1">个人分类: <a href="…&classid=1…">CATEGORY</a> | <a>1 次阅读</a> |
///       <a><span id="replynum_M">2</span> 个评论</a></dd>
///   </dl>
///   <p class="mtm">本页有 1 篇日志因作者的隐私设置或未通过审核而隐藏</p>
/// </div>
/// <div class="pg">…<a href="…&page=2" class="nxt">下一页</a></div>
/// ```
///
/// The privacy label is only shown to the author. An empty list is `<div class="emp">`.
SpaceListPage<SpaceBlog> parseSpaceBlogListPage(uh.Document document) {
  final list = document.querySelector('div#ct div.xld');
  if (list == null) {
    if (_noticeOf(document) case final notice?) {
      return SpaceListPage(
        items: const [],
        message: notice.message,
        needLogin: notice.needLogin,
        passwordRequired: notice.passwordRequired,
      );
    }
    return const SpaceListPage(items: []);
  }
  final items = <SpaceBlog>[];
  for (final dl in list.querySelectorAll('dl')) {
    final link = dl.querySelector('dt a[href*="do=blog"]');
    final href = link?.attributes['href'];
    final blogId = _intOf(_idRe, href);
    final uid = _intOf(_uidRe, href);
    final title = _textOf(link);
    if (blogId == null || uid == null || title == null) {
      continue;
    }
    final meta = dl.children.where((e) => e.localName == 'dd' && e.classes.isEmpty && e.id.isEmpty).firstOrNull;
    final info = dl.querySelector('dd.xg1');
    final privacy = meta?.querySelector('span.y');
    items.add(
      SpaceBlog(
        blogId: blogId,
        uid: uid,
        title: title,
        author: _textOf(meta?.children.where((e) => e.localName == 'a').firstOrNull),
        time: _textOf(meta?.querySelector('span.xg1')),
        summary: _textOf(dl.querySelector('dd[id^="blog_article_"]')),
        category: _textOf(info?.querySelector('a[href*="classid="]')),
        views: _intOf(_viewsRe, info?.text),
        replies: int.tryParse(_textOf(info?.querySelector('span[id^="replynum_"]')) ?? ''),
        privacy: _textOf(privacy),
      ),
    );
  }
  final note = list.children.where((e) => e.localName == 'p').map(_textOf).nonNulls.firstOrNull;
  return SpaceListPage(items: items, nextPageUrl: _nextPageUrl(document.querySelector('div#ct')), hiddenNote: note);
}

/// The comments of a blog page or of a wall page, the same list (`home/space_comment_li`):
///
/// ```html
/// <div id="comment_ul" class="xld xlda">
///   <dl id="comment_7_li" class="bbda cl">
///     <dd class="m avt"><a href="home.php?mod=space&uid=U"><img src="AVATAR"></a></dd>
///     <dt><span class="y xw0"><a id="c_7_edit">编辑</a> <a id="c_7_delete">删除</a> <a id="c_7_reply">回复</a></span>
///       <a href="home.php?mod=space&uid=U" id="author_7">NAME</a> <span class="xg1 xw0">2026-11-9 01:08</span></dt>
///     <dd id="comment_7">MESSAGE</dd>
///   </dl>
/// </div>
/// ```
///
/// The forum prints the delete and reply links to whom may use them; an anonymous comment has the site's anonymous
/// name as text in place of the author's link.
List<SpaceBlogComment> _commentsOf(uh.Document document) {
  final comments = <SpaceBlogComment>[];
  for (final dl in document.querySelectorAll('div#comment_ul dl[id^="comment_"]')) {
    final cid = int.tryParse(_digitsRe.firstMatch(dl.id)?.group(0) ?? '');
    final message = cid == null ? null : dl.querySelector('dd#comment_$cid');
    final author = dl.querySelector('dt a[id^="author_"]') ?? dl.querySelector('dt > a[href*="mod=space"]');
    if (cid == null || message == null) {
      continue;
    }
    final avatar = dl.querySelector('dd.m img');
    final avatarUrl = author == null ? null : avatar?.attributes['src'] ?? avatar?.attributes['data-src'];
    // A guest's or an anonymous comment has no link, only the name as text.
    final name = _textOf(author) ?? _ownText(dl.querySelector('dt')) ?? '';
    comments.add(
      SpaceBlogComment(
        cid: cid,
        author: name,
        uid: _intOf(_uidRe, author?.attributes['href']),
        avatarUrl: avatarUrl == null || avatarUrl.isEmpty ? null : spaceAbsoluteUrl(avatarUrl),
        time: _textOf(dl.querySelector('dt span.xg1')),
        message: message,
        canDelete: dl.querySelector('a#c_${cid}_delete') != null,
        canReply: dl.querySelector('a#c_${cid}_reply') != null,
      ),
    );
  }
  return comments;
}

/// The text of [e] itself, not of its children.
String? _ownText(uh.Element? e) {
  final s = e?.nodes.whereType<uh.Text>().map((t) => t.text ?? '').join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return s == null || s.isEmpty ? null : s;
}

/// A blog with its content and a page of its comments (`home.php?mod=space&uid=N&do=blog&id=M[&page=P]`).
///
/// ```html
/// <div class="vw mbm">
///   <div class="h pbm"><h1 class="ph">TITLE</h1>
///     <p class="xg2"><span class="xg1">2026-11-9 01:05</span> | <span class="xg1">个人分类:<a>CATEGORY</a></span></p>
///   </div>
///   <div id="blog_article" class="d cl">CONTENT</div>
/// </div>
/// <h3>评论 (<span id="comment_replynum">2</span> 个评论)</h3>
/// <div id="comment_ul" class="xld xlda">
///   <dl id="comment_7_li" class="bbda cl">
///     <dd class="m avt"><a href="home.php?mod=space&uid=U"><img src="AVATAR"></a></dd>
///     <dt><span class="y xw0">编辑 删除</span><a href="home.php?mod=space&uid=U" id="author_7">NAME</a>
///       <span class="xg1 xw0">2026-11-9 01:08</span></dt>
///     <dd id="comment_7">MESSAGE</dd>
///   </dl>
/// </div>
/// <div class="pg">…<a class="nxt">下一页</a></div>
/// ```
SpaceBlogDetail parseSpaceBlogDetail(uh.Document document) {
  final view = document.querySelector('div#ct div.vw');
  final content = document.querySelector('div#blog_article');
  if (view == null || content == null) {
    final notice = _noticeOf(document);
    return SpaceBlogDetail(
      message: notice?.message,
      needLogin: notice?.needLogin ?? false,
      passwordRequired: notice?.passwordRequired ?? false,
    );
  }
  final header = view.querySelector('div.h');
  final category = _textOf(header?.querySelector('p.xg2 a[href*="classid="]'));
  final comments = _commentsOf(document);
  return SpaceBlogDetail(
    title: _textOf(view.querySelector('h1')),
    // Beside the reads ("已有 3 次阅读"): the date, or how long ago ("3 小时前") for a recent one.
    time: header
        ?.querySelectorAll('p.xg2 > span.xg1')
        .map(_textOf)
        .nonNulls
        .where((e) => _timeRe.hasMatch(e) || !e.contains('阅读') && !e.contains(':') && !e.contains('：'))
        .firstOrNull,
    category: category,
    content: content,
    comments: comments,
    commentCount: int.tryParse(_textOf(document.querySelector('#comment_replynum')) ?? ''),
    nextCommentsUrl: _nextPageUrl(document.querySelector('div#div_main_content')?.parent),
  );
}

/// An album list page of a member (`home.php?mod=space&uid=N&do=album&view=me`).
///
/// ```html
/// <ul class="ml mla cl">
///   <li><div class="c"><a href="home.php?mod=space&uid=N&do=album&id=M"><img src="COVER" alt="NAME" /></a></div>
///     <p class="ptn"><a href="…&id=M" class="xi2">NAME</a> (2) </p></li>
///   <li><div class="c"><a href="…&id=-1"><div class="nophoto"></div></a></div>
///     <p class="ptn xi2"><a href="…&id=-1">默认相册</a></p></li>
/// </ul>
/// ```
SpaceListPage<SpaceAlbum> parseSpaceAlbumListPage(uh.Document document) {
  final list = document.querySelector('div#ct ul.mla');
  if (list == null) {
    if (_noticeOf(document) case final notice?) {
      return SpaceListPage(
        items: const [],
        message: notice.message,
        needLogin: notice.needLogin,
        passwordRequired: notice.passwordRequired,
      );
    }
    return const SpaceListPage(items: []);
  }
  final items = <SpaceAlbum>[];
  for (final li in list.children.where((e) => e.localName == 'li')) {
    final name = li.querySelector('p.ptn');
    final link = name?.querySelector('a[href*="do=album"]') ?? li.querySelector('a[href*="do=album"]');
    final href = link?.attributes['href'];
    final albumId = _intOf(_idRe, href);
    final uid = _intOf(_uidRe, href);
    final title = _textOf(link) ?? li.querySelector('img')?.attributes['alt'];
    if (albumId == null || uid == null || title == null || title.isEmpty) {
      continue;
    }
    final cover = li.querySelector('div.c img')?.attributes['src'];
    items.add(
      SpaceAlbum(
        albumId: albumId,
        uid: uid,
        name: title,
        coverUrl: cover == null || cover.isEmpty ? null : spaceAbsoluteUrl(cover),
        count: _intOf(_albumCountRe, name?.text),
      ),
    );
  }
  return SpaceListPage(items: items, nextPageUrl: _nextPageUrl(document.querySelector('div#ct')));
}

/// A page of the pictures of an album (`home.php?mod=space&uid=N&do=album&id=M`).
///
/// ```html
/// <div class="tbmu cl">…共 2 张图片</div>
/// <ul class="ptw ml mlp cl">
///   <li><a href="home.php?mod=space&uid=N&do=album&picid=P"><img src="data/attachment/album/…/x.png.thumb.jpg" alt="" /></a></li>
/// </ul>
/// ```
SpaceListPage<SpacePhoto> parseSpaceAlbumPhotosPage(uh.Document document) {
  final list = document.querySelector('div#ct ul.mlp');
  final titleText = document.querySelector('title')?.text ?? '';
  final title = _albumTitleRe.firstMatch(titleText)?.group(1)?.trim();
  if (list == null) {
    if (_noticeOf(document) case final notice?) {
      return SpaceListPage(
        items: const [],
        title: title,
        message: notice.message,
        needLogin: notice.needLogin,
        passwordRequired: notice.passwordRequired,
      );
    }
    return SpaceListPage(items: const [], title: title);
  }
  final items = <SpacePhoto>[];
  for (final a in list.querySelectorAll('li a[href*="picid="]')) {
    final picId = _intOf(_picIdRe, a.attributes['href']);
    final img = a.querySelector('img');
    final src = img?.attributes['src'] ?? img?.attributes['data-src'];
    if (picId == null || src == null || src.isEmpty) {
      continue;
    }
    final thumb = spaceAbsoluteUrl(src);
    final alt = img?.attributes['alt']?.trim();
    items.add(
      SpacePhoto(
        picId: picId,
        thumbUrl: thumb,
        imageUrl: spacePhotoImageUrl(thumb),
        title: alt == null || alt.isEmpty ? null : alt,
      ),
    );
  }
  return SpaceListPage(
    items: items,
    title: title,
    totalCount: _intOf(_photoTotalRe, document.querySelector('div#ct div.tbmu')?.text),
    nextPageUrl: _nextPageUrl(document.querySelector('div#ct')),
  );
}

List<SpaceFormChoice> _choicesOf(uh.Element? select, {Set<String> skip = const {}}) => [
  for (final option in select?.querySelectorAll('option') ?? const <uh.Element>[])
    if (option.attributes['value'] case final String value when !skip.contains(value))
      if (_textOf(option) case final String label) (value: value, label: label),
];

/// The result of reading a form page: the form, or the forum's words instead of it.
typedef SpaceFormPage<T> = ({T? form, String? message, bool needLogin});

/// The new blog form (`home.php?mod=spacecp&ac=blog`), or what the forum printed instead (no permission, the module
/// switched off, the login prompt).
///
/// ```html
/// <form id="ttHtmlEditor" action="home.php?mod=spacecp&ac=blog&blogid=" …>
///   <input name="subject" /> <textarea name="message"></textarea>
///   <select name="classid"><option value="0">------</option><option value="1">日常</option>
///     <option value="addoption">+新建分类</option></select>
///   <select name="friend"><option value="0">全站用户可见</option>…<option value="4">凭密码可见</option></select>
///   <input type="hidden" name="blogsubmit" value="true" /><input type="hidden" name="formhash" value="…" />
/// </form>
/// ```
SpaceFormPage<BlogPostForm> parseBlogPostForm(uh.Document document) {
  final form = document.querySelector('form#ttHtmlEditor') ?? document.querySelector('form[action*="ac=blog"]');
  final formHash = form?.querySelector('input[name="formhash"]')?.attributes['value'];
  final uid = parseLoggedUidFromDocument(document);
  if (form == null ||
      formHash == null ||
      formHash.isEmpty ||
      form.querySelector('input[name="blogsubmit"]') == null ||
      form.querySelector('[name="message"]') == null) {
    final notice = _noticeOf(document);
    return (form: null, message: notice?.message, needLogin: (notice?.needLogin ?? false) || uid == null);
  }
  if (uid == null) {
    return (form: null, message: null, needLogin: true);
  }
  return (
    form: BlogPostForm(
      uid: uid,
      formHash: formHash,
      categories: _choicesOf(form.querySelector('select[name="classid"]'), skip: const {'0', 'addoption'}),
      privacy: _choicesOf(form.querySelector('select[name="friend"]')),
      systemCategories: _choicesOf(form.querySelector('select[name="catid"]'), skip: const {'0', ''}),
    ),
    message: null,
    needLogin: false,
  );
}

final _uploadUrlRe = RegExp(r'''upload_url\s*:\s*["']([^"']+)["']''');
final _postParamsRe = RegExp(
  r'''post_params\s*:\s*\{\s*["']uid["']\s*:\s*["'](\d+)["']\s*,\s*["']hash["']\s*:\s*["']([0-9a-f]+)["']''',
);
final _sizeLimitRe = RegExp(r'''file_size_limit\s*:\s*["']?(\d+)''');
final _fileTypesRe = RegExp(r'''file_types\s*:\s*["']([^"']+)["']''');

/// The album upload page (`home.php?mod=spacecp&ac=upload`), or what the forum printed instead.
///
/// The pictures are sent one by one to the uploader of the page (`SWFUpload`, `upload_url`) with its `post_params`
/// (`uid`, `hash`), which answers the picture's `picid`; the album form then files them:
///
/// ```html
/// <form id="albumform" action="home.php?mod=spacecp&ac=upload">
///   <script>var upload = new SWFUpload({upload_url: "https://forum.test/misc.php?mod=swfupload&action=swfupload&operation=album",
///     post_params: {"uid" : "31", "hash":"…"}, file_size_limit : "2000", file_types : "*.jpg;*.jpeg;*.gif;*.png", …});</script>
///   <input type="radio" name="albumop" value="selectalbum" /> <input type="radio" name="albumop" value="creatalbum" />
///   <select name="albumid"><option value="1">ALBUM</option></select>
///   <input name="albumname" /> <textarea name="depict"></textarea> <select name="friend">…</select>
///   <input type="hidden" name="albumsubmit" value="true" /><input type="hidden" name="formhash" value="…" />
/// </form>
/// ```
SpaceFormPage<AlbumUploadForm> parseAlbumUploadForm(uh.Document document) {
  final form = document.querySelector('form#albumform');
  final formHash = form?.querySelector('input[name="formhash"]')?.attributes['value'];
  final uid = parseLoggedUidFromDocument(document);
  final script = form
      ?.querySelectorAll('script')
      .map((e) => e.text ?? '')
      .firstWhere(
        (e) => e.contains('SWFUpload'),
        orElse: () => '',
      );
  final uploadUrl = _uploadUrlRe.firstMatch(script ?? '')?.group(1);
  final params = _postParamsRe.firstMatch(script ?? '');
  if (form == null ||
      formHash == null ||
      formHash.isEmpty ||
      form.querySelector('input[name="albumsubmit"]') == null ||
      uploadUrl == null ||
      params == null) {
    final notice = _noticeOf(document);
    return (form: null, message: notice?.message, needLogin: (notice?.needLogin ?? false) || uid == null);
  }
  if (uid == null) {
    return (form: null, message: null, needLogin: true);
  }
  final types = _fileTypesRe.firstMatch(script!)?.group(1);
  final extensions = types == null
      ? null
      : [
          for (final e in types.split(';'))
            if (e.trim().replaceFirst(RegExp(r'^\*?\.'), '').toLowerCase() case final ext when ext.isNotEmpty) ext,
        ];
  return (
    form: AlbumUploadForm(
      uid: uid,
      formHash: formHash,
      uploadUrl: spaceAbsoluteUrl(uploadUrl),
      uploadUid: params.group(1)!,
      uploadHash: params.group(2)!,
      albums: _choicesOf(form.querySelector('select[name="albumid"]')),
      privacy: _choicesOf(form.querySelector('select[name="friend"]')),
      maxKb: int.tryParse(_sizeLimitRe.firstMatch(script)?.group(1) ?? ''),
      extensions: extensions == null || extensions.isEmpty ? const ['jpg', 'jpeg', 'gif', 'png'] : extensions,
    ),
    message: null,
    needLogin: false,
  );
}

final _picIdAnswerRe = RegExp(r'''["']picid["']\s*:\s*["']?(\d+)''');

/// The `picid` the album uploader answered [data] with (`{"picid":"12", "url":"…", "bigimg":"…"}`), null when it took
/// nothing (`"picid":"0"`: not a picture, too large, no room left, the module off) or the answer is not its own.
int? parseAlbumUploadAnswer(Object? data) {
  final picId = switch (data) {
    {'picid': final Object? v} => int.tryParse('$v'),
    final String s => int.tryParse(_picIdAnswerRe.firstMatch(s)?.group(1) ?? ''),
    _ => null,
  };
  return picId == null || picId <= 0 ? null : picId;
}

/// The id of the blog in the url [url] the forum goes to once a blog is posted
/// (`home.php?mod=space&uid=N&do=blog&quickforward=1&id=M`), null for any other url.
int? spaceBlogIdOfUrl(String? url) {
  if (url == null || !url.contains('do=blog')) {
    return null;
  }
  final id = _intOf(_idRe, url);
  return id == null || id <= 0 ? null : id;
}

/// The id of the album in the url [url] the forum goes to once pictures are filed
/// (`home.php?mod=space&uid=N&do=album&quickforward=1&id=M`, `-1` for the default album), null for any other url.
int? spaceAlbumIdOfUrl(String? url) {
  if (url == null || !url.contains('do=album')) {
    return null;
  }
  return _intOf(_idRe, url);
}

/// The first page of the blogs of [uid].
String spaceBlogListUrl(int uid) => '$baseUrl/home.php?mod=space&uid=$uid&do=blog&view=me';

/// The blog [blogId] of [uid].
String spaceBlogUrl(int uid, int blogId) => '$baseUrl/home.php?mod=space&uid=$uid&do=blog&id=$blogId';

/// The first page of the albums of [uid].
String spaceAlbumListUrl(int uid) => '$baseUrl/home.php?mod=space&uid=$uid&do=album&view=me';

/// The first page of the pictures of the album [albumId] of [uid].
String spaceAlbumUrl(int uid, int albumId) => '$baseUrl/home.php?mod=space&uid=$uid&do=album&id=$albumId';

/// The forum's words that a module of the space is switched off ("抱歉，留言板功能尚未开启", `wall_status_off`;
/// "抱歉，好友功能尚未开启", `friend_status_off`, which the greetings belong to).
bool spaceModuleSwitchedOff(String? message) => message != null && _switchedOffRe.hasMatch(message);

final _switchedOffRe = RegExp('尚未开启|尚未開啓|尚未開啟');

SpaceSession? _sessionOf(uh.Document document) {
  final uid = parseLoggedUidFromDocument(document);
  final formHash = parseFormHash(document);
  return uid == null || formHash == null || formHash.isEmpty ? null : SpaceSession(uid: uid, formHash: formHash);
}

/// A page of the wall of a member (`home.php?mod=space&uid=N&do=wall[&cid=C][&page=P]`): the messages, newest first,
/// twenty a page; with `cid` only that message.
///
/// ```html
/// <form id="quickcommentform_N" action="home.php?mod=spacecp&ac=comment">
///   <textarea name="message"></textarea>   (a guest: <div class="pt hm">您需要登录后才可以留言 …</div>)
///   <input type="hidden" name="id" value="N" /><input type="hidden" name="idtype" value="uid" />
///   <input type="hidden" name="formhash" value="…" />
/// </form>
/// <div id="div_main_content"><div id="comment"><div id="comment_ul">…the comments ([_commentsOf])…</div></div>
///   <div class="pgs cl mtm"><div class="pg">…<a href="…&page=2" class="nxt">下一页</a></div></div></div>
/// ```
///
/// What the forum prints instead (the privacy notice, `wall_status_off`, the login prompt) is the page's [SpaceListPage.message].
SpaceListPage<SpaceBlogComment> parseSpaceWallPage(uh.Document document) {
  final form = document.querySelector('form[id^="quickcommentform_"]');
  final list = document.querySelector('div#div_main_content');
  if (form == null && list == null) {
    if (_noticeOf(document) case final notice?) {
      return SpaceListPage(
        items: const [],
        message: notice.message,
        needLogin: notice.needLogin,
        passwordRequired: notice.passwordRequired,
      );
    }
    return const SpaceListPage(items: []);
  }
  return SpaceListPage(
    items: _commentsOf(document),
    nextPageUrl: _nextPageUrl(list ?? document.querySelector('div#ct')),
    session: _sessionOf(document),
    canPost: form?.querySelector('textarea[name="message"]') != null,
  );
}

/// The poke form (`home.php?mod=spacecp&ac=poke&op=send|reply&uid=N`), or what the forum printed instead (the
/// member himself, no permission `no_privilege_poke`, `friend_status_off`, the login prompt).
///
/// ```html
/// <form id="pokeform_N" action="home.php?mod=spacecp&ac=poke&op=send&uid=N">
///   <input type="hidden" name="pokesubmit" value="true" /><input type="hidden" name="formhash" value="…" />
///   <div class="mbm xs2"><a href="home.php?mod=space&uid=N" class="avt avts"><img …></a> 向 <strong>NAME</strong> 打个招呼:</div>
///   <ul class="poke cl">
///     <li><label><input type="radio" name="iconid" value="0" />不用动作</label></li>
///     <li><label><input type="radio" name="iconid" value="1" /><img alt="cyx" src="static/image/poke/cyx.gif" /> 踩一下</label></li>
///     <li><label><input type="radio" name="iconid" value="3" checked="checked" /><img … /> 微笑</label></li>
///   </ul>
///   <input type="text" name="note" />
/// </form>
/// ```
SpaceFormPage<PokeForm> parsePokeForm(uh.Document document, {required bool reply}) {
  final form = document.querySelector('form[id^="pokeform_"]');
  final formHash = form?.querySelector('input[name="formhash"]')?.attributes['value'];
  final uid = parseLoggedUidFromDocument(document);
  final targetUid = _intOf(_uidRe, form?.attributes['action']);
  final icons = <PokeIcon>[];
  var selected = '';
  for (final input in form?.querySelectorAll('input[name="iconid"]') ?? const <uh.Element>[]) {
    final id = input.attributes['value'];
    if (id == null || id.isEmpty) {
      continue;
    }
    final label = input.parent;
    final image = label?.querySelector('img')?.attributes['src'];
    icons.add(
      PokeIcon(
        id: id,
        label: _textOf(label) ?? id,
        imageUrl: image == null || image.isEmpty ? null : spaceAbsoluteUrl(image),
      ),
    );
    if (input.attributes.containsKey('checked')) {
      selected = id;
    }
  }
  if (form == null || formHash == null || formHash.isEmpty || targetUid == null || icons.isEmpty) {
    final notice = _noticeOf(document);
    return (form: null, message: notice?.message, needLogin: (notice?.needLogin ?? false) || uid == null);
  }
  if (uid == null) {
    return (form: null, message: null, needLogin: true);
  }
  return (
    form: PokeForm(
      uid: uid,
      targetUid: targetUid,
      targetName: _textOf(form.querySelector('div.xs2 strong')),
      formHash: formHash,
      icons: icons,
      selected: selected.isEmpty ? icons.first.id : selected,
      reply: reply,
    ),
    message: null,
    needLogin: false,
  );
}

/// A page of the greetings received (`home.php?mod=spacecp&ac=poke[&page=P]`), the latest of each member.
///
/// ```html
/// <div id="poke_ul" class="xld xlda">
///   <dl id="poke_31" class="bbda cl">
///     <dd class="m avt"><a href="home.php?mod=space&uid=31"><img src="AVATAR"></a></dd>
///     <dt id="poke_td_31"><p class="mbm"><a href="home.php?mod=space&uid=31" class="xi2">NAME</a>:
///       <span class="xw0"><img alt="wgs" src="static/image/poke/wgs.gif" class="vm" /> 握个手, 说: NOTE&nbsp;
///         <span class="xg1">11-10 12:06</span></span></p>
///       <div class="pbn ptm xg1 xw0 cl"><a href="…&op=reply&uid=31…">回打招呼</a> <a href="…&op=ignore&uid=31…">忽略</a></div></dt>
///   </dl>
/// </div>
/// ```
///
/// None left is `<div class="emp">还没有新招呼</div>`; what the forum prints instead (`friend_status_off`, the login
/// prompt) is the page's [SpaceListPage.message].
SpaceListPage<ReceivedPoke> parseReceivedPokePage(uh.Document document) {
  final ct = document.querySelector('div#ct');
  final session = _sessionOf(document);
  if (ct?.querySelector('ul.tb a[href*="ac=poke"]') == null) {
    if (_noticeOf(document) case final notice?) {
      return SpaceListPage(
        items: const [],
        message: notice.message,
        needLogin: notice.needLogin,
        passwordRequired: notice.passwordRequired,
      );
    }
    return SpaceListPage(items: const [], needLogin: session == null);
  }
  final items = <ReceivedPoke>[];
  for (final dl in ct!.querySelectorAll('div#poke_ul dl[id^="poke_"]')) {
    final uid = int.tryParse(_digitsRe.firstMatch(dl.id)?.group(0) ?? '');
    final line = dl.querySelector('dt p.mbm');
    final name = _textOf(line?.querySelector('a[href*="mod=space"]'));
    final content = line?.querySelector('span.xw0');
    if (uid == null || name == null || content == null) {
      continue;
    }
    final time = content.querySelector('span.xg1');
    final timeText = _textOf(time);
    time?.remove();
    final avatar = dl.querySelector('dd.m img');
    final avatarUrl = avatar?.attributes['src'] ?? avatar?.attributes['data-src'];
    items.add(
      ReceivedPoke(
        uid: uid,
        username: name,
        avatarUrl: avatarUrl == null || avatarUrl.isEmpty ? null : spaceAbsoluteUrl(avatarUrl),
        content: content,
        time: timeText,
      ),
    );
  }
  return SpaceListPage(items: items, nextPageUrl: _nextPageUrl(ct), session: session);
}

/// What the forum printed instead of a page of the space, for the parsers of its other pages (the follow lists, the
/// broadcasts, the records): the privacy notice, the 提示信息 of a switched off module, the login prompt; null when
/// the page is none of them.
({String message, bool needLogin, bool passwordRequired})? spaceNoticeOf(uh.Document document) => _noticeOf(document);

/// The account [document] was served to and the form hash of its session; null for a guest.
SpaceSession? spaceSessionOf(uh.Document document) => _sessionOf(document);

/// The next page of the pager (`div.pg a.nxt`) under [root], null on the last page.
String? spaceNextPageUrlOf(uh.Element? root) => _nextPageUrl(root);

final _cdataRe = RegExp(r'<!\[CDATA\[([\s\S]*)\]\]>');

/// The fragment of the answer [data] to an AJAX request of a list (more broadcasts, the replies of a record): the
/// `document` the forum's app API carries it in (plugin 2.6.0, a `page` result), else the text out of the forum's own
/// XML envelope (`<root><![CDATA[…]]></root>`); null for an answer that is none (a `showmessage` of the forum, as a
/// module switched off or the login prompt; nothing at all).
String? spaceAjaxFragmentOf(Object? data) {
  if (tsdmAppWriteResultOf(data) case final api?) {
    return api.kind == TsdmAppWriteKind.page ? api.documentHtml : null;
  }
  final text = tsdmAppAnswerText(data);
  if (text.trim().isEmpty || text.contains('errorhandle_') || text.contains('id="messagetext"')) {
    return null;
  }
  return _cdataRe.firstMatch(text)?.group(1) ?? text;
}

/// The first page of the wall of [uid] (of the account in use for 0: a guest is asked to log in); with [cid] only
/// that message.
String spaceWallUrl(int uid, {int? cid}) =>
    '$baseUrl/home.php?mod=space${uid > 0 ? '&uid=$uid' : ''}&do=wall${cid == null ? '' : '&cid=$cid'}';

/// The first page of the greetings received.
const spacePokeListUrl = '$baseUrl/home.php?mod=spacecp&ac=poke';
