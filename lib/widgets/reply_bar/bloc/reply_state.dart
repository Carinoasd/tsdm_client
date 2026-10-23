part of 'reply_bloc.dart';

/// Status of reply
enum ReplyStatus {
  /// Initial.
  initial,

  ///  Posting reply.
  loading,

  /// Reply succeed.
  success,

  /// Reply failed.
  failure,

  /// The forum asks for a captcha or a security question ([ReplyState.secCheck]) before it takes the reply: nothing was
  /// sent, the editor asks the user and sends again with the answers ([ReplyVerificationAnswered]).
  verification,
}

/// State of reply.
@MappableClass()
class ReplyState with ReplyStateMappable {
  /// Constructor.
  const ReplyState({
    this.status = ReplyStatus.initial,
    this.replyParameters,
    this.closed = true,
    this.needClearText = false,
    this.replyTypes = ReplyTypes.thread,
    this.failedReason,
    this.networkFailure = false,
    this.maybeSent = false,
    this.postedPid = '',
    this.postedPage = 0,
    this.browserUrl,
    this.secCheck,
    this.wrongAnswer = false,
    this.retryAt,
  });

  /// Current usage of reply.
  final ReplyTypes replyTypes;

  /// Status.
  final ReplyStatus status;

  /// Parameter used in reply.
  final ReplyParameters? replyParameters;

  /// Indicating can send reply or not.
  ///
  /// If true, current reply bar should be closed, because maybe the thread
  /// is closed.
  final bool closed;

  /// Indicating need to clear the text in reply text field.
  ///
  /// This should be set to true once sending request success, only one time.
  final bool needClearText;

  /// Why failed.
  final String? failedReason;

  /// The last failure never reached the server (offline, DNS, timeout): [failedReason] is empty and the UI shows a
  /// fixed network hint instead of the raw exception text.
  final bool networkFailure;

  /// The last failure came after the request left ([networkFailure] without
  /// [isNoNetworkFailure]: a timeout while waiting for the answer, a connection dropped): the forum may have stored
  /// the reply or the message, so the UI asks to refresh and check before sending it again, never to just retry.
  final bool maybeSent;

  /// Id of the post created by the last successful reply, empty when the server did not tell.
  final String postedPid;

  /// Page (in the server's default order) the last successful reply landed on, 0 when unknown.
  final int postedPage;

  /// The page to reply on in the browser when the last reply needs the website (the forum asks for a captcha or a
  /// security question, or the reply form has fields the app cannot fill): nothing was sent. Null otherwise.
  final String? browserUrl;

  /// What the forum asks for ([ReplyStatus.verification]), with the ids the answers go with; null otherwise.
  final SecCheck? secCheck;

  /// The answers sent last were not taken ([ReplyStatus.verification]).
  final bool wrongAnswer;

  /// When the forum takes the next post, after it refused the last one as too soon after the previous
  /// ([ReplyStatus.failure], `post_flood_ctrl`); null otherwise.
  final DateTime? retryAt;

  /// Copy with, but make the `replyParameters` to null.
  ReplyState copyWithNullReplyParameters() {
    return ReplyState(
      status: status,
      closed: closed,
      needClearText: needClearText,
      failedReason: failedReason,
      networkFailure: networkFailure,
      maybeSent: maybeSent,
      postedPid: postedPid,
      postedPage: postedPage,
      browserUrl: browserUrl,
      secCheck: secCheck,
      wrongAnswer: wrongAnswer,
      retryAt: retryAt,
    );
  }
}
