import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Two real thread rows captured from a Discuz! X5 forum page (fid=6): a sticky
/// thread with a recent last reply (`<span title>` relative time) and a normal
/// thread with a plain last reply time.
const _fixture = 'test/data/thread_row_x5.html';
const _sticky = 'stickthread_1264965';
const _plain = 'normalthread_1264206';

final _byCell = RegExp('<td class="by">(?:(?!</td>).)*</td>', dotAll: true);

uh.Element _tbody(String tableHtml, String id) => parseHtmlDocument(tableHtml).querySelector('tbody#$id')!;

/// Replace the last reply cell (the last `td.by`) of row [id] in [tableHtml] with [cell].
String _withLastReplyCell(String tableHtml, String id, String cell) {
  final row = RegExp('<tbody id="$id">.*?</tbody>', dotAll: true).firstMatch(tableHtml)!.group(0)!;
  final m = _byCell.allMatches(row).last;
  return tableHtml.replaceFirst(row, row.replaceRange(m.start, m.end, '<td class="by">$cell</td>'));
}

void main() {
  late String html;

  setUpAll(() {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    html = File(_fixture).readAsStringSync();
  });

  test('real X5 rows parse with both last reply time layouts', () {
    final recent = NormalThread.fromTBody(_tbody(html, _sticky))!;
    expect(recent.latestReplyAuthor.name, isNotEmpty);
    expect(recent.latestReplyAuthor.url, isNotEmpty);
    expect(recent.latestReplyTime, isNotNull);
    expect(recent.threadID, isNotEmpty);

    final plain = NormalThread.fromTBody(_tbody(html, _plain))!;
    expect(plain.latestReplyAuthor.name, isNotEmpty);
    expect(plain.latestReplyTime, isNotNull);
  });

  test('anonymous last replier without a link keeps the thread', () {
    final patched = _withLastReplyCell(
      html,
      _sticky,
      '<cite>匿名</cite><em><a href="forum.php?mod=redirect&amp;tid=1264965&amp;goto=lastpost">2026-9-5 11:14</a></em>',
    );
    final thread = NormalThread.fromTBody(_tbody(patched, _sticky));
    expect(thread, isNotNull);
    expect(thread!.latestReplyAuthor.name, '匿名');
    expect(thread.latestReplyAuthor.url, isEmpty);
    expect(thread.latestReplyTime, isNotNull);
  });

  test('last reply time without a link is read from text or title', () {
    const author = '<cite><a href="home.php?mod=space&amp;username=x">x</a></cite>';
    for (final em in ['<em>2026-9-5 11:14</em>', '<em><span title="2026-9-5 11:14">1 小时前</span></em>']) {
      final thread = NormalThread.fromTBody(_tbody(_withLastReplyCell(html, _sticky, '$author$em'), _sticky))!;
      expect(thread.latestReplyTime?.year, 2026, reason: em);
      expect(thread.latestReplyTime?.month, 9, reason: em);
      expect(thread.latestReplyTime?.day, 5, reason: em);
    }
  });

  test('empty last reply cell keeps the thread with empty info', () {
    final thread = NormalThread.fromTBody(_tbody(_withLastReplyCell(html, _sticky, '-'), _sticky));
    expect(thread, isNotNull);
    expect(thread!.latestReplyAuthor.name, isEmpty);
    expect(thread.latestReplyTime, isNull);
    expect(thread.threadID, isNotEmpty);
  });
}
