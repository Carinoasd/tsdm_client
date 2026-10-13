import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// The forum's app API, the `tsdmapp` Discuz plugin: `plugin.php?id=tsdmapp:api&action=…`, UTF-8 JSON.
///
/// The plugin is optional: every caller keeps its web page path and only uses an answer from here when there is one.
/// A forum without the plugin answers its "plugin not found" page instead of JSON; then the API is not asked again
/// for an hour, so polling does not cost an extra request each time.
///
/// Version 1 (plugin 1.0.0) is read-only: `status`, `notify`, `checkin`. Fields are only ever added; `api` is raised
/// when the meaning of a field changes. Since plugin 1.1.0 the forum can switch the API off (`error: off`, treated as
/// missing) and answers calls too close together with HTTP 429 (`error: busy`, a failed request here: the web path
/// is used for that one call).
abstract final class TsdmAppApi {
  /// Url of an action.
  static String url(String action, [Map<String, String> query = const {}]) => Uri.parse(
    '$baseUrl/plugin.php',
  ).replace(queryParameters: {'id': 'tsdmapp:api', 'action': action, ...query}).toString();

  /// How long a missing plugin is remembered.
  static const unavailableFor = Duration(hours: 1);

  static DateTime? _unavailableUntil;

  /// Whether the last answer said the forum has no API (for tests).
  static bool get knownUnavailable => _unavailableUntil != null && DateTime.now().isBefore(_unavailableUntil!);

  /// Forget a missing plugin (for tests, or after the user asks to check again).
  static void reset() => _unavailableUntil = null;

  /// Behave as on a forum without the plugin for [unavailableFor] (for tests of the web page paths).
  static void markUnavailable() => _unavailableUntil = DateTime.now().add(unavailableFor);

  /// Ask [action] with [client]; the parsed JSON object when the forum answered one, null otherwise.
  ///
  /// `{"ok":0,"error":"login"}` is an answer: the caller tells the expired session apart. A page that is not JSON
  /// marks the API missing for [unavailableFor]; a network error does not (the web path fails the same way).
  static Future<Map<String, dynamic>?> ask(
    NetClientProvider client,
    String action, [
    Map<String, String> query = const {},
  ]) => _ask(client, action, query, waitBusy: false, tries: 1);

  /// [ask], and an answer "too soon" (HTTP 429, `error: busy`, plugin 1.1.0) of a few seconds is waited for and asked
  /// once more: pages read the same action again right after a change (a title worn, a medal bought) to show the
  /// result, and the plugin takes one call per action and account every few seconds.
  static Future<Map<String, dynamic>?> askWaiting(
    NetClientProvider client,
    String action, [
    Map<String, String> query = const {},
  ]) => _ask(client, action, query, waitBusy: true, tries: 3);

  static Future<Map<String, dynamic>?> _ask(
    NetClientProvider client,
    String action,
    Map<String, String> query, {
    required bool waitBusy,
    required int tries,
  }) async {
    if (knownUnavailable) {
      return null;
    }
    final result = await client
        .get(
          url(action, query),
          options: waitBusy ? Options(validateStatus: (code) => code != null && (code < 300 || code == 429)) : null,
        )
        .run();
    if (waitBusy) {
      if (result case Right(value: final Response<dynamic> resp) when resp.statusCode == 429) {
        final data = resp.data;
        Object? json;
        try {
          json = data is Map ? data : jsonDecode('$data');
        } on FormatException {
          json = null;
        }
        final wait = json is Map ? (json['retry_after'] as num?)?.toInt() ?? 3 : 3;
        if (wait > 10) {
          return null;
        }
        await Future<void>.delayed(Duration(milliseconds: wait * 1000 + 300));
        // Another page or poller of the account may take the action again meanwhile: a few more waits, never the web
        // page of a plugin the parsers may not know any more.
        return _ask(client, action, query, waitBusy: tries > 2, tries: tries - 1);
      }
    }
    switch (result) {
      case Left(:final value):
        talker.debug('tsdmapp api $action failed: $value');
        return null;
      case Right(:final value):
        final data = value.data;
        final text = data is String ? data : (data == null ? '' : jsonEncode(data));
        Object? decoded;
        try {
          decoded = data is Map<String, dynamic> ? data : jsonDecode(text);
        } on FormatException {
          decoded = null;
        }
        if (decoded is! Map<String, dynamic> || decoded['ok'] is! int) {
          talker.info('tsdmapp api not available on the forum, using web pages for ${unavailableFor.inMinutes} min');
          _unavailableUntil = DateTime.now().add(unavailableFor);
          return null;
        }
        if (decoded['ok'] == 0 && decoded['error'] == 'off') {
          talker.info('tsdmapp api switched off on the forum, using web pages for ${unavailableFor.inMinutes} min');
          _unavailableUntil = DateTime.now().add(unavailableFor);
          return null;
        }
        if (decoded['ok'] == 0 && decoded['error'] == 'action') {
          // An older plugin without this action: not missing, just not for this question.
          return null;
        }
        return decoded;
    }
  }
}

