import 'dart:convert';

import 'package:tsdm_client/features/red_packet/models/models.dart';
import 'package:universal_html/html.dart' as uh;

/// The red packet entry at the top of a post body.
///
/// ```html
/// <div class="hb-entry claimed" data-tid="TID" onclick="hongbaoOpen(this)">
///   <div class="icon"></div>
///   <div><div class="t1">BLESS</div><div class="t2">均分紅包 · 剩 0/25 份 · 已被搶光</div></div>
///   <div class="claimed-mark">已被搶光</div>          <!-- hidden (display:none) while the packet is open -->
/// </div>
/// ```
final class RedPacketEntry {
  /// Constructor.
  const RedPacketEntry({required this.tid, required this.bless, required this.statusText, required this.claimed});

  /// Thread id of the packet.
  final String tid;

  /// Blessing text.
  final String bless;

  /// Second line: split mode, remaining shares and state.
  final String statusText;

  /// The forum marks the entry as claimed (by the current user) or all taken.
  final bool claimed;
}

final _dailyInitRe = RegExp(r'hongbaoDailyInit\((\{.*?\})\)', dotAll: true);
final _formHashInUrlRe = RegExp('formhash=([0-9A-Za-z]+)');

/// Parse a `div.hb-entry` element, null when it carries no thread id.
RedPacketEntry? parseRedPacketEntry(uh.Element element) {
  final tid = element.attributes['data-tid']?.trim();
  if (tid == null || tid.isEmpty) {
    return null;
  }
  return RedPacketEntry(
    tid: tid,
    bless: element.querySelector('.t1')?.innerText.trim() ?? '',
    statusText: element.querySelector('.t2')?.innerText.trim() ?? '',
    // The mark element is always present, hidden with display:none while the packet is open; only the class counts.
    claimed: element.classes.contains('claimed'),
  );
}

/// Decode a JSON object from a response body: an already decoded map, or its text.
///
/// Returns null for anything else, e.g. the HTML error page Discuz! answers to a bad formhash.
Map<String, dynamic>? decodeJsonObject(Object? data) {
  if (data is Map) {
    return Map<String, dynamic>.from(data);
  }
  if (data is String) {
    final text = data.trim();
    if (!text.startsWith('{')) {
      return null;
    }
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }
  return null;
}

/// Find the daily red packet config in the scripts of [document].
///
/// The forum only embeds `hongbaoDailyInit({...})` while the current user has not claimed today's packet.
DailyRedPacketConfig? parseDailyRedPacketConfig(uh.Document document) {
  for (final script in document.querySelectorAll('script')) {
    final config = parseDailyRedPacketConfigFromScript(script.text ?? '');
    if (config != null) {
      return config;
    }
  }
  return null;
}

/// Find the daily red packet config in one script text.
DailyRedPacketConfig? parseDailyRedPacketConfigFromScript(String script) {
  if (!script.contains('hongbaoDailyInit(')) {
    return null;
  }
  for (final match in _dailyInitRe.allMatches(script)) {
    final json = decodeJsonObject(match.group(1));
    if (json != null && json.containsKey('dateflag')) {
      return DailyRedPacketConfig.fromServerJson(json);
    }
  }
  return null;
}

/// Find the form hash of the current session in a page: a hidden `formhash` input, or the one in the logout link.
String? parseFormHash(uh.Document document) {
  final input = document.querySelector('input[name="formhash"]')?.attributes['value']?.trim();
  if (input != null && input.isNotEmpty) {
    return input;
  }
  for (final anchor in document.querySelectorAll('a[href*="formhash="]')) {
    final hash = _formHashInUrlRe.firstMatch(anchor.attributes['href'] ?? '')?.group(1);
    if (hash != null && hash.isNotEmpty) {
      return hash;
    }
  }
  return null;
}
