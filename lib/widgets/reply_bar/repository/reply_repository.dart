import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/parsing.dart';

/// Repository of reply.
final class ReplyRepository with LoggerMixin {
  /// Constructor.
  const ReplyRepository();

  /// Regexp to grep pmid wrapped in chat message send response.
  ///
  /// {'pmid':'${PMID}'}.
  // static final _messagePmidRe = RegExp(r"'pmid':'(?<pmid>\d+)'");

  /// Regexp to grep error message in chat message send response.
  ///
  /// errorhandle_pmsend('${ERR}', {});
  static final _messageErrorRe = RegExp(r"\('(?<err>.+)', \{\}\);\}");

  /// Reply to a post.
  AsyncVoidEither replyToPost({
    required ReplyParameters replyParameters,
    required String replyAction,
    required String replyMessage,
  }) => AsyncVoidEither(() async {
    final netClient = getIt.get<NetClientProvider>();
    final replyWindowUrl = '${replyAction.prependHost()}$replyPostWindowSuffix';
    final respEither = await netClient.get(replyWindowUrl).run();
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }

    final replyWindowResp = respEither.unwrap();
    if (replyWindowResp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(replyWindowResp.statusCode));
    }

    // The response is an ajax xml document with the html form wrapped in CDATA.
    //
    // Expected hidden inputs in the form:
    //
    // * formhash
    // * handlekey
    // * noticeauthor
    // * noticetrimstr
    // * noticeauthormsg
    // * usesig
    // * reppid
    // * reppost
    //
    // Note that `replyuid` is NOT in the form on Discuz X5, it is only a query parameter in the reply action url.
    final rawData = replyWindowResp.data as String;
    String? htmlData;
    try {
      htmlData = parseXmlDocument(rawData).documentElement?.nodes.firstOrNull?.text;
    } on Exception catch (_) {
      htmlData = null;
    }
    final replyWindowDoc = parseHtmlDocument(htmlData ?? rawData);
    String? inputValue(String name) => replyWindowDoc.querySelector('input[name="$name"]')?.attributes['value'];
    final formHash = inputValue('formhash');
    final handleKey = inputValue('handlekey');
    final noticeAuthor = inputValue('noticeauthor');
    final noticeTrimStr = inputValue('noticetrimstr');
    final noticeAuthorMsg = inputValue('noticeauthormsg');
    final replyUid = inputValue('replyuid') ?? replyAction.tryParseAsUri()?.queryParameters['replyuid'];
    final repPid = inputValue('reppid');
    final repPost = inputValue('reppost');
    final useSig = inputValue('usesig');
    final subject = inputValue('subject');
    if (formHash == null || handleKey == null || repPid == null || repPost == null) {
      final errorText = replyWindowDoc.querySelector('div.alert_error')?.innerText.trim();
      error(
        'failed to fetch reply to post parameters: formHash=$formHash, '
        'handleKey=$handleKey, noticeAuthor=$noticeAuthor, error=$errorText',
      );
      error(
        'failed to fetch reply to post parameters: '
        'noticeAuthorMsg=$noticeAuthorMsg, replyuid=$replyUid, '
        'reppid=$repPid, reppost=$repPost',
      );
      return left(ReplyToPostFetchParameterFailedException());
    }

    final formData = <String, String>{
      'formhash': formHash,
      'handlekey': handleKey,
      'noticeauthor': ?noticeAuthor,
      'noticetrimstr': ?noticeTrimStr,
      'noticeauthormsg': ?noticeAuthorMsg,
      'replyuid': ?replyUid,
      'reppid': repPid,
      'reppost': repPost,
      'usesig': useSig ?? '1',
      // TODO: Build subject instead of const empty string.
      'subject': subject ?? '',
      // TODO: Support reply with rich text.
      'message': replyMessage,
    };

    final respEither2 = await netClient
        .postForm(formatReplyPostUrl(replyParameters.fid, replyParameters.tid), data: formData)
        .run();

