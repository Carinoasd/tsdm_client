part of 'models.dart';

/// Model for the result of fetch notification API.
@MappableClass()
final class NotificationV2 with NotificationV2Mappable {
  /// Constructor.
  const NotificationV2({
    required this.status,
    required this.noticeList,
    required this.personalMessageList,
    required this.broadcastMessageList,
  });

  /// Response status.
  final int status;

  /// All notices fetched.
  @MappableField(key: 'notification')
  final List<NoticeV2> noticeList;

  /// All personal messages.
  @MappableField(key: 'private_message')
  final List<PersonalMessageV2> personalMessageList;

  /// All broadcast messages.
  @MappableField(key: 'public_message')
  final List<BroadcastMessageV2> broadcastMessageList;

  /// All notice nodes in notice page.
  ///
  /// `div.nts > dl#notice_XXX` on Discuz X5, `form#deletepmform > div > dl` on older versions.
  ///
  /// A friend request notice carries two `id` attributes (`id="pendingFriend_UID" notice="NID" id="notice_NID"`) and
  /// the parser keeps the first one, so such nodes are only found through the `notice` attribute.
  static List<uh.Element> noticeNodes(uh.Document document) {
    final nodes = document.querySelectorAll('div.nts > dl[notice], div.nts > dl[id^="notice_"]');
    if (nodes.isNotEmpty) {
      return nodes;
    }
    return document.querySelectorAll('form#deletepmform > div > dl');
  }

  /// All personal message nodes in private message page.
  static List<uh.Element> personalMessageNodes(uh.Document document) => document.querySelectorAll('dl[id^="pmlist_"]');

  /// All broadcast message nodes in broadcast message page.
  static List<uh.Element> broadcastMessageNodes(uh.Document document) =>
      document.querySelectorAll('dl[id^="gpmlist_"]');

  /// Parse all kinds of notification from the three html documents.
  ///
  /// * [noticeDoc]: `home.php?mod=space&do=notice`.
  /// * [personalMessageDoc]: `home.php?mod=space&do=pm&filter=privatepm`.
  /// * [broadcastMessageDoc]: `home.php?mod=space&do=pm&filter=announcepm`.
  ///
  /// Only notifications not earlier than [since] (timestamp in seconds) are kept, if provided.
  // ignore: prefer_constructors_over_static_methods
  static NotificationV2 fromDocuments({
    required uh.Document noticeDoc,
    required uh.Document personalMessageDoc,
    required uh.Document broadcastMessageDoc,
    int? since,
  }) {
    final noticeList = noticeNodes(noticeDoc).map(Notice.toV2).whereType<NoticeV2>().toList();
    final pmList = personalMessageNodes(
      personalMessageDoc,
    ).map(PersonalMessage.toV2).whereType<PersonalMessageV2>().toList();
    final bmList = broadcastMessageNodes(
      broadcastMessageDoc,
    ).map(BroadcastMessage.toV2).whereType<BroadcastMessageV2>().toList();

    return NotificationV2(
      status: 0,
      noticeList: since == null ? noticeList : noticeList.where((e) => e.timestamp >= since).toList(),
      personalMessageList: since == null ? pmList : pmList.where((e) => e.timestamp >= since).toList(),
      broadcastMessageList: since == null ? bmList : bmList.where((e) => e.timestamp >= since).toList(),
    );
  }

  /// Return the datetime of latest notification, no matter the notification is a notice, personal message or
  /// broadcast message.
  ///
  /// Use this method to find the latest timestamp covers all notification generated that confirmed by the server side.
  /// Which means: all notification till this time have been confirmed and provided by the server.
  ///
  /// Note that all timestamp in notification model is in second so there is a chance of missing notification, but
  /// this behavior is inside the server side, we may do nothing on it.
  ///
  /// ## CAUTION
  ///
  /// Return null if all types of notification are empty.
  DateTime? latestTimestamp() {
    final noticeTime = switch (noticeList.isEmpty) {
      true => 0,
      false => noticeList.map((e) => e.timestamp).reduce(math.max),
    };
    final pmTime = switch (personalMessageList.isEmpty) {
      true => 0,
      false => personalMessageList.map((e) => e.timestamp).reduce(math.max),
    };
    final bmTime = switch (broadcastMessageList.isEmpty) {
      true => 0,
      false => broadcastMessageList.map((e) => e.timestamp).reduce(math.max),
    };

    // The latest timestamp (in seconds) of notification time.
    final latestTime = [noticeTime, pmTime, bmTime].reduce(math.max);

    if (latestTime == 0) {
      return null;
    }

    return DateTime.fromMillisecondsSinceEpoch(latestTime * 1000);
  }
}
