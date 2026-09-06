import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/checkin/models/models.dart';
import 'package:tsdm_client/features/checkin/utils/parse_checkin.dart';
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
    final checkInRespData = checkInResp.data as String;
    final checkInResult = parseCheckinResponseMessage(checkInRespData);

    // Return results.
    if (checkInResult == null) {
      talker.error('check in result in null: ${checkInRespData.length} bytes');
      return CheckinResultOtherError(checkInRespData);
    }

    final r2 = _checkCheckinResultText(checkInResult);
    if (r2 != null) {
      return r2;
    }

    talker.error('check in with other error: $checkInResult');
    return CheckinResultOtherError(checkInResult);
  });
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
  if (result.contains('签到时间还没有到') || result.contains('签到时间还未开始')) {
    talker.error('check in failed: early in time');
    return const CheckinResultEarlyInTime();
  }
  return null;
}
