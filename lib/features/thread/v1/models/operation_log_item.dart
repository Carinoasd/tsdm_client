part of 'models.dart';

/// An item, or call it an action, in the thread operation changelog.
@MappableClass()
final class OperationLogItem with OperationLogItemMappable {
  /// Constructor.
  const OperationLogItem({required this.username, required this.action, required this.time, required this.duration});

  /// Build an instance from a list of td node.
  static OperationLogItem? fromTr(uh.Element element) {
    final tds = element.querySelectorAll('td');
    if (tds.length != 4) {
      return null;
    }

    final username = element.querySelector('a')?.innerText;
    final time = tds[1].dateTime();
    final action = tds[2].innerText;
    String? duration = tds[3].innerText;
    if (duration.isEmpty) {
      duration = null;
    }

    if (username == null || time == null) {
      return null;
    }

    return OperationLogItem(username: username, time: time, action: action, duration: duration);
  }

  /// The rows of the thread's moderation log of the forum's app API (plugin 4.0.0: `type: thread_mod`, `schema` 50),
  /// in its order (the window's, newest first), as the window shows them: the moderator, the time (the member's wall
  /// clock, `timeoffset`, to the second), the action with the item used for it, and its end (the time it expires, or
  /// "permanent" where the window prints it), else the reason the window prints in that place (a recommendation's).
  ///
  /// Only the rows a member did (`operator.kind` `user`): the window prints no link for the cron and
  /// for the "moderation team" (a forum hiding the moderators), and its parser leaves those rows out, as here.
  static List<OperationLogItem> listFromApi(Map<String, dynamic> json) {
    final offset = tsdmAppTimeOffset(json);
    final items = <OperationLogItem>[];
    for (final row in tsdmAppList(json['logs'])) {
      final operator = tsdmAppMap(row['operator']);
      final username = tsdmAppText(operator['username']);
      final time = tsdmAppWallClockTime(row['dateline'], offset);
      if (operator['kind'] != 'user' || username.isEmpty || time == null) {
        continue;
      }
      final magic = tsdmAppText(row['magic']);
      final action = '${tsdmAppText(row['action_text'])}${magic.isEmpty ? '' : '($magic)'}';
      final expiration = tsdmAppWallClockTime(row['expiration'], offset);
      final reason = tsdmAppText(row['reason']).trim();
      final duration = expiration != null
          ? expiration.yyyyMMDDHHMM()
          : (tsdmAppInt(row['unlimited']) == 1
                ? t.threadPage.operationLog.permanent
                : (reason.isEmpty ? null : reason));
      items.add(OperationLogItem(username: username, action: action, time: time, duration: duration));
    }
    return items;
  }

  /// User launched the action.
  final String username;

  /// Action description.
  final String action;

  /// When happened.
  final DateTime time;

  /// The action effect duration may be null.
  final String? duration;
}
