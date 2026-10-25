part of 'models.dart';

/// Image url of empty packet.
const _emptyPacketImageUrl = 'static/image/post/rp-2.svg';

extension _ParseExtension on uh.Element {
  static final _rateActionRe = RegExp("'rate', '(?<url>forum.php[^']*)',");

  String? _parseRateAction() {
    return _rateActionRe.firstMatch(attributes['onclick'] ?? '')?.namedGroup('url');
  }

  /// Get the image url from an `<img>` node, prefer the lazy load attributes.
  ///
  /// Discuz X5 lazy loads images with `data-src`, older styles use `data-original`.
  String? _lazyImageUrl() {
    final url = attributes['data-src'] ?? attributes['data-original'] ?? attributes['src'] ?? attributes['file'];
    if (url == null || url.isEmpty) {
      return null;
    }
    if (url.startsWith('./')) {
      return url.substring(2).prependHost();
    }
    return url.prependHost();
  }
}

/// Parse the uid from user space url.
String? _uidFromUrl(String? url) =>
    url?.tryParseAsUri()?.queryParameters['uid'] ?? url?.split('uid=').elementAtOrNull(1);

/// Whether the author column [node] of a floor prints "头像被屏蔽" in place of the avatar: the site hides the avatars
/// of banned authors (`<div class="avatar">头像被屏蔽</div>`, no image).
bool _avatarBlockedIn(uh.Element? node) =>
    node?.querySelectorAll('div.avatar').any((e) => e.querySelector('img') == null && e.innerText.trim() == '头像被屏蔽') ??
    false;

/// Post model.
///
/// Each [Post] contains a reply.
@MappableClass()
class Post with PostMappable {
  /// Constructor.
  const Post({
    required this.postID,
    required this.postFloor,
    required this.author,
    required this.publishTime,
    required this.data,
    required this.replyAction,
    required this.rateAction,
    required this.lastEditUsername,
    required this.lastEditTime,
    required this.shareLink,
    required this.page,
    required this.isDraft,
    required this.packetAllTaken,
    this.locked = const [],
    this.rate,
    this.packetUrl,
    this.editUrl,
    this.userBriefProfile,
    this.poll,
    this.postMedals,
    this.badge,
    this.secondBadge,
    this.signature,
    this.pokemon,
    this.checkin,
    this.reportTarget,
    this.messageBbcode,
    this.messageReason,
    this.bbcodeOff = false,
    this.smileyOff = false,
    this.parseUrlOff = false,
    this.attachments = const [],
    this.bbcodeCodes,
    this.smiliesVersion,
    this.customTags,
    this.stand,
    this.standVotes = 0,
    this.best = false,
    this.special,
    this.bestAnswerRequest,
    this.debateVoteRequest,
    this.avatarBlocked = false,
    this.hot = false,
    this.hotFloor,
    this.fromApp = false,
  });

