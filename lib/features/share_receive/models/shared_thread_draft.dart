import 'package:tsdm_client/features/post/models/poll_create.dart';

/// What a share puts into the editor of a new thread (the route's `extra`): the shared text as the title and the
/// post ([transfer], null when nothing was shared as text) and the shared images to upload as attachments once the
/// form is loaded ([imagePaths], copies in this app's cache).
final class SharedThreadDraft {
  /// Constructor.
  const SharedThreadDraft({required this.transfer, required this.imagePaths});

  /// Subject and body for the editor, bound to the account and the forum chosen, as the poll editor hands them over.
  final ThreadModeTransfer? transfer;

  /// Paths of the shared images.
  final List<String> imagePaths;
}
