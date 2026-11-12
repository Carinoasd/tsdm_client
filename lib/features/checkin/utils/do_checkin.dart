import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/utils/parse_checkin.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:universal_html/parsing.dart';

const _checkInPageUrl = '$baseUrl/plugin.php?id=dsu_paulsign:sign';
const _checkInRequestUrl = '$baseUrl/plugin.php?id=dsu_paulsign:sign&operation=qiandao&infloat=1&inajax=1';

/// Do a checkin work for a specified user with given [feeling] and [message].
///
/// User info and credential MUST be wrapped in [netClient].
///
/// This function acts like a common function used by both AutoCheckinRepository
/// and CheckinRepository, but not becomes a static function of those' base
/// class, because they don't have it.
Task<CheckinResult> doCheckin(NetClientProvider netClient, CheckinFeeling feeling, String message) {
  return Task(() async {
    // The forum's app API tells the state plainly when the forum has it; checking in itself stays the web form.
    final apiAnswer = await TsdmAppApi.ask(netClient, 'checkin');
    if (apiAnswer != null && apiAnswer['ok'] == 0 && apiAnswer['error'] == 'login') {
      talker.error('check in failed: not logged in (app api)');
      return const CheckinResultNotAuthorized();
    }
    switch (checkinStateOf(apiAnswer)) {
      case (checkedToday: true, openNow: _):
        talker.info('check in skipped: checked in today (app api)');
        return const CheckinResultAlreadyChecked();
      case (checkedToday: false, openNow: false):
        talker.warning('check in not done: checkin is not open now (app api)');
        return const CheckinResultEarlyInTime();
      case (checkedToday: false, openNow: true):
        // With the state told, the checkin page is only read for its form hash, and it is the heaviest page of all
        // (every account, every day) and the one most bound to the checkin plugin's template. The API tells the hash:
        // post the form directly (roadmap item 3). Without it (an older plugin, a busy answer) the page is read as
        // before.
        final formHash = await _apiFormHash(netClient, apiAnswer!);
        if (formHash != null) {
          talker.info('check in: form hash from the app api, checkin page skipped');
          return _postCheckin(netClient, formHash, feeling, message, askedAt: apiAnswer['time']);
        }
      case null:
        break;
    }

    final respEither = await netClient.get(_checkInPageUrl).run();
    if (respEither.isLeft()) {
      return _requestFailed(respEither.unwrapErr());
    }
    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      talker.error(
        'failed to check in: web request failed with status code '
        '${resp.statusCode}',
      );
      return CheckinResultWebRequestFailed(resp.statusCode);
    }
    final document = parseHtmlDocument(resp.data as String);

    // Session expired: the server renders the login form instead of the checkin page. A guest page still carries a
    // form hash, so this comes before looking for one; the post would only answer "您需要先登录". Same rule as the
    // notification fetch.
    if (document.querySelector('form#lsform') != null && document.querySelector('div#um') == null) {
      talker.error('check in failed: not logged in');
      return const CheckinResultNotAuthorized();
    }

    // The service desk box tells the truth; the page title may not (see below).
    if (parseCheckinDeskStatus(document) ?? false) {
      talker.info('check in skipped: the checkin page says checked in today');
      return const CheckinResultAlreadyChecked();
    }

    final maybeCheckinMessage = parseCheckinPageMessage(document);
    if (maybeCheckinMessage != null) {
      final r2 = _checkCheckinResultText(maybeCheckinMessage);
      if (r2 != null) {
        return r2;
      }
    }

    final formHash = parseCheckinFormHash(document);
    if (formHash == null) {
      return const CheckinResultFormHashNotFound();
    }

    return _postCheckin(netClient, formHash, feeling, message, askedAt: apiAnswer?['time']);
  });
}

final _formHashRe = RegExp(r'^[0-9a-f]{8}$');

/// The form hash of [netClient]'s session told by the forum's app API, null when it does not tell.
///
/// The `checkin` answer [checkin] may carry it (plugin 1.6.0); `status` does since plugin 1.3.1. `status` answers
/// guests too, with a guest's hash: only the hash of a logged-in session is taken.
Future<String?> _apiFormHash(NetClientProvider netClient, Map<String, dynamic> checkin) async {
  String? hashOf(Map<String, dynamic>? json) => switch (json?['formhash']) {
    final String hash when _formHashRe.hasMatch(hash) => hash,
    _ => null,
  };
  final own = hashOf(checkin);
  if (own != null) {
    return own;
  }
  final status = await TsdmAppApi.ask(netClient, 'status');
  final uid = status?['uid'];
  if (status?['ok'] != 1 || uid is! int || uid <= 0) {
    return null;
  }
  return hashOf(status);
}

