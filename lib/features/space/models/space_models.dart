import 'package:universal_html/html.dart' as uh;

/// One page of a list of a member's space (the blogs, the albums, the pictures of an album), as the web page shows it.
///
/// A page the forum printed instead of the list (the privacy notice "抱歉！由于 NAME 的隐私设置，您不能访问当前内容",
/// the password form of a protected album, the 提示信息 of a switched off module) has no [items] and its words in
/// [message]; [needLogin] when it asks to log in.
final class SpaceListPage<T> {
  /// Constructor.
  const SpaceListPage({
    required this.items,
    this.nextPageUrl,
    this.title,
    this.totalCount,
    this.hiddenNote,
    this.message,
    this.needLogin = false,
    this.passwordRequired = false,
    this.session,
    this.canPost = false,
  });

  /// The items of this page.
  final List<T> items;

  /// Absolute url of the next page, null on the last one.
  final String? nextPageUrl;

  /// The name of the album whose pictures these are; null for the other lists.
  final String? title;

  /// The number of pictures of the album ("共 N 张图片"); null when not told.
  final int? totalCount;

  /// The forum's note under a blog list when some of the page are hidden from the viewer ("本页有 1 篇日志因作者的
  /// 隐私设置或未通过审核而隐藏").
  final String? hiddenNote;

  /// What the forum printed instead of the list.
  final String? message;

  /// The forum asks to log in.
  final bool needLogin;

  /// The album asks for its password ([message] is the forum's words).
  final bool passwordRequired;

  /// The account the page was served to and its form hash, for the wall and the greetings received; null for a guest
  /// and for the other lists.
  final SpaceSession? session;

  /// A wall page printed its message box to the viewer (a guest gets the login words instead).
  final bool canPost;
}

/// A blog in a member's blog list (`home.php?mod=space&uid=N&do=blog&view=me`).
final class SpaceBlog {
  /// Constructor.
  const SpaceBlog({
    required this.blogId,
    required this.uid,
    required this.title,
    this.author,
    this.time,
    this.summary,
    this.category,
    this.views,
    this.replies,
    this.privacy,
  });

  /// Blog id.
  final int blogId;

  /// The author's uid.
  final int uid;

  /// Title.
  final String title;

  /// The author's name.
  final String? author;

  /// When it was posted, as the forum wrote it ("2026-11-9 01:05").
  final String? time;

  /// The beginning of the content, plain text.
  final String? summary;

  /// The author's own category ("个人分类").
  final String? category;

  /// Times read, when the forum tells it.
  final int? views;

  /// Number of comments.
  final int? replies;

  /// Who may read it ("仅好友可见", "仅自己可见"…), shown to its author only; null for everyone.
  final String? privacy;
}

/// A comment under a blog.
final class SpaceBlogComment {
  /// Constructor.
  const SpaceBlogComment({
    required this.cid,
    required this.author,
    required this.message,
    this.uid,
    this.avatarUrl,
    this.time,
    this.canDelete = false,
    this.canReply = false,
  });

  /// Comment id.
  final int cid;

  /// Who wrote it.
  final String author;

  /// Their uid.
  final int? uid;

  /// Their avatar.
  final String? avatarUrl;

  /// When, as the forum wrote it.
  final String? time;

  /// The comment as the forum rendered it.
  final uh.Element message;

  /// The forum printed its delete link to the viewer (`c_CID_delete`): the author, the owner of the wall or blog, a
  /// moderator of comments.
  final bool canDelete;

  /// The forum printed its reply link to the viewer (`c_CID_reply`): on a wall, the owner's own wall only.
  final bool canReply;
}

/// A blog with its content and a page of its comments (`home.php?mod=space&uid=N&do=blog&id=M`).
///
/// A page the forum printed instead (the privacy notice, the password form, a deleted blog's 提示信息) has no content
/// and its words in [message].
final class SpaceBlogDetail {
  /// Constructor.
  const SpaceBlogDetail({
    this.title,
    this.time,
    this.category,
    this.content,
    this.comments = const [],
    this.commentCount,
    this.nextCommentsUrl,
    this.message,
    this.needLogin = false,
    this.passwordRequired = false,
  });

  /// Title.
  final String? title;

  /// When it was posted, as the forum wrote it.
  final String? time;

  /// The author's own category.
  final String? category;

  /// The content as the forum rendered it (`div#blog_article`).
  final uh.Element? content;

  /// The comments of this page.
  final List<SpaceBlogComment> comments;

  /// Number of comments the blog has.
  final int? commentCount;

  /// Absolute url of the next page of comments, null on the last one.
  final String? nextCommentsUrl;

  /// What the forum printed instead of the blog.
  final String? message;

  /// The forum asks to log in.
  final bool needLogin;

  /// The blog asks for its password.
  final bool passwordRequired;
}

/// An album in a member's album list (`home.php?mod=space&uid=N&do=album&view=me`).
final class SpaceAlbum {
  /// Constructor.
  const SpaceAlbum({required this.albumId, required this.uid, required this.name, this.coverUrl, this.count});

  /// Album id; -1 is the default album the pictures of the posts and blogs go to.
  final int albumId;

