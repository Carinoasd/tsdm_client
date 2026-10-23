import 'dart:convert';
import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
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
///
/// Plugin 1.9.0 adds the private conversation list (`pmlist`) and `seen`, the only action that writes: it does what
/// opening the notice page and the private message page on the web does to the forum (the notices marked read, the
/// "new" prompts cleared), now that the notification fetch reads the lists from here instead of those pages. It is
/// sent with [post]; its `notify` answer carries the form hash for it ([notifyCarriesLists]) and the clock the notices
/// are marked read as of ([notifyListsUnreadNotice]).
///
/// Plugin 2.0.0 answers the forum page in the JSON mode with every field the app reads as structured data
/// (`schema: 2`): the app builds the page from them and never parses the `document` of such an answer
/// (`forumPageFromApi`); an older plugin's answer, without `schema`, is parsed from its `document` as before.
///
/// Plugin 2.4.0 answers the search results (`schema: 6`), the guide lists (`schema: 7`) and the "my threads" pages
/// (`schema: 9`) as structured fields too, one row shape for the three (`searchApiAnswerOf`, `guideApiAnswerOf`,
/// `myThreadApiAnswerOf`); their readers take such an answer as a [TsdmAppStructuredPage] and the web page (or an
/// older plugin's answer) as a [TsdmAppWebPage] ([TsdmAppPageHttpExt.mapHttpPageAnswer]).
///
/// Plugin 2.5.0 answers the favorites (`schema: 8`), the friends lists (`schema: 10`), a private message
/// conversation (`schema: 11`) and the credit log (`schema: 12`) the same way (`favoriteApiAnswerOf`,
/// `friendApiAnswerOf`, `chatApiAnswerOf`, `creditApiAnswerOf`), each with a shape of its own; the forum's own
/// message of such a plugin tells the login prompt apart ([tsdmAppMessageAsksLogin]).
///
/// Plugin 2.6.0 answers the result of a write (a posted form, an AJAX dialog read for one) as one JSON object when the
/// request carries [tsdmAppJsonWriteQuery] (`type: result`, `schema: 13`, [tsdmAppWriteResultOf]): the handler call
/// of an AJAX `showmessage`, the 提示信息 page, a redirect or a page, classified ([TsdmAppWriteKind]). Every form the app
/// posts carries it ([NetClientProvider.postForm]); the readers of the results try it first and parse the forum's own
/// answer as before when there is none.
///
/// Plugin 2.3.0 answers a page asked with `nodoc=1` ([tsdmAppNodocQuery], sent with every JSON mode request) without
/// the `document` and `head` blocks when the answer carries the page as structured fields (`schema`) or is the forum's
/// message: an answer with a `schema` is a page whether or not it carries the blocks ([tsdmAppAnswerHasStructuredPage]).
/// The plugin version the last `status` or `notify` answer named is kept in [pluginInfo], for the settings page.
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

  /// What the forum's plugin last told about itself (its `version`, and since 2.3.0 whether it takes `nodoc`), null
  /// until an answer of an action named it (`status` and `notify` do, every plugin version). Kept for this run only:
  /// the settings page shows it, without asking the forum itself; the notification poll asks `notify` soon after
  /// the app starts with a logged in account.
  static final ValueNotifier<TsdmAppPluginInfo?> pluginInfo = ValueNotifier(null);

  /// Forget a missing plugin, and what the plugin told about itself (for tests, or after the user asks to check again).
  static void reset() {
    _unavailableUntil = null;
    pluginInfo.value = null;
    _postFormSeen = false;
  }

  static bool _postFormSeen = false;

  /// Note that a post form came back as structured fields (plugin 2.9.0, `type: post`, `schema` 16) in this run.
  static void notePostForm() => _postFormSeen = true;

  /// Whether the forum's plugin is known to answer the post forms as structured fields (plugin 2.9.0): it named
  /// [tsdmAppPostFormVersion] or later in an answer of an action ([pluginInfo]: the notification poll asks `notify`
  /// soon after the app starts), or such a form came back in this run ([notePostForm]).
  ///
  /// Only a hint for the reply window: the forum's own window is an AJAX fragment (`inajax=1`), while the structured
  /// form is asked without `inajax`, which an older plugin answers as a write result instead. The window is asked
  /// the new way only on this hint, and what is read is still decided by the answer: a window that does not come
  /// back as a post form is asked again the way it always was.
  static bool get knowsPostForm {
    final info = pluginInfo.value;
    return _postFormSeen || (info != null && compareTsdmAppVersions(info.version, tsdmAppPostFormVersion) >= 0);
  }

  /// Keep what an answer [json] of an action tells about the plugin ([pluginInfo]): an answer without a `version`
  /// (an older action's, or a message such as `login`) tells nothing and changes nothing. Only `status` names
  /// `nodoc`, and not every answer names `api`: what is known of the version holds through the answers of the same
  /// version that leave them out.
  static void _notePluginInfo(Map<String, dynamic> json) {
    var info = TsdmAppPluginInfo.fromAnswer(json);
    if (info == null) {
      return;
    }
    final known = pluginInfo.value;
    if (known != null && known.version == info.version) {
      // The same plugin: what an answer does not name (`api`, `nodoc`) stays as known.
      info = TsdmAppPluginInfo(
        version: info.version,
        api: info.api ?? known.api,
        nodoc: json.containsKey('nodoc') ? info.nodoc : known.nodoc,
      );
    }
    if (info != known) {
      pluginInfo.value = info;
    }
  }

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
        final decoded = _jsonObjectOf(value.data);
        if (decoded == null || decoded['ok'] is! int) {
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
        _notePluginInfo(decoded);
        return decoded;
    }
  }

  /// Post [form] to [action] with [client], once (no transport retry, no redirect followed); the parsed JSON object
  /// when the forum answered one, null otherwise. For `seen` (plugin 1.9.0), the only action that writes.
  ///
  /// Unlike [ask], an answer that is not JSON does not mark the API missing: Discuz itself answers a form hash it
  /// does not take with its "System Error" page (HTTP 503, a failed request here), before the plugin is reached, and
  /// that tells nothing about the plugin. A failed request, HTTP 429 (`error: busy`), an older plugin without the
  /// action (`error: action`) and an API switched off (`error: off`) give null as well. The caller logs it and asks
  /// again on its next fetch.
  static Future<Map<String, dynamic>?> post(NetClientProvider client, String action, Map<String, String> form) async {
    if (knownUnavailable) {
      return null;
    }
    // The plugin's own API answers JSON as it is: never asked for a write result.
    switch (await client.postForm(url(action), data: form, singleAttempt: true, tsdmAppJson: false).run()) {
      case Left(:final value):
        talker.debug('tsdmapp api $action (post) failed: $value');
        return null;
      case Right(:final value):
        final decoded = _jsonObjectOf(value.data);
        if (decoded == null || decoded['ok'] is! int) {
          talker.warning('tsdmapp api $action (post) answered no JSON (HTTP ${value.statusCode})');
          return null;
        }
        if (decoded['ok'] == 0 && (decoded['error'] == 'action' || decoded['error'] == 'off')) {
          talker.debug('tsdmapp api $action (post) not available: ${decoded['error']}');
          return null;
        }
        _notePluginInfo(decoded);
        return decoded;
    }
  }

  /// The JSON object of an answer body [data], null when it is not one.
  static Map<String, dynamic>? _jsonObjectOf(Object? data) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    final text = data is String ? data : (data == null ? '' : jsonEncode(data));
    try {
      return switch (jsonDecode(text)) {
        final Map<String, dynamic> json => json,
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }
}

