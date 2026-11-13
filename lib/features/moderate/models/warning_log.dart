import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/moderate/models/moderate_posts.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// One warning of a member, as the forum's warning window lists it.
final class WarningRecord {
  /// Constructor.
  const WarningRecord({required this.operator, required this.time, required this.reason, this.operatorUid});

  /// Who warned: the moderator's name where the forum shows the moderators (`moduser_public`), its words for the
  /// staff otherwise (管理团队).
  final String operator;

  /// The moderator's uid, null where the forum does not link the moderator: a tap on the record opens the profile.
  final int? operatorUid;

  /// When, as the forum prints it.
  final String time;

  /// The reason given, may be empty.
  final String reason;
}

/// The warnings of a member, as the forum's warning window (`forum.php?mod=misc&action=viewwarning`) shows them.
final class WarningLog {
  /// Constructor.
  const WarningLog({required this.records, this.summary = ''});

  /// The warnings in the forum's order.
  final List<WarningRecord> records;

  /// The forum's line under the list (how many times the member was warned, and when the forum bans posting), may be
  /// empty.
  final String summary;
}

/// What the warning window answered: the warnings, or the forum's message in their place.
sealed class WarningLogAnswer {
  const WarningLogAnswer();
}

/// The warnings.
final class WarningLogShown extends WarningLogAnswer {
  /// Constructor.
  const WarningLogShown(this.log);

  /// What the window lists.
  final WarningLog log;
}

/// The forum's message instead of the list: no warning any more, no such member, no access to the forum…
final class WarningLogRefused extends WarningLogAnswer {
  /// Constructor.
  const WarningLogRefused(this.message);

  /// The forum's words, may be empty.
  final String message;
}

/// The url of the warning window of member [uid] in thread [tid], as the floor's warning mark of the web page opens it
/// (an ajax window). The forum lists the member's warnings in every thread; the thread only decides whether the
/// account may look (the forum's view permission). Null without a thread or a member.
String? warningLogUrl({required int tid, required int uid}) {
  if (tid <= 0 || uid <= 0) {
    return null;
  }
  return '$baseUrl/forum.php?mod=misc&action=viewwarning&tid=$tid&uid=$uid&inajax=1';
}

final _cdata = RegExp(r'<!\[CDATA\[(.*?)\]\]>', dotAll: true);

String _text(uh.Element? e) => (e?.text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Read the warning window [raw] (an ajax xml answer, or the page the forum prints without `inajax`): its list
/// (`table.list`, the head row left out), or the forum's message (`showmessage`: `div.alert_error` in the window,
/// `div#messagetext` on a page). Null when it is neither.
WarningLogAnswer? parseWarningLog(String raw) {
  final html = _cdata.firstMatch(raw)?.group(1) ?? raw;
  final doc = parseHtmlDocument(html);
  // The message boxes carry the error hook's script, whose text is not the message.
  for (final script in doc.querySelectorAll('script')) {
    script.remove();
  }
  final table = doc.querySelector('div.floatwrap table.list') ?? doc.querySelector('table.list');
  if (table != null) {
    final records = <WarningRecord>[];
    for (final row in table.querySelectorAll('tr')) {
      final cells = row.children.where((e) => e.localName == 'td').toList();
      if (row.parent?.localName == 'thead' || cells.length < 3) {
        continue;
      }
      final link = cells[0].querySelector('a');
      records.add(
        WarningRecord(
          operator: _text(cells[0]),
          operatorUid: modcpAuthorUidOf(link),
          time: _text(cells[1]),
          reason: _text(cells[2]),
        ),
      );
    }
    // The line under the list is the window's own (`div.o` right after the window's `div.f_c`), not any other on a page.
    final window = table.parent?.parent;
    final line = window?.nextElementSibling;
    final summary = line != null && line.localName == 'div' && line.classes.contains('o') ? _text(line) : '';
    return WarningLogShown(WarningLog(records: List.unmodifiable(records), summary: summary));
  }
  final box =
      doc.querySelector('div.alert_error') ??
      doc.querySelector('div.alert_info') ??
      doc.querySelector('div#messagetext p') ??
      doc.querySelector('div#messagetext');
  if (box != null) {
    return WarningLogRefused(_text(box));
  }
  return null;
}