  /// Build a [Post] from a floor [p] of a structured thread page answer of the forum's app API (plugin 2.1.0,
  /// `schema: 3`, see `threadPageFromApi`), the same [Post] [fromPostNode] reads from the floor of the web page.
  ///
  /// The floor's content `body_html` (the `div.pcb` of the floor, cut from the page as it is) is the `data` the content
  /// renderer gets, untouched: quotes, spoilers, hidden parts, the comment and rate blocks are all in there as on the
  /// web page. The author column `author_html` (the inside of the floor's `td.pls`) is put back in the cell the page
  /// prints it in (`<td id="userinfo_PID" class="pls">`, the id the brief profile reads the floor's `div#ts_avatar_PID`
  /// by: the nickname, the avatar, the group badge) and parsed with the selectors of the web page
  /// ([_parseAuthorColumn]) for what the other plugins put there: the brief profile, medals, badges, pokemon,
  /// checkin. The user group of the brief profile is the one the column prints as text (the staff's
  /// `a.stat_authortitle`), else the name the page gives the badge (its `alt`), else the floor's `group` (`title`,
  /// `color`): the page prints a member's group as its badge only, with an empty `alt`, whose file name is only a
  /// guess at the name. The rest comes from the fields:
  ///
  /// * the author from `author` / `authorid` / `avatar`, an anonymous floor (`anonymous` 1) named "匿名" without uid,
  ///   link or avatar; `dateline` (unix seconds) as the publish time, the forum's wall clock with [timeOffset] (the
  ///   answer's `timeoffset`) as the page prints it ("发表于 2026-10-1 05:30:15"), whatever the device's zone;
  /// * `position` as the floor number (the forum's -1 of a hot reply gives none), `share_url` as the share link;
  ///   `hot` (plugin 2.8.2) marks a hot reply, which the page prints "推荐" for, with the floor it really is
  ///   (`hot_position`, 0 when it cannot be worked out); `avatar_blocked` (plugin 2.8.2) is the "头像被屏蔽" the
  ///   page prints in place of the avatar, which the answer then gives empty; `from_app` (plugin 3.3.0) marks a floor
  ///   posted, replied or edited from the app ([fromApp]);
  /// * `lastedit` as the last edit (the name and the time text the page prints; none when either is empty);
  /// * the purchase lock of the first floor of a paid thread not yet bought ([pay], `thread.pay`, `need_pay` 1), the
  ///   other locks stay in the content for the renderer, as on the web page;
  /// * `rate` as the rate table (the columns, each record's values and reason, the totals), `poll_html` as the poll
  ///   form of the first floor of a poll thread (with [viewerUid], the account the answer was served to);
  /// * the actions the forum allows this account (`can.*` 1) with their urls (`urls.*`): reply, rate, edit, and the
  ///   report of the floor for [viewerUid] in thread [tid] of forum [fid];
  /// * the red packet of the floor from `packet_html` (its `div#ts_packet`, which sits beside the content on the web
  ///   page, so it is not in `body_html`; empty when the floor has none): its url, and whether it is all taken.
  ///
  /// [page] is the page the floor was asked on; [draft] whether the thread is a draft (its first floor is then the
  /// draft, as on the web page, when it can be edited).
  ///
  /// The placeholder of a deleted floor of a rush thread (`deleted` 1: no author, `urls` and `group` null, every
  /// html field empty) builds an empty floor without author, content or action; `threadPageFromApi` leaves it out.
  ///
  /// Plugin 2.7.0 (`schema: 14`) adds the floor's bbcode for the app's own renderer, kept beside everything above:
  /// `message` as [messageBbcode] (null when the answer withholds it, `message_reason` telling why, or has none),
  /// `bbcodeoff` / `smileyoff` / `parseurloff` as the forum renders the floor, `attachments` (what the forum loaded
  /// for this request), and the answer's [codes] with the floor's own switches ([PostBbcodeCodes]) and the version
  /// of the smilies table ([smiliesVersion], the answer's `smilies_version`).
  ///
  /// Plugin 2.8.0 (`schema: 15`) adds what the page prints in the floor's header for a special thread: the side of a
  /// floor of a debate ([stand], with its supporters [standVotes]; only when [threadSpecial], the thread's `special`,
  /// is 5 and the floor is not the first) and the accepted answer of a bounty ([best]). The special block of the first
  /// floor and the accepting of an answer are added by `threadPageFromApi`, which reads the answer's `special`.
  factory Post.fromApi(
    Map<String, dynamic> p, {
    required String tid,
    required int fid,
    required int viewerUid,
    required int page,
    Map<String, dynamic>? pay,
    bool draft = false,
    Object? codes,
    String? smiliesVersion,
    int threadSpecial = 0,
    num timeOffset = 8,
  }) {
    final pid = _apiInt(p['pid']);
    final postID = '$pid';
    final first = _apiInt(p['first']) == 1;
    final position = _apiInt(p['position']);
    final authorId = _apiInt(p['authorid']);
    final anonymous = _apiInt(p['anonymous']) == 1 || authorId <= 0;
    final avatarBlocked = _apiInt(p['avatar_blocked']) == 1;
    final hot = _apiInt(p['hot']) == 1;
    final author = anonymous
        ? const User(name: _anonymousName, url: '')
        : User(
            name: _apiText(p['author']),
            uid: '$authorId',
            url: '$baseUrl/home.php?mod=space&uid=$authorId',
            avatarUrl: avatarBlocked ? null : _apiImageUrl(p['avatar']),
          );

    final authorHtml = _apiText(p['author_html']);
    final table = parseHtmlDocument(
      '<table><tbody><tr><td id="userinfo_$postID" class="pls">$authorHtml</td></tr></tbody></table>',
    ).querySelector('table')!;
    final group = p['group'] is Map<String, dynamic> ? _apiMap(p['group']) : null;
    final column = _parseAuthorColumn(
      table,
      table.querySelector('td.pls'),
      postID: postID,
      author: author,
      groupTitle: group == null ? null : _apiText(group['title']),
      groupColor: group == null ? null : _apiText(group['color']),
    );
    final signatureHtml = _apiText(p['signature_html']);

    final can = _apiMap(p['can']);
    final urls = _apiMap(p['urls']);
    String? allowed(String key) =>
        _apiInt(can[key]) == 1 && _apiText(urls[key]).isNotEmpty ? _apiText(urls[key]).prependHost() : null;
    final editUrl = allowed('edit');
    final reportTarget = _apiInt(can['report']) == 1 && viewerUid > 0 && pid > 0 && fid > 0 && !anonymous
        ? PostReportTarget(pid: pid, tid: int.tryParse(tid) ?? 0, fid: fid, viewerUid: viewerUid)
        : null;

    // The last edit line as the page prints it; none when the plugin could not read the name and the time out of
    // it (both empty), as the card would print an empty line otherwise. The time is whatever the forum printed
    // ("2026-10-16 02:02", "昨天 12:00"…), carried as text as the page's is.
    final lastEditMap = p['lastedit'] is Map<String, dynamic> ? _apiMap(p['lastedit']) : null;
    final lastEdit =
        lastEditMap != null && _apiText(lastEditMap['username']).isNotEmpty && _apiText(lastEditMap['time']).isNotEmpty
        ? lastEditMap
        : null;

    final locked = <Locked>[];
    if (first && pay != null && _apiInt(pay['need_pay']) == 1 && _apiInt(pay['price']) > 0) {
      final payers = _apiInt(pay['payers']);
      locked.add(
        Locked.purchase(
          price: _apiInt(pay['price']),
          purchasedCount: payers > 0 ? payers : null,
          tid: tid,
          pid: postID,
        ),
      );
    }

    final pollHtml = _apiText(p['poll_html']);
    final bodyHtml = _apiText(p['body_html']);
    // The red packet block sits beside the content on the web page (`div.pct > div#ts_packet`, not in `body_html`):
    // the answer cuts it out as `packet_html`, read with the selectors of the web page.
    final packetHtml = _apiText(p['packet_html']);
    final packetNode = packetHtml.isEmpty
        ? null
        : parseHtmlDocument('<div class="pct">$packetHtml</div>').querySelector('div#ts_packet > a');
    final shareUrl = _apiText(p['share_url']);

    return Post(
      postID: postID,
      postFloor: position > 0 ? position : null,
      author: author,
      publishTime: _apiWallClock(p['dateline'], timeOffset),
      data: bodyHtml,
      locked: locked,
      replyAction: allowed('reply'),
      rate: _rateFromApi(p['rate'], tid: tid, pid: postID),
      rateAction: allowed('rate'),
      packetUrl: packetNode?.attributes['href']?.prependHost(),
      packetAllTaken: packetNode?.querySelector('img')?.attributes['src'] == _emptyPacketImageUrl,
      editUrl: editUrl,
      lastEditUsername: lastEdit == null ? null : _apiText(lastEdit['username']),
      lastEditTime: lastEdit == null ? null : _apiText(lastEdit['time']),
      userBriefProfile: avatarBlocked ? column.userBriefProfile?.copyWith(avatarUrl: null) : column.userBriefProfile,
      shareLink: shareUrl.isEmpty ? null : shareUrl.prependHost(),
      page: page,
      isDraft: first && draft && editUrl != null,
      poll: pollHtml.isEmpty ? null : PostPoll(form: pollHtml, viewerUid: viewerUid > 0 ? viewerUid : null),
      postMedals: column.postMedals,
      badge: column.badge,
      secondBadge: column.secondBadge,
      signature: signatureHtml.isEmpty ? column.signature : signatureHtml,
      pokemon: column.pokemon,
      checkin: column.checkin,
      reportTarget: reportTarget,
      messageBbcode: p['message'] is String ? p['message'] as String : null,
      messageReason: p['message_reason'] is String ? p['message_reason'] as String : null,
      bbcodeOff: _apiInt(p['bbcodeoff']) != 0,
      smileyOff: _apiInt(p['smileyoff']) != 0,
      parseUrlOff: _apiInt(p['parseurloff']) != 0,
      attachments: _apiList(
        p['attachments'],
      ).whereType<Map<String, dynamic>>().map(PostAttachment.fromApi).whereType<PostAttachment>().toList(),
      bbcodeCodes: PostBbcodeCodes.fromApi(codes, p),
      smiliesVersion: smiliesVersion == null || smiliesVersion.isEmpty ? null : smiliesVersion,
      customTags: switch (p['customtags']) {
        final List<dynamic> tags => List.unmodifiable(tags.whereType<String>().map((e) => e.toLowerCase())),
        final Map<String, dynamic> tags => List.unmodifiable(tags.keys.map((e) => e.toLowerCase())),
        _ => null,
      },
      stand: threadSpecial == 5 && !first && p['stand'] is num && const {0, 1, 2}.contains(_apiInt(p['stand']))
          ? _apiInt(p['stand'])
          : null,
      standVotes: threadSpecial == 5 && !first && _apiInt(p['stand_votes']) > 0 ? _apiInt(p['stand_votes']) : 0,
      best: _apiInt(p['best']) == 1,
      avatarBlocked: avatarBlocked,
      hot: hot,
      hotFloor: hot && _apiInt(p['hot_position']) > 0 ? _apiInt(p['hot_position']) : null,
      fromApp: _apiInt(p['from_app']) == 1,
    );
  }