/// The version of the forum's plugin this app was written against: every page it builds from structured fields, and
/// the lean answers it asks for (`nodoc=1`), are what that plugin gives. An older plugin answers less; the app then
/// parses those pages from the web page (or the blocks of the answer) as before. Shown on the settings page beside
/// the version the forum's plugin last named ([TsdmAppApi.pluginInfo]).
const expectedTsdmAppVersion = '3.0.0';

/// The first version of the forum's plugin that answers the post forms (a new thread, a reply, an edit, the reply
/// window) as structured fields (`type: post`, `schema` 16): see [TsdmAppApi.knowsPostForm].
const tsdmAppPostFormVersion = '2.9.0';

/// What the forum's plugin tells about itself in the answer of an action: `status` and `notify` name their `version`
/// since plugin 1.0.0 (1.9.0 for `notify`), and 2.3.0 adds `nodoc: 1` to `status` when it takes [tsdmAppNodocQuery].
/// The `smilies` action (2.7.0) names it `plugin_version`: its `version` is the version of the smilies table.
@immutable
final class TsdmAppPluginInfo {
  /// Constructor.
  const TsdmAppPluginInfo({required this.version, required this.api, required this.nodoc});

  /// The info of an action answer [json], null when it names no `version` (or `plugin_version`, which comes first).
  static TsdmAppPluginInfo? fromAnswer(Map<String, dynamic> json) {
    final version = json.containsKey('plugin_version') ? json['plugin_version'] : json['version'];
    if (version is! String || version.isEmpty) {
      return null;
    }
    return TsdmAppPluginInfo(
      version: version,
      api: (json['api'] as num?)?.toInt(),
      nodoc: json['nodoc'] == 1 || json['nodoc'] == true,
    );
  }

  /// The plugin's version, as it names it (`2.3.0`).
  final String version;

  /// The `api` of the answer (raised when the meaning of a field changes), null when the answer has none.
  final int? api;

  /// Whether the plugin said it takes `nodoc=1` (`nodoc: 1` in `status`, plugin 2.3.0). An answer without the field
  /// (an older plugin, `notify`) leaves it false: it tells nothing about the parameter, which the plugin ignores.
  final bool nodoc;

  /// Whether [version] is older than [expectedTsdmAppVersion]: some pages are then parsed from the web page.
  bool get olderThanExpected => compareTsdmAppVersions(version, expectedTsdmAppVersion) < 0;

  @override
  bool operator ==(Object other) =>
      other is TsdmAppPluginInfo && other.version == version && other.api == api && other.nodoc == nodoc;

  @override
  int get hashCode => Object.hash(version, api, nodoc);

  @override
  String toString() => 'TsdmAppPluginInfo(version: $version, api: $api, nodoc: $nodoc)';
}

