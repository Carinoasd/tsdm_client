import 'dart:io' if (dart.library.js) 'package:web/web.dart';

import 'package:dio/dio.dart' show Options;
import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// The pages, small forms and write results of the forum's app API that need `tsdmv=4` (plugin 4.0.0).
///
/// The app already asks many of these urls with [tsdmAppJsonQuery] and parses their web page (or `document`): the
/// plugin answers them as structured fields only when the request also carries [tsdmAppV4Query], and without it the
/// answer is word for word the one of 3.9.0. So the parameter is sent only once the last `status` of the forum's
/// plugin said it knows it ([TsdmAppV4.on]; [TsdmAppApi.ensureStatus] asks one when none told it yet), and only for
/// what that `status` lists ([TsdmAppV4Flags]). Every reader keeps its web page path: an older plugin, one switched
/// off, an answer that is not the page asked for, all read the page as before.
///
/// * A page: [withTsdmAppV4Page], read with [fetchTsdmAppV4Page] into a [TsdmAppV4Answer].
/// * A small form (`type: form`, `schema` 17): [withTsdmAppV4Form], read with `smallFormAnswerOf` as the forms of
///   plugin 3.0.0 are.
/// * A write (the forum's own form posted back, or a GET that writes): [withTsdmAppV4Write], sent once with
///   [postTsdmAppV4] or [getTsdmAppV4Write]; the answer is a write result (`schema` 13) or the same page drawn again
///   ([tsdmAppV4WriteOutcomeOf]). Decide from `message_key` (and the fields each page names), never from `ok` alone.

/// Query parameter of plugin 4.0.0: the page, the small form or the write result of 4.0.0 instead of the answer of
/// 3.9.0. Only the literal `4` is taken.
const tsdmAppV4Query = 'tsdmv=4';

/// The lists of `status` (plugin 4.0.0) naming what is answered with [tsdmAppV4Query], by their key in `status`.
enum TsdmAppV4Group {
  /// The pages of the moderation panel (`moderate`, `member`, `ipban`, `recyclebin`, `recyclebinpost`, `editforum`,
  /// `announcement`); the pages of 3.9.0 (`modcp_pages`) need no `tsdmv`.
  modcpPages('modcp_pages_v4'),

  /// The lists of the thread page: `ratings`, `poll_voters`, `thread_mod`, `payments`.
  threadLists('thread_lists'),

  /// `credit_base`, `credit_rule`, `usergroup_info`.
  creditPages('credit_pages'),

  /// `privacy_filter`, and `blockuser` while the forum runs that plugin.
  blockPages('block_pages'),

  /// `doing`, `docomment`, `feed`, `follow`, `blog`, `album`, `wall`, `poke`.
  spacePages('space_pages'),

  /// `task_list`, `task`, `task_parter`.
  taskPages('task_pages'),

  /// `magic_shop`, `magic_mybox`, `magic_log`.
  magicPages('magic_pages'),

  /// The small forms: those of 3.x (`rate`, `report`…, which need no `tsdmv`) and since 4.0.0 `moderate`, `delpost`,
  /// `warn`, `banpost`, `delcomment`, `removerate`, `threadtypes`, `friendadd`, `favorite`, `poke`, `collection`,
  /// `ignore`, `magicbuy`, `magicuse` (which do).
  forms('forms')
  ;

  const TsdmAppV4Group(this.key);

  /// The key of the list in `status`.
  final String key;
}

/// What a `status` of the forum's plugin says it answers with [tsdmAppV4Query] (plugin 4.0.0). A `status` of an older
/// plugin names none of it: every flag off, every list empty ([TsdmAppV4Flags.none]).
@immutable
final class TsdmAppV4Flags {
  /// Constructor.
  const TsdmAppV4Flags({
    required this.on,
    this.announce = false,
    this.notifyPaging = false,
    this.achievement = false,
    this.lists = const {},
  });

  /// The flags of the `status` answer [json].
  factory TsdmAppV4Flags.fromStatus(Map<String, dynamic> json) {
    if (json['v4'] != 1) {
      return none;
    }
    return TsdmAppV4Flags(
      on: true,
      announce: json['announce'] == 1,
      notifyPaging: json['notify_paging'] == 1,
      achievement: json['achievement'] == 1,
      lists: {
        for (final group in TsdmAppV4Group.values)
          if (json[group.key] case final List<dynamic> names) group: {...names.whereType<String>()},
      },
    );
  }

  /// The flags of a `status` that names none.
  static const none = TsdmAppV4Flags(on: false);

  /// `v4: 1`: the plugin knows [tsdmAppV4Query]. Nothing else here counts without it.
  final bool on;

