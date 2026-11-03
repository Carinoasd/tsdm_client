import 'package:tsdm_client/features/blocking/repository/keyword_block_repository.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/utils/notice_info.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';

/// Whether a notice with author [authorId] must not be shown or announced with block list [list].
///
/// The author only comes from the notice's own ignore link; notices without it (rows saved before the field existed,
/// or a merged copy whose author is not known any more) and system notices (author 0) are never hidden because
/// their author is unknown. While [list] is not known every attributed notice is held back, see
/// [UserBlockList.hides].
bool isBlockedNoticeAuthor(int? authorId, UserBlockList list) => list.hides(authorId);

/// Whether the personal message conversation with [peerUid] is muted with block list [list]: it must not be
/// announced nor counted in the unread badge.
///
/// Muted is not hidden: the conversation is still fetched, stored with its real read state and listed, so the user
/// can open it at any time and unblocking brings the badge back. While [list] is not known every conversation is
/// muted, see [UserBlockList.hides].
bool isMutedPersonalMessagePeer(int? peerUid, UserBlockList list) => list.hides(peerUid);

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

/// Whether a notice with html [data] triggered by [authorId] is hidden by a keyword of [keywords]: the title of the
/// thread it names contains one (ignoring case). Notices triggered by the owner of [keywords] are never hidden.
bool isKeywordBlockedNotice(String data, int? authorId, KeywordBlockList keywords) {
  if (keywords.titleKeys.isEmpty || keywords.isOwner(authorId)) {
    return false;
  }
  final title = noticeThreadTitleOfHtml(data);
  return title != null && containsKeyword(title, keywords.titleKeys);
}

/// The keyword list of [uid] for filtering notices outside the UI; a list that can not be read hides nothing.
Future<KeywordBlockList> noticeKeywordListOf(StorageProvider storage, int uid) async {
  try {
    return await KeywordBlockRepository(storage).load(uid);
  } on KeywordBlockStorageException {
    return KeywordBlockList.unknown(uid, status: UserBlockListStatus.failed);
  }
}

/// Drop what [list] keeps quiet from [notification]: notices of blocked authors ([isBlockedNoticeAuthor]) or hidden by
/// [keywords] ([isKeywordBlockedNotice]), and personal message conversations with muted peers
/// ([isMutedPersonalMessagePeer]). Broadcast messages are kept as they are.
///
/// Only for the part of a fetch that is announced as news (system notification, auto sync hint). Never apply it to
/// the copies that are stored or listed: conversations with muted peers stay stored and accessible. The name is
/// kept from when only notices were filtered.
NotificationV2 withoutBlockedNotices(
  NotificationV2 notification,
  UserBlockList list, {
  KeywordBlockList keywords = const KeywordBlockList.empty(null),
}) {
  if (list.isKnown && list.uids.isEmpty && keywords.titleKeys.isEmpty) {
    return notification;
  }
  return notification.copyWith(
    noticeList: notification.noticeList
        .where((e) => !isBlockedNoticeAuthor(e.authorId, list) && !isKeywordBlockedNotice(e.data, e.authorId, keywords))
        .toList(),
    personalMessageList: notification.personalMessageList
        .where((e) => !isMutedPersonalMessagePeer(e.peerUid, list))
        .toList(),
  );
}