/// Compare two dotted versions [a] and [b] (`2.3.0`, `2.10.1`) part by part as numbers, a missing part as 0, a part
/// that is not a number (`2.3.0-beta`: `0-beta`) by its leading digits: negative when [a] is older, 0 when they are
/// the same, positive when [a] is newer.
int compareTsdmAppVersions(String a, String b) {
  int partOf(List<String> parts, int i) =>
      i < parts.length ? int.tryParse(RegExp(r'^\d*').firstMatch(parts[i].trim())?.group(0) ?? '') ?? 0 : 0;
  final pa = a.split('.');
  final pb = b.split('.');
  final length = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < length; i++) {
    final diff = partOf(pa, i) - partOf(pb, i);
    if (diff != 0) {
      return diff;
    }
  }
  return 0;
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
///
/// `pms` lists the unread received conversations only: a conversation whose last message the user sent (in the app
/// or on the web), or read on the web, never showed there, and the private message page was not fetched for it, so
/// it never reached the stored list (GitHub #193). Plugin 1.8.0 adds `pm_last`, the time (seconds, forum clock) of the
/// latest change of any conversation of the user, sent or received, read or not (0 when there is none): a time after
/// [since] counts as new. An older plugin leaves it out and the gate decides as before.
TsdmAppNotifyGate notifyGateOf(Map<String, dynamic>? json, {required int since}) {
  if (json == null) {
    return const TsdmAppFetchPages();
  }
  if (json['ok'] != 1) {
    return json['error'] == 'login' ? const TsdmAppNotLoggedIn() : const TsdmAppFetchPages();
  }
  final notices = json['notices'];
  final announces = json['announces'];
  final time = (json['time'] as num?)?.toInt();
  if (time == null ||
      notices is! List ||
      announces is! List ||
      notices.whereType<Map<String, dynamic>>().any((e) => ((e['dateline'] as num?)?.toInt() ?? 0) >= since) ||
      announces.isNotEmpty ||
      notifyPmSignalOf(json, since: since)) {
    return const TsdmAppFetchPages();
  }
  return TsdmAppNothingNew(DateTime.fromMillisecondsSinceEpoch(time * 1000, isUtc: true));
}

/// Whether a `notify` answer [json] tells that a private conversation changed at or after [since] (seconds), the
/// private message part of [notifyGateOf]: an unread received conversation (`pms`) with its last message since then,
/// or the latest change of any conversation (`pm_last`, plugin 1.8.0) after it. A `pms` that is not a list cannot
/// tell, which counts as a change.
bool notifyPmSignalOf(Map<String, dynamic> json, {required int since}) {
  final pms = json['pms'];
  final pmLast = json['pm_last'];
  return pms is! List ||
      pms.whereType<Map<String, dynamic>>().any((e) => ((e['lastdateline'] as num?)?.toInt() ?? 0) >= since) ||
      (pmLast is num && pmLast.toInt() > since);
}

/// Whether a `notify` answer [json] carries the lists the notification fetch reads instead of the notice and private
/// message pages (plugin 1.9.0): the form hash `seen` is posted with, the notices, the unread broadcast messages, the
/// forum's clock and the offset (hours) the forum shows the member's times with, `timeoffset`. An older plugin leaves
/// the form hash out; its answer only gates the pages ([notifyGateOf]).
bool notifyCarriesLists(Map<String, dynamic>? json) =>
    json != null &&
    json['ok'] == 1 &&
    json['formhash'] is String &&
    json['notices'] is List &&
    json['announces'] is List &&
    json['time'] is int &&
    json['timeoffset'] is num;

/// Whether a `notify` answer [json] lists an unread notice: then `seen` is posted for the notices, with the clock of
/// that answer (`time`) as `notice`.
///
/// The forum marks every unread notice read for it, as the notice page does, unless one is unread with a time at or
/// after that clock (`newer`: it arrived, or was flagged unread again, while or after `notify` answered), which the
/// next fetch gets first. Not an id: Discuz updates a notice in place when the same thread or post fires again (same
/// id, unread again, the time of now), so a bound by id would mark read a notice the app never got.
bool notifyListsUnreadNotice(Map<String, dynamic> json) {
  final notices = json['notices'];
  return notices is List && notices.whereType<Map<String, dynamic>>().any((e) => e['new'] == 1);
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

/// Query parameter asking the plugin for a lean JSON answer (plugin 2.3.0), sent together with [tsdmAppJsonQuery]
/// on every page asked in the JSON mode.
///
/// A page the plugin answers as structured fields (`schema`: the forum page, the thread page, the profile, the
/// homepage) then comes without the `document` and `head` blocks, which the app never reads of such an answer. The
/// forum's own message (`error: message`, with `message`, `login` and `uid`) comes without them too, whatever the
/// page: the pages built from fields read the message from them, and for the pages the app still parses from their
/// blocks (the private messages, the favorites, the search…) [tsdmAppPageDocument] rebuilds the message page the
/// forum would have printed, so their parsers read it as before. The `unknown` answers (the antitheft challenge,
/// the thread cache a guest is served) keep their blocks. An older plugin ignores the parameter and answers the
/// blocks as before. See [tsdmAppAnswerHasStructuredPage] for what the app takes for a page without them.
const tsdmAppNodocQuery = 'nodoc=1';

/// The query of the JSON mode as parameters ([tsdmAppJsonQuery] and [tsdmAppNodocQuery]), for a page whose url is
/// built from a map of parameters.
const tsdmAppJsonQueryParameters = {'tsdmapp': 'json', 'nodoc': '1'};

/// Add [tsdmAppJsonQuery] and [tsdmAppNodocQuery] to [url]; an AJAX url (`inajax=1`, answered as an XML fragment) is
/// left as it is, as is one already in the JSON mode. For a write (a form target, an AJAX dialog read for one) see
/// [withTsdmAppJsonWrite].
///
/// The parameters go before a `#fragment`, which is never sent to the server: the chat history url ends with `#last`
/// and so was always answered the web page (roadmap item 3).
String withTsdmAppJson(String url) {
  final hash = url.indexOf('#');
  final base = hash < 0 ? url : url.substring(0, hash);
  if (base.contains('inajax=1') || base.contains(tsdmAppJsonQuery)) {
    return url;
  }
  final separator = !base.contains('?') ? '?' : (base.endsWith('?') || base.endsWith('&') ? '' : '&');
  return '$base$separator$tsdmAppJsonQuery&$tsdmAppNodocQuery${hash < 0 ? '' : url.substring(hash)}';
}

/// The document to parse from a forum page answer [data]: the web page itself, or the page rebuilt from the blocks of
/// a JSON answer. A thread answer also gets the `<link>` to the thread the thread parser reads the tid from.
///
/// The forum's message answered without its blocks (`error: message` asked with [tsdmAppNodocQuery], plugin 2.3.0)
/// is rebuilt as the 提示信息 page the forum prints and the 2.2.x plugin cut ([tsdmAppMessageDocument]): the parsers
/// that read the message and the login prompt from the page keep reading them.
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
  if (json is Map<String, dynamic> && json['document'] is! String && json['ok'] == 0 && json['error'] == 'message') {
    return tsdmAppMessageDocument(json);
  }
  if (json is! Map<String, dynamic> || json['document'] is! String) {
    return parseHtmlDocument(data is String ? data : '');
  }
  // The links of the page head (the thread parser and the report links read the tid from them); older answers had none.
  final tid = json['thread'] is Map<String, dynamic> ? (json['thread'] as Map<String, dynamic>)['tid'] : null;
  final head = json['head'] is String && (json['head'] as String).isNotEmpty
      ? json['head'] as String
      : (tid is int ? '<link href="forum.php?mod=viewthread&amp;tid=$tid" />' : '');
  return parseHtmlDocument(_tsdmAppPageHtml(head, '${json['document']}'));
}

