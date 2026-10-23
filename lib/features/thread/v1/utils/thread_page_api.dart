import 'dart:convert';

import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/forum/models/models.dart';
import 'package:tsdm_client/features/thread/v1/models/models.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/special_block.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/card/post_card/post_medal_menu_info.dart';
import 'package:universal_html/parsing.dart';

/// The structured thread page answer in [data]: a JSON answer of the forum's app API that carries every field the app
/// reads (plugin 2.1.0, `schema` 3 or later, `type: thread`: other pages have their own schemas), or the forum's own
/// message of such a plugin (no permission, please log in, no such thread: `ok` 0, `error: message`, with `login`
/// telling the two apart). Null when the answer has to be read from its `document` as before: a web page, an older
/// plugin's answer (no `schema`, no `login`), the antitheft challenge or the thread cache a guest is served
/// (`error: unknown`), a failed build.
///
/// The page is then built by [threadPageFromApi]; the `document` of the answer, when there is one, is never parsed.
Map<String, dynamic>? threadApiAnswerOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  final schema = json['schema'];
  final structured = schema is num && schema >= 3;
  if (json['ok'] == 1) {
    return structured && json['type'] == 'thread' ? json : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message' && (structured || json['login'] is int)) {
    return json;
  }
  return null;
}

/// Build the thread page from a structured answer [json] of the forum's app API ([threadApiAnswerOf]), asked for
/// page [pageNumber].
///
/// The same [ThreadPageInfo] the web page gives through [parseThreadDocument], from the fields instead of the html:
///
/// * `thread` gives the id (null when the answer does not name it, so the page keeps the thread it asked for), the
///   title, the forum, the counts, the soft close (the lock beside the title), the draft mark, the latest moderation
///   sentence (`modact`, the page's `div.modact`), the type (`typeid` with `typename`, the `[type]` beside the
///   title; none when the thread has no type) and the thread's author (`authorid`, [ThreadPageInfo.authorUid]; none
///   for an anonymous thread, `authorid` 0), on every page, so a page past the first tells who started the thread;
///   the reply count is the "回复: N" of the page's info row (`allreplies`, plugin 2.8.2: replies and comments,
///   whatever filter the page has), `replies` before;
/// * `forum.name` is the forum's name, `nav` the breadcrumbs from the group down to the forum of the thread (the
///   group linked as `forum.php?gid=`, a forum as `forum.php?mod=forumdisplay&fid=`), the thread itself not among
///   them, as the page's breadcrumb parser leaves them;
/// * `page` / `pages` are the pagination the forum printed (`page` clamped to the last page as the forum does when
///   asked past it; the `pages` of the forum's own order, which a reversed or author-only request keeps), `ppp` the
///   floors per page of the account and `thread.replies` the replies the pages are counted from;
/// * `reply.allowed` (the thread takes a reply), `reply.fastpost` (the fast reply form is printed) and
///   `reply.fastpost_allowed` (the form has its textarea: a newbie, an account without avatar… have `allowed` 1 but
///   no textarea) tell a member whether the thread is closed (`threadClosed`), as the page parser reads the form and
///   its closed hint; a guest's page is never closed, as the web page tells a guest to log in instead;
/// * `reply` with the answer's `formhash` is the fast reply form (`replyParameters`), none when the forum prints no
///   form (`fastpost` 0);
/// * `posts` are the floors in the forum's order, hot and sticky replies included ([Post.fromApi]), with the
///   answer's `uid` as the account they were served to; the placeholder of a deleted floor of a rush thread
///   (`deleted` 1) is left out, as the page parser leaves it out; the times are the forum's wall clock with the
///   answer's `timeoffset`, as the page prints them; since plugin 2.7.0 (`schema: 14`) each floor also
///   keeps its bbcode, its attachments, the answer's `codes` and `smilies_version`, for the app's own renderer;
/// * `menus_html` are the medal menus of the page, parsed as the page's (`PostMedalMenuItem`);
/// * since plugin 2.8.0 (`schema: 15`) `special` is the special block of the first floor (poll, goods, bounty,
///   activity, debate: [ThreadSpecial], null when the answer has none or names another type), kept on the page and
///   on the first floor ([Post.special]), whose content then leaves out what the forum's template of the block
///   printed ([bodyHtmlWithoutSpecialBlock]): the app shows the block as its own card. The floors the account may
///   accept as the answer of a bounty (`special.set_best.pids`) carry the request doing it
///   ([Post.bestAnswerRequest]); each floor's side in a debate and the accepted answer come with the floor
///   ([Post.fromApi]). Without `special` every floor is exactly what it was.
///
/// The forum's message (`ok` 0): `login` 1 is the login prompt of a guest (`needLogin`), 0 a member without
/// permission (`havePermission` false, the message text as the denied message, as the page's `#messagetext p`);
/// such a page names no thread and has no reply form, as the web page has none.
ThreadPageInfo threadPageFromApi(Map<String, dynamic> json, int pageNumber) {
  if (json['ok'] != 1) {
    final needLogin = json['login'] == 1;
    return ThreadPageInfo(
      tid: null,
      title: null,
      fid: null,
      forumName: null,
      currentPage: pageNumber,
      totalPages: pageNumber,
      havePermission: needLogin,
      permissionDeniedMessage: needLogin
          ? null
          : parseHtmlDocument('<p>${htmlEscape.convert(_text(json['message']))}</p>').querySelector('p'),
      needLogin: needLogin,
      threadSoftClosed: false,
      // No reply form on a message page, as on the web page.
      threadClosed: true,
      postList: const [],
      replyParameters: null,
      threadType: null,
      isDraft: false,
      latestModAct: null,
      breadcrumbs: const [],
      postMedals: const [],
      viewCount: null,
      replyCount: null,
    );
  }

  final thread = _map(json['thread']);
  final forum = _map(json['forum']);
  final reply = _map(json['reply']);
  final uid = _int(json['uid']);
  // A thread id the answer does not name (or names badly) is null, so the page keeps the thread it asked for.
  final tidValue = _int(thread['tid']);
  final tid = tidValue > 0 ? '$tidValue' : null;
  final fidValue = _int(thread['fid']);
  final fid = fidValue > 0 ? fidValue : null;
  final currentPage = json['page'] is num ? _int(json['page']) : pageNumber;
  final totalPages = json['pages'] is num ? _int(json['pages']) : pageNumber;
  final draft = _int(thread['draft']) == 1;
  final pay = thread['pay'] is Map<String, dynamic> ? _map(thread['pay']) : null;
  final timeOffset = tsdmAppTimeOffset(json);
  final special = ThreadSpecial.fromApi(
    json['special'],
    formHash: _text(json['formhash']),
    viewerUid: uid,
    timeOffset: timeOffset,
  );

  // The placeholder a rush thread prints for a deleted floor (`deleted` 1: "无效楼层，该帖已经被删除", no author, no
  // content) is left out, as the page parser leaves out a floor without an author.
  final bestAnswerForm = special == null ? _rewardBestAnswerFormOf(thread, viewerUid: uid, page: currentPage) : null;
  final postList = _list(json['posts']).where((p) => _int(p['deleted']) != 1).map((p) {
    final first = _int(p['first']) == 1;
    var post = Post.fromApi(
      p,
      tid: tid ?? '',
      fid: fid ?? 0,
      viewerUid: uid,
      page: currentPage,
      pay: pay,
      draft: draft,
      codes: json['codes'],
      smiliesVersion: json['smilies_version'] is String ? json['smilies_version'] as String : null,
      threadSpecial: _int(thread['special']),
      timeOffset: timeOffset,
    );
    post = _withSpecial(post, special, first: first);
    post = _withDebateVote(
      post,
      special,
      tid: tidValue,
      viewerUid: uid,
      debate: _int(thread['special']) == 5,
      closed: _int(thread['closed']) != 0,
    );
    // A page without the bounty's block (another page than the first): the thread's author accepts on the floors the
    // forum's own form takes ([_rewardBestAnswerFormOf]).
    if (bestAnswerForm != null &&
        !first &&
        _int(p['invisible']) == 0 &&
        _int(p['anonymous']) == 0 &&
        _int(p['authorid']) > 0 &&
        _int(p['authorid']) != uid) {
      final request = rewardBestAnswerRequest(
        bestAnswerForm,
        _int(p['pid']),
        formHash: _text(json['formhash']),
        viewerUid: uid,
      );
      if (request != null) {
        post = post.copyWith(bestAnswerRequest: request);
      }
    }
    return post;
  }).toList();

  final typeId = _int(thread['typeid']);
  final typeName = _text(thread['typename']);
  final threadType = typeId > 0 && typeName.isNotEmpty ? FilterType(name: typeName, typeID: '$typeId') : null;

  final formHash = _text(json['formhash']);
  final replyParameters = _int(reply['fastpost']) == 1 && formHash.isNotEmpty && tid != null && fid != null
      ? ReplyParameters(
          fid: '$fid',
          tid: tid,
          postTime: reply['posttime'] is String ? _text(reply['posttime']) : null,
          formHash: formHash,
          subject: _text(reply['subject']),
          debate: _int(thread['special']) == 5,
          debateStand: _int(thread['special']) == 5 ? _debateStandOf(reply, special) : null,
          viewerUid: uid > 0 ? uid : null,
          // Plugin 2.9.1: the quick reply asks for a captcha or a security question (`reply.seccheck`).
          verification: reply['seccheck'] is Map,
          secCheck: SecCheck.fromJson(reply['seccheck'], modid: SecCheck.viewthreadModid),
        )
      : null;

  final breadcrumbs = _list(json['nav'])
      .map(
        (e) => ThreadBreadcrumb(
          description: _text(e['name']),
          link: Uri.parse(
            _text(e['type']) == 'group'
                ? '$baseUrl/forum.php?gid=${_int(e['fid'])}'
                : '$baseUrl/forum.php?mod=forumdisplay&fid=${_int(e['fid'])}',
          ),
        ),
      )
      .toList();

  final menus = json['menus_html'] is List ? (json['menus_html'] as List).whereType<String>().join() : '';
  final postMedals = menus.isEmpty
      ? const <PostMedalMenuItem>[]
      : parseHtmlDocument(menus)
            .querySelectorAll(r'div[id^="md_"][id$="_menu"]')
            .map(PostMedalMenuItem.fromDiv)
            .whereType<PostMedalMenuItem>()
            .toList();

  final modAct = _text(thread['modact']);

  return ThreadPageInfo(
    tid: tid,
    title: _text(thread['subject']),
    fid: fid,
    forumName: _text(forum['name']),
    currentPage: currentPage,
    totalPages: totalPages,
    havePermission: true,
    permissionDeniedMessage: null,
    needLogin: false,
    threadSoftClosed: _int(thread['soft_closed']) == 1,
    // Closed for a member when the forum takes no reply, prints no fast reply form, or a form without its textarea
    // (a newbie, an account without avatar…), as the page parser reads the form. A guest is told to log in instead
    // of a closed thread on the web page: not closed until logged in.
    threadClosed:
        uid > 0 &&
        (_int(reply['allowed']) == 0 || _int(reply['fastpost']) == 0 || _int(reply['fastpost_allowed']) == 0),
    postList: postList,
    replyParameters: replyParameters,
    threadType: threadType,
    isDraft: draft,
    latestModAct: modAct.isEmpty ? null : modAct,
    breadcrumbs: breadcrumbs,
    postMedals: postMedals,
    viewCount: _int(thread['views']),
    // What the page's info row prints as "回复: N" (replies and comments, whatever filter the page has; plugin
    // 2.8.2); `replies` is the count the forum changed for the pages (one author's floors…), taken before.
    replyCount: thread['allreplies'] is num ? _int(thread['allreplies']) : _int(thread['replies']),
    special: special,
    authorUid: _int(thread['authorid']) > 0 ? _int(thread['authorid']) : null,
    postsPerPage: _int(json['ppp']) > 0 ? _int(json['ppp']) : null,
    paginationReplies: thread['replies'] is num ? _int(thread['replies']) : null,
    // The order the floors came in: the one asked, or the thread's own when none was (its author set it).
    newestFirst: _int(json['ordertype']) == 1,
  );
}

