import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';

/// What the forum answered an evaluation of a thread ([ThreadRecommendRepository.submit]).
sealed class ThreadRecommendOutcome {
  const ThreadRecommendOutcome();
}

/// The forum counted it.
final class ThreadRecommendDone extends ThreadRecommendOutcome {
  /// Constructor.
  const ThreadRecommendDone();
}

/// The forum refused it (evaluated already, the account's own thread, no evaluation left today, no permission, a
/// stale form hash…); [message] is the forum's own words.
final class ThreadRecommendRefused extends ThreadRecommendOutcome {
  /// Constructor.
  const ThreadRecommendRefused(this.message);

  /// The forum's message.
  final String message;
}

/// The forum asks to log in first.
final class ThreadRecommendNeedLogin extends ThreadRecommendOutcome {
  /// Constructor.
  const ThreadRecommendNeedLogin();
}

/// Another account is in use than the one the page was served to: nothing was sent, or its answer was dropped.
final class ThreadRecommendAccountChanged extends ThreadRecommendOutcome {
  /// Constructor.
  const ThreadRecommendAccountChanged();
}

/// No verdict: the request failed, or the answer tells nothing. The evaluation may have been counted all the same.
final class ThreadRecommendUnknown extends ThreadRecommendOutcome {
  /// Constructor.
  const ThreadRecommendUnknown();
}

/// The language keys the forum counts an evaluation with (`source/app/forum/child/misc/recommend.php`).
const threadRecommendDoneKeys = {'recommend_succeed', 'recommend_daycount_succeed'};

/// The outcome of the forum's answer [data] to an evaluation.
///
/// The forum answers every outcome, its success included, through the error handler of its AJAX menu (`msgtype` 3),
/// so the plugin's result (plugin 2.6.0, [tsdmAppWriteResultOf]) is `ok` 0 with `alert` error whatever happened: the
/// verdict is the language key (`recommend_succeed`, `recommend_daycount_succeed`), or, without one, the handler's
/// values, which have the change of the evaluation index (`recommendv`) only when it was counted. The login prompt
/// (`to_login`) is told apart; any other message is a refusal, shown as the forum shows it: the index ("评价指数 N")
/// on its own line above the reason.
///
/// Without the plugin (or with an older one) the answer is the forum's AJAX fragment, read the same way: counted when
/// the handler's values or the fragment have the change of the index (`recommentv`), refused with its text otherwise.
ThreadRecommendOutcome threadRecommendOutcomeOf(Object? data) {
  if (tsdmAppWriteResultOf(data) case final result?) {
    final values = result.values;
    if (threadRecommendDoneKeys.contains(result.messageKey) || values.containsKey('recommendv')) {
      return const ThreadRecommendDone();
    }
    if (result.messageKey == 'to_login' || result.login) {
      return const ThreadRecommendNeedLogin();
    }
    if (result.message.isEmpty) {
      return const ThreadRecommendUnknown();
    }
    return ThreadRecommendRefused(_withIndexLine(result.message, values['recommendc']));
  }
  final text = tsdmAppAnswerText(data);
  final fragment = _cdataRe.firstMatch(text)?.group(1);
  if (fragment == null) {
    return const ThreadRecommendUnknown();
  }
  if (fragment.contains('id="recommentv"') || fragment.contains("'recommendv':")) {
    return const ThreadRecommendDone();
  }
  final message = _plainText(fragment);
  return message.isEmpty ? const ThreadRecommendUnknown() : ThreadRecommendRefused(message);
}

final _cdataRe = RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>');

/// The plugin's plain text [message] of a refusal with the line break the forum prints after the evaluation index
/// [index] ("评价指数 1" then "您已评价过本主题"), which the plain text lost; as it is when the index is not in it.
String _withIndexLine(String message, String? index) {
  if (index == null || index.isEmpty) {
    return message;
  }
  final at = message.indexOf(index);
  if (at < 0) {
    return message;
  }
  final end = at + index.length;
  final rest = message.substring(end).trim();
  return rest.isEmpty ? message : '${message.substring(0, end).trim()}\n$rest';
}

/// The text of the forum's AJAX [fragment]: its scripts left out, a line break for each `<br>`, the tags dropped.
String _plainText(String fragment) {
  final text = fragment
      .replaceAll(RegExp(r'<script\b[\s\S]*?</script>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp('<[^>]*>'), '');
  return _unescape(text).split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).join('\n');
}

String _unescape(String text) => text
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&');

/// Sends the evaluation of a thread ("支持" or "踩", [ThreadRecommend]) the way the forum's page does: its AJAX menu
/// (a GET that writes) with the result parameter of the forum's app API ([withTsdmAppJsonWrite]), sent once.
final class ThreadRecommendRepository {
  /// Constructor; [send] is the transport (tests inject their own).
  const ThreadRecommendRepository({required this.send});

  /// The app's client, bound to the account in use: once another account is current the request is dropped
  /// ([IdentityChangedException]). Never retried, never redirected.
  factory ThreadRecommendRepository.network(NetClientProvider client) => ThreadRecommendRepository(
    send: (url) async => switch (await client.get(withTsdmAppJsonWrite(url), singleAttempt: true).run()) {
      Right(:final value) => value.data,
      Left(:final value) => throw value,
    },
  );

  /// Send a GET to the url, return the forum's answer; throws when the request failed.
  final Future<Object?> Function(String url) send;

  /// Evaluate the thread of [recommend] as [side]. A guest's page sends nothing: the forum asks to log in.
  ///
  /// The caller checks first that the account in use is the one the page was served to
  /// ([ThreadRecommend.viewerUid]): its form hash is in the request.
  Future<ThreadRecommendOutcome> submit(ThreadRecommend recommend, ThreadRecommendSide side) async {
    if (recommend.guest) {
      return const ThreadRecommendNeedLogin();
    }
    final Object? data;
    try {
      data = await send(recommend.url(side));
    } on IdentityChangedException {
      return const ThreadRecommendAccountChanged();
    } on Exception catch (e) {
      talker.warning('thread recommend failed: tid ${recommend.tid} ${side.query}: $e');
      return const ThreadRecommendUnknown();
    }
    return threadRecommendOutcomeOf(data);
  }
}
