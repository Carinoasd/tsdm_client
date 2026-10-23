import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:dio/dio.dart' show Response;
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/extensions/universal_html.dart';
import 'package:tsdm_client/features/rate/models/models.dart';
import 'package:tsdm_client/features/tsdmapp/small_form.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Extension on [String] that provides filling rate url methods.
extension _FillRateTarget on String {
  /// Some query parameters not exists in incoming rateTarget.
  String _fillRateTarget() {
    return '$this&infloat=yes&handlekey=rate&t='
        '${DateTime.now().millisecondsSinceEpoch}&'
        'inajax=1&ajaxtarget=fwin_content_rate';
  }
}

/// Repository of rate.
final class RateRepository with LoggerMixin {
  /// Constructor; [currentUid] tells the account a window is asked for (the logged in account by default).
  RateRepository({int Function()? currentUid}) : _currentUid = currentUid ?? currentLoginUid;

  final int Function() _currentUid;

  static const _rateTarget = '$baseUrl/forum.php?mod=misc&action=rate&ratesubmit=yes&infloat=yes&inajax=1';

  /// Regexp to grep the error text from response html body.
  static final _errorTextRe = RegExp('alert_error">(?<error>[^<]+)<');

  /// The error handler call in the answer to a rate the forum refused.
  ///
  /// Discuz! X5 answers a rate refused on submit (not enough points to rate, over the 24 hour limit, wrong score...)
  /// with the message followed by the call, the message quoted with `\'` escaped:
  ///
  /// `抱歉，您的天使币不足，无法评分<script ...>if(typeof errorhandle_rate=='function') {errorhandle_rate('抱歉，您的天使币不足，无法评分', {'extcreditstitle':'天使币'});}</script>`
  static final _errorHandleRateRe = RegExp(r"{errorhandle_rate\('(?<error>(?:[^'\\]|\\.)+)',");

  String _buildRateLogTarget({required String tid, required String pid}) =>
      '$baseUrl/forum.php?mod=misc&action=viewratings&tid=$tid&pid=$pid'
      '&infloat=yes&handlekey=viewratings&inajax=1&ajaxtarget=fwin_content_viewratings';

  List<RateLogItem> _buildRateLogItemListFromDocument(uh.Document doc) => doc
      .querySelectorAll('table.list > tbody > tr')
      .map((tr) {
        final tds = tr.querySelectorAll('td');
        if (tds.length != 4) {
          return null;
        }

        final attrRaw = tds.first.innerText.trim().split(' ');
        if (attrRaw.length != 2) {
          return null;
        }
        final attrName = attrRaw.first;
        final attrValue = int.tryParse(attrRaw.last);
        final userNode = tds[1].querySelector('a');
        final username = userNode?.innerText.trim();
        final uid = userNode?.attributes['href']?.tryParseAsUri()?.queryParameters['uid'];
        final time = tds[2].dateTime();
        final reason = tds[3].innerText.trim();

        if (attrValue == null || username == null || uid == null || time == null) {
          warning('incomplete rate log item: attrValue=$attrValue, username=$username, uid=$uid, time=$time');
          return null;
        }

        return RateLogItem(
          attrName: attrName,
          attrValue: attrValue,
          username: username,
          uid: uid,
          time: time,
          reason: reason,
        );
      })
      .whereType<RateLogItem>()
      .toList();

  /// Fetch rate info for given [pid].
  ///
  /// The window is asked as a small form of the forum's app API ([withTsdmAppForm], plugin 3.0.0): the form as
  /// structured fields ([RateWindowInfo.fromApi]: the ranges, today's remaining, the choices, the form as served), or
  /// the forum's message instead of it (no permission, rated already, the login prompt), its text as the forum wrote
  /// it. Either must be served to the account that asked (`currentUid` of the constructor): another account's, or a guest's, is a
  /// failure. An older plugin does not know [tsdmAppFormQuery] and answers the window as its write result (plugin
  /// 2.6.0, [tsdmAppWriteResultOf]): a `page` result carries the form in its document, a refusal (not allowed to
  /// rate…) is the error hook, a `handle` with the forum's message. Without the plugin the AJAX fragment is parsed,
  /// as before. A form the plugin could not tell (`unknown`), or one with fields the app does not know, is asked
  /// again the way it always was.
  AsyncEither<RateWindowInfo> fetchInfo({required String pid, required String rateTarget}) => AsyncEither(() async {
    final url = rateTarget._fillRateTarget();
    final uid = _currentUid();
    final Response<dynamic> resp;
    switch (await getIt.get<NetClientProvider>().get(withTsdmAppForm(url)).run()) {
      case Left(:final value):
        return left(value);
      case Right(:final value) when value.statusCode != HttpStatus.ok:
        return left(HttpRequestFailedException(value.statusCode));
      case Right(:final value):
        resp = value;
    }
    switch (smallFormAnswerOf(resp.data, SmallFormKind.rate)) {
      case final SmallFormAnswer answer when answer.identityProblem(uid) != null:
        return left(RateInfoWithErrorException(answer.identityProblem(uid)!));
      case final SmallFormMessage message:
        return left(
          RateInfoWithErrorException(message.reason.isNotEmpty ? message.reason : t.ratePostPage.failedToRate),
        );
      case final SmallFormFields form:
        if (form.usable) {
          if (RateWindowInfo.fromApi(form) case final info?) {
            debug('got rate form of the app api');
            return right(info);
          }
        }
        return _fetchInfoAsBefore(url);
      case null when isSmallFormUnknown(resp.data):
        return _fetchInfoAsBefore(url);
      case null:
        return _parseInfo(resp.data);
    }
  });