  /// Post ID.
  final String postID;

  /// Post floor number.
  /// Make it nullable to be compatible with all web page styles.
  final int? postFloor;

  /// Post author, can not be null, should have avatar.
  final User author;

  /// Post publish time.
  final DateTime? publishTime;

  // TODO: Confirm data display.
  /// Post data.
  final String data;

  /// `<div class="locked">` after `<div id="postmessage_xxx">`.
  /// Need purchase to see full thread content.
  final List<Locked> locked;

  /// `<dl id="ratelog_xxx">` in `<div class="pcb">`.
  /// Rate records on this post.
  ///
  /// Optional.
  final Rate? rate;

  /// Url to reply this post.
  final String? replyAction;

  /// Url to rate this post.
  final String? rateAction;

  /// 红包Url.
  ///
  /// Optional.
  final String? packetUrl;

  /// Is all packet taken away.
  final bool packetAllTaken;

  /// Url to edit this post.
  ///
  /// Generally this field is not null only when current user is the author
  /// of the post.
  ///
  /// Format: $HOME?mod=post&action=edit&fid=${fid}&tid=${tid}&pid=${pid}
  ///
  /// Though we can manually format this edit url, it is not available when
  /// the current user is not the author. So just parse the url and never
  /// manually format it.
  final String? editUrl;