/// [post] with what the page's [special] block gives it: the [first] floor the block itself, its content without the
/// forum's html of the block; a floor the account may accept as the answer of a bounty the request doing it.
Post _withSpecial(Post post, ThreadSpecial? special, {required bool first}) {
  if (special == null) {
    return post;
  }
  final pid = int.tryParse(post.postID) ?? 0;
  if (first) {
    if (post.isSpoofed) {
      // The plugin gives no block for a forged first floor; nothing of it is shown either way.
      return post;
    }
    return post.copyWith(
      special: special,
      data: bodyHtmlWithoutSpecialBlock(post.data, special, pid: post.postID),
    );
  }
  if (special case final RewardSpecial reward when pid > 0) {
    if (reward.bestAnswerRequest(pid) case final request?) {
      return post.copyWith(bestAnswerRequest: request);
    }
  }
  return post;
}

/// [post] with the support of its side in a [debate] ([Post.debateVoteRequest]): the page prints "支持 N" on every
/// floor taking a side; the app offers it to an account that is not the floor's author ([viewerUid], none for a
/// guest), in a thread not [closed] and a debate not ended, the forum refusing anything else anyway. The action is
/// the block's `vote_post`; a page without the block (another page than the first, only one author's floors) has the
/// forum's own link of the floor ([_debateVotePostOf]), the same action.
Post _withDebateVote(
  Post post,
  ThreadSpecial? special, {
  required int tid,
  required int viewerUid,
  required bool debate,
  required bool closed,
}) {
  if (!debate || closed || viewerUid <= 0 || (post.stand != 1 && post.stand != 2) || post.author.uid == '$viewerUid') {
    return post;
  }
  final template = switch (special) {
    final DebateSpecial block => block.ended ? null : block.votePost,
    null => tid > 0 ? _debateVotePostOf(tid) : null,
    _ => null,
  };
  final request = debateVotePostRequest(template, int.tryParse(post.postID) ?? 0, viewerUid: viewerUid);
  return request == null ? post : post.copyWith(debateVoteRequest: request);
}

