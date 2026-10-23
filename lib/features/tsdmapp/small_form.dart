import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';

/// The first `schema` of a small form answer (plugin 3.0.0, `type: form`): the rate, report and buy windows, the
/// user group list and its switch window, the profile editor. Fields are only ever added: a later schema is read the
/// same way.
const smallFormSchema = 17;

/// Query parameter asking the forum's plugin for a small form as structured fields (plugin 3.0.0), sent together
/// with [tsdmAppJsonQuery] on a GET of one of the five forms ([withTsdmAppForm]).
///
/// The plugin answers `type: form`, `schema` [smallFormSchema] ([smallFormAnswerOf]). An older plugin does not know
/// the parameter and answers what it always answered to `tsdmapp=json`: the write result of a window (`schema` 13,
/// `kind: page`, the fragment the app parses) and the web page itself for the user group list and the profile editor.
/// The app reads that answer as before: one request either way.
const tsdmAppFormQuery = 'tsdmform=1';

/// The kinds of small forms, as `form` of the answer names them.
enum SmallFormKind {
  /// The rate window (`forum.php?mod=misc&action=rate`).
  rate,

  /// The report window (`misc.php?mod=report`).
  report,

  /// The window to buy a paid thread (`forum.php?mod=misc&action=pay`).
  buy,

  /// The user group list (`home.php?mod=spacecp&ac=usergroup&do=expiry`) and its switch window (`do=switch`).
  usergroup,

  /// The profile editor (`home.php?mod=spacecp`).
  profile,
}

/// Add [tsdmAppJsonQuery] and [tsdmAppFormQuery] to [url] (and [tsdmAppNodocQuery] for a whole [page]: the user group
/// list and the profile editor), before a `#fragment`; a parameter already there is not added again. A window keeps
/// its `infloat=yes&inajax=1`: the forum only builds the rate and report forms for an AJAX request.
String withTsdmAppForm(String url, {bool page = false}) {
  final hash = url.indexOf('#');
  final base = hash < 0 ? url : url.substring(0, hash);
  final buffer = StringBuffer(base);
  var separator = !base.contains('?') ? '?' : (base.endsWith('?') || base.endsWith('&') ? '' : '&');
  for (final query in [tsdmAppJsonQuery, tsdmAppFormQuery, if (page) tsdmAppNodocQuery]) {
    if (RegExp('[?&]${RegExp.escape(query)}(?:&|\$)').hasMatch(base)) {
      continue;
    }
    buffer
      ..write(separator)
      ..write(query);
    separator = '&';
  }
  if (hash >= 0) {
    buffer.write(url.substring(hash));
  }
  return buffer.toString();
}

/// [url] with `inajax=1`, as the website's `ajaxpost` posts a window's form: added unless it is there.
String withSmallFormInAjax(String url) {
  final uri = Uri.parse(url);
  if (uri.queryParametersAll['inajax']?.contains('1') ?? false) {
    return url;
  }
  return '$url${url.contains('?') ? '&' : '?'}inajax=1';
}

/// What plugin 3.0.0 answered for a small form, see [smallFormAnswerOf].
sealed class SmallFormAnswer {
  const SmallFormAnswer(this.json);

  /// The answer as it came.
  final Map<String, dynamic> json;

  /// The account the answer was served to, 0 for a guest.
  int get uid => tsdmAppInt(json['uid']);

  /// Whether the answer was served to account [uid] (logged in): any other account, or a guest, is not it.
  bool servedTo(int? uid) => uid != null && uid > 0 && this.uid == uid;

  /// What to tell the user when the answer was not served to account [uid] (the account that asked): the forum served
  /// a guest (the session expired: the forum's login prompt, or the app's own "log in first"), or another account (the
  /// account changed meanwhile). Null when it was served to [uid]. Such an answer is never used.
  String? identityProblem(int? uid) {
    if (servedTo(uid)) {
      return null;
    }
    if (this.uid == 0) {
      return switch (this) {
        SmallFormMessage(:final reason) when reason.isNotEmpty => reason,
        _ => t.general.needLogin,
      };
    }
    return t.general.accountChangedRetry;
  }
}

/// The form as structured fields (`ok` 1, `type: form`, `schema` [smallFormSchema] or later).
final class SmallFormFields extends SmallFormAnswer {
  const SmallFormFields._(super.json);

  Map<String, dynamic> get _submit => tsdmAppMap(json['submit']);

  /// Whether the answer carries a form to post (`submit`): the user group list carries none.
  bool get hasSubmit => json['submit'] is Map<String, dynamic>;

  /// The hidden fields of the form and its submit button, as served (`submit.fields`); each request gets its own.
  Map<String, String> get submitFields => {
    for (final MapEntry(:key, :value) in tsdmAppMap(_submit['fields']).entries)
      if (_text(value) case final String v) key: v,
  };