  /// Name of user who last edited this post.
  final String? lastEditUsername;

  /// Time of last edited.
  final String? lastEditTime;

  /// Url to share this floor
  final String? shareLink;

  /// Brief user profile of current post.
  ///
  /// May be null, maybe...
  final UserBriefProfile? userBriefProfile;

  /// Current page number.
  final int page;

  /// Flag indicating whether the post is in draft state.
  ///
  /// Draft post only can be a first floor, equivalent to editing a thread that
  /// not published yet.
  final bool isDraft;

  /// The poll of the post (`form#poll`, only ever in the first floor) as the page it was read from showed it.
  final PostPoll? poll;

  /// Whether the post holds a poll.
  bool get hasPoll => poll != null;

  /// User medals in current post.
  ///
  /// All medals are belong to the current post's author. But medals here are only images without text info which shall
  /// be completed by the thread page level hidden medal menu in thread page.
  final List<PostMedal>? postMedals;

  /// The image url of the main badge, usually the user group.
  final String? badge;

  /// The image url of the optional second badge, user group or user purchased badge.
  final String? secondBadge;

  /// Html format signature.
  final String? signature;

  /// Pokemon in floor.
  final PostFloorPokemon? pokemon;

  /// Author checkin status.
  final PostCheckinStatus? checkin;

  /// The report the forum offered for this floor to the account that read the page, see [extractPostReportTarget].
  ///
  /// Null when the page context is unknown, for own posts and floors without the report link (#127).
  final PostReportTarget? reportTarget;

  /// The floor's bbcode as the author wrote it (plugin 2.7.0, `message`), for the app's own renderer.
  ///
  /// Null when the answer has none (a web page, an older plugin) or withholds it: the forum only gives it when the
  /// account sees the whole content on the web page ([messageReason] tells why not). [data] stays the content as the
  /// forum printed it either way.
  final String? messageBbcode;

  /// Why [messageBbcode] is withheld (`hide`, `password`, `pay`, `locked`, `banned`, `moderate`, `json`, `html`,
  /// `bbcodeoff`, `jammer`, `imgcontent`, `spoofed`, `deleted`, `missing`); empty when given, null when the answer has
  /// no such field.
  final String? messageReason;

  /// The forum prints [messageBbcode] literally, tags as text (`bbcodeoff` 1).
  final bool bbcodeOff;

  /// The forum leaves smiley codes as text in this floor (`smileyoff` 1).
  final bool smileyOff;

  /// The author asked the forum's editor not to link bare urls (`parseurloff` 1). The forum does not link bare urls
  /// when it shows a post either way; kept for reference, the app links them as its html renderer does.
  final bool parseUrlOff;

  /// The attachments of the floor the forum loaded for this request ([PostAttachment]).
  final List<PostAttachment> attachments;

  /// The forum's bbcode switches for this floor; null when the answer has none.
  final PostBbcodeCodes? bbcodeCodes;

  /// The version of the forum's smilies table the floor was rendered with (`smilies_version`); null when none.
  final String? smiliesVersion;

  /// The site's own bbcode tags the forum expands in this floor (`customtags`, for its author), such as `spoiler`;
  /// null when the answer does not say (plugin 2.7.0), in which case the app draws none of them.
  final List<String>? customTags;

  /// The forum's app API gives nothing of this floor's content (plugin 2.7.0, `message_reason: spoofed`): the html of
  /// another floor forged this floor's ids on the page, so the floor's own html (content, author column, poll, red
  /// packet), last edit and rate are left out; only the author is real. The card shows a neutral line instead of an
  /// empty floor, whichever renderer is in use.
  bool get isSpoofed => messageReason == 'spoofed';

  /// The side the floor takes in a debate (plugin 2.8.0, `stand`): 0 neutral, 1 affirmative, 2 negative; null when
  /// the floor takes none (the thread is no debate, the first floor, an older plugin).
  final int? stand;

  /// The supporters of the floor's side in a debate (`stand_votes`, the page's "支持 N"); 0 otherwise.
  final int standVotes;

  /// The floor is the accepted answer of a bounty (`best`; the forum tells it on the first page only).
  final bool best;

  /// The special block of the thread (poll, goods, bounty, activity, debate), on the first floor only, when the page
  /// gave it (plugin 2.8.0); its html is then cut out of [data] (see `threadPageFromApi`).
  final ThreadSpecial? special;

  /// Accepting this floor as the answer of the bounty, when the account may (the thread's author, plugin 2.8.0).
  final SpecialRequest? bestAnswerRequest;

  /// Supporting this floor's side in a debate (the page's "支持 N"), for an account that is not its author (plugin
  /// 2.8.0).
  final SpecialRequest? debateVoteRequest;

  /// The page prints "头像被屏蔽" in place of the author's avatar (the site hides the avatars of banned authors and of
  /// floors banned one by one): the card shows no avatar either, not even one kept for the author ([author] has none).
  final bool avatarBlocked;

