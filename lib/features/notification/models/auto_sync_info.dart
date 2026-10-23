part of 'models.dart';

/// Base class of state or result from auto sync notice actions.
///
/// All types derived are used for pushing local notifications.
///
/// Functionality only get enabled when auto sync notice feature is enabled.
@MappableClass()
sealed class NotificationAutoSyncInfo with NotificationAutoSyncInfoMappable {
  /// Constructor.
  const NotificationAutoSyncInfo({
    required this.notice,
    required this.personalMessage,
    required this.broadcastMessage,
    required this.timestamp,
    this.lines = const [],
  });

  /// Count of unread notice.
  final int notice;

  /// Count of unread personal message.
  final int personalMessage;

  /// Count of unread broadcast message.
  final int broadcastMessage;

  /// Timestamp happened.
  final int timestamp;

  /// One line per new notification of the sync, newest first, at most [maxLines]: the lines of an expanded system
  /// notification (Android's inbox style). Empty for a result built without them.
  final List<NotificationAutoSyncLine> lines;

  /// Lines kept in [lines].
  static const maxLines = 5;

  /// Number of new notifications of the sync.
  int get total => notice + personalMessage + broadcastMessage;
}

/// Kind of a [NotificationAutoSyncLine].
@MappableEnum()
enum NotificationAutoSyncLineKind {
  /// A notice.
  notice,

  /// A private message.
  personalMessage,

  /// A broadcast message.
  broadcastMessage,
}

/// One new notification of a sync, a line of the expanded system notification.
@MappableClass()
final class NotificationAutoSyncLine with NotificationAutoSyncLineMappable {
  /// Constructor.
  const NotificationAutoSyncLine({required this.kind, required this.text, this.user});

  /// What it is.
  final NotificationAutoSyncLineKind kind;

  /// Its text in one line: the text of a notice (the forum writes who did what), the summary of a message.
  final String text;

  /// Sender of a private message.
  final String? user;
}

/// Received notice in auto sync notice actions.
///
/// No personal message, no broadcast message.
@MappableClass()
final class NotificationAutoSyncInfoNotice extends NotificationAutoSyncInfo
    with NotificationAutoSyncInfoNoticeMappable {
  /// Constructor.
  const NotificationAutoSyncInfoNotice({
    required this.msg,
    required super.notice,
    required super.personalMessage,
    required super.broadcastMessage,
    required super.timestamp,
    super.lines,
    this.nid,
    this.author,
    this.noticeType,
    this.fromIdType,
    this.threadTitle,
    this.quote,
    this.tid,
    this.pid,
  });

  /// Text of the notice, in one line.
  final String msg;

  /// Id of the notice announced, null when unknown.
  final int? nid;

  /// Name of the user who triggered it, null for a system notice or when unknown.
  final String? author;

  /// Notice type of the forum (`post`, `at`, `rate`...), null when unknown.
  final String? noticeType;

  /// `from_idtype` of the forum's app API, null when unknown.
  final String? fromIdType;

  /// Title of the thread it is about, null when it names none.
  final String? threadTitle;

  /// Text it quotes (the mentioning post, the reason of a rate), null when none.
  final String? quote;

  /// Thread it links, null when none.
  final int? tid;

  /// Floor it links, null when none.
  final int? pid;
}

/// Received personal message in auto sync notice actions.
@MappableClass()
final class NotificationAutoSyncInfoPm extends NotificationAutoSyncInfo with NotificationAutoSyncInfoPmMappable {
  /// Constructor.
  const NotificationAutoSyncInfoPm({
    required this.user,
    required this.msg,
    required super.notice,
    required super.personalMessage,
    required super.broadcastMessage,
    required super.timestamp,
    super.lines,
    this.peerUid,
  });

  /// Uid of the peer of the conversation, null when unknown.
  final int? peerUid;

  /// Username of the message sender.
  final String user;

  /// Preview of message;
  final String msg;
}

/// Received broadcast message in auto sync notice actions.
@MappableClass()
final class NotificationAutoSyncInfoBm extends NotificationAutoSyncInfo with NotificationAutoSyncInfoBmMappable {
  /// Constructor.
  const NotificationAutoSyncInfoBm({
    required this.msg,
    required super.notice,
    required super.personalMessage,
    required super.broadcastMessage,
    required super.timestamp,
    super.lines,
  });

  /// Preview of message.
  final String msg;
}