/// The html of a page the JSON mode cut into [blocks], with [head]: the blocks sit inside `div#wp.wp` on the web page
/// and some parsers match through it.
String _tsdmAppPageHtml(String head, String blocks) =>
    '<html><head>$head</head><body><div id="wp" class="wp">$blocks</div></body></html>';

/// The head script naming the account [uid] a page was served to (`discuz_uid`), none for a guest.
String _tsdmAppUidScript(Object? uid) =>
    uid is int && uid > 0 ? "<script type=\"text/javascript\">var discuz_uid = '$uid';</script>" : '';

/// The html of the 提示信息 page the forum prints for a message [text] (plain text) shown as [alertClass]
/// (`alert_right`, `alert_error`, `alert_info`), served to [uid]: the message in `div#messagetext > p`, the link to go
/// on to [url] (`p.alert_btnleft > a`, none when empty) and `div#messagelogin` when the forum asks to [login].
String _tsdmAppMessagePageHtml({
  required Object? uid,
  required String text,
  required String alertClass,
  required bool login,
  String url = '',
}) {
  final escaped = htmlEscape.convert(text);
  final link = url.isEmpty ? '' : '<p class="alert_btnleft"><a href="${htmlEscape.convert(url)}">$escaped</a></p>';
  return _tsdmAppPageHtml(
    _tsdmAppUidScript(uid),
    '<div id="ct" class="wp cl"> '
    '${login ? '<div id="messagelogin"></div> ' : ''}'
    '<div id="messagetext" class="$alertClass"><p>$escaped</p>$link</div> '
    '</div>',
  );
}

/// The 提示信息 page of the forum's message answer [json] (`ok` 0, `error: message`), as the forum prints it and the
/// 2.2.x plugin answered it in `document` and `head`: the message in `div#messagetext > p` (`alert_info` for the
/// login prompt, `alert_error` for a refusal, as Discuz! classes them), `div#messagelogin` when the forum asks to log
/// in (`login` 1), and the `discuz_uid` of the account the page was served to (`uid`, none for a guest) in the head
/// script the 2.2.x `head` carried. The parsers of the pages read from their blocks tell the message, the prompt and
/// the account from these, as they did.
uh.Document tsdmAppMessageDocument(Map<dynamic, dynamic> json) {
  final login = json['login'] == 1;
  return parseHtmlDocument(
    _tsdmAppMessagePageHtml(
      uid: json['uid'],
      text: tsdmAppText(json['message']),
      alertClass: login ? 'alert_info' : 'alert_error',
      login: login,
    ),
  );
}

/// Whether a forum page answer [data] has no page at all: a JSON answer the plugin failed to build
/// (`{"ok":0,"error":"internal"}`, without the page's blocks), an empty JSON body (the request died before the plugin
/// printed its answer; dio reads an empty `application/json` body as null), or a blank one served as a web page (a PHP
/// fatal error with the errors hidden, a proxy that cut the answer: dio reads it as an empty string). No forum page is
/// blank, and a blank JSON body is not read at all: dio throws on it, which is a failed request already. A caller that
/// would take an empty page for "nothing there" (the notification poll, which then moves its window on; the draft box,
/// which then finds no account on it; a list page, which then shows an empty list) treats it as a failed request: every
/// page asked in the JSON mode does, through [TsdmAppPageHttpExt.mapHttpPage] or [fetchTsdmAppPageHtml] where it does
/// not check by itself.
///
/// A JSON answer that carries the page as structured fields, or is the forum's message with `login`, is a page
/// whether or not it carries the blocks ([tsdmAppAnswerHasStructuredPage]): asked with [tsdmAppNodocQuery], plugin
/// 2.3.0 leaves them out of such an answer.
bool tsdmAppAnswerWithoutPage(Object? data) => switch (data) {
  null => true,
  final String text when text.trim().isEmpty => true,
  _ => switch (_tsdmAppAnswerJson(data)) {
    final Map<dynamic, dynamic> json => json['document'] is! String && !tsdmAppAnswerHasStructuredPage(json),
    _ => false,
  },
};

