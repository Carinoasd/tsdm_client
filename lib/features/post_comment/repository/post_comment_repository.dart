import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/post_comment/models/post_comment.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart' show withSmallFormInAjax;
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// A form of the forum's window, to send as the window would: [action] with [fields] and what is typed.
final class PostCommentForm {
  /// Constructor.
  const PostCommentForm({required this.action, required this.fields, this.uid, this.maxLength = 200});

  /// Where the form goes (absolute).
  final String action;

  /// The fields the window carries (`formhash`, `handlekey`, the moderation form's `fid`, `tid`, `topiclist`), sent as
  /// they are, with the button's own.
  final Map<String, String> fields;

  /// The account the window was served to, when the answer names it (the forum's app API); null for the forum's own
  /// AJAX fragment.
  final int? uid;

  /// The most characters the forum takes (the comment window's `checklen`, 200 by default).
  final int maxLength;
}

/// What the forum answered when asked for a window.
sealed class PostCommentWindow {
  const PostCommentWindow();
}

/// The window's form.
final class PostCommentWindowForm extends PostCommentWindow {
  /// Constructor.
  const PostCommentWindowForm(this.form);

  /// The form.
  final PostCommentForm form;
}

/// The forum refused to open the window; [message] says why in its words, empty when it said nothing.
final class PostCommentWindowRefused extends PostCommentWindow {
  /// Constructor.
  const PostCommentWindowRefused(this.message);

  /// The forum's words.
  final String message;
}

/// The window could not be read (the request failed, or the answer is not a window).
final class PostCommentWindowFailed extends PostCommentWindow {
  /// Constructor.
  const PostCommentWindowFailed();
}

/// What the forum answered a sent form.
sealed class PostCommentOutcome {
  const PostCommentOutcome();
}

/// Done; [message] is the forum's, empty when it gave none.
final class PostCommentDone extends PostCommentOutcome {
  /// Constructor.
  const PostCommentDone(this.message);

  /// The forum's words.
  final String message;
}

/// Refused; [message] is the forum's, empty when it gave none.
final class PostCommentRefused extends PostCommentOutcome {
  /// Constructor.
  const PostCommentRefused(this.message);

  /// The forum's words.
  final String message;
}

/// No verdict: the request failed, or the answer tells nothing. The form may have been taken all the same: only the
/// page read again tells.
final class PostCommentUnknown extends PostCommentOutcome {
  /// Constructor.
  const PostCommentUnknown();
}

/// Read [url] (absolute); throws when the request failed.
typedef PostCommentGet = Future<Object?> Function(String url);

/// Send [fields] to [url] once (never retried); throws when the request failed or its result is unknown.
typedef PostCommentPost = Future<Object?> Function(String url, Map<String, String> fields);

/// The comments (点评) of floors: the forum's comment window and its form, the pages of comments after the first,
/// and the moderators' delete window and form.
///
/// Every window and page is asked with the result parameter of the forum's app API ([withTsdmAppJsonWrite]), whose
/// answer names the account it was served to; a forum without the plugin answers its AJAX fragment, read as the web
/// page reads it. Forms are sent once, as the windows send them (`inajax=1`).
final class PostCommentRepository with LoggerMixin {
  /// Constructor; transports are injected so the flow is tested without the forum.
  PostCommentRepository({required this.get, required this.post});

