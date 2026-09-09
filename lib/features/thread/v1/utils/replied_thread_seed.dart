import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Whether [posts] hold a reply written by user [uid]: a floor of theirs other than the first one, which is the
/// thread itself.
///
/// A floor without a number (some styles) counts, the first floor never does.
bool hasReplyBy(List<Post> posts, int uid) {
  final id = '$uid';
  return posts.any((post) => post.postFloor != 1 && post.author.uid == id);
}

/// Seed the local "replied" mark (issue #21) of user [uid] on the thread [tid] in forum [fid] from the floors
/// loaded on a thread page: when one of [posts] is a reply of theirs the thread is recorded like after sending one,
/// so replies made before the marks existed, or from elsewhere, show up as well.
///
/// Nothing is recorded while the user, the thread or the forum is unknown. Returns whether a mark was recorded.
Future<bool> seedRepliedThreadFromPosts({
  required StorageProvider storageProvider,
  required int? uid,
  required String? tid,
  required int? fid,
  required List<Post> posts,
}) async {
  final threadId = int.tryParse(tid ?? '');
  if (uid == null || threadId == null || fid == null || !hasReplyBy(posts, uid)) {
    return false;
  }
  await storageProvider.recordRepliedThread(uid: uid, tid: threadId, fid: fid);
  return true;
}
