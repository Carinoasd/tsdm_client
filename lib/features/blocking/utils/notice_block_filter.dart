import 'package:tsdm_client/features/blocking/repository/keyword_block_repository.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/blocking/utils/thread_author_cache.dart';
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
/// thread it names contains one (compared as `foldKeywordText` does).
///
/// [type] and [fromIdType] are the notice's ignore type and `from_idtype`, see [noticeKindOf]. Never hidden:
///
/// * notices triggered by the owner of [keywords];
/// * notices about the owner's own posts or threads: replies, quotes, rates, comments, moderation, bounties,
///   activities and magic items ([noticeKindOf]), and notices whose text says so when the type is not known
///   ("回复了您的帖子", "点评了您的帖子"...);
/// * notices about a thread [ThreadAuthorCache] knows the owner started.
///
/// Mentions in threads of others and the other notices naming a thread are hidden.
bool isKeywordBlockedNotice(
  String data,
  int? authorId,
  KeywordBlockList keywords, {
  String? type,
  String? fromIdType,
}) {
  if (keywords.titleKeys.isEmpty || keywords.isOwner(authorId)) {
    return false;
  }
  final subject = noticeSubjectOfHtml(data);
  final title = subject.title;
  if (title == null || !containsKeyword(title, keywords.titleKeys) || subject.aboutOwnPost) {
    return false;
  }
  if (_aboutOwnContent.contains(
    noticeKindOf(type: type, fromIdType: fromIdType, target: subject.target, body: data),
  )) {
    return false;
  }
  final tid = subject.target?.tid;
  return tid == null || !keywords.isOwner(ThreadAuthorCache.authorOf('$tid'));
}

/// Kinds of notices about the user's own post or thread, see [isKeywordBlockedNotice].
const Set<NoticeKind> _aboutOwnContent = {
  NoticeKind.reply,
  NoticeKind.quote,
  NoticeKind.rate,
  NoticeKind.comment,
  NoticeKind.moderation,
  NoticeKind.reward,
  NoticeKind.activity,
  NoticeKind.magic,
};

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
        .where(
          (e) =>
              !isBlockedNoticeAuthor(e.authorId, list) &&
              !isKeywordBlockedNotice(e.data, e.authorId, keywords, type: e.ignoreType, fromIdType: e.fromIdType),
        )
        .toList(),
    personalMessageList: notification.personalMessageList
        .where((e) => !isMutedPersonalMessagePeer(e.peerUid, list))
        .toList(),
  );
}
