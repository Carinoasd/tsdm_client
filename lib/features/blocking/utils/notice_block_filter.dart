import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Whether a notice with author [authorId] must not be shown or announced with block list [list].
///
/// The author only comes from the notice's own ignore link; notices without it (rows saved before the field existed,
/// or a merged copy whose author is not known any more) and system notices (author 0) are never hidden because
/// their author is unknown. While [list] is not known every attributed notice is held back, see
/// [UserBlockList.hides].
bool isBlockedNoticeAuthor(int? authorId, UserBlockList list) => list.hides(authorId);

/// The block list of [uid] for filtering notices outside the UI (sync, counts, background service).
///
/// A list that can not be read is returned as unknown (failed) instead of empty: attributed notices are then held
/// back rather than announced, and nothing is written to the list.
Future<UserBlockList> noticeBlockListOf(StorageProvider storage, int uid) async {
  try {
    return await UserBlockRepository(storage).load(uid);
  } on UserBlockStorageException {
    return UserBlockList.unknown(uid, status: UserBlockListStatus.failed);
  }
}

/// Drop notices hidden by [list] from [notification]; personal and broadcast messages are kept as they are.
NotificationV2 withoutBlockedNotices(NotificationV2 notification, UserBlockList list) {
  if (list.isKnown && list.uids.isEmpty) {
    return notification;
  }
  return notification.copyWith(
    noticeList: notification.noticeList.where((e) => !isBlockedNoticeAuthor(e.authorId, list)).toList(),
  );
}
