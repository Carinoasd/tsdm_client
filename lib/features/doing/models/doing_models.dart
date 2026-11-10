import 'package:universal_html/html.dart' as uh;

/// Whose records a page lists (`home.php?mod=space&do=doing&view=…`).
enum DoingView {
  /// Everyone's ("随便看看").
  all,

  /// Of the members the account follows ("我的关注").
  follow,

  /// Of the account and its friends ("我和好友的记录").
  friends,

  /// The account's own ("我的记录").
  mine
  ;

  /// The `view` of the forum's url.
  String get query => switch (this) {
    DoingView.all => 'all',
    DoingView.follow => 'follow',
    DoingView.friends => 'we',
    DoingView.mine => 'me',
  };
}

/// A record (记录): a short note of a member.
final class Doing {
  /// Constructor.
  const Doing({
    required this.doid,
    required this.uid,
    required this.username,
    required this.content,
    this.avatarUrl,
    this.time,
    this.imageUrls = const [],
    this.replyCount = 0,
    this.canDelete = false,
  });

  /// Its id.
  final int doid;

  /// Who wrote it.
  final int uid;

  /// Their name.
  final String username;

  /// Their avatar.
  final String? avatarUrl;

  /// When, as the forum wrote it.
  final String? time;

  /// The record as the forum rendered it (and what it shares, when it does).
  final uh.Element content;

  /// Its pictures, full size.
  final List<String> imageUrls;

  /// How many replies it has.
  final int replyCount;

  /// The forum printed its delete link: the member's own record (or a moderator of records).
  final bool canDelete;
}

/// A reply to a record, or to another reply of it.
final class DoingComment {
  /// Constructor.
  const DoingComment({
    required this.id,
    required this.doid,
    required this.uid,
    required this.username,
    required this.message,
    this.avatarUrl,
    this.time,
    this.nested = false,
    this.canReply = false,
    this.canDelete = false,
  });

  /// Its id (`docid`).
  final int id;

  /// The record.
  final int doid;

  /// Who wrote it.
  final int uid;

  /// Their name.
  final String username;

  /// Their avatar.
  final String? avatarUrl;

  /// When, as the forum wrote it.
  final String? time;

  /// The reply as the forum rendered it ("回复 NAME: …" for a reply to a reply of a reply).
  final uh.Element message;

  /// A reply to a reply, shown under it.
  final bool nested;

  /// The forum printed its reply link.
  final bool canReply;

  /// The forum printed its delete link.
  final bool canDelete;
}

/// A page of the replies of a record (ten top replies a page, each with its own replies).
final class DoingCommentPage {
  /// Constructor.
  const DoingCommentPage({required this.comments, required this.page, required this.hasMore, this.message});

  /// The replies of this page.
  final List<DoingComment> comments;

  /// The page.
  final int page;

  /// Another page follows.
  final bool hasMore;

  /// The forum's words instead of the replies (the module switched off).
  final String? message;
}