    if (respEither2.isLeft()) {
      return left(respEither2.unwrapErr());
    }

    final resp2 = respEither2.unwrap();
    if (!(resp2.data as String).contains('回复发布成功')) {
      return left(ReplyToPostResultFailedException());
    }

    return rightVoid();
  });

  /// Post reply to thread tid/fid.
  /// This will add a post in thread, as reply to that thread.
  ///
  /// # Exception
  ///
  /// * **HttpRequestFailedException** when http request failed.
  /// * **ReplyToThreadResultFailedException** when reply finished but no
  /// successful result found in response.
  Future<void> replyToThread({required ReplyParameters replyParameters, required String replyMessage}) async {
    final formData = <String, String>{
      'message': replyMessage,
      'usesig': '1',
      'formhash': replyParameters.formHash,
      'subject': replyParameters.subject,
    };
    // Only apply post time when not null.
    if (replyParameters.postTime != null) {
      formData['posttime'] = replyParameters.postTime.toString();
    }
    final e = await getIt
        .get<NetClientProvider>()
        .postForm(formatReplyThreadUrl(replyParameters.fid, replyParameters.tid), data: formData)
        .run();
    if (e.isLeft()) {
      handle(e.unwrapErr());
    }

    final resp = e.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      throw HttpRequestFailedException(resp.statusCode);
    }
    if (!(resp.data as String).contains('回复发布成功')) {
      throw ReplyToThreadResultFailedException();
    }
  }

  /// Reply personalMessage in history page.
  AsyncVoidEither replyHistoryPersonalMessage({
    required String targetUrl,
    required String formHash,
    required String message,
  }) => AsyncVoidEither(() async {
    final formData = <String, String>{'message': message, 'formhash': formHash};

    final e = await getIt.get<NetClientProvider>().postForm(targetUrl, data: formData).run();
    if (e.isLeft()) {
      return left(e.unwrapErr());
    }
    final resp = e.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      throw HttpRequestFailedException(resp.statusCode);
    }

    final data = resp.data as String;

    if (data.contains('succeedhandle_pmsend')) {
      // Success.
      // return _messagePmidRe.firstMatch(data)?.namedGroup('pmid');
      return rightVoid();
    }
    if (data.contains('errorhandle_pmsend')) {
      final errorMessage = _messageErrorRe.firstMatch(data)?.namedGroup('err');
      return left(ReplyPersonalMessageFailedException(errorMessage ?? 'unknown error'));
    }
    return rightVoid();
  });

  /// Reply a personal message, use as we are chatting though the chat dialog
  /// when we in browser, this means in chat page, not chat history page.
  ///
  /// # Exception
  ///
  /// * **HttpRequestFailedException** when http request failed.
  /// * **ReplyPersonalMessageFailedException** when reply failed.
  ///
  /// # Return
  ///
  /// Return the pmid if send message succeed which is used to show the new
  /// generated message.
  AsyncVoidEither replyPersonalMessage(String touid, Map<String, String> formData) => AsyncVoidEither(() async {
    final e = await getIt.get<NetClientProvider>().postForm(formatSendMessageUrl(touid), data: formData).run();
    if (e.isLeft()) {
      return left(e.unwrapErr());
    }

    final resp = e.unwrap();

    if (resp.statusCode != HttpStatus.ok) {
      throw HttpRequestFailedException(resp.statusCode);
    }

    final data = resp.data as String;

    if (data.contains('succeedhandle_pmsend')) {
      // Success.
      // return _messagePmidRe.firstMatch(data)?.namedGroup('pmid');
      return rightVoid();
    }
    if (data.contains('errorhandle_showmsg_$touid')) {
      final errorMessage = _messageErrorRe.firstMatch(data)?.namedGroup('err');
      return left(ReplyPersonalMessageFailedException(errorMessage ?? 'unknown error'));
    }

    return rightVoid();
  });
}
