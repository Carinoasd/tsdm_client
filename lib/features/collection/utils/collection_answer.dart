import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:universal_html/parsing.dart';

/// What the forum answered a change of a collection (subscribe, create, edit, delete, put a thread in, take threads
/// out, comment).
sealed class CollectionOutcome {
  const CollectionOutcome();
}

/// The forum did it; [message] is its own words, [values] what its success handler carried (`ctid` of a new
/// collection).
final class CollectionDone extends CollectionOutcome {
  /// Constructor.
  const CollectionDone({this.message = '', this.values = const {}});

  /// The forum's message.
  final String message;

  /// The values of the forum's success handler.
  final Map<String, String> values;
}

/// The forum refused it; [message] is its own words.
final class CollectionRefused extends CollectionOutcome {
  /// Constructor.
  const CollectionRefused(this.message);

  /// The forum's message.
  final String message;
}

/// The forum asks to log in first.
final class CollectionNeedLogin extends CollectionOutcome {
  /// Constructor.
  const CollectionNeedLogin();
}

/// Another account is in use than the one the page was served to: nothing was sent, or its answer was dropped.
final class CollectionAccountChanged extends CollectionOutcome {
  /// Constructor.
  const CollectionAccountChanged();
}

/// No verdict: the request failed, or the answer tells nothing (the forum answers a subscription it already has, or
/// one it has not, with an empty page). The change may have been made all the same: the page is read again.
final class CollectionUnknown extends CollectionOutcome {
  /// Constructor.
  const CollectionUnknown();
}

final _cdataRe = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>');
final _succeedRe = RegExp(
  r"succeedhandle_\w+\('(?:[^'\\]|\\.)*',\s*'(?<message>(?:[^'\\]|\\.)*)'(?:,\s*\{(?<values>[^}]*)\})?",
);
final _errorRe = RegExp(r"errorhandle_\w+\('(?<message>(?:[^'\\]|\\.)*)'");
final _valueRe = RegExp(r"'(\w+)'\s*:\s*'((?:[^'\\]|\\.)*)'");
final _systemErrorRe = RegExp(r'<div class="info">\s*<li>([\s\S]*?)</li>');

String _unescapeJs(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);

String _plainText(String html) {
  final text = parseHtmlDocument(
    '<div>${html.replaceAll(RegExp(r'<script\b[\s\S]*?</script>', caseSensitive: false), '')}</div>',
  ).body?.text;
  return (text ?? '').split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).join('\n');
}

/// The outcome of the forum's answer [data] to a change of a collection.
///
/// With the forum's app API (plugin 2.6.0) the answer is its result ([tsdmAppWriteResultOf]): the forum's message
/// with its verdict, the success handler's values (`ctid`, `status`) in `values`; an empty page (`kind: page`) is
/// what the forum answers a subscription it has already (or an unsubscription of one it has not), which tells
/// nothing. Without the plugin the answer is the forum's AJAX fragment, read the same way: its success handler
/// (`succeedhandle_followcollection('url', 'message', {'status':'1'})`) or its error handler.
///
/// A stale form hash is answered, with or without the plugin, by the forum's "System Error" page (`request_tainting`),
/// a refusal with the reason it prints.
CollectionOutcome collectionOutcomeOf(Object? data) {
  if (tsdmAppWriteResultOf(data) case final result?) {
    if (result.login) {
      return const CollectionNeedLogin();
    }
    if (result.kind == TsdmAppWriteKind.page) {
      return const CollectionUnknown();
    }
    if (result.succeeded && !result.isError) {
      return CollectionDone(message: result.message, values: result.values);
    }
    return result.message.isEmpty ? const CollectionUnknown() : CollectionRefused(result.message);
  }
  final text = tsdmAppAnswerText(data);
  if (_systemErrorRe.firstMatch(text) case final match?) {
    final message = _plainText(match.group(1)!);
    return message.isEmpty ? const CollectionUnknown() : CollectionRefused(message);
  }
  final fragment = _cdataRe.firstMatch(text)?.group(1);
  if (fragment == null) {
    return const CollectionUnknown();
  }
  if (fragment.contains("'login_before_enter_home'") || fragment.contains('member.php?mod=logging&action=login')) {
    return const CollectionNeedLogin();
  }
  if (_succeedRe.firstMatch(fragment) case final match?) {
    return CollectionDone(
      message: _unescapeJs(match.namedGroup('message')!),
      values: {
        for (final m in _valueRe.allMatches(match.namedGroup('values') ?? '')) m.group(1)!: _unescapeJs(m.group(2)!),
      },
    );
  }
  if (_errorRe.firstMatch(fragment) case final match?) {
    final message = _unescapeJs(match.namedGroup('message')!).trim();
    return message.isEmpty ? const CollectionUnknown() : CollectionRefused(message);
  }
  final message = _plainText(fragment);
  return message.isEmpty ? const CollectionUnknown() : CollectionRefused(message);
}

/// The html of the forum's window [data] (an AJAX dialog read with [withTsdmAppJsonWrite]): the plugin's page
/// (`kind: page`), or the forum's own XML fragment; empty when the answer is no window.
String collectionDialogHtml(Object? data) {
  if (tsdmAppWriteResultOf(data) case final result?) {
    return result.documentHtml;
  }
  final text = tsdmAppAnswerText(data);
  return _cdataRe.firstMatch(text)?.group(1) ?? '';
}
