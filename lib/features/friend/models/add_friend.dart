/// A friend group offered by the add-friend form.
final class FriendGroup {
  /// Constructor.
  const FriendGroup({required this.gid, required this.name});

  /// Group id, the `gid` form value.
  final String gid;

  /// Group name as shown on the forum.
  final String name;
}

/// What the forum answered to a request for the add-friend form.
sealed class AddFriendFormResult {
  const AddFriendFormResult();
}

/// The form: the request can be sent.
final class AddFriendForm extends AddFriendFormResult {
  /// Constructor.
  const AddFriendForm({
    required this.formHash,
    required this.targetName,
    required this.groups,
    required this.selectedGid,
    this.noteHint,
  });

  /// `formhash` of the form.
  final String formHash;

  /// Name of the member to add, as the forum prints it.
  final String targetName;

  /// Groups to file the friend under.
  final List<FriendGroup> groups;

  /// The group preselected by the forum.
  final String selectedGid;

  /// Hint printed under the note field (length limit etc.).
  final String? noteHint;
}

/// The forum refused before showing a form: already friends, a request still pending, adding oneself.
final class AddFriendRefused extends AddFriendFormResult {
  /// Constructor.
  const AddFriendRefused(this.message);

  /// The forum's message.
  final String message;
}

/// The forum's answer to a submitted request.
final class AddFriendResult {
  /// Constructor.
  const AddFriendResult({required this.success, required this.message});

  /// The request was sent (or the two are friends now).
  final bool success;

  /// The forum's message, success or not.
  final String message;
}