  /// The owner's uid.
  final int uid;

  /// Name.
  final String name;

  /// Absolute url of the cover, null without pictures.
  final String? coverUrl;

  /// Number of pictures, when the forum tells it.
  final int? count;
}

/// A picture of an album.
final class SpacePhoto {
  /// Constructor.
  const SpacePhoto({required this.picId, required this.thumbUrl, required this.imageUrl, this.title});

  /// Picture id.
  final int picId;

  /// Absolute url of the thumbnail the album shows.
  final String thumbUrl;

  /// Absolute url of the picture itself.
  final String imageUrl;

  /// Its title, when it has one.
  final String? title;
}

/// A choice of a select of a form: the `value` posted and the `label` shown.
typedef SpaceFormChoice = ({String value, String label});

/// The new blog form (`home.php?mod=spacecp&ac=blog`), as the forum served it to [uid].
final class BlogPostForm {
  /// Constructor.
  const BlogPostForm({
    required this.uid,
    required this.formHash,
    required this.categories,
    required this.privacy,
    this.systemCategories = const [],
  });

  /// The account the form was served to.
  final int uid;

  /// The form hash.
  final String formHash;

  /// The author's own categories (`classid`), without the empty choice and the "new category" one.
  final List<SpaceFormChoice> categories;

  /// Who may read it (`friend`): 0 everyone, 1 friends, 2 chosen friends, 3 only the author, 4 with a password.
  final List<SpaceFormChoice> privacy;

  /// The site's categories (`catid`), when the site has them; the forum says when it asks for one.
  final List<SpaceFormChoice> systemCategories;
}

/// The album upload page (`home.php?mod=spacecp&ac=upload`), as the forum served it to [uid].
final class AlbumUploadForm {
  /// Constructor.
  const AlbumUploadForm({
    required this.uid,
    required this.formHash,
    required this.uploadUrl,
    required this.uploadUid,
    required this.uploadHash,
    required this.albums,
    required this.privacy,
    this.maxKb,
    this.extensions = const ['jpg', 'jpeg', 'gif', 'png'],
  });

  /// The account the page was served to.
  final int uid;

  /// The form hash of the album form.
  final String formHash;

  /// Where a picture is sent (`misc.php?mod=swfupload&action=swfupload&operation=album`).
  final String uploadUrl;

  /// The `uid` the upload is posted with.
  final String uploadUid;

  /// The `hash` the upload is posted with.
  final String uploadHash;

  /// The member's albums the pictures can go to (`albumid`).
  final List<SpaceFormChoice> albums;

  /// Who may see a new album (`friend`).
  final List<SpaceFormChoice> privacy;

  /// The largest picture the forum takes, in KB; null when not told.
  final int? maxKb;

  /// The file extensions the forum takes, lower case.
  final List<String> extensions;

  /// Whether the forum takes the file [filename] (by its extension).
  bool accepts(String filename) {
    final dot = filename.lastIndexOf('.');
    return dot >= 0 && extensions.contains(filename.substring(dot + 1).toLowerCase());
  }
}

/// The account a page was served to ([uid], from the page) and the form hash of its session: what a form of the
/// page is posted with.
final class SpaceSession {
  /// Constructor.
  const SpaceSession({required this.uid, required this.formHash});

  /// The account.
  final int uid;

  /// The form hash.
  final String formHash;
}

/// A greeting of the poke form (`iconid`): 0 is the plain greeting, without a picture.
final class PokeIcon {
  /// Constructor.
  const PokeIcon({required this.id, required this.label, this.imageUrl});

  /// The `iconid` posted.
  final String id;

  /// Its name ("握个手").
  final String label;

  /// Absolute url of its picture, null for none.
  final String? imageUrl;
}

/// The poke form (`home.php?mod=spacecp&ac=poke&op=send|reply&uid=N`), as the forum served it to [uid].
final class PokeForm {
  /// Constructor.
  const PokeForm({
    required this.uid,
    required this.targetUid,
    required this.formHash,
    required this.icons,
    required this.selected,
    required this.reply,
    this.targetName,
  });

  /// The account the form was served to.
  final int uid;

  /// Who is greeted.
  final int targetUid;

  /// Their name, as the form prints it.
  final String? targetName;

  /// The form hash.
  final String formHash;

  /// The greetings the forum offers, in its order.
  final List<PokeIcon> icons;

  /// The greeting checked by the forum.
  final String selected;

  /// Greeting back (`op=reply`): the greeting received from [targetUid] is removed once sent.
  final bool reply;
}

/// A greeting received (`home.php?mod=spacecp&ac=poke`): the latest one of each member.
final class ReceivedPoke {
  /// Constructor.
  const ReceivedPoke({
    required this.uid,
    required this.username,
    required this.content,
    this.avatarUrl,
    this.time,
  });

  /// Who greeted.
  final int uid;

  /// Their name.
  final String username;

  /// Their avatar.
  final String? avatarUrl;

  /// The greeting as the forum rendered it: its picture, its name, what they said.
  final uh.Element content;

  /// When, as the forum wrote it.
  final String? time;
}
