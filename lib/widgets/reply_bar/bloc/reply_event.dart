part of 'reply_bloc.dart';

/// Event of reply
@MappableClass()
sealed class ReplyEvent with ReplyEventMappable {
  /// Constructor.
  const ReplyEvent();
}

/// Parameters used in reply.
///
/// Because reply bar does not handle events about page refresh (html document
/// fetching), reply parameters are provided by external
/// blocs (e.g. ThreadBloc).
///
/// When those bloc parsed the latest reply parameters from html document,
/// they should call this event
/// to sync parameters with here.
@MappableClass()
final class ReplyParametersUpdated extends ReplyEvent with ReplyParametersUpdatedMappable {
  /// Constructor.
  const ReplyParametersUpdated(this.replyParameters) : super();

  /// Parameters used in posting the reply data.
  final ReplyParameters? replyParameters;
}

/// The thread, which contains current reply bar, is closed (or not) and can
/// not (or can) send replies.
///
/// Because reply bar does not handle events about page refresh (html document
/// fetching), thread closed state are provided by external
/// blocs. (e.g. ThreadBloc).
///
/// When those bloc parsed the latest reply parameters from html document, they
/// should call this event
/// to sync parameters with here.
@MappableClass()
final class ReplyThreadClosed extends ReplyEvent with ReplyThreadClosedMappable {
  /// Constructor.
  const ReplyThreadClosed({required this.closed}) : super();

  /// Thread is closed or not.
  final bool closed;
}

/// User required to reply to another post.
@MappableClass()
final class ReplyToPostRequested extends ReplyEvent with ReplyToPostRequestedMappable implements _DraftedReply {
  /// Constructor.
  const ReplyToPostRequested({
    required this.replyParameters,
    required this.replyAction,
    required this.replyMessage,
    this.stand,
    this.verification,
    this.draftUid,
    this.draftKey,
  }) : super();

  /// Parameters used in posting the reply data.
  final ReplyParameters replyParameters;

  /// Action parameter used in posting the reply data.
  final String replyAction;

  /// Message to reply.
  final String replyMessage;

  /// The side the reply takes in a debate (0 neutral, 1 affirmative, 2 negative); null for any other thread.
  final int? stand;

  /// The answers to the captcha or the security question the forum asks, null when none was asked yet.
  final SecCheckAnswer? verification;

  @override
  final int? draftUid;

  @override
  final String? draftKey;
}

/// User required to reply to a thread.
@MappableClass()
final class ReplyToThreadRequested extends ReplyEvent with ReplyToThreadRequestedMappable implements _DraftedReply {
  /// Constructor.
  const ReplyToThreadRequested({
    required this.replyParameters,
    required this.replyMessage,
    this.stand,
    this.verification,
    this.draftUid,
    this.draftKey,
  }) : super();

  /// Parameters used in posting the reply data.
  final ReplyParameters replyParameters;

  /// Message to reply.
  final String replyMessage;

  /// The side the reply takes in a debate (0 neutral, 1 affirmative, 2 negative); null for any other thread.
  final int? stand;

  /// The answers to the captcha or the security question the forum asks, null when none was asked yet.
  final SecCheckAnswer? verification;

  @override
  final int? draftUid;

  @override
  final String? draftKey;
}

/// The user answered the captcha or the security question the forum asked for ([ReplyStatus.verification]): the reply
/// goes again with [answer].
@MappableClass()
final class ReplyVerificationAnswered extends ReplyEvent with ReplyVerificationAnsweredMappable {
  /// Constructor.
  const ReplyVerificationAnswered(this.answer);

  /// The answers.
  final SecCheckAnswer answer;
}

/// The user did not answer the captcha or the security question the forum asked for: the reply was not sent.
@MappableClass()
final class ReplyVerificationCancelled extends ReplyEvent with ReplyVerificationCancelledMappable {
  /// Constructor.
  const ReplyVerificationCancelled();
}

/// This event is used to reset the state of flag needClearText in state.
///
/// That flag should only be true once when user send post succeed, then reset
/// to false.
@MappableClass()
final class ReplyResetClearTextStateTriggered extends ReplyEvent with ReplyResetClearTextStateTriggeredMappable {}

/// Reply in chat history page.
@MappableClass()
final class ReplyChatHistoryRequested extends ReplyEvent
    with ReplyChatHistoryRequestedMappable
    implements _DraftedReply {
  /// Constructor.
  const ReplyChatHistoryRequested({
    required this.targetUrl,
    required this.formHash,
    required this.message,
    this.draftUid,
    this.draftKey,
  });

  /// Url to post form data.
  final String targetUrl;

  /// Form hash.
  final String formHash;

  /// Message content.
  final String message;

  @override
  final int? draftUid;

  @override
  final String? draftKey;
}

/// Requested to send message in chat page.
@MappableClass()
final class ReplyChatRequested extends ReplyEvent with ReplyChatRequestedMappable implements _DraftedReply {
  /// Constructor.
  const ReplyChatRequested(this.touid, this.formData, {this.draftUid, this.draftKey});

  /// Query parameter used in url to post message to server.
  final String touid;

  /// Form data used in post request to send message to server.
  final Map<String, String> formData;

  @override
  final int? draftUid;

  @override
  final String? draftKey;
}

/// A reply or a message written in an editor whose local draft goes once it is sent.
abstract interface class _DraftedReply {
  /// The account the local draft belongs to, null when there is none.
  int? get draftUid;

  /// The key of the local draft (`LocalDraftKey.value`), null when there is none.
  String? get draftKey;
}
