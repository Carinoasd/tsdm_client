part of 'post_edit_bloc.dart';

/// Event of editing post.
@MappableClass()
sealed class PostEditEvent with PostEditEventMappable {
  /// Constructor.
  const PostEditEvent();
}

/// Invalidate the editor immediately on any authentication transition.
@MappableClass()
final class PostEditIdentityChanged extends PostEditEvent with PostEditIdentityChangedMappable {
  /// Constructor.
  const PostEditIdentityChanged();
}

/// User requested to load the data to edit.
@MappableClass()
final class PostEditLoadDataRequested extends PostEditEvent with PostEditLoadDataRequestedMappable {
  /// Constructor.
  const PostEditLoadDataRequested(this.editUrl) : super();

  /// Url to get the edit content data.
  final String editUrl;
}

/// User completed the editing and need to post to the server.
@MappableClass()
final class PostEditCompleteEditRequested extends PostEditEvent with PostEditCompleteEditRequestedMappable {
  /// Constructor.
  const PostEditCompleteEditRequested({
    required this.formHash,
    required this.postTime,
    required this.delattachop,
    required this.wysiwyg,
    required this.fid,
    required this.tid,
    required this.pid,
    required this.page,
    required this.threadType,
    required this.threadTitle,
    required this.data,
    required this.options,
    required this.save,
    required this.perm,
    required this.price,
    this.draftKey,
    this.rewardPrice,
  }) : super();

  /// The reward price of the first post of an open reward thread ([PostFormEdits.rewardPrice]), null to keep it.
  final int? rewardPrice;

  /// Form hash.
  final String formHash;

  /// Post time.
  final String postTime;

  /// Delattachop.
  final String delattachop;

  /// What you see is what you get.
  ///
  /// "0".
  final String wysiwyg;

  /// Forum id.
  final String fid;

  /// Thread id.
  final String tid;

  /// Post id.
  final String pid;

  /// Page.
  ///
  /// Provided by server.
  final String page;

  /// Thread type.
  ///
  /// Only needed when editing or creating a new thread.
  final PostEditThreadType? threadType;

  /// Thread title.
  ///
  /// Only needed when editing or creating a new thread.
  final String? threadTitle;

  /// Post data, or first floor post data when submitting a thread.
  final String data;

  /// Additional options provided by server.
  final List<PostEditContentOption> options;

  /// Save post as draft or publish as new thread.
  ///
  /// Only set to "1" when editing thread in draft state.
  final String save;

  /// Optional permission required to access this thread.
  final String? perm;

  /// Optional thread price.
  final int? price;

  /// The key of the local draft of the editor (`LocalDraftKey.value`), deleted once the edit was taken.
  final String? draftKey;
}

/// Fetch required info for publishing, including form hash, post time and more.
@MappableClass()
final class ThreadPubFetchInfoRequested extends PostEditEvent with ThreadPubFetchInfoRequestedMappable {
  /// Constructor.
  const ThreadPubFetchInfoRequested({required this.fid, this.kind = ThreadKind.normal});

  /// Forum id.
  final String fid;

  /// The kind of thread to write: the forum's form of that kind.
  final ThreadKind kind;
}

/// Post a new thread to forum.
@MappableClass()
final class ThreadPubPostThread extends PostEditEvent with ThreadPubPostThreadMappable {
  /// Constructor.
  const ThreadPubPostThread(
    this.info, {
    this.verification,
    this.draftKey,
    this.attachNew = const [],
    this.rewardPrice,
    this.hongbao,
    this.activity,
    this.debate,
  });

  /// The activity of an activity thread ([PostFormEdits.activity]), null for any other thread.
  final ActivityEdits? activity;

  /// The debate of a debate thread ([PostFormEdits.debate]), null for any other thread.
  final DebateEdits? debate;

  /// All info to post in body.
  final ThreadPublishInfo info;

  /// The reward price of a reward thread ([PostFormEdits.rewardPrice]), null for any other thread.
  final int? rewardPrice;

  /// The red packet of a red packet thread ([PostFormEdits.hongbao]), null for any other thread.
  final HongbaoEdits? hongbao;

  /// The attachments uploaded while the thread was written, by `aid` ([PostFormEdits.attachNew]).
  final List<int> attachNew;

  /// The answers to the captcha or the security question the forum asks, null when none is asked (yet).
  final SecCheckAnswer? verification;

  /// The key of the local draft of the editor (`LocalDraftKey.value`), deleted once the thread was taken.
  final String? draftKey;
}