/// Whether a JSON answer [json] of a forum page carries the page without its `document`: as structured fields (a
/// numeric `schema`: the forum page since plugin 2.0.0, the thread page since 2.1.0, the profile since 2.2.0, the
/// homepage since 2.3.0, the search results, the guide lists and the "my threads" pages since 2.4.0, the favorites,
/// the friends lists, a private message conversation and the credit log since 2.5.0), or as the
/// forum's own message with `login` telling a guest apart (`ok` 0, `error: message`, plugin 2.2.0). Asked with
/// [tsdmAppNodocQuery], plugin 2.3.0 leaves the `document` and `head` out of these; the app reads their fields
/// instead and never misses the blocks.
///
/// An answer without `schema` and without `login` (an older plugin's, the `unknown` of the antitheft challenge or
/// the thread cache, a failed build) is read from its `document` as before, and has no page without one.
bool tsdmAppAnswerHasStructuredPage(Map<dynamic, dynamic> json) =>
    json['schema'] is num || (json['ok'] == 0 && json['error'] == 'message' && json['login'] is int);

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
  // An `unknown` answer always carries its document (the challenge, the thread cache); one without is a page built
  // from nothing, which holds no post either.
  final document = json['document'];
  return document is! String || parseHtmlDocument(document).querySelector('div#postlist, div[id^="post_"]') == null;
}

/// The JSON object of a forum page answer [data], null when it is a web page (or not a JSON object).
///
/// For the callers that read the structured fields of an answer instead of its `document` (the forum page since
/// plugin 2.0.0, `schema: 2`: `forumApiAnswerOf`).
Map<String, dynamic>? tsdmAppAnswerJson(Object? data) => switch (_tsdmAppAnswerJson(data)) {
  final Map<String, dynamic> json => json,
  _ => null,
};

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

/// [FPHttpExt.mapHttp] for a forum page asked in the JSON mode ([withTsdmAppJson]), given the document of the answer
/// ([tsdmAppPageDocument], [mapHttpPage]) or, for a page the forum may answer as structured fields, the answer the
/// way its reader takes it ([mapHttpPageAnswer]).
///
/// An answer without a page ([tsdmAppAnswerWithoutPage]) is a failed request like a bad status code is. Taken as the
/// empty document it would be, the page would show an empty list (or ask the user to log in) for a forum that merely
/// failed to answer. A JSON answer that carries a page is parsed as ever, whether its list is empty or its `ok` is 0
/// (a forum message such as "no permission" is a page too).
extension TsdmAppPageHttpExt on AsyncEither<Response<dynamic>> {
  /// The answer when it is a page: `HttpRequestFailedException` when the status code is not 200, or the answer has
  /// no page.
  AsyncEither<Response<dynamic>> _page() => AsyncEither(
    () async => switch (await run()) {
      Left(:final value) => left(value),
      Right(:final value) when value.statusCode != HttpStatus.ok || tsdmAppAnswerWithoutPage(value.data) => left(
        HttpRequestFailedException(value.statusCode),
      ),
      Right(:final value) => right(value),
    },
  );

  /// * Return error if any.
  /// * Return `HttpRequestFailedException` when status code is not 200, or the answer has no page.
  /// * Return result called on [onPage] when ok.
  AsyncEither<T> mapHttpPage<T>(T Function(uh.Document document) onPage) =>
      _page().map((response) => onPage(tsdmAppPageDocument(response.data)));

  /// [mapHttpPage] for a page the forum may answer as structured fields: the page's `…ApiAnswerOf`
  /// (`searchApiAnswerOf`, `guideApiAnswerOf`, `myThreadApiAnswerOf`, `favoriteApiAnswerOf`, `friendApiAnswerOf`,
  /// `chatApiAnswerOf`, `creditApiAnswerOf`, [structuredOf]) tells the answers to build
  /// from their fields ([TsdmAppStructuredPage]), every other page is the document to parse as before
  /// ([TsdmAppWebPage]).
  ///
  /// * Return error if any.
  /// * Return `HttpRequestFailedException` when status code is not 200, or the answer has no page.
  /// * Return the structured answer when [structuredOf] takes it, else the document of the answer.
  AsyncEither<TsdmAppPageAnswer> mapHttpPageAnswer(Map<String, dynamic>? Function(Object? data) structuredOf) =>
      _page().map(
        (response) => switch (structuredOf(response.data)) {
          final Map<String, dynamic> json => TsdmAppStructuredPage(json),
          null => TsdmAppWebPage(tsdmAppPageDocument(response.data)),
        },
      );
}

/// A forum page asked in the JSON mode, the way the readers of the list pages (the search results, the guide lists,
/// the "my threads" pages; since plugin 2.5.0 the favorites, the friends lists, a private message conversation and
/// the credit log) take it from their repository: the web page (or an older plugin's answer, whose blocks are
/// rebuilt as one, [tsdmAppPageDocument]), parsed as it always was, or the structured answer of the forum's app API
/// (plugin 2.4.0), built from its fields and never from a `document` (which a lean answer, `nodoc=1`, does not
/// carry). See [TsdmAppPageHttpExt.mapHttpPageAnswer].
sealed class TsdmAppPageAnswer {
  const TsdmAppPageAnswer();
}

/// The web page, or an older plugin's answer rebuilt as one.
final class TsdmAppWebPage extends TsdmAppPageAnswer {
  /// Constructor.
  const TsdmAppWebPage(this.document);

  /// The page.
  final uh.Document document;
}

/// The structured answer of the forum's app API: the page as fields (`schema`), or the forum's own message of such a
/// plugin (`ok` 0, `error: message`), as the page's `…ApiAnswerOf` told them apart.
final class TsdmAppStructuredPage extends TsdmAppPageAnswer {
  /// Constructor.
  const TsdmAppStructuredPage(this.json);

