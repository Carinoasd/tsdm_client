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
    this.postedPid = '',
    this.postedPage = 0,
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

  /// Id of the post created by the last successful reply, empty when the server did not tell.
  final String postedPid;

  /// Page (in the server's default order) the last successful reply landed on, 0 when unknown.
  final int postedPage;

  /// Copy with, but make the `replyParameters` to null.
  ReplyState copyWithNullReplyParameters() {
    return ReplyState(
      status: status,
      closed: closed,
      needClearText: needClearText,
      failedReason: failedReason,
      networkFailure: networkFailure,
      postedPid: postedPid,
      postedPage: postedPage,
    );
  }
}
