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

  /// Waiting for user to edit.
  editing,

  /// Uploading data.
  uploading,

  /// Failed to load data.
  failedToUpload,

  /// Post edit result success.
  success,

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
  });

  /// Status.
  final PostEditStatus status;

  /// Forum name as hint when publishing thread.
  final String? forumName;

  /// Post content.
  final PostEditContent? content;

  /// Error text html element.
  ///
  /// Use this to show the error message.
  final String? errorText;

  /// Information used in publishing thread.
  final ThreadPublishInfo? threadPublishInfo;

  /// Thread id of new published thread after publish succeeded.
  ///
  /// Redirect to this page.
  final String? redirectTid;
}