/// What `notify` tells about the time since the last fetch.
sealed class TsdmAppNotifyGate {
  const TsdmAppNotifyGate();
}

/// Nothing new: the web pages need not be fetched.
final class TsdmAppNothingNew extends TsdmAppNotifyGate {
  /// Constructor.
  const TsdmAppNothingNew(this.serverTime);

  /// The forum's clock when it answered.
  final DateTime serverTime;
}

/// Something new, or the API could not tell: fetch the web pages as usual.
final class TsdmAppFetchPages extends TsdmAppNotifyGate {
  /// Constructor.
  const TsdmAppFetchPages();
}

/// The forum answered that the cookie is not logged in.
final class TsdmAppNotLoggedIn extends TsdmAppNotifyGate {
  /// Constructor.
  const TsdmAppNotLoggedIn();
}

/// Decide from a `notify` answer [json] whether anything arrived at or after [since] (seconds).
///
/// Notices and private messages carry the time they arrived. Broadcast messages carry the time they were written and
/// reach the members in batches (GitHub #154), so any unread one counts as new; the web path then decides from the
/// stored ones, as it always did.
TsdmAppNotifyGate notifyGateOf(Map<String, dynamic>? json, {required int since}) {
  if (json == null) {
    return const TsdmAppFetchPages();
  }
  if (json['ok'] != 1) {
    return json['error'] == 'login' ? const TsdmAppNotLoggedIn() : const TsdmAppFetchPages();
  }
  bool any(String key, String timeKey) =>
      (json[key] is List) &&
      (json[key] as List).whereType<Map<String, dynamic>>().any((e) => ((e[timeKey] as num?)?.toInt() ?? 0) >= since);
  final announces = json['announces'];
  final time = (json['time'] as num?)?.toInt();
  if (time == null ||
      json['notices'] is! List ||
      json['pms'] is! List ||
      announces is! List ||
      any('notices', 'dateline') ||
      any('pms', 'lastdateline') ||
      announces.isNotEmpty) {
    return const TsdmAppFetchPages();
  }
  return TsdmAppNothingNew(DateTime.fromMillisecondsSinceEpoch(time * 1000, isUtc: true));
}

/// The checkin state told by `checkin`, null when the API cannot tell (missing plugin, no checkin plugin, old API).
({bool checkedToday, bool openNow})? checkinStateOf(Map<String, dynamic>? json) {
  if (json == null || json['ok'] != 1 || json['installed'] != 1) {
    return null;
  }
  final checked = json['checked_today'];
  final window = json['window'];
  if (checked is! int || window is! Map<String, dynamic> || window['open_now'] is! int) {
    return null;
  }
  return (checkedToday: checked == 1, openNow: window['open_now'] == 1);
}

/// Query parameter asking a forum page for its JSON mode (stage 2: thread and forum pages).
///
/// The forum renders the page as usual and, with the plugin, answers JSON holding the blocks the app's parsers read
/// (`document`), cut from its final output: same permissions and content as the web page, without header, footer and
/// sidebar. Without the plugin (or with it switched off) the parameter is ignored and the page comes back as usual.
const tsdmAppJsonQuery = 'tsdmapp=json';

/// Add [tsdmAppJsonQuery] to [url]; an AJAX url (`inajax=1`, answered as an XML fragment) is left as it is.
///
/// The parameter goes before a `#fragment`, which is never sent to the server: the chat history url ends with `#last`
/// and so was always answered the web page (roadmap item 3).
String withTsdmAppJson(String url) {
  final hash = url.indexOf('#');
  final base = hash < 0 ? url : url.substring(0, hash);
  if (base.contains('inajax=1') || base.contains(tsdmAppJsonQuery)) {
    return url;
  }
  final separator = !base.contains('?') ? '?' : (base.endsWith('?') || base.endsWith('&') ? '' : '&');
  return '$base$separator$tsdmAppJsonQuery${hash < 0 ? '' : url.substring(hash)}';
}