  /// `announce: 1`: the broadcast messages as a list (`pmlist&filter=announce`) and their detail as a page (`announcepm`,
  /// `schema` 40).
  final bool announce;

  /// `notify_paging: 1`: `notify` takes `limit` and `before` (GitHub #156).
  final bool notifyPaging;

  /// `achievement: 1`: the forum runs the achievements of the titles plugin (its page, `schema` 68).
  final bool achievement;

  /// The names of each list of `status` ([TsdmAppV4Group]).
  final Map<TsdmAppV4Group, Set<String>> lists;

  /// Whether [name] is in the list [group] (and the plugin knows [tsdmAppV4Query] at all).
  bool has(TsdmAppV4Group group, String name) => on && (lists[group]?.contains(name) ?? false);

  @override
  bool operator ==(Object other) =>
      other is TsdmAppV4Flags &&
      other.on == on &&
      other.announce == announce &&
      other.notifyPaging == notifyPaging &&
      other.achievement == achievement &&
      other.lists.length == lists.length &&
      lists.entries.every((e) => setEquals(other.lists[e.key], e.value));

  @override
  int get hashCode => Object.hash(on, announce, notifyPaging, achievement, Object.hashAllUnordered(lists.keys));

  @override
  String toString() =>
      'TsdmAppV4Flags(on: $on, announce: $announce, notifyPaging: $notifyPaging, achievement: $achievement, '
      'lists: ${lists.map((k, v) => MapEntry(k.key, v.length))})';
}

/// What the app may ask of the forum's plugin with [tsdmAppV4Query] now: what the last `status` said
/// ([TsdmAppPluginInfo.v4]), as long as the plugin is used at all (not missing, not switched off, not older than
/// [tsdmAppMinimumVersion]). Nothing is on until a `status` of the plugin's version told it ([TsdmAppApi.ensureStatus]).
abstract final class TsdmAppV4 {
  /// The flags of the last `status` when the plugin knows [tsdmAppV4Query] and is used; null otherwise.
  static TsdmAppV4Flags? get flags {
    final info = TsdmAppApi.pluginInfo.value;
    if (info == null || info.olderThanMinimum || TsdmAppApi.knownUnavailable || TsdmAppApi.knownTooOld) {
      return null;
    }
    final flags = info.v4;
    return flags != null && flags.on ? flags : null;
  }

  /// The plugin knows [tsdmAppV4Query].
  static bool get on => flags != null;

  /// The broadcast messages are read from the plugin ([TsdmAppV4Flags.announce]).
  static bool get announce => flags?.announce ?? false;

  /// `notify` is read page by page ([TsdmAppV4Flags.notifyPaging]).
  static bool get notifyPaging => flags?.notifyPaging ?? false;

  /// The achievements page is answered ([TsdmAppV4Flags.achievement]).
  static bool get achievement => flags?.achievement ?? false;

  /// [name] of [group] is answered with [tsdmAppV4Query] ([TsdmAppV4Flags.has]).
  static bool has(TsdmAppV4Group group, String name) => flags?.has(group, name) ?? false;
}

/// The AJAX parameters of the forum's floating windows, dropped from a page asked with [withTsdmAppV4Page]: the
/// plugin answers the whole page (the same fields) and the forum would otherwise answer some as an XML fragment.
const _ajaxParameters = {'inajax', 'infloat', 'handlekey', 'ajaxtarget', 't'};

/// [url] with each of [add] (`key=value`) appended unless that key is there already, and the parameters named in
/// [drop] left out; the rest of the query kept as it was written, before a `#fragment`.
String _withQuery(String url, List<String> add, {Set<String> drop = const {}}) {
  final hash = url.indexOf('#');
  final base = hash < 0 ? url : url.substring(0, hash);
  final fragment = hash < 0 ? '' : url.substring(hash);
  final mark = base.indexOf('?');
  final path = mark < 0 ? base : base.substring(0, mark);
  final kept = <String>[
    for (final pair in (mark < 0 ? '' : base.substring(mark + 1)).split('&'))
      if (pair.isNotEmpty && !drop.contains(Uri.decodeQueryComponent(pair.split('=').first))) pair,
  ];
  final keys = {for (final pair in kept) Uri.decodeQueryComponent(pair.split('=').first)};
  for (final pair in add) {
    if (keys.add(pair.split('=').first)) {
      kept.add(pair);
    }
  }
  return '$path?${kept.join('&')}$fragment';
}

/// [url], a page of plugin 4.0.0 (`schema` 40 to 71), as it is asked: [tsdmAppJsonQuery], [tsdmAppV4Query] and
/// [tsdmAppNodocQuery] added, the AJAX parameters of a floating window (`inajax`, `infloat`, `handlekey`, `ajaxtarget`)
/// dropped: the plugin answers the whole page.
String withTsdmAppV4Page(String url) =>
    _withQuery(url, const [tsdmAppJsonQuery, tsdmAppV4Query, tsdmAppNodocQuery], drop: _ajaxParameters);

