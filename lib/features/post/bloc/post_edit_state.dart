part of 'post_edit_bloc.dart';

/// Status of editing a post.
@MappableEnum()
enum PostEditStatus {
  /// Initial.
  initial,

  /// Loading data.
  loading,

  /// Failed to load data.
  failedToLoad,

  /// Authentication changed; the old private form is no longer usable.
  identityChanged,

  /// Structured editor data requires the website editor.
  unsupported,

  /// The forum asks this account for a captcha or a security question to post here, which only the website shows:
  /// continue there, nothing is posted from the app.
  verificationRequired,

  /// Waiting for user to edit.
  editing,

  /// Uploading data.
  uploading,

  /// Failed to load data.
  failedToUpload,

  /// Post edit result success.
  success,

  /// The forum took the edits of a draft the member asked to publish, but keeps the thread a draft (a scheduled
  /// publication, a plugin): it was not published (plugin 2.9.0, the thread checked after posting).
  stillDraft,

  /// Server accepted the content, but it could not be confirmed as a private draft.
  draftUnconfirmed,
}

/// State of mappable.
@MappableClass()
final class PostEditState with PostEditStateMappable {
  /// Constructor.
  const PostEditState({
    this.status = PostEditStatus.initial,
    this.forumName,
    this.content,
    this.errorText,
    this.threadPublishInfo,
    this.redirectTid,
    this.needsBrowser = false,
    this.secCheck,
    this.wrongAnswer = false,
  });

  /// Status.
  final PostEditStatus status;

  /// Forum name as hint when publishing thread.
  final String? forumName;

  /// Post content.
  final PostEditContent? content;

  /// Error text html element.
  ///
  /// Use this to show the error message: the forum's reason a post was refused ([PostEditStatus.failedToUpload]), or
  /// the forum's message shown instead of the form ([PostEditStatus.failedToLoad], plugin 2.9.0).
  final String? errorText;

  /// Information used in publishing thread.
  final ThreadPublishInfo? threadPublishInfo;

  /// Thread id of new published thread after publish succeeded.
  ///
  /// Redirect to this page.
  final String? redirectTid;

  /// The forum refused the post because it asks for a captcha or a security question the app cannot show
  /// ([PostEditStatus.failedToUpload]): nothing was posted, the content stays to continue on the website.
  final bool needsBrowser;

  /// The forum refused the post for the captcha or the security question it asks ([PostEditStatus.failedToUpload]):
  /// what to answer before posting again (the editor asks the user and sends again). Null otherwise.
  final SecCheck? secCheck;

  /// The answers sent last were not taken ([secCheck]).
  final bool wrongAnswer;
}
