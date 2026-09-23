import 'package:tsdm_client/features/friend/models/add_friend.dart';

/// Why approving a friend request stopped without an answer of the forum.
enum ApproveFriendFailure {
  /// The request did not reach the forum, or its answer did not come back.
  network,

  /// The forum answered with its login page.
  notLoggedIn,

  /// The current account changed while approving: nothing more is done for the previous account.
  accountMismatch,

  /// A site challenge (Cloudflare) answered instead of the forum.
  challenge,

  /// The forum answered, but not with the approval form this app knows: nothing was sent.
  unknownForm,

  /// The approval was sent but its answer was not understood: it may or may not have been applied.
  unknownAfterSubmit,
}

/// What the forum answered to a request for the approval form of a pending friend request.
sealed class ApproveFriendFormResult {
  const ApproveFriendFormResult();
}

/// The approval form of the friend request of [targetUid].
///
/// This is the `add2submit` form the forum shows for a pending request (radio groups, no note), not the add-friend form
/// (`addsubmit`, a group select and a note) of [AddFriendForm].
final class ApproveFriendForm extends ApproveFriendFormResult {
  /// Constructor.
  const ApproveFriendForm({
    required this.targetUid,
    required this.targetName,
    required this.groups,
    required this.selectedGid,
    required this.fields,
  });

  /// Uid of the member whose request is approved.
  final int targetUid;

  /// Name of that member as the form prints it, empty when it does not.
  final String targetName;

  /// Groups offered to file the new friend under.
  final List<FriendGroup> groups;

  /// The group checked by the forum, the first one when none is.
  final String selectedGid;

  /// Hidden fields of the form, in their order and with the values the forum served (`referer`, `add2submit`, `from`,
  /// `handlekey`, `formhash`).
  final List<(String, String)> fields;

  /// The served value of the hidden field [name], null when the form has none.
  String? field(String name) {
    for (final (key, value) in fields) {
      if (key == name) {
        return value;
      }
    }
    return null;
  }

  /// Whether [gid] is one of the offered [groups].
  bool offers(String gid) => groups.any((e) => e.gid == gid);
}

/// The forum refused before showing the form: the request no longer exists, the two are friends already, ...
final class ApproveFriendRefused extends ApproveFriendFormResult {
  /// Constructor.
  const ApproveFriendRefused(this.message);

  /// The forum's message.
  final String message;
}