/// Post the checkin form with [formHash], [feeling] and [message], the same fields as the web page sends.
///
/// [askedAt] is the forum's clock (`time`) of the `checkin` answer read before the post, when there was one: a
/// checkin recorded at or after it is the one posted ([_checkinStateAfterPost]).
Future<CheckinResult> _postCheckin(
  NetClientProvider netClient,
  String formHash,
  CheckinFeeling feeling,
  String message, {
  Object? askedAt,
}) async {
  final body = <String, String>{
    'formhash': formHash,
    'qdxq': feeling.toString(),
    'qdmode': '1',
    'todaysay': message,
    'fastreply': '1',
  };

  final checkInRespEither = await netClient.postForm(_checkInRequestUrl, data: body).run();
  if (checkInRespEither.isLeft()) {
    return _requestFailed(checkInRespEither.unwrapErr());
  }
  final checkInResp = checkInRespEither.unwrap();
  // The forum's app API (plugin 2.6.0) answers the check-in plugin's float window as a `page` result, the forum's
  // own message (not logged in…) as a `handle` or `message`; an older plugin answers the fragment. Both are read by
  // the same parser.
  final apiResult = tsdmAppWriteResultOf(checkInResp.data);
  if (apiResult != null && apiResult.login) {
    talker.error('check in failed: not logged in (app api)');
    return const CheckinResultNotAuthorized();
  }
  final checkInResult = parseCheckinResponseMessage(checkInResp.data);

  // What the forum's app API says now decides (the check-in plugin's answer has no language key: its float window
  // is a `page`): the words of the answer only tell why when it did not check in. Without the API (an older plugin,
  // no checkin plugin, a failed read) the words decide, as before.
  final askedTime = switch (askedAt) {
    final int n => n,
    final String text => int.tryParse(text),
    _ => null,
  };
  if (await _checkinStateAfterPost(netClient, askedAt: askedTime) case final state?) {
    return _resultByState(state, checkInResult, apiResult, checkInResp.data);
  }

  // Return results.
  if (checkInResult == null) {
    // What the answer says, as text: the forum's fragment as it came, or the message (or the page text) of the app
    // API's result, never the decoded object.
    final text = apiResult == null
        ? tsdmAppAnswerText(checkInResp.data)
        : (apiResult.reason.isNotEmpty ? apiResult.reason : (apiResult.document.body?.text ?? '').trim());
    talker.error('check in result in null: ${text.length} bytes');
    return CheckinResultOtherError(text);
  }

  final r2 = _checkCheckinResultText(checkInResult);
  if (r2 != null) {
    return r2;
  }

  talker.error('check in with other error: $checkInResult');
  return CheckinResultOtherError(checkInResult);
}

/// The checkin state the forum's app API tells right after the checkin form was posted, null when it does not tell
/// ([checkinStateOf]: no plugin, an older one, no checkin plugin, a failed read).
///
/// The plugin takes one call of an action per account every few seconds and `checkin` was just asked before the
/// post: the answer "too soon" is waited for ([TsdmAppApi.askWaiting]). An answer "not logged in" is a state too.
///
/// Checked in is also a checkin recorded (`last_time`) at or after [askedAt], the clock of the answer read before the
/// post: the forum's day may have turned while the answer was waited for (a checkin posted at 23:59:5x). Without that
/// clock only `checked_today` tells (a checkin of another device just before the post is never taken for this one).
Future<({bool checkedToday, bool openNow, bool loggedOut})?> _checkinStateAfterPost(
  NetClientProvider netClient, {
  int? askedAt,
}) async {
  final answer = await TsdmAppApi.askWaiting(netClient, 'checkin');
  if (answer != null && answer['ok'] == 0 && answer['error'] == 'login') {
    return (checkedToday: false, openNow: false, loggedOut: true);
  }
  final lastTime = answer?['last_time'];
  final recorded = lastTime is int && lastTime > 0 && askedAt != null && lastTime >= askedAt;
  return switch (checkinStateOf(answer)) {
    (:final checkedToday, :final openNow) => (
      checkedToday: checkedToday || recorded,
      openNow: openNow,
      loggedOut: false,
    ),
    null => null,
  };
}