  /// The url the form posts to as served (`submit.url`), relative to the forum; empty when there is none.
  String get submitUrlRaw => tsdmAppText(_submit['url']);

  /// Whether the form posts as `multipart/form-data` (the profile editor).
  bool get multipart => tsdmAppText(_submit['enctype']) == 'multipart/form-data';

  /// The names of the fields other plugins print into the form (`hook_fields`), whose values are not given.
  List<String> get hookFieldNames => [
    for (final hook in tsdmAppList(json['hook_fields']))
      if (hook['names'] case final List<dynamic> names) ...names.whereType<String>(),
  ];

  /// Why the plugin says the app should use the web page instead (`unsupported`: `validate`, `file`, `district`…).
  List<String> get unsupported => switch (json['unsupported']) {
    final List<dynamic> list => list.map((e) => '$e').toList(),
    _ => const [],
  };

  /// Whether the app can fill and post this form as served: nothing unsupported and no other plugin's fields, whose
  /// values the answer does not carry. Otherwise the web page is read as before.
  bool get usable => unsupported.isEmpty && (json['hook_fields'] is! List || (json['hook_fields'] as List).isEmpty);

  /// The absolute url [submitUrlRaw] names when it is a same-site url of [script] (`forum.php`, `misc.php`,
  /// `home.php`) whose query holds every parameter of [expect] with that value; null otherwise.
  String? submitUrl(String script, Map<String, String> expect) {
    final raw = submitUrlRaw;
    if (raw.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || !isForumScriptUri(uri, script)) {
      return null;
    }
    final query = uniqueQueryParameters(uri);
    if (query == null || expect.entries.any((e) => query[e.key] != e.value)) {
      return null;
    }
    return Uri.parse(baseUrl).replace(path: '/$script', query: uri.query).toString();
  }
}

/// The forum's message shown instead of the form (`ok` 0, `error: message`): no permission, rated already, bought
/// already, not enough credits, not in the group, the login prompt…
final class SmallFormMessage extends SmallFormAnswer {
  const SmallFormMessage._(super.json);

  /// The forum's message, plain text; empty for the login window the forum sends a guest of a window to.
  String get message => tsdmAppText(json['message']);

  /// The Discuz! language key of the message (`thread_rate_duplicate`, `credits_buy_thread`…).
  String get messageKey => tsdmAppText(json['message_key']);

  /// The forum asks to log in.
  bool get login => json['login'] == 1;

  /// Where the forum goes on to (the thread of a bought thread, the login window), empty when it names nothing.
  String get url => tsdmAppText(json['url']);

  /// What to tell the user: the forum's [message] as it wrote it, or the app's own "log in first" when the forum
  /// asks to log in without one.
  String get reason => message.isNotEmpty ? message : (login ? t.general.needLogin : '');
}

/// The answer [data] of a small form of kind [form] asked with [withTsdmAppForm], when plugin 3.0.0 (or later)
/// answered it: the form ([SmallFormFields]) or the forum's message ([SmallFormMessage]).
///
/// Null for anything else, which the caller reads as it always did: the web page, an older plugin's answer (the
/// write result of a window), a form of another kind. See [isSmallFormUnknown] for the answer of a form the plugin
/// could not tell.
SmallFormAnswer? smallFormAnswerOf(Object? data, SmallFormKind form) {
  final json = tsdmAppAnswerJson(data);
  if (json == null || json['form'] != form.name) {
    return null;
  }
  if (json['ok'] == 1) {
    final schema = json['schema'];
    return json['type'] == 'form' && schema is num && schema >= smallFormSchema ? SmallFormFields._(json) : null;
  }
  if (json['ok'] == 0 && json['error'] == 'message') {
    return SmallFormMessage._(json);
  }
  return null;
}

/// Whether [data] is plugin 3.0.0's answer for a small form it could not tell (`{"ok":0,"error":"unknown",
/// "form":…}`): neither the form nor the older answer the app parses. The caller asks again without
/// [tsdmAppFormQuery] and reads that answer as before.
bool isSmallFormUnknown(Object? data) {
  final json = tsdmAppAnswerJson(data);
  return json != null && json['ok'] == 0 && json['error'] == 'unknown' && json['form'] is String;
}

/// The account logged in now, 0 for none: the account a small form is asked for.
int currentLoginUid() =>
    getIt.isRegistered<SettingsRepository>() ? getIt.get<SettingsRepository>().currentSettings.loginUid : 0;

/// The controls of an input description list [value] of a small form answer.
List<PostFormInput> smallFormInputs(Object? value) =>
    value is List ? value.map(PostFormInput.fromJson).whereType<PostFormInput>().toList() : const [];

String? _text(Object? value) => switch (value) {
  final String s => s,
  final num n => '$n',
  _ => null,
};
