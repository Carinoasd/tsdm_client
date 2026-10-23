import 'dart:io' if (dart.libaray.js) 'package:web/web.dart';

import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/editor/utils/mention.dart';
import 'package:tsdm_client/features/notification/utils/personal_message_sent.dart';
import 'package:tsdm_client/features/post/models/post_form.dart';
import 'package:tsdm_client/features/post/utils/post_limits.dart';
import 'package:tsdm_client/features/post/utils/verification.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;
import 'package:universal_html/parsing.dart';

/// Where a stored reply landed: the id of the new post and the page it is on (server default order), when the
/// server told them in the success hook.
typedef PostedReply = ({String? pid, int? page});

/// The reply window asked as the post form of the forum's app API (plugin 2.9.0): the forum's own window
/// ([replyPostWindowSuffix]) without `inajax` and its target, which give the AJAX fragment instead.
const _replyFormWindowSuffix = '&infloat=yes&handlekey=reply';

/// What the reply window of a thread or a floor tells before anything is written ([ReplyRepository.fetchReplyFormInfo]):
/// the size limits of the message (plugin 2.9.0 only), the checks the forum asks for and the quote of the floor.
final class ReplyFormInfo {
  /// Constructor.
  const ReplyFormInfo({this.limits, this.secCheck, this.quote});

  /// The forum's size limits of the message, null when the window does not tell them (the forum's own window).
  final MessageLimits? limits;

  /// What the forum asks before taking the reply, null when nothing.
  final SecCheck? secCheck;