/// The forum's "设为最佳答案" form for the floors of an open bounty of the account in use ([viewerUid]), on a page
/// without the bounty's block (plugin 2.8.0 gives `set_best` with the first floor only): the thread's author of a
/// bounty not resolved yet (`thread.price` above 0) posts the page's `form#modactions` (`optgroup`, `operation`,
/// `listextra`, `page` of page [page]) to `bestanswer` for a floor, as on the first page. Null otherwise; a moderator
/// accepting an old bounty does it on the first page or the web page, the forum refusing anything else anyway.
RewardSetBest? _rewardBestAnswerFormOf(Map<String, dynamic> thread, {required int viewerUid, required int page}) {
  final tid = _int(thread['tid']);
  if (_int(thread['special']) != 3 ||
      _int(thread['price']) <= 0 ||
      viewerUid <= 0 ||
      _int(thread['authorid']) != viewerUid ||
      tid <= 0) {
    return null;
  }
  return RewardSetBest(
    actionTemplate: 'forum.php?mod=misc&action=bestanswer&tid=$tid&pid={pid}&from=&bestanswersubmit=yes',
    method: 'POST',
    fields: {'optgroup': '', 'operation': '', 'listextra': 'page%3D$page', 'page': '$page'},
    pids: const [],
  );
}