  /// The answer.
  final Map<String, dynamic> json;
}

/// The url of page [page] of the list page [url]: its `page` parameter replaced (or added), the rest of the query as
/// it was. A structured answer of a list page (plugin 2.4.0) tells whether there is a next page (`has_next`) but
/// names no url for it, as the web page did in its pagination links.
String tsdmAppListPageUrl(String url, int page) {
  final uri = Uri.parse(url);
  return uri.replace(queryParameters: {...uri.queryParameters, 'page': '$page'}).toString();
}

/// An integer field of an API answer [value]: 0 when missing or not a number.
int tsdmAppInt(Object? value) => switch (value) {
  final num n => n.toInt(),
  final String s => int.tryParse(s) ?? 0,
  _ => 0,
};

/// A text field of an API answer [value]: empty when missing.
String tsdmAppText(Object? value) => value is String ? value : '';

/// A time field of an API answer [value] (unix seconds of the forum's clock, which the answers give exact), the real
/// instant; null when missing or 0 (the forum has no time for it).
///
/// The rule: a page that shows a time RELATIVE to now (the thread lists: "3 分钟前") takes the real instant, as the
/// forum computes the same difference. A page that shows an ABSOLUTE time (a favorite's time, a chat message, a
/// credit change, the profile) takes the forum's wall clock instead, [tsdmAppWallClockTime] with the `timeoffset` of
/// the answer: the page prints the member's wall clock and the page parsers read that text as a naive [DateTime], so
/// the structured path shows the same clock whatever the device's zone.
DateTime? tsdmAppTime(Object? value) {
  final seconds = tsdmAppInt(value);
  return seconds > 0 ? DateTime.fromMillisecondsSinceEpoch(seconds * 1000) : null;
}

/// The forum's wall clock of a time field of an API answer [value] (unix seconds) for a member whose times the forum
/// shows with an offset of [timeOffset] hours (`timeoffset` of the answer, [tsdmAppTimeOffset]): a naive [DateTime]
/// (the device's local zone) holding the clock the web page prints, to the second (the answers give the exact
/// second; the pages only print the minute). Null when missing or 0. See [tsdmAppTime] for when which applies.
DateTime? tsdmAppWallClockTime(Object? value, num timeOffset) {
  final seconds = tsdmAppInt(value);
  if (seconds <= 0) {
    return null;
  }
  final t = DateTime.fromMillisecondsSinceEpoch(
    seconds * 1000,
    isUtc: true,
  ).add(Duration(milliseconds: (timeOffset * 3600 * 1000).round()));
  return DateTime(t.year, t.month, t.day, t.hour, t.minute, t.second);
}

/// The offset (hours) the forum shows the member's times with, `timeoffset` of a page answer [json] (every JSON mode
/// answer carries it); the forum's own offset (+8) when the answer names none.
num tsdmAppTimeOffset(Map<String, dynamic> json) => json['timeoffset'] is num ? json['timeoffset'] as num : 8;

/// Whether the forum's message answer [json] (`ok` 0, `error: message`) asks the reader to log in: the forum said so
/// (`login` 1, plugin 2.2.0), or the message reads as the login prompt, as the parsers of the pages read from their
/// blocks tell it from `div#messagelogin` and from the wording of the message.
bool tsdmAppMessageAsksLogin(Map<String, dynamic> json) {
  final message = tsdmAppText(json['message']);
  return json['login'] == 1 || message.contains('登录') || message.contains('登入');
}

/// An object field of an API answer [value]: empty when missing.
Map<String, dynamic> tsdmAppMap(Object? value) => value is Map<String, dynamic> ? value : const {};

/// A list of objects of an API answer [value]: empty when missing, anything that is not an object left out.
List<Map<String, dynamic>> tsdmAppList(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];

/// Whether a row [row] of a list page answer (the search results, the guide lists, the "my threads" pages: plugin
/// 2.4.0, one row shape) names a thread (`tid`) and its subject, as the web parsers require of a row before they take
/// it; a row without is dropped, as the parsers drop a malformed row.
bool tsdmAppIsThreadRow(Map<String, dynamic> row) =>
    tsdmAppInt(row['tid']) > 0 && tsdmAppText(row['subject']).isNotEmpty;

/// The html of the forum page [url] asked of [client] in the JSON mode ([withTsdmAppJson]), for the pages that hand a
/// page around as a string ([tsdmAppPageHtml]). Throws the failure of the request, and [HttpRequestFailedException]
/// for an answer without a page ([tsdmAppAnswerWithoutPage]): an empty string would be read as a page without the
/// account, a list or a form, and not as the failure it is.
Future<String> fetchTsdmAppPageHtml(NetClientProvider client, String url) async =>
    tsdmAppPageHtml(await fetchTsdmAppPageAnswer(client, url));

/// The answer of the forum page [url] asked of [client] in the JSON mode ([withTsdmAppJson]), as the forum gave it:
/// the web page, or the JSON answer (for the callers that read its structured fields when it has them, and its
/// page otherwise, [tsdmAppPageHtml]). An answer that carries the page as structured fields (`schema`) is a page
/// whether or not it carries the blocks too ([tsdmAppAnswerHasStructuredPage]); otherwise throws as
/// [fetchTsdmAppPageHtml] throws.
Future<Object?> fetchTsdmAppPageAnswer(NetClientProvider client, String url) async =>
    switch (await client.get(withTsdmAppJson(url)).run()) {
      Right(:final value) when tsdmAppAnswerWithoutPage(value.data) => throw HttpRequestFailedException(
        value.statusCode,
      ),
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    };