/// [url], a small form of plugin 4.0.0 (`moderate`, `delpost`, `friendadd`…: [TsdmAppV4Group.forms]), as it is asked:
/// [tsdmAppJsonQuery], [tsdmAppV4Query], `tsdmform=1` and [tsdmAppNodocQuery] added, the rest kept (a window keeps its
/// `inajax=1`: the forum builds some forms only for an AJAX request, and the client sends `X-Requested-With` for it).
/// All three of `tsdmapp`, `tsdmv` and `tsdmform` are needed, or the answer is that of 3.9.0.
String withTsdmAppV4Form(String url) =>
    _withQuery(url, const [tsdmAppJsonQuery, tsdmAppV4Query, 'tsdmform=1', tsdmAppNodocQuery]);

/// [url], the target of a write of plugin 4.0.0 (a form posted back, a GET that writes), as it is sent:
/// [tsdmAppJsonWriteQuery] and [tsdmAppV4Query] added. The plugin then fills `message_key` where the forum gives
/// none, and answers a form the forum draws again with the same page (`schema`) instead of the 3.9.0 result.
String withTsdmAppV4Write(String url) => _withQuery(url, const [tsdmAppJsonWriteQuery, tsdmAppV4Query]);

/// A page of plugin 4.0.0 as [tsdmAppV4AnswerOf] read it.
sealed class TsdmAppV4Answer {
  const TsdmAppV4Answer(this.json);

  /// The answer as it came.
  final Map<String, dynamic> json;

  /// The account the answer was served to, 0 for a guest.
  int get uid => tsdmAppInt(json['uid']);

  /// The offset (hours) the forum shows the member's times with ([tsdmAppTimeOffset]).
  num get timeOffset => tsdmAppTimeOffset(json);
}

/// The page asked for (`ok` 1, its `type`, its `schema` or later).
final class TsdmAppV4Page extends TsdmAppV4Answer {
  const TsdmAppV4Page._(super.json);

  /// The `schema` of the answer.
  int get schema => tsdmAppInt(json['schema']);
}

/// The forum stopped at its message instead of the page (`ok` 0, `error: message`): no permission, not found, the
/// function switched off, the login prompt.
final class TsdmAppV4Message extends TsdmAppV4Answer {
  const TsdmAppV4Message._(super.json);

  /// The forum's message, plain text.
  String get message => tsdmAppText(json['message']);

  /// The Discuz! language key of the message (`thread_rate_log_nonexistence`, `pm_status_off`…); empty when the forum
  /// gave none.
  String get messageKey => tsdmAppText(json['message_key']);

  /// The forum asks to log in (a guest).
  bool get login => json['login'] == 1;

  /// What to tell the user: the forum's [message], or the app's own "log in first" when the forum asks to log in
  /// without one.
  String get reason => message.isNotEmpty ? message : (login ? t.general.needLogin : '');
}

/// The plugin refused the page itself (`ok` 0 with another `error`): `privacy` (the space's owner hides it),
/// `polloption` (an option that is not the thread's), `login`…
final class TsdmAppV4Refused extends TsdmAppV4Answer {
  const TsdmAppV4Refused._(super.json);

  /// The plugin's code of the refusal.
  String get error => tsdmAppText(json['error']);

  /// The plugin's message, often empty.
  String get message => tsdmAppText(json['message']);
}

/// The errors of the plugin that tell nothing about the page (the API missing or switched off, a failed build): the
/// reader takes the web page path for them.
const _notAnswered = {'off', 'action', 'unknown', 'internal', 'busy'};

/// The answer [data] of a page asked with [withTsdmAppV4Page] read as page [type] of `schema` [schema] (or later): the
/// page, the forum's message, or the plugin's refusal. Null for anything else (the web page, an answer of another
/// type, an older plugin's answer, an error that tells nothing of the page): the caller reads the page as before.
TsdmAppV4Answer? tsdmAppV4AnswerOf(Object? data, {required String type, required int schema}) {
  final json = tsdmAppAnswerJson(data);
  if (json == null) {
    return null;
  }
  if (json['ok'] == 1) {
    return json['type'] == type && tsdmAppInt(json['schema']) >= schema ? TsdmAppV4Page._(json) : null;
  }
  if (json['ok'] != 0) {
    return null;
  }
  return switch (json['error']) {
    'message' => TsdmAppV4Message._(json),
    final String error when error.isNotEmpty && !_notAnswered.contains(error) => TsdmAppV4Refused._(json),
    _ => null,
  };
}