  /// Uses [client]: a GET with the result parameter, a POST through [NetClientProvider.postForm] (which adds it).
  factory PostCommentRepository.network(NetClientProvider client) => PostCommentRepository(
    get: (url) async => switch (await client.get(withTsdmAppJsonWrite(url)).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
    post: (url, fields) async => switch (await client.postForm(url, data: fields, singleAttempt: true).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
  );

  /// Page and window reads.
  final PostCommentGet get;

  /// Form sends.
  final PostCommentPost post;

  /// The comment window [commentAction] of a floor (`Post.commentAction`), as the forum's `showWindow` asks it.
  Future<PostCommentWindow> openComment(String commentAction) async {
    final url = _windowUrl(commentAction, handleKey: 'comment');
    return _window(url, (doc) {
      final form = doc.querySelector('form#commentform');
      if (form == null) {
        return null;
      }
      final limit = int.tryParse(doc.querySelector('#checklen')?.text?.trim() ?? '');
      return (form: form, button: 'commentsubmit', maxLength: limit != null && limit > 0 ? limit : 200);
    });
  }

  /// Send the comment [message] with [form] ([openComment]).
  Future<PostCommentOutcome> sendComment(PostCommentForm form, String message) =>
      _send(form, {'message': message}, doneKeys: const {'comment_add_succeed'});

  /// The moderators' window deleting comment [commentId] of thread [tid], as `modaction('delcomment', ID)` asks it.
  Future<PostCommentWindow> openDelete({required String tid, required int commentId}) {
    final url =
        '$baseUrl/forum.php?mod=topicadmin&action=delcomment&tid=$tid&handlekey=mods&infloat=yes&nopost=yes'
        '&topiclist[]=$commentId&inajax=1';
    return _window(url, (doc) {
      final form = doc.querySelector('form#topicadminform');
      if (form == null || !(form.attributes['action'] ?? '').contains('delcomment')) {
        return null;
      }
      return (form: form, button: 'modsubmit', maxLength: 0);
    });
  }

  /// Delete the comment of [form] ([openDelete]), with the moderator's [reason] (may be empty).
  Future<PostCommentOutcome> sendDelete(PostCommentForm form, String reason) =>
      _send(form, {'reason': reason}, doneKeys: const {'admin_succeed'});

  /// Page [page] (2 and up) of the comments of floor [pid] of thread [tid]; null when it could not be read.
  Future<PostCommentPage?> fetchMore({required String tid, required String pid, required int page}) async {
    final url = '$baseUrl/forum.php?mod=misc&action=commentmore&tid=$tid&pid=$pid&page=$page&inajax=1';
    final Object? data;
    try {
      data = await get(url);
    } on Object catch (e) {
      error('comment page read failed: ${e.runtimeType}');
      return null;
    }
    final result = tsdmAppWriteResultOf(data);
    final html = switch (result) {
      final r? when r.kind == TsdmAppWriteKind.page => r.documentHtml,
      final _? => null,
      null => data is String ? _ajaxHtml(data) : null,
    };
    return html == null ? null : parsePostCommentMore(html, page: page);
  }

  /// [url] as the forum's `showWindow` asks a window: `infloat=yes&handlekey=…&inajax=1` added when missing.
  static String _windowUrl(String url, {required String handleKey}) {
    final uri = Uri.parse(url.replaceAll('&amp;', '&').prependHost());
    final query = Map<String, String>.of(uri.queryParameters)
      ..putIfAbsent('infloat', () => 'yes')
      ..putIfAbsent('handlekey', () => handleKey)
      ..putIfAbsent('inajax', () => '1');
    return uri.replace(queryParameters: query).toString();
  }

  Future<PostCommentWindow> _window(
    String url,
    ({uh.Element form, String button, int maxLength})? Function(uh.HtmlDocument doc) formOf,
  ) async {
    final Object? data;
    try {
      data = await get(url);
    } on Object catch (e) {
      error('comment window read failed: ${e.runtimeType}');
      return const PostCommentWindowFailed();
    }
    final result = tsdmAppWriteResultOf(data);
    final String html;
    int? uid;
    if (result != null) {
      if (result.kind != TsdmAppWriteKind.page) {
        // The forum's message instead of the window: a refusal, the login prompt.
        return PostCommentWindowRefused(result.reason);
      }
      html = result.documentHtml;
      uid = result.uid;
    } else if (data is String) {
      html = _ajaxHtml(data);
    } else {
      return const PostCommentWindowFailed();
    }
    final doc = parseHtmlDocument(html);
    final found = formOf(doc);
    if (found == null) {
      final message = _refusalOf(html, doc);
      return message == null ? const PostCommentWindowFailed() : PostCommentWindowRefused(message);
    }
    final action = found.form.attributes['action']?.replaceAll('&amp;', '&').trim() ?? '';
    if (action.isEmpty) {
      return const PostCommentWindowFailed();
    }
    final fields = <String, String>{
      for (final input in found.form.querySelectorAll('input[type="hidden"]'))
        if ((input.attributes['name'] ?? '').isNotEmpty) input.attributes['name']!: input.attributes['value'] ?? '',
    };
    final button = found.form.querySelector('button[name="${found.button}"]');
    fields[found.button] = button?.attributes['value'] ?? 'true';
    return PostCommentWindowForm(
      PostCommentForm(
        action: withSmallFormInAjax(action.prependHost()),
        fields: fields,
        uid: uid,
        maxLength: found.maxLength,
      ),
    );
  }

  Future<PostCommentOutcome> _send(
    PostCommentForm form,
    Map<String, String> typed, {
    required Set<String> doneKeys,
  }) async {
    final Object? data;
    try {
      data = await post(form.action, {...form.fields, ...typed});
    } on Object catch (e) {
      error('comment form send failed: ${e.runtimeType}');
      return const PostCommentUnknown();
    }
    return postCommentOutcomeOf(data, doneKeys: doneKeys);
  }
}

/// The outcome of the forum's answer [data] to a sent comment or delete form, done with one of [doneKeys].
///
/// The result of the forum's app API (plugin 2.6.0): refused when the forum says so (not `ok`, the login prompt),
/// with its words; done with one of [doneKeys] or a message shown as a success. The forum's AJAX fragment otherwise:
/// its success handler (`succeedhandle_KEY('url', 'message', …)`) is done, its error handler refused. Anything else
/// tells nothing.
PostCommentOutcome postCommentOutcomeOf(Object? data, {required Set<String> doneKeys}) {
  final result = tsdmAppWriteResultOf(data);
  if (result != null) {
    if (result.kind == TsdmAppWriteKind.page) {
      return const PostCommentUnknown();
    }
    if (!result.succeeded) {
      return PostCommentRefused(result.reason);
    }
    if (doneKeys.contains(result.messageKey) || result.alert == 'right') {
      return PostCommentDone(result.message);
    }
    return result.messageKey.isEmpty ? const PostCommentUnknown() : PostCommentRefused(result.message);
  }
  if (data is! String) {
    return const PostCommentUnknown();
  }
  final html = _ajaxHtml(data);
  if (_succeedRe.firstMatch(html) case final m?) {
    return PostCommentDone(_jsString(m.group(1)!).trim());
  }
  if (_errorRe.firstMatch(html) case final m?) {
    return PostCommentRefused(_jsString(m.group(1)!).trim());
  }
  return const PostCommentUnknown();
}

/// `succeedhandle_KEY('url', 'message'`.
final _succeedRe = RegExp(r"succeedhandle_\w+\(\s*'(?:[^'\\]|\\.)*'\s*,\s*'((?:[^'\\]|\\.)*)'");

/// `errorhandle_KEY('message'`.
final _errorRe = RegExp(r"errorhandle_\w+\(\s*'((?:[^'\\]|\\.)*)'");

/// `<root><![CDATA[…]]></root>`.
final _cdataRe = RegExp(r'<!\[CDATA\[([\s\S]*)\]\]>');

/// The html an AJAX answer carries, the text itself otherwise.
String _ajaxHtml(String data) => _cdataRe.firstMatch(data)?.group(1) ?? data;

/// A single quoted JavaScript string's text.
String _jsString(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);

/// The forum's words in a fragment that is not the window: its error handler, its `alert_error`, or its text.
String? _refusalOf(String html, uh.HtmlDocument doc) {
  if (_errorRe.firstMatch(html) case final m?) {
    return _jsString(m.group(1)!).trim();
  }
  for (final e in doc.querySelectorAll('script')) {
    e.remove();
  }
  final alert = (doc.querySelector('.alert_error') ?? doc.querySelector('.alert_info'))?.text?.trim();
  if (alert != null && alert.isNotEmpty) {
    return alert;
  }
  // A bare message (`抱歉，…`), not a page.
  final body = doc.body;
  final text = body?.text?.trim();
  return body == null || body.children.isNotEmpty || text == null || text.isEmpty || text.length > 200 ? null : text;
}
