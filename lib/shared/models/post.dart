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
    this.hasPoll = false,
    this.postMedals,
    this.badge,
    this.secondBadge,
    this.signature,
    this.pokemon,
    this.checkin,
  });

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

  /// Poll is not supported, leave a message instead.
  final bool hasPoll;

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

  /// Build [Post] from [element] that has attribute id "post_$postID".
  static Post? fromPostNode(uh.Element element, int page) {
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
    final postAuthorAvatarUrl = (postInfoNode?.querySelector('div.avatar img') ?? postInfoNode?.querySelector('img'))
        ?._lazyImageUrl();
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

    final hasPoll = postDataNode?.querySelector('form#poll') != null;

    final postFloor = postDataNode?.querySelector('div.pi > strong > a > em')?.firstEndDeepText()?.parseToInt();

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

    // User profile
    //
    // The user info column is empty for guests (and the profile is not available), do not treat it as an error.
    UserBriefProfile? userBriefProfile;
    if (userProfileNode != null && userProfileNode.querySelector('div.tsdm_statbar') != null) {
      userBriefProfile = UserBriefProfile.buildFromUserProfileNode(userProfileNode, author: postAuthor);
    } else {
      talker.info('post $postID: user profile node not found, maybe not logged in');
    }

    final isDraft = element.querySelector('a.psave') != null;

    // Medals used by the current posts' author.
    //
    // Discuz X5: `<div class="tsdm_medalbar"><a><img id="md_${PID}_${MID}"><img ...></a></div>`, not all `<img>` are
    // wrapped in `<a>`.
    // Legacy: `<div class="md_ctrl"><a><img></a></div>`.
    var postMedals = element
        .querySelectorAll('div.tsdm_medalbar img[id^="md_"]')
        .map(PostMedal.fromImg)
        .whereType<PostMedal>()
        .toList();
    if (postMedals.isEmpty) {
      postMedals = element
          .querySelectorAll('div.md_ctrl > a > img')
          .map(PostMedal.fromImg)
          .whereType<PostMedal>()
          .toList();
    }

    // User group badge and optional second badge.
    final badge = element.querySelector('div#$avatarId div.tsdm_norm_title > img')?._lazyImageUrl();
    // We can not use `:is(.tsdmtitles, .tsdm_lv_title)` here.
    //
    // Discuz X5: `<div class="tsdmtitle-badges"><div class="tsdmtitle-title"><img></div></div>`.
    final secondBadge =
        userProfileNode?.querySelector('div.tsdmtitle-badges div.tsdmtitle-title > img')?._lazyImageUrl() ??
        element.querySelector('div.tsdm_statbar > a > img.tsdmtitles')?._lazyImageUrl() ??
        element.querySelector('div.tsdm_statbar > a > img.tsdm_lv_title')?._lazyImageUrl();
    final signature = element.querySelector('div.sign_inner')?.innerHtml;

    // Pokemon, optional.
    //
    // Legacy: `<div class="tsdm_pokemon">`.
    // Discuz X5: `<div class="tns xg2">` in the user info column.
    PostFloorPokemon? pokemon;
    final pokemonNode = element.querySelector('div.tsdm_pokemon');
    if (pokemonNode != null) {
      pokemon = PostFloorPokemon.fromDiv(pokemonNode);
    }
    final pokemonNodeX5 = userProfileNode?.querySelector('div.tns');
    if (pokemon == null && pokemonNodeX5 != null) {
      pokemon = PostFloorPokemon.fromTnsDiv(pokemonNodeX5);
    }

    // Checkin status, optional.
    final PostCheckinStatus? checkin;
    final checkinNode = element.querySelector('div.qdsmile');
    if (checkinNode != null) {
      checkin = PostCheckinStatus.fromDiv(checkinNode);
    } else {
      checkin = null;
    }

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
      userBriefProfile: userBriefProfile,
      shareLink: shareLink,
      page: page,
      isDraft: isDraft,
      hasPoll: hasPoll,
      postMedals: postMedals,
      badge: badge,
      secondBadge: secondBadge,
      signature: signature,
      pokemon: pokemon,
      checkin: checkin,
    );
  }

  /// Build a list of [Post] from the given [ThreadData] [uh.Element].
  ///
  /// [element]'s id is "postlist".
  static List<Post> buildListFromThreadDataNode(uh.Element? element, int page) {
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
        final post = Post.fromPostNode(currentElement, page);
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