/// The forum's "支持" link of a floor of debate [tid] (`viewthread_node`), as plugin 2.8.0 gives it in `vote_post`.
SpecialActionTemplate _debateVotePostOf(int tid) => SpecialActionTemplate(
  actionTemplate: 'forum.php?mod=misc&action=debatevote&tid=$tid&pid={pid}',
  method: 'GET',
  fields: const {'inajax': '1'},
);

/// The side of the debate the account took, as the page tells it: `reply.stand` (the forum's `firststand` on every
/// debate page, 0 none taken), or on the first page of an answer without it `special.reply_stand` (0 none taken
/// too); null when the page does not tell (another page of an answer without `reply.stand`).
int? _debateStandOf(Map<String, dynamic> reply, ThreadSpecial? special) {
  if (reply['stand'] is num) {
    final stand = _int(reply['stand']);
    return stand == 1 || stand == 2 ? stand : 0;
  }
  return special is DebateSpecial ? special.replyStand : null;
}

/// The reply parameters of a page just read ([next]) keeping the side of a debate the account took that an earlier
/// page of the same thread told ([previous]), when this page does not tell it ([ReplyParameters.debateStand] null:
/// an answer without `reply.stand`, past the first page).
///
/// Only a side taken (1 or 2) is kept, which the forum keeps for every later reply; "none taken yet" is not, the
/// account may have replied on a side since. Only for the same account ([ReplyParameters.viewerUid]): the side of one
/// account sent with another's reply would bind that one to it for good.
ReplyParameters? withKnownDebateStand(ReplyParameters? next, ReplyParameters? previous) {
  if (next == null ||
      previous == null ||
      !next.debate ||
      next.debateStand != null ||
      previous.tid != next.tid ||
      next.viewerUid == null ||
      previous.viewerUid != next.viewerUid) {
    return next;
  }
  final stand = previous.debateStand;
  return stand == 1 || stand == 2 ? next.copyWith(debateStand: stand) : next;
}

/// The account a structured answer [json] ([threadApiAnswerOf]) was served to: its `uid`, null for a guest (0) and
/// for the forum's message, which names none. The readers bound to one account (a draft confirmed, a poll verified,
/// a report prepared) check it as they check the page's `discuz_uid` on the document path.
int? threadApiViewerUid(Map<String, dynamic> json) {
  final uid = _int(json['uid']);
  return uid > 0 ? uid : null;
}

int _int(Object? value) => switch (value) {
  final num n => n.toInt(),
  final String s => int.tryParse(s) ?? 0,
  _ => 0,
};

String _text(Object? value) => value is String ? value : '';

Map<String, dynamic> _map(Object? value) => value is Map<String, dynamic> ? value : const {};

List<Map<String, dynamic>> _list(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];