  /// The quote of the floor the forum puts in front of the reply (`noticetrimstr`, BBCode), null without one.
  final String? quote;
}

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

  /// `succeedhandle_<handlekey>('<url>', '<message>', {...})`.
  ///
  /// Emitted by Discuz! `showmessage()` only when the reply was stored (a forward url exists), for both the plain
  /// success message and the "needs moderation" one, so it is a more reliable marker than one language string.
  static final _succeedHandleRe = RegExp(r"succeedhandle_\w*\('((?:[^'\\]|\\.)*)',\s*'((?:[^'\\]|\\.)*)'");

  /// `errorhandle_<handlekey>('<message>', {...})` carries the rejection reason.
  static final _errorHandleRe = RegExp(r"errorhandle_\w*\('((?:[^'\\]|\\.)*)'");

  /// Whether the reply response says the reply was stored.
  static bool _isReplyStored(String data) =>
      _succeedHandleRe.hasMatch(data) || data.contains('回复发布成功') || data.contains('回复需要审核');

  /// The message inside the success hook, if any.
  static String? _storedMessage(String data) => _succeedHandleRe.firstMatch(data)?.group(2)?.replaceAll(r"\'", "'");

  /// Where a stored reply landed, from the forward url inside the success hook
  /// (`forum.php?mod=viewthread&tid=…&pid=<new post>&page=<page>…`). Parts the server did not tell are null.
  static PostedReply postedReplyOf(String data) => postedReplyOfUrl(_succeedHandleRe.firstMatch(data)?.group(1) ?? '');

  /// Where a stored reply landed, from the forward [url] the forum goes on to (the success hook's, or the `url` of
  /// the app API's result). Parts the url does not tell are null.
  static PostedReply postedReplyOfUrl(String url) => (
    pid: RegExp(r'[?&]pid=(\d+)').firstMatch(url)?.group(1),
    page: int.tryParse(RegExp(r'[?&]page=(\d+)').firstMatch(url)?.group(1) ?? ''),
  );

  /// The reply result of the forum's app API (plugin 2.6.0, [tsdmAppWriteResultOf]) in the answer [data], null when
  /// the forum answered itself.
  ///
  /// Stored when the forum called the success hook (`handle`, `post_reply_succeed` or the "needs moderation" one),
  /// went on to the thread (`redirect`, a form the forum did not take as AJAX) or printed the success page
  /// (`message` with `alert_right`), as [_isReplyStored] tells from the forum's own answer; anything else (the
  /// error hook, a refusal page, the login prompt, a page) is rejected with the forum's message, or the text of the
  /// page when the result carries no message. A refusal for a missing captcha or security question
  /// ([TsdmAppWriteResult.asksVerification]) is told apart (`verification`): the reply needs the website.
  static ({bool stored, String? reason, String url, ({bool seccode, bool secqaa})? verification})? _replyResultOf(
    Object? data,
  ) {
    final result = tsdmAppWriteResultOf(data);
    if (result == null) {
      return null;
    }
    if (result.asksVerification) {
      // A site asking for a captcha by the number of posts or their interval decides it when the reply is posted.
      return (
        stored: false,
        reason: result.reason,
        url: result.url,
        verification: refusedVerification(messageKey: result.messageKey, reason: result.reason),
      );
    }
    final stored = switch (result.kind) {
      TsdmAppWriteKind.handle || TsdmAppWriteKind.redirect => result.succeeded,
      TsdmAppWriteKind.message =>
        result.succeeded &&
            (result.alert == 'right' || result.message.contains('回复发布成功') || result.message.contains('回复需要审核')),
      TsdmAppWriteKind.page => false,
    };
    final reason = result.reason.isNotEmpty ? result.reason : _serverMessage(result.html);
    return (
      stored: stored,
      reason: stored ? null : reason,
      url: result.url,
      verification: stored ? null : refusedVerification(messageKey: result.messageKey, reason: reason),
    );
  }

  /// Human readable reason from a Discuz! inajax `showmessage()` response, if any.
  static String? _serverMessage(String data) {
    final fromHandle = _errorHandleRe.firstMatch(data)?.group(1);
    if (fromHandle != null && fromHandle.isNotEmpty) {
      return fromHandle.replaceAll(r"\'", "'");
    }
    String? htmlData;
    try {
      htmlData = parseXmlDocument(data).documentElement?.nodes.firstOrNull?.text;
    } on Object catch (_) {
      // Not the AJAX fragment: a whole page (the xml parser throws a state error on one, not an exception).
      htmlData = null;
    }
    final doc = parseHtmlDocument(htmlData ?? data);
    doc.querySelectorAll('script').forEach((e) => e.remove());
    final text = (doc.querySelector('div.alert_error') ?? doc.querySelector('div#messagetext'))?.innerText.trim();
    return (text == null || text.isEmpty) ? null : text;
  }

  /// Reply to a post.
  ///
  /// [stand] is the side the reply takes in a debate (0 neutral, 1 affirmative, 2 negative), sent as the reply
  /// window's `stand` select; none for any other thread.
  ///
  /// When the forum's plugin is known to answer the post forms (plugin 2.9.0, [TsdmAppApi.knowsPostForm]) the reply
  /// window is asked as its post form first ([_replyToPostWithForm]); a window that does not come back as one, and
  /// every window of a forum not known to, is asked and read the way it always was.
  ///
  /// A window asking for a captcha or a security question is posted only with [verification] answering them: without,
  /// [ReplyNeedsVerificationException] with what it asks (the user answers, the reply goes again); a window asking
  /// without telling the ids is [ReplyNeedsBrowserException], with the reply page to continue on in the browser.
  AsyncEither<PostedReply> replyToPost({
    required ReplyParameters replyParameters,
    required String replyAction,
    required String replyMessage,
    int? stand,
    SecCheckAnswer? verification,
  }) => AsyncEither(() async {
    final netClient = getIt.get<NetClientProvider>();
    if (TsdmAppApi.knowsPostForm) {
      final structured = await _replyToPostWithForm(
        netClient,
        replyParameters: replyParameters,
        replyAction: replyAction,
        replyMessage: replyMessage,
        stand: stand,
        verification: verification,
      );
      if (structured != null) {
        return structured;
      }
    }
    final replyWindowUrl = withTsdmAppJsonWrite('${replyAction.prependHost()}$replyPostWindowSuffix');
    final respEither = await netClient.get(replyWindowUrl).run();
    if (respEither.isLeft()) {
      // Only the window was asked: nothing posted.
      return left(ReplyWindowFetchFailedException.of(respEither.unwrapErr()));
    }

    final replyWindowResp = respEither.unwrap();
    if (replyWindowResp.statusCode != HttpStatus.ok) {
      return left(ReplyWindowFetchFailedException(noNetwork: false, statusCode: replyWindowResp.statusCode));
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
    // The forum's app API (plugin 2.6.0) answers the window as a `page` result with the form in its document; the
    // forum refuses in the window (not logged in…) with the error hook, which has no form either.
    final windowResult = tsdmAppWriteResultOf(replyWindowResp.data);
    final replyWindowDoc = _windowDocumentOf(replyWindowResp.data);
    final browserUrl = replyAction.prependHost();
    SecCheck? asked;
    if (documentAsksVerification(replyWindowDoc)) {
      // The forum asks for a captcha or a security question: never post without the answers.
      asked = _windowSecCheck(replyWindowDoc);
      if (asked == null) {
        error('reply window asks for a captcha or a security question it names no id of');
        return left(ReplyNeedsBrowserException(url: browserUrl, verification: true));
      }
      if (verification == null || !verification.covers(asked)) {
        info('reply window asks for a captcha or a security question');
        return left(ReplyNeedsVerificationException(check: verification?.check.merge(asked) ?? asked, url: browserUrl));
      }
    }
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
      final errorText = windowResult != null && windowResult.reason.isNotEmpty
          ? windowResult.reason
          : replyWindowDoc.querySelector('div.alert_error')?.innerText.trim();
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
      'message': toOfficialMentions(replyMessage),
      'stand': ?stand?.toString(),
      ...?verification?.fields,
    };

    // Posted once: a transport retry would post the reply twice.
    final respEither2 = await netClient
        .postForm(formatReplyPostUrl(replyParameters.fid, replyParameters.tid), data: formData, singleAttempt: true)
        .run();
    return _postedReplyOf(respEither2, browserUrl: browserUrl, verification: verification, asked: asked);
  });

  /// The document of the reply window answer [data]: the form inside the forum's AJAX fragment, or the document of the
  /// write result of the forum's app API (plugin 2.6.0).
  static uh.Document _windowDocumentOf(Object? data) {
    final windowResult = tsdmAppWriteResultOf(data);
    final rawData = windowResult?.html ?? tsdmAppAnswerText(data);
    String? htmlData;
    if (windowResult == null) {
      try {
        htmlData = parseXmlDocument(rawData).documentElement?.nodes.firstOrNull?.text;
      } on Object catch (_) {
        htmlData = null;
      }
    }
    return windowResult?.document ?? parseHtmlDocument(htmlData ?? rawData);
  }

  /// What the forum's reply window [document] asks for, with the ids of its placeholders; null when it names none.
  static SecCheck? _windowSecCheck(uh.Document document) =>
      SecCheck.fromElement(document.querySelector('form#postform') ?? document.documentElement);

  /// Where the reply posted from the reply window landed, from the answer [respEither] of the post: the result of the
  /// forum's app API ([_replyResultOf]) or the forum's own answer, the forum's reason when it refused; a refusal for a
  /// missing (or wrong) captcha or security question is [ReplyNeedsVerificationException] with what to answer: the
  /// checks of [verification] and those the window [asked], with the refused one.
  Either<AppException, PostedReply> _postedReplyOf(
    Either<AppException, Response<dynamic>> respEither, {
    required String browserUrl,
    SecCheckAnswer? verification,
    SecCheck? asked,
  }) {
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }

    final resp2 = respEither.unwrap();
    if (_replyResultOf(resp2.data) case final result?) {
      if (result.verification case final refused?) {
        error('reply to post refused for a captcha or a security question');
        return left(
          ReplyNeedsVerificationException(
            check: refusedCheck(refused, answered: verification?.check, told: asked),
            url: browserUrl,
            wrongAnswer: verification != null,
          ),
        );
      }
      if (!result.stored) {
        error('reply to post rejected by server: ${result.reason}');
        return left(ReplyToPostResultFailedException(result.reason));
      }
      info('reply to post stored (app api)');
      return right(postedReplyOfUrl(result.url));
    }
    final data2 = tsdmAppAnswerText(resp2.data);
    if (!_isReplyStored(data2)) {
      final reason = _serverMessage(data2);
      if (refusedVerification(reason: reason) case final refused?) {
        error('reply to post refused for a captcha or a security question');
        return left(
          ReplyNeedsVerificationException(
            check: refusedCheck(refused, answered: verification?.check, told: asked),
            url: browserUrl,
            wrongAnswer: verification != null,
          ),
        );
      }
      error('reply to post rejected by server: $reason');
      return left(ReplyToPostResultFailedException(reason));
    }
    info('reply to post stored: ${_storedMessage(data2)?.length ?? 0} chars');

    return right(postedReplyOf(data2));
  }

  /// Reply to a floor through the reply window asked as the post form of the forum's app API (plugin 2.9.0,
  /// `type: post`, `schema` 16; asked without `inajax`, which gives the forum's own fragment): the form's hidden fields
  /// as served (`submit.fields`: the form hash, the encrypted `noticeauthor`, the quote in `noticetrimstr`, which the
  /// forum puts in front of the message, the window's `handlekey`…) and every other control, with the message and the
  /// debate side, posted once to the url the form names (`submit.url`) with `inajax=1`, as the website posts the window.
  /// The window is asked for every reply: its values hold for one request only.
  ///
  /// Null when the window did not come back as such a form (a forum without the plugin, an older one): the caller asks
  /// the window the way it always did. A window served to another account than the one replying (the account the
  /// thread page was served to, [ReplyParameters.viewerUid], and the one of the global cookie) or to a guest, and the
  /// forum's message instead of the window, are [ReplyToPostFetchParameterFailedException] (with the message); a window
  /// asking for a captcha or a security question ([PostForm.secCheck]) is posted with [verification] answering it, else
  /// [ReplyNeedsVerificationException] (or [ReplyNeedsBrowserException] when it names no ids); a window with fields the
  /// app cannot fill (another plugin's, another editor: [PostForm.editorSupport]) is [ReplyNeedsBrowserException]:
  /// nothing is sent.
  Future<Either<AppException, PostedReply>?> _replyToPostWithForm(
    NetClientProvider netClient, {
    required ReplyParameters replyParameters,
    required String replyAction,
    required String replyMessage,
    int? stand,
    SecCheckAnswer? verification,
  }) async {
    final respEither = await netClient
        .get(withTsdmAppJson('${replyAction.prependHost()}$_replyFormWindowSuffix'))
        .run();
    final Response<dynamic> resp;
    switch (respEither) {
      case Left(:final value):
        // Only the window was asked: nothing posted.
        return left(ReplyWindowFetchFailedException.of(value));
      case Right(:final value):
        resp = value;
    }
    if (resp.statusCode != HttpStatus.ok) {
      return left(ReplyWindowFetchFailedException(noNetwork: false, statusCode: resp.statusCode));
    }
    final json = postFormAnswerOf(resp.data);
    if (json == null) {
      info("reply window is no post form, asking the forum's window");
      return null;
    }
    // The account replying: the one the thread page was served to, and the one of the global cookie the request
    // carried. A window served to another account (or to a guest) is not posted.
    final owner = getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>().userLoginInfo.uid : null;
    final served = tsdmAppInt(json['uid']);
    final form = PostForm.fromJson(json);
    if (served <= 0 ||
        (owner != null && owner != served) ||
        (replyParameters.viewerUid != null && replyParameters.viewerUid != served) ||
        form == null) {
      final message = tsdmAppText(json['message']);
      final who = served <= 0 ? 'a guest' : (form == null ? 'the forum message' : 'another account');
      error('reply window refused ($who): $message');
      return left(ReplyToPostFetchParameterFailedException(message.isEmpty ? null : message));
    }
    TsdmAppApi.notePostForm();
    final browserUrl = replyAction.prependHost();
    switch (form.editorSupport('reply')) {
      case PostFormSupport.verification:
        error('reply window asks for a captcha or a security question it names no id of');
        return left(ReplyNeedsBrowserException(url: browserUrl, verification: true));
      case PostFormSupport.unsupported:
        error('reply window not supported: ${form.unsupported} ${form.hookFields}');
        return left(ReplyNeedsBrowserException(url: browserUrl, verification: false));
      case PostFormSupport.supported:
        break;
    }
    final asked = form.secCheck;
    if (asked != null && (verification == null || !verification.covers(asked))) {
      info('reply window asks for a captcha or a security question');
      return left(ReplyNeedsVerificationException(check: verification?.check.merge(asked) ?? asked, url: browserUrl));
    }
    final body = form.bodyWith(PostFormEdits(message: toOfficialMentions(replyMessage)));
    if (stand != null) {
      body.set('stand', '$stand');
    }
    for (final MapEntry(:key, :value) in (verification?.fields ?? const <String, String>{}).entries) {
      body.set(key, value);
    }
    final data = body.toMap();
    final url = form.submitUrl;
    if (data == null || url == null) {
      return left(ReplyNeedsBrowserException(url: browserUrl, verification: false));
    }
    // Posted once: a transport retry would post the reply twice.
    final respEither2 = await netClient.postForm('$url&inajax=1', data: data, singleAttempt: true).run();
    return _postedReplyOf(respEither2, browserUrl: browserUrl, verification: verification, asked: asked);
  }

  /// What the reply window of [replyAction] (the reply link of a floor, or the reply page of a thread) tells before a
  /// reply is written: the message's size limits, the checks the forum asks for and the quote of the floor.
  ///
  /// Asked as the post form of the forum's app API when the plugin is known to answer it (plugin 2.9.0, the limits are
  /// only known then), else as the forum's own window. Only a GET: nothing is posted, and the reply still asks the
  /// window again when it is sent. Null when the window could not be read (offline, the forum's message instead).
  Future<ReplyFormInfo?> fetchReplyFormInfo(String replyAction) async {
    try {
      return await _fetchReplyFormInfo(replyAction);
    } on Object catch (e, st) {
      // Only a hint for the editor: the reply asks the window again when it is sent.
      warning('failed to read the reply window: $e');
      handleRaw(e, st);
      return null;
    }
  }

  Future<ReplyFormInfo?> _fetchReplyFormInfo(String replyAction) async {
    final netClient = getIt.get<NetClientProvider>();
    if (TsdmAppApi.knowsPostForm) {
      final resp = await netClient.get(withTsdmAppJson('${replyAction.prependHost()}$_replyFormWindowSuffix')).run();
      switch (resp) {
        case Left():
          return null;
        case Right(:final value):
          if (value.statusCode != HttpStatus.ok) {
            return null;
          }
          if (postFormAnswerOf(value.data) case final json?) {
            final form = PostForm.fromJson(json);
            if (form == null) {
              // The forum's message instead of the window.
              return null;
            }
            TsdmAppApi.notePostForm();
            final quote = form.submitFields['noticetrimstr'];
            return ReplyFormInfo(
              limits: MessageLimits.of(form),
              secCheck: form.secCheck,
              quote: quote == null || quote.trim().isEmpty ? null : quote,
            );
          }
      }
    }
    final resp = await netClient.get(withTsdmAppJsonWrite('${replyAction.prependHost()}$replyPostWindowSuffix')).run();
    switch (resp) {
      case Left():
        return null;
      case Right(:final value):
        if (value.statusCode != HttpStatus.ok) {
          return null;
        }
        final document = _windowDocumentOf(value.data);
        if (document.querySelector('input[name="formhash"]') == null) {
          return null;
        }
        final quote = document.querySelector('input[name="noticetrimstr"]')?.attributes['value'];
        return ReplyFormInfo(
          secCheck: documentAsksVerification(document) ? _windowSecCheck(document) : null,
          quote: quote == null || quote.trim().isEmpty ? null : quote,
        );
    }
  }

  /// Post reply to thread tid/fid.
  /// This will add a post in thread, as reply to that thread.
  ///
  /// # Exception
  ///
  /// * **HttpRequestFailedException** when http request failed.
  /// * **ReplyToThreadResultFailedException** when reply finished but no
  /// successful result found in response, carrying the server's reason.
  /// * **ReplyNeedsVerificationException** when the forum asks for a captcha or a security question the reply does not
  /// answer ([verification]): the thread page said so ([ReplyParameters.secCheck], nothing is sent), or the forum
  /// refused the reply for it.
  /// * **ReplyNeedsBrowserException** when the thread page said the forum asks for one without telling the ids.
  ///
  /// [stand] is the side the reply takes in a debate (0 neutral, 1 affirmative, 2 negative), sent as the fast reply
  /// form's `stand` select (the page's "加入正方／反方" opens the reply with it); none for any other thread. The forum
  /// keeps the side of the account's first reply for every later one.
  AsyncEither<PostedReply> replyToThread({
    required ReplyParameters replyParameters,
    required String replyMessage,
    int? stand,
    SecCheckAnswer? verification,
  }) => AsyncEither(() async {
    final browserUrl = '$homePage?mod=post&action=reply&fid=${replyParameters.fid}&tid=${replyParameters.tid}';
    final asked = replyParameters.secCheck;
    if (replyParameters.verification || asked != null) {
      // The thread page said the forum asks for a captcha or a security question: never post without the answers.
      if (asked == null) {
        error('quick reply asks for a captcha or a security question it names no id of');
        return left(ReplyNeedsBrowserException(url: browserUrl, verification: true));
      }
      if (verification == null || !verification.covers(asked)) {
        info('quick reply asks for a captcha or a security question');
        return left(ReplyNeedsVerificationException(check: verification?.check.merge(asked) ?? asked, url: browserUrl));
      }
    }
    final formData = <String, String>{
      'message': toOfficialMentions(replyMessage),
      'usesig': '1',
      'formhash': replyParameters.formHash,
      'subject': replyParameters.subject,
      'stand': ?stand?.toString(),
      ...?verification?.fields,
    };
    // Only apply post time when not null.
    if (replyParameters.postTime != null) {
      formData['posttime'] = replyParameters.postTime.toString();
    }
    // Posted once: a transport retry would post the reply twice.
    final respEither = await getIt
        .get<NetClientProvider>()
        .postForm(formatReplyThreadUrl(replyParameters.fid, replyParameters.tid), data: formData, singleAttempt: true)
        .run();
    if (respEither.isLeft()) {
      return left(respEither.unwrapErr());
    }

    final resp = respEither.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      return left(HttpRequestFailedException(resp.statusCode));
    }
    ({bool seccode, bool secqaa})? refused;
    if (_replyResultOf(resp.data) case final result?) {
      if (result.verification == null) {
        if (!result.stored) {
          error('reply to thread rejected by server: ${result.reason}');
          return left(ReplyToThreadResultFailedException(result.reason));
        }
        info('reply to thread stored (app api)');
        return right(postedReplyOfUrl(result.url));
      }
      refused = result.verification;
    } else {
      final data = tsdmAppAnswerText(resp.data);
      if (_isReplyStored(data)) {
        info('reply to thread stored: ${_storedMessage(data)?.length ?? 0} chars');
        return right(postedReplyOf(data));
      }
      final reason = _serverMessage(data);
      refused = refusedVerification(reason: reason);
      if (refused == null) {
        error('reply to thread rejected by server: $reason');
        return left(ReplyToThreadResultFailedException(reason));
      }
    }
    // A site asking by the number of posts or their interval decides it when the reply is posted.
    error('quick reply refused for a captcha or a security question');
    return left(
      ReplyNeedsVerificationException(
        check: refusedCheck(refused!, answered: verification?.check, told: asked, modid: SecCheck.viewthreadModid),
        url: browserUrl,
        wrongAnswer: verification != null,
      ),
    );
  });

  /// Reply personalMessage in history page.
  AsyncVoidEither replyHistoryPersonalMessage({
    required String targetUrl,
    required String formHash,
    required String message,
  }) => _reportSent(() async {
    final formData = <String, String>{'message': toOfficialMentions(message), 'formhash': formHash};

    // Sent once: a transport retry would send the message twice.
    final e = await getIt.get<NetClientProvider>().postForm(targetUrl, data: formData, singleAttempt: true).run();
    if (e.isLeft()) {
      return left(e.unwrapErr());
    }
    final resp = e.unwrap();
    if (resp.statusCode != HttpStatus.ok) {
      throw HttpRequestFailedException(resp.statusCode);
    }

    if (_messageResultOf(resp.data) case final result?) {
      return result;
    }
    final data = tsdmAppAnswerText(resp.data);

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
  AsyncVoidEither replyPersonalMessage(String touid, Map<String, String> formData) => _reportSent(() async {
    // Sent once: a transport retry would send the message twice.
    final e = await getIt
        .get<NetClientProvider>()
        .postForm(formatSendMessageUrl(touid), data: formData, singleAttempt: true)
        .run();
    if (e.isLeft()) {
      return left(e.unwrapErr());
    }

    final resp = e.unwrap();

    if (resp.statusCode != HttpStatus.ok) {
      throw HttpRequestFailedException(resp.statusCode);
    }

    if (_messageResultOf(resp.data) case final result?) {
      return result;
    }
    final data = tsdmAppAnswerText(resp.data);

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

  /// The outcome of a sent private message told by the forum's app API (plugin 2.6.0, [tsdmAppWriteResultOf]) in
  /// the answer [data], null when the forum answered itself: sent when the forum called the success hook
  /// (`succeedhandle_pmsend`, `handle` with `do_success`), failed with the forum's message on the error hook or a
  /// refusal page. As with the forum's own answer, an answer that is neither (a page) counts as sent.
  static Either<AppException, void>? _messageResultOf(Object? data) {
    final result = tsdmAppWriteResultOf(data);
    if (result == null) {
      return null;
    }
    if (result.kind == TsdmAppWriteKind.page || result.succeeded) {
      return rightVoid();
    }
    return left(ReplyPersonalMessageFailedException(result.reason.isEmpty ? 'unknown error' : result.reason));
  }

  /// Run the private message [send] and tell [PersonalMessageSent] when the forum accepted it: the conversation list
  /// of the account that sent is refreshed for it (GitHub #193).
  ///
  /// The account is the one of the global cookie the request carries, read before sending: the refresh must not run
  /// for an account switched to meanwhile.
  static AsyncVoidEither _reportSent(Future<Either<AppException, void>> Function() send) => AsyncVoidEither(() async {
    final sender = getIt.isRegistered<CookieProvider>() ? getIt.get<CookieProvider>().userLoginInfo.uid : null;
    final result = await send();
    if (result.isRight()) {
      PersonalMessageSent.notify(sender);
    }
    return result;
  });
}