/// Query parameter asking the plugin for the result of a write as JSON (plugin 2.6.0, `type: result`, `schema: 13`):
/// a posted form, or a GET the forum answers as an AJAX fragment (`inajax=1`, `infloat=yes`: the dialogs of the
/// favorites, the rate and report forms, the quick reply window…).
///
/// The forum handles the request exactly as without it (the form hash, the permissions, the flood control, the other
/// plugins: the plugin writes nothing and changes no field) and the plugin turns what the forum answered (the
/// `succeedhandle_KEY`/`errorhandle_KEY` script of an AJAX `showmessage`, the 提示信息 page, a redirect, a whole page
/// or fragment) into one JSON object ([tsdmAppWriteResultOf]), HTTP 200 whatever the forum's own status was. An
/// older plugin (or none) ignores the parameter and the forum's answer comes back as it always did: every reader
/// tries the JSON result first and parses that answer as before when there is none. Sent with every form the app
/// posts ([NetClientProvider.postForm]) but the login, the uploads and the plugin's own API, which the plugin leaves
/// alone anyway. [tsdmAppNodocQuery] means nothing for a write (only a `page` carries a `document`, never left out)
/// and is not sent.
const String tsdmAppJsonWriteQuery = tsdmAppJsonQuery;

/// Add [tsdmAppJsonWriteQuery] to [url], a form target or an AJAX dialog the app reads for a write, unless it is
/// there already. Unlike [withTsdmAppJson] an `inajax=1` url is not left alone, and `nodoc=1` is not added.
///
/// The parameter goes before a `#fragment`, which is never sent to the server.
String withTsdmAppJsonWrite(String url) {
  final hash = url.indexOf('#');
  final base = hash < 0 ? url : url.substring(0, hash);
  if (base.contains(tsdmAppJsonQuery)) {
    return url;
  }
  final separator = !base.contains('?') ? '?' : (base.endsWith('?') || base.endsWith('&') ? '' : '&');
  return '$base$separator$tsdmAppJsonWriteQuery${hash < 0 ? '' : url.substring(hash)}';
}

/// What the forum answered a write with, as the plugin classified it (plugin 2.6.0, in this order).
enum TsdmAppWriteKind {
  /// The forum called the handler of an AJAX form: `succeedhandle_KEY('url', 'message', {values})` or
  /// `errorhandle_KEY('message', {values})`. [TsdmAppWriteResult.handleKey] names the form, [TsdmAppWriteResult.values]
  /// are the handler's object (`pid`, `tid` of a reply, `favid` of a favorite…), [TsdmAppWriteResult.ok] is 1 for the
  /// success handler and for the error handler shown as a success (`alert` right: the report's `report_succeed`).
  handle,

  /// The forum printed its 提示信息 page (`div#messagetext`): a refusal (`alert` error, `ok` 0), a success or a note
  /// with a link to go on to ([TsdmAppWriteResult.url]), or the login prompt ([TsdmAppWriteResult.login], `ok` 0).
  message,

  /// The forum redirected (`Location`, or the AJAX `window.location.href` branch): [TsdmAppWriteResult.url] is the
  /// target, `ok` 1 unless it is the login page.
  redirect,

  /// Anything else: a whole page or a fragment (the rate and report forms, the check-in plugin's own float window,
  /// the `parent.show_success('')` of the profile editor…), cut as the JSON mode cuts a page and carried in
  /// [TsdmAppWriteResult.document]. `ok` is 1 unless the forum's own status was an error (400 and up) or the page is
  /// a `parent.show_error(`: the reader decides from the document.
  page,
}

/// The result of a write the forum answered through the plugin (plugin 2.6.0, `type: result`, `schema: 13`), see
/// [tsdmAppJsonWriteQuery] and [tsdmAppWriteResultOf].
///
/// A reader decides from [kind] with [messageKey], [alert] and [login], and [url] or [values], never from [ok] alone:
/// the forum's verdicts are not uniform (a `page` is always `ok`; an error handler may be a success).
final class TsdmAppWriteResult {
  TsdmAppWriteResult._(this.json, this.kind);

  /// The answer as it came.
  final Map<String, dynamic> json;

  /// What the forum answered with.
  final TsdmAppWriteKind kind;

  /// The plugin's verdict: 1 for a success handler, an error handler shown as a success, a message page that is not
  /// a refusal nor the login prompt, a redirect that is not to the login page, and a page the forum answered with a
  /// status below 400 that is not a `parent.show_error(`.
  bool get ok => json['ok'] == 1;

  /// The forum's verdict on a [TsdmAppWriteKind.handle], [TsdmAppWriteKind.message] or [TsdmAppWriteKind.redirect]:
  /// [ok] and not the login prompt. A [TsdmAppWriteKind.page] has next to none (see [ok]): read [document].
  bool get succeeded => ok && !login;

  /// The forum asks to log in: the message page carries the login box, or the redirect goes to the login page.
  bool get login => json['login'] == 1;

  /// The account the request was handled for, 0 for a guest.
  int get uid => tsdmAppInt(json['uid']);

  /// The form hash of the session.
  String get formHash => tsdmAppText(json['formhash']);

  /// The forum's message, plain text; empty when there is none (a redirect, a page).
  String get message => tsdmAppText(json['message']);

  /// What to tell the user about this result: the forum's [message], or, when there is none and the forum asks to
  /// log in, the app's own "log in first"; empty otherwise (each reader then says what it said without the result).
  /// Never the name of the [kind] or any other field of the answer.
  String get reason => message.isNotEmpty ? message : (login ? t.general.needLogin : '');

