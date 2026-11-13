import 'package:tsdm_client/constants/url.dart';

/// The lists of the forum's collections (淘专辑, `forum.php?mod=collection`).
///
/// [mine] and [subscribed] are one page of the forum (`op=my`, not paged), split by the mark the forum prints on each
/// row (`span.ctag0` created, `ctag1` maintained with others, `ctag2` subscribed).
enum CollectionListTab {
  /// The recommended ones (the page without `op`).
  recommended,

  /// Every collection (`op=all`), in the [CollectionOrder] picked.
  all,

  /// The account's own ones and the ones it maintains with their creator.
  mine,

  /// The ones the account subscribed to.
  subscribed,
}

/// The orders of [CollectionListTab.all], the forum's `order` values.
enum CollectionOrder {
  /// Newest first (the forum's default).
  dateline,

  /// Most threads first.
  threadnum,

  /// Most comments first.
  commentnum,

  /// Most subscribers first.
  follownum,
}

/// How the account is related to a collection of the "my collections" page (`span.ctag0`, `ctag1`, `ctag2`).
enum CollectionRelation {
  /// The account created it.
  created,

  /// The account maintains it with its creator (an accepted invitation).
  team,

  /// The account subscribed to it.
  subscribed,
}

/// A thread a collection row names as its latest one.
typedef CollectionLatestThread = ({int tid, String subject});

/// A row of a collection list.
final class CollectionSummary {
  /// Constructor.
  const CollectionSummary({
    required this.ctid,
    required this.name,
    required this.description,
    required this.keywords,
    required this.threadCount,
    required this.followCount,
    required this.commentCount,
    required this.creatorUid,
    required this.creatorName,
    required this.lastUpdate,
    required this.latestThread,
    required this.relation,
    required this.updated,
  });

  /// Collection id.
  final int ctid;

  /// Name.
  final String name;

  /// The start of its description, as the row prints it.
  final String description;

  /// Its keywords (淘帖标签).
  final List<String> keywords;

  /// Threads in it, null when the row does not tell.
  final int? threadCount;

  /// Subscribers, null when the row does not tell.
  final int? followCount;

  /// Comments, null when the row does not tell.
  final int? commentCount;

  /// The creator.
  final int? creatorUid;

  /// The creator's name.
  final String creatorName;

  /// The time of its last change, as the forum prints it.
  final String lastUpdate;

  /// The latest thread put into it.
  final CollectionLatestThread? latestThread;

  /// How the account is related to it (the "my collections" page only).
  final CollectionRelation? relation;

  /// Changed since the account last opened it (the "my collections" page prints its name red).
  final bool updated;
}

/// A page of a collection list.
final class CollectionListResult {
  /// Constructor.
  const CollectionListResult({
    required this.items,
    required this.currentPage,
    required this.totalPages,
    required this.canCreate,
    required this.formHash,
    required this.viewerUid,
  });

  /// The rows in the forum's order.
  final List<CollectionSummary> items;

  /// This page.
  final int currentPage;

  /// The pages of the list.
  final int totalPages;

  /// The forum offers to create a collection (the "创建淘专辑" link of the tabs).
  final bool canCreate;

  /// The form hash of the session, empty for a guest.
  final String formHash;

  /// The account the page was served to, 0 for a guest, null when it names none.
  final int? viewerUid;
}

/// What the account may do with the subscription of a collection, as the forum's page offers it.
enum CollectionFollowState {
  /// Nothing: the account's own collection, a guest, or a user group that may not subscribe.
  none,

  /// Not subscribed: the page offers to subscribe.
  canFollow,

  /// Subscribed: the page offers to unsubscribe.
  following,
}

/// A thread of a collection.
final class CollectionThread {
  /// Constructor.
  const CollectionThread({
    required this.tid,
    required this.subject,
    required this.reason,
    required this.authorUid,
    required this.authorName,
    required this.date,
    required this.replies,
    required this.views,
  });

  /// Thread id.
  final int tid;

  /// Subject.
  final String subject;

  /// Why it was put in (淘帖理由), empty when none was given.
  final String reason;

  /// The thread's author, null for an anonymous one.
  final int? authorUid;

  /// The author's name.
  final String authorName;

  /// The date the thread was posted, as the forum prints it.
  final String date;

  /// Replies, null when the row does not tell.
  final int? replies;

  /// Views, null when the row does not tell.
  final int? views;
}