  /// A hot reply: the forum puts it first on the first page and numbers it -1, printed "推荐" by the default
  /// template and "-1#" by the site's theme in place of its floor number ([postFloor] is null).
  final bool hot;

  /// The floor a [hot] reply really is (plugin 2.8.2, `hot_position`), where it is printed on its own page; null when
  /// not known and for any other floor. Since plugin 2.8.4 the plugin also works it out when the thread counts floors
  /// one by one (keeps no floor positions); it gives 0 when it cannot (posted in the same second as another floor,
  /// floors the viewer cannot see, reply counts that do not add up), as does the web page, which never tells it.
  final int? hotFloor;

  /// The floor was posted, replied or edited from the app: the forum's app API (plugin 3.3.0) records it (`from_app`,
  /// on the web page "来自天使动漫App"). Floors sent before the plugin recorded them are not marked.
  final bool fromApp;

  /// The floor number to name this floor by: [postFloor], or for a [hot] reply the floor it really is ([hotFloor]).
  int? get shownFloor => postFloor ?? hotFloor;

  /// Build [Post] from [element] that has attribute id "post_$postID".
  ///
  /// [reportContext] holds the ids of the page [element] was read from; without it no report target is kept.
  /// [viewerUid] is the account that page was served to (null for a guest page, or when it does not say), kept with
  /// the poll of the post.
  static Post? fromPostNode(uh.Element element, int page, {PostReportPageContext? reportContext, int? viewerUid}) {
    final trRootNode = element.querySelector('table > tbody > tr');
    final postID = element.id.replaceFirst('post_', '');
    if (postID.isEmpty) {
      talker.error('failed to build post: empty post ID');
      return null;
    }
    final avatarId = 'ts_avatar_$postID';
    // <td class="pls">
    //
    // Note that on Discuz X5 the user info column is EMPTY for guests.
    final userProfileNode =
        trRootNode?.children.firstWhereOrNull((e) => e.localName == 'td' && e.classes.contains('pls')) ??
        trRootNode?.querySelector('td:nth-child(1)');
    final postInfoNode = userProfileNode?.querySelector('div#$avatarId');
    // <td class="plc tsdm_ftc">
    final postDataNode =
        trRootNode?.children.firstWhereOrNull((e) => e.localName == 'td' && e.classes.contains('plc')) ??
        trRootNode?.querySelector('td:nth-child(2)');

    // Author info.
    //
    // Sources of author name and uid, in priority:
    //
    // 1. Post header: `<div class="authi"><a href="home.php?mod=space&uid=${UID}" class="xi2">${NAME}</a>`. This one is
    //    always available, even for guests.
    // 2. Hidden user info popup: `<div id="userinfo${PID}"> <strong><a href="...uid=${UID}">${NAME}</a></strong>`.
    // 3. Legacy: `<div id="ts_avatar_${PID}"><div class="post_username_${N}">${NAME}</div>`.
    final authorHeaderNode = postDataNode
        ?.querySelectorAll('div.pi div.authi > a[href*="uid="]')
        .firstWhereOrNull((e) => e.firstEndDeepText()?.trim().isNotEmpty ?? false);
    final authorPopupNode = userProfileNode?.querySelector('div#userinfo$postID strong > a[href*="uid="]');
    final legacyNameNode = postInfoNode?.querySelector('div[class^="post_username"]');

    final avatarLinkNode = postInfoNode?.querySelector('div.avatar > a');
    final postAuthorUrl =
        authorHeaderNode?.attributes['href'] ??
        authorPopupNode?.attributes['href'] ??
        avatarLinkNode?.attributes['href'];
    final postAuthorName =
        authorHeaderNode?.firstEndDeepText()?.trim() ??
        authorPopupNode?.firstEndDeepText()?.trim() ??
        legacyNameNode?.firstEndDeepText()?.trim() ??
        postInfoNode?.querySelector('div')?.firstEndDeepText()?.trim();
    final postAuthorUid = _uidFromUrl(postAuthorUrl);
    // "头像被屏蔽" printed in place of the avatar: no image of the column is the avatar then.
    final avatarBlocked = _avatarBlockedIn(userProfileNode);
    final postAuthorAvatarUrl = avatarBlocked
        ? null
        : (postInfoNode?.querySelector('div.avatar img') ?? postInfoNode?.querySelector('img'))?._lazyImageUrl();
    final postAuthor = User(
      name: postAuthorName ?? '',
      uid: postAuthorUid,
      url: postAuthorUrl?.prependHost() ?? '',
      avatarUrl: postAuthorAvatarUrl,
    );

    if (postAuthor.isNotValid()) {
      talker.error('failed to build post: invalid author: $postAuthor');
      return null;
    }
    final postPublishTimeNode = postDataNode?.querySelector('#authorposton$postID');
    // Recent post can grep [publishTime] in the the "title" attribute
    // in first child.
    // Otherwise fallback split time string.
    final postPublishTime = postPublishTimeNode?.dateTime();
    // Sometimes the #postmessage_ID ID does not match postID.
    // e.g. tid=1184238
    // Use div.pcb to match it.
    //
    // Some threads have poll area in it, causing dom structure from:
    // <div class="pcb">
    //   <div class="t_fsz">
    //     <table cellspacing="0" cellpadding="0">
    //       Post Data
    //     </table>
    //   </div>
    // </div>
    //
    // to:
    //
    // <div class="pcb">
    //   <div class="pcbs">
    //     <table cellspacing="0" cellpadding="0">
    //       Post Data
    //     </table>
    //     <form id="poll" name="poll">
    //     </form>
    //   </div>
    // </div>
    //
    // Now we only search for the <div class="pcb"> node.
    final postData =
        postDataNode?.querySelector('div.pcb')?.innerHtml ?? postDataNode?.querySelector('div.pcbs')?.innerHtml;

    // Locked block in this post.
    //
    // Already purchased locked block has `<span>已购买人数: xx</span>`, here
    // only need not purchased ones.
    //
    // Should not build locked with points which must be built in "postmessage"
    // munching.
    final locked = postDataNode
        ?.querySelectorAll('div.locked')
        .where((e) => e.querySelector('span') == null)
        .map(
          (e) => Locked.fromLockDivNode(
            e,
            allowWithPoints: false,
            allowWithReply: false,
            allowWithAuthor: false,
            allowWithBlocked: false,
            // Sale info is rendered inline in post content.
            allowWithSales: false,
          ),
        )
        .where((e) => e.isValid())
        .toList();

    final pollNode = postDataNode?.querySelector('form#poll');

    final printedFloor = postDataNode?.querySelector('div.pi > strong > a > em')?.firstEndDeepText()?.parseToInt();
    // A hot reply: the forum numbers it -1, which the site's theme prints as it is ("-1#"), the default template as
    // "推荐". It has no floor number of its own.
    final hot =
        (printedFloor != null && printedFloor <= 0) ||
        (printedFloor == null &&
            (postDataNode?.querySelector('div.pi > strong > a')?.innerText.contains('推荐') ?? false));
    final postFloor = hot ? null : printedFloor;

    final shareLink = postDataNode?.querySelector('div.pi > strong > a')?.attributes['href']?.prependHost();

    // Some users have style overflow in signature so the following selector not
    // works:
    //
    // 'table > tbody > tr:nth-child(2) > td.tsdm_replybar > div.po > '
    //           'div > em > a[href*="action=reply"]',
    //
    // Should use a more permissive one.
    final replyAction =
        element
            .querySelector(
              'table > tbody > tr:nth-child(2) > td.tsdm_replybar div.pob em > '
              'a[href*="action=reply"]',
            )
            ?.firstHref() ??
        element.querySelector('td.tsdm_replybar div.pob a[href*="action=reply"]')?.firstHref() ??
        element.querySelector('div.pob a.fastre')?.firstHref();

    final rateNode = postDataNode?.querySelector('div.pct > div.pcb > dl.rate');
    final rate = Rate.fromRateLogNode(rateNode);
    final packetUrl = postDataNode?.querySelector('div.pct > div#ts_packet > a')?.attributes['href']?.prependHost();
    final packetAllTaken =
        postDataNode?.querySelector('div.pct > div#ts_packet > a > img')?.attributes['src'] == _emptyPacketImageUrl;

    // Parse rate action:
    // * If current post is the first floor in thread, rate action node is in <div id="fj">...</div>.
    // * If current post is not the first floor, rate action is in <div class="pob cl"><p>...</p></div>
    // Allow to be empty.
    String? rateAction;
    rateAction = element
        .querySelector('table  div.pob.cl p > a[onclick*="action=rate"]')
        ?._parseRateAction()
        ?.prependHost();

    rateAction ??= element.querySelector('div#fj > a[onclick*="action=rate"]')?._parseRateAction()?.prependHost();

    // Url to edit the post is also in the `<div id=fj>` node.
    // We can only find it by the content text "编辑"。
    //
    // For posts not in the first floor, the edit url is in the reply bar: `<div class="pob"><em><a class="editp">`.
    final editUrl =
        element
            .querySelectorAll('div#fj > a')
            .firstWhereOrNull((e) => e.firstEndDeepText() == '编辑')
            ?.attributes['href']
            ?.prependHost() ??
        element
            .querySelector('td.tsdm_replybar div.pob em > a[href*="action=edit"]')
            ?.attributes['href']
            ?.prependHost();

    // Check for last edit status.
    final lastEditText = element.querySelector('i.pstatus')?.innerText.trim().split(' ');
    String? lastEditUsername;
    String? lastEditTime;
    // 本帖最后由 $username 于 xxxx-xx-xx xx:xx:xx 编辑
    // 0         1         2 3          4        5
    if (lastEditText != null) {
      lastEditText.removeLast(); // 编辑
      final time = lastEditText.removeLast();
      final date = lastEditText.removeLast();
      lastEditText
        ..removeLast() // 于
        ..removeAt(0); // 本帖最后由
      final name = lastEditText.join(' ');
      lastEditUsername = name;
      lastEditTime = '$date $time';
    }

    final column = _parseAuthorColumn(element, userProfileNode, postID: postID, author: postAuthor);

    final isDraft = isFirstThreadPost(element) && element.querySelectorAll('a.psave').any(isDraftPublishLink);

    return Post(
      postID: postID,
      postFloor: postFloor,
      author: postAuthor,
      publishTime: postPublishTime,
      data: postData ?? '',
      locked: locked ?? [],
      replyAction: replyAction,
      rate: rate,
      rateAction: rateAction,
      packetUrl: packetUrl,
      packetAllTaken: packetAllTaken,
      editUrl: editUrl,
      lastEditUsername: lastEditUsername,
      lastEditTime: lastEditTime,
      userBriefProfile: avatarBlocked ? column.userBriefProfile?.copyWith(avatarUrl: null) : column.userBriefProfile,
      shareLink: shareLink,
      page: page,
      isDraft: isDraft,
      poll: pollNode == null ? null : PostPoll(form: pollNode.outerHtml ?? '', viewerUid: viewerUid),
      postMedals: column.postMedals,
      badge: column.badge,
      secondBadge: column.secondBadge,
      signature: column.signature,
      pokemon: column.pokemon,
      checkin: column.checkin,
      reportTarget: extractPostReportTarget(
        element,
        postId: postID,
        context: reportContext,
        authorUid: postAuthor.uid,
      ),
      avatarBlocked: avatarBlocked,
      hot: hot,
      // The forum's app API (plugin 3.3.0) prints "来自天使动漫App" for a floor sent from the app (its own span).
      fromApp: element.querySelector('#tsdmappfrom$postID') != null,
    );
  }