/// The document to parse from a forum page answer [data]: the web page itself, or the page rebuilt from the blocks of
/// a JSON answer. A thread answer also gets the `<link>` to the thread the thread parser reads the tid from.
uh.Document tsdmAppPageDocument(Object? data) {
  final Object? json;
  if (data is Map<String, dynamic>) {
    json = data;
  } else if (data is String && data.trimLeft().startsWith('{')) {
    try {
      json = jsonDecode(data);
    } on FormatException {
      return parseHtmlDocument(data);
    }
  } else {
    return parseHtmlDocument(data is String ? data : '');
  }
  if (json is! Map<String, dynamic> || json['document'] is! String) {
    return parseHtmlDocument(data is String ? data : '');
  }
  // The links of the page head (the thread parser and the report links read the tid from them); older answers had none.
  final tid = json['thread'] is Map<String, dynamic> ? (json['thread'] as Map<String, dynamic>)['tid'] : null;
  final head = json['head'] is String && (json['head'] as String).isNotEmpty
      ? json['head'] as String
      : (tid is int ? '<link href="forum.php?mod=viewthread&amp;tid=$tid" />' : '');
  // The blocks sit inside `div#wp.wp` on the web page and some parsers match through it.
  return parseHtmlDocument(
    '<html><head>$head</head><body><div id="wp" class="wp">${json['document']}</div></body></html>',
  );
}

/// Whether a forum page answer [data] has no page at all: a JSON answer the plugin failed to build
/// (`{"ok":0,"error":"internal"}`, without the page's blocks), or an empty JSON body (the request died before the plugin
/// printed its answer; dio reads an empty `application/json` body as null). A caller that would take an empty page for
/// "nothing there" (the notification poll, which then moves its window on; the draft box, which then finds no account
/// on it) treats it as a failed request.
bool tsdmAppAnswerWithoutPage(Object? data) => switch (data) {
  null => true,
  _ => switch (_tsdmAppAnswerJson(data)) {
    final Map<dynamic, dynamic> json => json['document'] is! String,
    _ => false,
  },
};

/// Whether a thread page answer [data] holds neither the thread nor a forum message: no page at all
/// ([tsdmAppAnswerWithoutPage]), or a JSON answer that is not `ok` 1, not a forum message (`error: message`: no
/// permission, no such thread…, which the web page shows the same) and without posts in its document.
///
/// A thread page gives that when the forum answered the antitheft (防采集) challenge instead: the plugin buffers the
/// page from its first hook and turns whatever was printed into JSON when the request ends, and the challenge script is
/// printed (and the request ended) before the thread is built. The answer is `{"ok":0,"error":"unknown"}` with only a
/// form hash for a document, the script is lost, and the challenge can only be solved on the web page
/// (`AntitheftInterceptor`).
///
/// A guest may be served the forum's thread cache instead (`viewthread_loadcache`): the cached page is printed and the
/// request ended before the thread is built too, so the answer is `unknown` as well, but its document holds the whole
/// post list and is parsed as it is, as the web page would be. The cache is only read after the antitheft check passed.
bool tsdmAppAnswerWithoutContent(Object? data) {
  if (tsdmAppAnswerWithoutPage(data)) {
    return true;
  }
  final json = _tsdmAppAnswerJson(data);
  if (json == null || json['ok'] == 1 || json['error'] == 'message') {
    return false;
  }
  return parseHtmlDocument(json['document'] as String).querySelector('div#postlist, div[id^="post_"]') == null;
}

/// The JSON object of a forum page answer [data], null when it is a web page.
Map<dynamic, dynamic>? _tsdmAppAnswerJson(Object? data) {
  if (data is Map) {
    return data;
  }
  if (data is! String || !data.trimLeft().startsWith('{')) {
    return null;
  }
  try {
    return switch (jsonDecode(data)) {
      final Map<dynamic, dynamic> json => json,
      _ => null,
    };
  } on FormatException {
    return null;
  }
}

/// The html of a forum page answer [data], for callers that hand a page around as a string: the web page itself, or
/// the page rebuilt from the blocks of a JSON answer (see [tsdmAppPageDocument]).
String tsdmAppPageHtml(Object? data) {
  if (data is String && !data.trimLeft().startsWith('{')) {
    return data;
  }
  return tsdmAppPageDocument(data).documentElement?.outerHtml ?? '';
}
