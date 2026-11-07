part of 'edit_avatar_bloc.dart';

/// Current status of [EditAvatarState].
enum EditAvatarStatus {
  /// Initial state.
  initial,

  /// Loading edit avatar page information.
  loading,

  /// Uploading the result: new avatar url.
  uploading,

  /// Waiting for user to upload avatar.
  waitingForUpload,

  /// Successfully uploaded image url.
  success,

  /// Failed to load avatar edit page or upload new image url to server.
  failure,
}

/// Base state of edit avatar bloc.
@MappableClass()
final class EditAvatarState with EditAvatarStateMappable {
  /// Constructor.
  const EditAvatarState({
    this.status = EditAvatarStatus.initial,
    this.avatarUrl,
    this.draftUrl,
    this.formHash,
    this.canUpload = false,
    this.currentAvatar,
    this.uploadFailure,
  });

  /// Current status.
  final EditAvatarStatus status;

  /// The external url of avatar.
  final String? avatarUrl;

  /// The url user inputted but not submitted to server yet, because of a network error or something else...
  final String? draftUrl;

  /// The used form hash; null when the page has no external avatar form.
  final String? formHash;

  /// Whether the page has the avatar editor of the forum, to upload an image.
  final bool canUpload;

  /// The avatar the forum shows now (the uploaded one).
  final String? currentAvatar;

  /// Why the last image upload failed, null when it did not.
  final String? uploadFailure;
}