  /// The window [url] asked as before plugin 3.0.0 (the write result of plugin 2.6.0, or the AJAX fragment) and
  /// parsed from its document.
  Future<Either<AppException, RateWindowInfo>> _fetchInfoAsBefore(String url) async => switch (await getIt
      .get<NetClientProvider>()
      .get(withTsdmAppJsonWrite(url))
      .run()) {
    Left(:final value) => left(value),
    Right(:final value) when value.statusCode != HttpStatus.ok => left(HttpRequestFailedException(value.statusCode)),
    Right(:final value) => _parseInfo(value.data),
  };

  /// The window in the answer [data] of an older plugin (its write result) or of the forum (the AJAX fragment).
  Either<AppException, RateWindowInfo> _parseInfo(Object? data) {
    final result = tsdmAppWriteResultOf(data);
    final uh.Element? divCNode;
    if (result != null) {
      if (result.kind != TsdmAppWriteKind.page) {
        return left(
          result.reason.isNotEmpty ? RateInfoWithErrorException(result.reason) : RateInfoInvalidDivCNode(),
        );
      }
      divCNode = result.document.body;
    } else {
      final xmlDoc = parseXmlDocument(tsdmAppAnswerText(data));
      final htmlBodyData = xmlDoc.documentElement?.nodes.firstOrNull?.text;
      if (htmlBodyData == null) {
        return left(RateInfoHtmlBodyNotFound());
      }
      divCNode = parseHtmlDocument(htmlBodyData).body;
    }
    if (divCNode == null) {
      return left(RateInfoDivCNodeNotFound());
    }
    final rateWindowInfo = RateWindowInfo.fromDivCNode(divCNode);
    if (rateWindowInfo == null) {
      final errorText = divCNode.querySelector('div.alert_error')?.childNodes[0].text;
      if (errorText != null) {
        return left(RateInfoWithErrorException(errorText));
      }
      return left(RateInfoInvalidDivCNode());
    }
    debug('got rate form hash');
    return right(rateWindowInfo);
  }

  /// Rate with given info [formData], posted to [target] (`submit.url` of a window of the forum's app API, plugin
  /// 3.0.0, posted with `inajax=1` as the website does) or, for a window parsed from the web page, to the fixed rate
  /// url.
  ///
  /// The forum's app API (plugin 2.6.0) answers the result as JSON ([tsdmAppWriteResultOf]): the success hook
  /// (`thread_rate_succeed`) is a success, the error hook (`thread_rate_duplicate`, not enough points…), a refusal
  /// page or the login prompt fail with the forum's message ([TsdmAppWriteResult.reason]; without one the rate page
  /// says what it says for a refusal without a reason). A `page` is read as the forum's fragment would be. An older
  /// plugin answers the AJAX fragment, read as before.
  ///
  /// Sent once, never retried by the transport: the forum takes a second rate of the same post by the same account
  /// (and, for a group whose rates come off the rater's own credits, takes them twice).
  AsyncVoidEither rate(Map<String, String> formData, {String? target}) => AsyncVoidEither(() async {
    final url = target == null ? _rateTarget : withSmallFormInAjax(target);
    final respEither = await getIt.get<NetClientProvider>().postForm(url, data: formData, singleAttempt: true).run();
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }
    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(resp.statusCode));
    }

    if (tsdmAppWriteResultOf(resp.data) case final result?) {
      if (result.kind == TsdmAppWriteKind.page && result.ok) {
        return _rateResultOf(result.documentHtml);
      }
      if (result.kind != TsdmAppWriteKind.page && result.succeeded) {
        return rightVoid();
      }
      return left(RateFailedException(result.reason));
    }
    return _rateResultOf(tsdmAppAnswerText(resp.data));
  });

  /// The rate result of the forum's AJAX answer (or the fragment of a `page` result) [data]: the refusal in an
  /// `alert_error` box or in the error hook, a success otherwise.
  Either<AppException, void> _rateResultOf(String data) {
    final errorText = _errorTextRe.firstMatch(data)?.namedGroup('error');
    if (errorText != null) {
      return left(RateFailedException(errorText));
    }
    final errorHandleRateText = _errorHandleRateRe.firstMatch(data)?.namedGroup('error');
    if (errorHandleRateText != null) {
      return left(RateFailedException(errorHandleRateText.replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!)));
    }
    return rightVoid();
  }

  /// Fetch all rate log for post specified by [pid] and [tid].
  AsyncEither<List<RateLogItem>> fetchRateLog({required String tid, required String pid}) => getIt
      .get<NetClientProvider>()
      .get(_buildRateLogTarget(tid: tid, pid: pid))
      .mapHttp((v) => v.data as String)
      .map((e) => parseXmlDocument(e).documentElement?.nodes.first.text ?? '')
      .map(parseHtmlDocument)
      .map(_buildRateLogItemListFromDocument);
}