  /// What the author column of a floor (`td.pls`, [userProfileNode]) and the blocks other plugins add to the floor
  /// hold about the author: the brief profile, the medals worn, the group badges, the signature, the pokemon and the
  /// checkin state.
  ///
  /// [scope] is the node the floor-wide selectors search: the whole `div#post_PID` of a web page
  /// ([fromPostNode]), or the table the author column of a structured answer is wrapped in ([Post.fromApi]), so that
  /// both paths read the same selectors. [groupTitle] and [groupColor] are the floor's user group of a structured
  /// answer, for the brief profile ([UserBriefProfile.buildFromUserProfileNode]).
  static _AuthorColumn _parseAuthorColumn(
    uh.Element scope,
    uh.Element? userProfileNode, {
    required String postID,
    required User author,
    String? groupTitle,
    String? groupColor,
  }) {
    final avatarId = 'ts_avatar_$postID';
    // User profile
    //
    // The user info column is empty for guests (and the profile is not available), do not treat it as an error.
    UserBriefProfile? userBriefProfile;
    if (userProfileNode != null && userProfileNode.querySelector('div.tsdm_statbar') != null) {
      userBriefProfile = UserBriefProfile.buildFromUserProfileNode(
        userProfileNode,
        author: author,
        groupTitle: groupTitle,
        groupColor: groupColor,
      );
    } else {
      talker.info('post $postID: user profile node not found, maybe not logged in');
    }

    // Medals used by the current posts' author.
    //
    // Discuz X5: `<div class="tsdm_medalbar"><a><img id="md_${PID}_${MID}"><img ...></a></div>`, not all `<img>` are
    // wrapped in `<a>`.
    // Legacy: `<div class="md_ctrl"><a><img></a></div>`.
    var postMedals = scope
        .querySelectorAll('div.tsdm_medalbar img[id^="md_"]')
        .map(PostMedal.fromImg)
        .whereType<PostMedal>()
        .toList();
    if (postMedals.isEmpty) {
      postMedals = scope
          .querySelectorAll('div.md_ctrl > a > img')
          .map(PostMedal.fromImg)
          .whereType<PostMedal>()
          .toList();
    }

    // User group badge and optional second badge.
    final badge = scope.querySelector('div#$avatarId div.tsdm_norm_title > img')?._lazyImageUrl();
    // We can not use `:is(.tsdmtitles, .tsdm_lv_title)` here.
    //
    // Discuz X5: `<div class="tsdmtitle-badges"><div class="tsdmtitle-title"><img></div></div>`. The image is looked
    // up anywhere inside that same title block, so a link around it (`<a><img></a>`) still counts; nothing outside
    // the block of this floor's author column is used.
    final secondBadge =
        userProfileNode?.querySelector('div.tsdmtitle-badges div.tsdmtitle-title img')?._lazyImageUrl() ??
        scope.querySelector('div.tsdm_statbar > a > img.tsdmtitles')?._lazyImageUrl() ??
        scope.querySelector('div.tsdm_statbar > a > img.tsdm_lv_title')?._lazyImageUrl();
    final signature = scope.querySelector('div.sign_inner')?.innerHtml;

    // Pokemon, optional.
    //
    // Legacy: `<div class="tsdm_pokemon">`.
    // Discuz X5: `<div class="tns xg2">` in the user info column.
    PostFloorPokemon? pokemon;
    final pokemonNode = scope.querySelector('div.tsdm_pokemon');
    if (pokemonNode != null) {
      pokemon = PostFloorPokemon.fromDiv(pokemonNode);
    }
    final pokemonNodeX5 = userProfileNode?.querySelector('div.tns');
    if (pokemon == null && pokemonNodeX5 != null) {
      pokemon = PostFloorPokemon.fromTnsDiv(pokemonNodeX5);
    }

    // Checkin status, optional.
    final PostCheckinStatus? checkin;
    final checkinNode = scope.querySelector('div.qdsmile');
    if (checkinNode != null) {
      checkin = PostCheckinStatus.fromDiv(checkinNode);
    } else {
      checkin = null;
    }

    return (
      userBriefProfile: userBriefProfile,
      postMedals: postMedals,
      badge: badge,
      secondBadge: secondBadge,
      signature: signature,
      pokemon: pokemon,
      checkin: checkin,
    );
  }

