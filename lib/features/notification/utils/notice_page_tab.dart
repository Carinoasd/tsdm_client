import 'package:flutter/foundation.dart';

/// The tabs of the notice page, in their order.
enum NoticePageTab {
  /// Notices (提醒).
  notice,

  /// Private messages (私人消息).
  personalMessage,

  /// Broadcast messages (公共消息).
  broadcastMessage,
}

/// The tab of the notice page another page asked for (the private messages entry of the "me" tab), until the notice
/// page shows it.
///
/// The notice page is a tab of the home shell, built on its first visit and kept afterwards: it takes the tab asked
/// for when it is built, and follows the later asks while it lives. Either way it sets this back to null once shown.
final noticePageTabRequest = ValueNotifier<NoticePageTab?>(null);