/// Ask page [url] of [client] with [withTsdmAppV4Page] and read it as [tsdmAppV4AnswerOf] does, for account [uid] (0
/// for a guest):
///
/// * nothing is asked and `Right(null)` given unless the plugin is known to answer pages of 4.0.0 ([TsdmAppV4.on]; the
///   caller checks its own flag, [TsdmAppV4.has]);
/// * `Right(null)` too for an answer that is not the page (the caller reads the web page as before);
/// * an answer served to another account is [IdentityChangedException], except the forum's login prompt served to a
///   guest (the session ended), which is given as the [TsdmAppV4Message] it is;
/// * a failed request (no answer, a status other than 200) is the failure.
AsyncEither<TsdmAppV4Answer?> fetchTsdmAppV4Page(
  NetClientProvider client,
  String url, {
  required String type,
  required int schema,
  required int uid,
}) => AsyncEither(() async {
  if (!TsdmAppV4.on) {
    return right(null);
  }
  switch (await client.get(withTsdmAppV4Page(url)).run()) {
    case Left(:final value):
      return left(value);
    case Right(:final value) when value.statusCode != HttpStatus.ok:
      return left(HttpRequestFailedException(value.statusCode));
    case Right(:final value):
      final answer = tsdmAppV4AnswerOf(value.data, type: type, schema: schema);
      return switch (answer) {
        null => right(null),
        _ when answer.uid == uid => right(answer),
        TsdmAppV4Message(login: true) when answer.uid == 0 => right(answer),
        _ => left(IdentityChangedException()),
      };
  }
});

/// Post the forum's own form [data] to [url] with [client] once ([withTsdmAppV4Write]: no transport retry, no
/// redirect followed); the answer as it came, for [tsdmAppV4WriteOutcomeOf]. A timed out write may have been carried
/// out: the caller reads the page again, never posts again by itself.
AsyncEither<Object?> postTsdmAppV4(NetClientProvider client, String url, Map<String, String> data) =>
    client.postForm(withTsdmAppV4Write(url), data: data, singleAttempt: true).map((response) => response.data);

/// Send the GET that writes [url] with [client] once ([withTsdmAppV4Write]: the task's apply, draw and give up of
/// plugin 4.0.0, which the forum carries out on the GET itself). Only when the user asked for it: never preloaded,
/// never retried, never put where something fetches urls by itself. The answer as it came, for
/// [tsdmAppV4WriteOutcomeOf]; HTTP errors are kept as answers (the plugin answers JSON with them).
AsyncEither<Object?> getTsdmAppV4Write(NetClientProvider client, String url) => client
    .get(withTsdmAppV4Write(url), singleAttempt: true, options: Options(validateStatus: (code) => code != null))
    .map((response) => response.data);

/// What the forum answered a write of plugin 4.0.0 with, see [tsdmAppV4WriteOutcomeOf].
sealed class TsdmAppV4WriteOutcome {
  const TsdmAppV4WriteOutcome();
}

/// The write result (`type: result`, `schema` 13): decide from [TsdmAppWriteResult.messageKey].
final class TsdmAppV4Written extends TsdmAppV4WriteOutcome {
  /// Constructor.
  const TsdmAppV4Written(this.result);

  /// The result.
  final TsdmAppWriteResult result;
}

/// The forum drew the same page again (`ok` 1 whatever happened): decide from the fields the page names
/// (`message_key`, `result.error`, `error`, `count`…).
final class TsdmAppV4Redrawn extends TsdmAppV4WriteOutcome {
  /// Constructor.
  const TsdmAppV4Redrawn(this.answer);

  /// The page, or the forum's message instead of it.
  final TsdmAppV4Answer answer;
}

/// Anything else (an older plugin's answer, the forum's own page): nothing is known of the write; read the page again.
final class TsdmAppV4WriteUnknown extends TsdmAppV4WriteOutcome {
  /// Constructor.
  const TsdmAppV4WriteUnknown();
}

/// The answer [data] of a write of plugin 4.0.0 ([postTsdmAppV4], [getTsdmAppV4Write]): the write result, or page
/// [type] of `schema` [schema] drawn again when the caller names one, or nothing known.
TsdmAppV4WriteOutcome tsdmAppV4WriteOutcomeOf(Object? data, {String? type, int? schema}) {
  if (tsdmAppWriteResultOf(data) case final result?) {
    return TsdmAppV4Written(result);
  }
  if (type != null && schema != null) {
    if (tsdmAppV4AnswerOf(data, type: type, schema: schema) case final answer?) {
      return TsdmAppV4Redrawn(answer);
    }
  }
  return const TsdmAppV4WriteUnknown();
}