  /// The [Rate] of a floor from the `rate` field [value] of a structured answer, shaped as [Rate.fromRateLogNode]
  /// reads it from the rate table of the web page: the columns with the reason column last, each record's values
  /// printed as the page prints them (`+ 2`, `-1`) with the reason as the last value, the totals as the status.
  /// Null when the floor has no rate, or the field lists no record.
  static Rate? _rateFromApi(Object? value, {required String tid, required String pid}) {
    if (value is! Map<String, dynamic>) {
      return null;
    }
    final columns = _apiList(value['columns']).map(_apiText).toList();
    final totals = _apiList(value['totals']).map(_apiInt).toList();
    final records = _apiList(value['records']).whereType<Map<String, dynamic>>().map((r) {
      final uid = _apiInt(r['uid']);
      final values = _apiList(r['values']).map(_apiInt).map((e) => e > 0 ? '+ $e' : '$e');
      return SingleRate(
        user: User(
          name: _apiText(r['username']),
          uid: uid > 0 ? '$uid' : null,
          url: '$baseUrl/home.php?mod=space&uid=$uid',
          avatarUrl: _apiImageUrl(r['avatar']),
        ),
        attrValueList: [...values, _apiText(r['reason'])],
      );
    }).toList();
    if (columns.isEmpty || records.isEmpty) {
      return null;
    }
    final status = <String>[];
    for (var i = 0; i < columns.length && i < totals.length; i++) {
      status.add('${columns[i]} ${totals[i] > 0 ? '+${totals[i]}' : '${totals[i]}'}');
    }
    return Rate(
      userCount: _apiInt(value['count']),
      detailUrl: '$baseUrl/forum.php?mod=misc&action=viewratings&tid=$tid&pid=$pid',
      attrList: [...columns, _rateReasonColumn],
      records: records,
      rateStatus: status.join(' '),
    );
  }