/// A member named on a collection's page (its creator, the ones maintaining it).
typedef CollectionMember = ({int uid, String name});

/// The page of one collection (`forum.php?mod=collection&action=view&ctid=N`).
final class CollectionDetail {
  /// Constructor.
  const CollectionDetail({
    required this.ctid,
    required this.name,
    required this.description,
    required this.keywords,
    required this.creator,
    required this.teamworkers,
    required this.followCount,
    required this.followState,
    required this.threadCount,
    required this.commentCount,
    required this.averageRate,
    required this.rateCount,
    required this.canManage,
    required this.threads,
    required this.currentPage,
    required this.totalPages,
    required this.formHash,
    required this.viewerUid,
  });

  /// Collection id.
  final int ctid;

  /// Name.
  final String name;

  /// Description, plain text.
  final String description;

  /// Keywords.
  final List<String> keywords;

  /// The creator.
  final CollectionMember? creator;

  /// The members maintaining it with the creator.
  final List<CollectionMember> teamworkers;

  /// Subscribers.
  final int followCount;

  /// The subscription the page offers.
  final CollectionFollowState followState;

  /// Threads in it.
  final int threadCount;

  /// Comments on it.
  final int commentCount;

  /// The average of its ratings (1 to 5), null when nobody rated it.
  final double? averageRate;

  /// How many rated it.
  final int rateCount;

  /// The page offers to edit and delete it and to take threads out of it (its creator, a manager of collections).
  final bool canManage;

  /// The threads of this page.
  final List<CollectionThread> threads;

  /// This page of its threads.
  final int currentPage;

  /// The pages of its threads.
  final int totalPages;

  /// The form hash of the session, empty when the page has none (a guest).
  final String formHash;

  /// The account the page was served to, 0 for a guest, null when it names none.
  final int? viewerUid;

  /// The web page of the collection.
  String get url => collectionUrl(ctid);
}

/// A comment on a collection.
final class CollectionComment {
  /// Constructor.
  const CollectionComment({
    required this.uid,
    required this.username,
    required this.time,
    required this.message,
    required this.rate,
  });

  /// The author.
  final int? uid;

  /// The author's name.
  final String username;

  /// When it was written, as the forum prints it.
  final String time;

  /// Text, empty for a rating without words.
  final String message;

  /// The rating given with it (1 to 5), null without one.
  final int? rate;
}

/// A page of the comments of a collection (`action=view&op=comment`).
final class CollectionCommentPage {
  /// Constructor.
  const CollectionCommentPage({
    required this.ctid,
    required this.name,
    required this.comments,
    required this.currentPage,
    required this.totalPages,
    required this.canComment,
    required this.myRate,
    required this.formHash,
    required this.viewerUid,
  });

  /// Collection id.
  final int ctid;

  /// Collection name.
  final String name;

  /// The comments, newest first.
  final List<CollectionComment> comments;

  /// This page.
  final int currentPage;

  /// The pages.
  final int totalPages;

  /// The page has the comment form.
  final bool canComment;

  /// The rating the account gave already ("您已评分"), null when it may still rate.
  final int? myRate;

  /// The form hash of the session.
  final String formHash;

  /// The account the page was served to.
  final int? viewerUid;
}

/// A collection the account may put a thread in.
typedef CollectionChoice = ({int ctid, String name});

/// The forum's window to put a thread in a collection (`action=edit&op=addthread&tid=N`).
final class CollectThreadForm {
  /// Constructor.
  const CollectThreadForm({
    required this.tid,
    required this.choices,
    required this.remainingCreate,
    required this.formHash,
    required this.viewerUid,
    this.submitUrl,
    this.submitFields,
  });

  /// The thread.
  final int tid;

  /// Where the form posts (absolute), for the small form `collection` of plugin 4.0.0; null for the web window.
  final String? submitUrl;

  /// The fields of the form as the plugin served them (`submit.fields` and `submit.lists`, the lists numbered), sent
  /// back as they are with the chosen collections and the reason; null for the web window.
  final Map<String, String>? submitFields;

  /// The account's collections (its own and the ones it maintains) that do not hold the thread yet.
  final List<CollectionChoice> choices;

  /// How many more collections the account may create.
  final int remainingCreate;

  /// The form hash of the session.
  final String formHash;

  /// The account the window was served to.
  final int viewerUid;
}

/// The web page of collection [ctid].
String collectionUrl(int ctid) => '$baseUrl/forum.php?mod=collection&action=view&ctid=$ctid';