/// The result of the checkin posted, decided by [state], the forum's app API read after the post: checked in today
/// is a success, whatever the words of the answer say ([text], the message parsed from it, kept for the user), unless
/// they say it was done already (checked in meanwhile elsewhere); not checked in is never one, the words
/// ([_checkCheckinResultText]) only tell why, and the closed window tells it when they do not.
CheckinResult _resultByState(
  ({bool checkedToday, bool openNow, bool loggedOut}) state,
  String? text,
  TsdmAppWriteResult? apiResult,
  Object? data,
) {
  if (state.loggedOut) {
    talker.error('check in failed: not logged in (app api, after the post)');
    return const CheckinResultNotAuthorized();
  }
  final told = text == null ? null : _checkCheckinResultText(text);
  if (state.checkedToday) {
    if (told is CheckinResultAlreadyChecked) {
      // Checked in meanwhile by another device or the background checkin: done today either way.
      talker.info('check in skipped: checked in today already (app api, after the post)');
      return told;
    }
    talker.info('check in success: checked in today (app api, after the post)');
    return CheckinResultSuccess(text ?? '');
  }
  if (told != null && told is! CheckinResultSuccess && told is! CheckinResultAlreadyChecked) {
    return told;
  }
  if (told is CheckinResultSuccess || told is CheckinResultAlreadyChecked) {
    // The words say checked in, the forum has no checkin of today: the forum's record decides, the words are what
    // there is to show.
    talker.warning('check in: the answer says checked in, the app api has no checkin of today');
  }
  if (!state.openNow) {
    talker.warning('check in not done: checkin is not open now (app api, after the post)');
    return const CheckinResultEarlyInTime();
  }
  final reason =
      text ??
      (apiResult == null
          ? tsdmAppAnswerText(data)
          : (apiResult.reason.isNotEmpty ? apiResult.reason : (apiResult.document.body?.text ?? '').trim()));
  talker.error('check in not done: not checked in today (app api, after the post), ${reason.length} bytes');
  return CheckinResultOtherError(reason);
}

/// The result of a request that did not get a usable answer.
///
/// A 429 is the server rate-limiting us (seen when several accounts checked in at once): it is reported with the
/// `Retry-After` the server gave, if any, so the caller can wait and try again. It is not logged as an error of ours.
CheckinResult _requestFailed(AppException e) {
  if (e case HttpHandshakeFailedException(:final statusCode, :final headers)) {
    if (statusCode == HttpStatus.tooManyRequests) {
      talker.warning('check in rate limited by the server');
      return CheckinResultWebRequestFailed(
        statusCode,
        retryAfterSeconds: int.tryParse(headers?.value('retry-after') ?? ''),
      );
    }
    talker.handle(e);
    return CheckinResultWebRequestFailed(statusCode);
  }
  talker.handle(e);
  return const CheckinResultWebRequestFailed(null);
}

CheckinResult? _checkCheckinResultText(String result) {
  // "您今天已经签到过了或者签到时间还未开始" is all the forum says before 1:00, when checkin is not open yet. Read as
  // "already checked in" it was recorded as today's checkin: the app showed it checked in, never tried again, and the
  // website had no checkin. Only "not open yet" is safe: an account that did check in is then simply tried again.
  // When the page says it checked in, the service desk box above has already answered.
  if (result.contains('签到时间还未开始') || result.contains('签到时间还没有到')) {
    talker.warning('check in not done: checkin is not open yet (or already done): $result');
    return const CheckinResultEarlyInTime();
  }
  if (result.contains('签到成功')) {
    talker.info('check in success: $result');
    return CheckinResultSuccess(result);
  }
  if (result.contains('已经签到')) {
    talker.error('check in failed: already checked in today');
    return const CheckinResultAlreadyChecked();
  }
  if (result.contains('需要先登录')) {
    talker.error('check in failed: not logged in');
    return const CheckinResultNotAuthorized();
  }
  if (result.contains('已经过了签到时间')) {
    talker.error('check in failed: late in time');
    return const CheckinResultLateInTime();
  }
  return null;
}