  /// Build a list of [Post] from the given [ThreadData] [uh.Element].
  ///
  /// [element]'s id is "postlist". [reportContext] and [viewerUid] are those of the page, see [fromPostNode].
  static List<Post> buildListFromThreadDataNode(
    uh.Element? element,
    int page, {
    PostReportPageContext? reportContext,
    int? viewerUid,
  }) {
    if (element == null) {
      return [];
    }
    final threadDataRootNode =
        // Style 5
        element.querySelector('div.bm > div') ??
        // Some normal styles.
        element.childAtOrNull(2);
    var currentElement = threadDataRootNode;
    final tdPostList = <Post>[];
    while (currentElement != null) {
      // This while is a while (0), will not loop twice.
      if ((currentElement.attributes['id'] ?? '').startsWith('post_')) {
        // Build post here.
        final post = Post.fromPostNode(currentElement, page, reportContext: reportContext, viewerUid: viewerUid);
        if (post == null) {
          talker.error('warning: post is empty');
          currentElement = currentElement.nextElementSibling;
          continue;
        }
        tdPostList.add(post);
      }
      currentElement = currentElement.nextElementSibling;
    }
    if (tdPostList.isEmpty) {
      talker.error('warning: post list is empty');
    }
    return tdPostList;
  }
}

/// The poll form of a post as the page it was read from showed it, and the account that page was served to.
///
/// The form, its formhash included, belongs to that account: the poll card shows it when it is still the account in
/// use, instead of asking the forum for the same page again (see PollCard).
@MappableClass()
final class PostPoll with PostPollMappable {
  /// Constructor.
  const PostPoll({required this.form, required this.viewerUid});

  /// The `form#poll` element, as html.
  final String form;

  /// The account the page was served to; null for a guest page, or a page that does not say.
  final int? viewerUid;
}

/// The reason column the rate table of the web page ends with, after the credit columns.
const _rateReasonColumn = '理由';

/// What [Post._parseAuthorColumn] reads from the author column of a floor.
typedef _AuthorColumn = ({
  UserBriefProfile? userBriefProfile,
  List<PostMedal> postMedals,
  String? badge,
  String? secondBadge,
  String? signature,
  PostFloorPokemon? pokemon,
  PostCheckinStatus? checkin,
});

Map<String, dynamic> _apiMap(Object? value) => value is Map<String, dynamic> ? value : const {};

List<Object?> _apiList(Object? value) => value is List ? value : const [];

/// An image url of a structured answer as the forum prints it (`./data/avatar/…`, `data/avatar/…` or absolute), on
/// the forum's host; null when empty.
String? _apiImageUrl(Object? value) {
  final url = _apiText(value);
  if (url.isEmpty) {
    return null;
  }
  return (url.startsWith('./') ? url.substring(2) : url).prependHost();
}