  /// The Discuz! language key the message was shown with (`post_reply_succeed`, `post_flood_ctrl`,
  /// `favorite_do_success`, `request_has_been_sent`…), only when the forum's language packs have it; empty when the
  /// forum gave plain text (a page, a third-party plugin's own words).
  String get messageKey => tsdmAppText(json['message_key']);

  /// Where the forum goes on to: the success handler's url, the link of a message page, the redirect target. Empty
  /// when there is none.
  String get url => tsdmAppText(json['url']);

  /// The `handlekey` of a [TsdmAppWriteKind.handle] (`fastpost`, `rate`, `favoritethread`…), empty otherwise.
  String get handleKey => tsdmAppText(json['handlekey']);

  /// The handler's object of a [TsdmAppWriteKind.handle], every value as text; empty otherwise.
  Map<String, String> get values => switch (json['values']) {
    final Map<dynamic, dynamic> map => {for (final e in map.entries) '${e.key}': '${e.value ?? ''}'},
    _ => const {},
  };

  /// How the forum showed the message: `right` (a success), `error` (a refusal), `info` (a note) or empty (a
  /// redirect, a page).
  String get alert => tsdmAppText(json['alert']);

  /// The message was shown as a refusal.
  bool get isError => alert == 'error';

  /// The forum refused the form because it asks for a captcha (`submit_seccode_invalid`) or a security question
  /// (`submit_secqaa_invalid`) the form did not carry: only the website shows them. A site asking by the number of
  /// posts or their interval only decides this when the form is posted (plugin 2.9.1 notes), so a form served without
  /// any can still be refused this way. Nothing was posted.
  bool get asksVerification => messageKey == 'submit_seccode_invalid' || messageKey == 'submit_secqaa_invalid';

  /// The page or fragment of a [TsdmAppWriteKind.page] as the plugin cut it, empty for the other kinds (a `document`
  /// of another kind, which the plugin never gives, is never read).
  String get documentHtml => kind == TsdmAppWriteKind.page ? tsdmAppText(json['document']) : '';

  /// The head of a whole page of a [TsdmAppWriteKind.page], empty otherwise.
  String get head => kind == TsdmAppWriteKind.page ? tsdmAppText(json['head']) : '';

  /// The answer as the page the forum would have printed, parsed once on first use: a [TsdmAppWriteKind.page] as the
  /// JSON mode rebuilds a page from its blocks ([tsdmAppPageDocument], the blocks inside `div#wp`); every other kind
  /// as the 提示信息 page of its message, with the class Discuz! gives it (`alert_right`, `alert_error`, `alert_info`),
  /// the link to go on to (`p.alert_btnleft > a`), the login box (`div#messagelogin`) when the forum asks to log in,
  /// and the `discuz_uid` of the account in the head. The readers that parsed the forum's page keep reading it.
  late final uh.HtmlDocument document = parseHtmlDocument(html);

  /// The html [document] is parsed from, for the readers that hand a page around as text.
  late final String html = _html();

  String _html() {
    if (kind == TsdmAppWriteKind.page) {
      return _tsdmAppPageHtml('${_tsdmAppUidScript(uid)}$head', documentHtml);
    }
    final alertClass = switch (alert) {
      'right' => 'alert_right',
      'error' => 'alert_error',
      'info' => 'alert_info',
      _ => login ? 'alert_info' : (kind == TsdmAppWriteKind.message || !ok ? 'alert_error' : 'alert_right'),
    };
    return _tsdmAppMessagePageHtml(uid: uid, text: message, alertClass: alertClass, login: login, url: url);
  }

  @override
  String toString() =>
      'TsdmAppWriteResult(kind: ${kind.name}, ok: $ok, key: $messageKey, alert: $alert, login: $login, '
      'handlekey: $handleKey, url: $url, message: $message)';
}

/// The result of a write in the answer [data] (the body dio decoded: a JSON object, or text), null for anything
/// else: the forum's own answer (the AJAX XML fragment, a page, a redirect followed to a page) of a forum without the
/// plugin or with an older one, or of plugin 2.6.0 when its classifier failed (the forum's answer then comes back
/// untouched: every reader keeps its parser of it), a JSON answer that is not a result (`type` other than `result`,
/// an unknown `kind`), and text that is not JSON.
///
/// A result is taken as it is, whatever its `schema`: fields are only ever added.
TsdmAppWriteResult? tsdmAppWriteResultOf(Object? data) {
  final json = tsdmAppAnswerJson(data);
  if (json == null || json['type'] != 'result') {
    return null;
  }
  final kind = switch (json['kind']) {
    'handle' => TsdmAppWriteKind.handle,
    'message' => TsdmAppWriteKind.message,
    'redirect' => TsdmAppWriteKind.redirect,
    'page' => TsdmAppWriteKind.page,
    _ => null,
  };
  return kind == null ? null : TsdmAppWriteResult._(json, kind);
}

/// The html of the answer [data] to a write, for the readers that take the answer as text and read the forum's page
/// from it (the 提示信息 of a plugin's form, the catalogue a search posted for): the result's page
/// ([TsdmAppWriteResult.html]) when the plugin answered one, the text as it came otherwise.
String tsdmAppWriteAnswerHtml(Object? data) => tsdmAppWriteResultOf(data)?.html ?? tsdmAppAnswerText(data);

/// The body [data] of an answer as text, the way the readers of the forum's own answers take it: text as it is,
/// nothing as empty, a JSON value dio decoded (an answer that is not a write result) encoded back. Never the
/// `toString()` of a decoded object.
String tsdmAppAnswerText(Object? data) => switch (data) {
  null => '',
  final String text => text,
  final Map<dynamic, dynamic> _ || final List<dynamic> _ => jsonEncode(data),
  _ => '$data',
};
