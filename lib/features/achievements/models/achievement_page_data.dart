import 'package:tsdm_client/constants/url.dart';
import 'package:universal_html/html.dart' as uh;

/// Read-only achievement landing page. Reward actions are never requested.
const achievementsUrl = '$baseUrl/plugin.php?id=tsdmtitle:achi';

/// What the forum actually supplied, without inferred progress/completion values.
final class AchievementPageData {
  /// Constructor.
  const AchievementPageData({required this.recognized, this.empty = false, this.content = '', this.message = ''});

  /// Whether the known achievement-list section was found.
  final bool recognized;

  /// The server explicitly says there are no achievements.
  final bool empty;

  /// Read-only text from the achievement list, preserving conditions and line breaks.
  final String content;

  /// Forum permission/error message.
  final String message;
}

/// Read visible text only, keeping the table/list structure legible and ignoring
/// scripts, hidden nodes and controls. Links become plain text, so reward actions
/// cannot be triggered. Explicit HTML progress values are retained as raw ratios.
String achievementText(uh.Node node) {
  final buffer = StringBuffer();
  void visit(uh.Node current) {
    if (current is uh.Text) {
      buffer.write(current.text);
      return;
    }
    if (current is! uh.Element) return;
    final tag = current.tagName.toLowerCase();
    if ({'script', 'style', 'input', 'select', 'textarea', 'iframe'}.contains(tag) ||
        current.hasAttribute('hidden') ||
        RegExp(
          r'display\s*:\s*none|visibility\s*:\s*hidden',
          caseSensitive: false,
        ).hasMatch(current.getAttribute('style') ?? '')) {
      return;
    }
    if (tag == 'progress') {
      final value = current.getAttribute('value');
      final max = current.getAttribute('max');
      if (value != null) buffer.write(max == null ? value : '$value / $max');
      buffer.writeln();
      return;
    }
    final block = {'p', 'div', 'li', 'tr', 'h1', 'h2', 'h3', 'h4', 'br', 'dt', 'dd'}.contains(tag);
    if (block) buffer.writeln();
    current.nodes.forEach(visit);
    if (block) buffer.writeln();
    if (tag == 'td' || tag == 'th') buffer.write('  ');
  }

  visit(node);
  return buffer
      .toString()
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((line) => line.isNotEmpty)
      .join('\n');
}

/// The current live X5 page has a 成就列表 section and an explicit 暂无成就 state.
///
/// All three authorized test accounts returned that state on 2026-09-15. Until
/// the forum exposes populated examples, preserve any newly supplied content as
/// read-only source text rather than guessing entry selectors, percentages or
/// completed/incomplete filters from names or numerical conditions.
AchievementPageData parseAchievementPage(uh.Document document) {
  final heading = document.querySelectorAll('#ct .bm_h h2').where((e) => (e.text?.trim() ?? '') == '成就列表').firstOrNull;
  final body = heading?.parent?.parent?.querySelector('.bm_c');
  if (body == null) {
    final message = document.querySelector('#messagetext');
    return AchievementPageData(recognized: false, message: message == null ? '' : achievementText(message));
  }
  final content = achievementText(body);
  final empty = body.querySelector('.emp')?.text?.trim();
  return AchievementPageData(
    recognized: true,
    empty: (empty == '暂无成就' || empty == '暫無成就') && content == empty,
    content: content,
  );
}
