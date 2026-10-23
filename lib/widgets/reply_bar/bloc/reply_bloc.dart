import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

part 'reply_bloc.mapper.dart';

part 'reply_event.dart';

part 'reply_state.dart';

/// Emitter
typedef _Emit = Emitter<ReplyState>;

/// Bloc of reply
class ReplyBloc extends Bloc<ReplyEvent, ReplyState> with LoggerMixin {
  /// Constructor.
  ///
  /// With both [storageProvider] and [authenticationRepository], every reply stored in a thread (to the thread or
  /// to one of its floors) is recorded as a local "replied" mark of the current account (issue #21); the chat pages
  /// leave them out, they never reply in threads.
  ReplyBloc({
    required ReplyRepository replyRepository,
    StorageProvider? storageProvider,
    AuthenticationRepository? authenticationRepository,
  }) : _replyRepository = replyRepository,
       _storageProvider = storageProvider,
       _authenticationRepository = authenticationRepository,
       super(const ReplyState()) {
    on<ReplyParametersUpdated>(_onReplyParametersUpdated);
    on<ReplyThreadClosed>(_onReplyThreadClosed);
    on<ReplyToPostRequested>(_counted(_onReplyToPostRequested));
    on<ReplyToThreadRequested>(_counted(_onReplyToThreadRequested));
    on<ReplyResetClearTextStateTriggered>(_onReplyResetClearTextStateTriggered);
    on<ReplyChatHistoryRequested>(_counted(_onReplyChatHistoryRequested));
    on<ReplyChatRequested>(_counted(_onReplyChatRequested));
  }

  /// Replies and messages being sent right now, by every page together.
  static int _sending = 0;

  /// Whether a reply or a message is being sent on any page.
  ///
  /// An account switch waits for it (GitHub #184 follow-up): the switch drops the answer of every request still
  /// running for the previous account, so the user would see a failure for a reply the forum stored and send it again.
  /// Counted around the request itself, not from the states: a page closed while sending stops getting states, but
  /// its request still goes on.
  static bool get sendingAny => _sending > 0;

  /// [handler] counted in [sendingAny] until it ends, however it ends.
  static EventHandler<E, ReplyState> _counted<E extends ReplyEvent>(EventHandler<E, ReplyState> handler) =>
      (event, emit) async {
        _sending++;
        try {
          await handler(event, emit);
        } finally {
          _sending--;
        }
      };

  final ReplyRepository _replyRepository;
  final StorageProvider? _storageProvider;
  final AuthenticationRepository? _authenticationRepository;

  /// Remember that the current account replied in the thread of [parameters] (local "replied" mark, issue #21).
  ///
  /// Skipped without a logged user; a storage error is logged, the reply itself was stored on the server.
  Future<void> _recordReplied(ReplyParameters parameters) async {
    final storage = _storageProvider;
    final uid = _authenticationRepository?.currentUser?.uid;
    final tid = int.tryParse(parameters.tid);
    final fid = int.tryParse(parameters.fid);
    if (storage == null || uid == null || tid == null || fid == null) {
      return;
    }
    try {
      await storage.recordRepliedThread(uid: uid, tid: tid, fid: fid);
      // Keep the success state no matter what the local mark did.
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      error('failed to record replied thread tid=$tid: $e', e, st);
    }
  }

  Future<void> _onReplyParametersUpdated(ReplyParametersUpdated event, _Emit emit) async {
    if (event.replyParameters == null) {
      emit(state.copyWithNullReplyParameters());
    } else {
      emit(state.copyWith(replyParameters: event.replyParameters));
    }
  }

  Future<void> _onReplyThreadClosed(ReplyThreadClosed event, _Emit emit) async {
    emit(state.copyWith(closed: event.closed));
  }

  Future<void> _onReplyToPostRequested(ReplyToPostRequested event, _Emit emit) async {
    emit(state.copyWith(status: ReplyStatus.loading));
    final ret = await _replyRepository
        .replyToPost(
          replyParameters: event.replyParameters,
          replyAction: event.replyAction,
          replyMessage: event.replyMessage,
          stand: event.stand,
        )
        .run();
    if (ret.isLeft()) {
      final err = ret.unwrapErr();
      handle(err);
      emit(_failed(err));
      return;
    }
    await _recordReplied(event.replyParameters);
    emit(_stored(ret.unwrap()));
  }

  Future<void> _onReplyToThreadRequested(ReplyToThreadRequested event, _Emit emit) async {
    emit(state.copyWith(status: ReplyStatus.loading));
    final ret = await _replyRepository
        .replyToThread(replyParameters: event.replyParameters, replyMessage: event.replyMessage, stand: event.stand)
        .run();
    if (ret.isLeft()) {
      final err = ret.unwrapErr();
      handle(err);
      emit(_failed(err));
      return;
    }
    await _recordReplied(event.replyParameters);
    emit(_stored(ret.unwrap()));
  }

  /// Success state carrying where the new post landed, so the thread page can jump to it.
  ReplyState _stored(PostedReply posted) => state.copyWith(
    status: ReplyStatus.success,
    needClearText: true,
    postedPid: posted.pid ?? '',
    postedPage: posted.page ?? 0,
    browserUrl: null,
  );

  /// Whether an answer with HTTP [statusCode] may come after the forum stored the post: a server error (5xx, the
  /// forum may have failed after writing) or a redirect (3xx: the forum goes on to the new post after storing it, and
  /// a post sent once does not follow it). A client error (4xx) refused the request before anything was stored.
  static bool _mayHaveStored(int? statusCode) =>
      statusCode != null && (statusCode >= 500 || (statusCode >= 300 && statusCode < 400));

  /// Failure state for [e]: the server's own words when it gave any, the HTTP status when a broken answer came
  /// back, or the network flag when nothing came back at all (offline, DNS failure, timeout).
  ///
  /// Nothing came back but the request left ([isNoNetworkFailure] tells the forum was never reached), or a server
  /// error or a redirect came back ([_mayHaveStored]): the forum may have stored it ([ReplyState.maybeSent]). The posts are sent once (`singleAttempt`), never again by the transport.
  ///
  /// A reply that needs the website ([ReplyNeedsBrowserException]: a captcha or a security question, fields the app
  /// cannot fill) says so and names the page to reply on ([ReplyState.browserUrl]); nothing was sent.
  ReplyState _failed(AppException e) => switch (e) {
    HttpHandshakeFailedException(statusCode: null) || HttpRequestFailedException(statusCode: null) => state.copyWith(
      status: ReplyStatus.failure,
      failedReason: '',
      networkFailure: true,
      maybeSent: !isNoNetworkFailure(e),
      browserUrl: null,
    ),
    HttpHandshakeFailedException(:final statusCode) || HttpRequestFailedException(:final statusCode) => state.copyWith(
      status: ReplyStatus.failure,
      failedReason: 'HTTP $statusCode',
      networkFailure: false,
      maybeSent: _mayHaveStored(statusCode),
      browserUrl: null,
    ),
    ReplyNeedsBrowserException(:final url, :final verification) => state.copyWith(
      status: ReplyStatus.failure,
      failedReason: verification ? t.threadPage.replyNeedsVerification : t.threadPage.replyNeedsBrowser,
      networkFailure: false,
      maybeSent: false,
      browserUrl: url,
    ),
    _ => state.copyWith(
      status: ReplyStatus.failure,
      failedReason: e.message ?? e.runtimeType.toString(),
      networkFailure: false,
      maybeSent: false,
      browserUrl: null,
    ),
  };

  Future<void> _onReplyResetClearTextStateTriggered(ReplyResetClearTextStateTriggered event, _Emit emit) async {
    emit(state.copyWith(needClearText: false));
  }

  Future<void> _onReplyChatHistoryRequested(ReplyChatHistoryRequested event, _Emit emit) async {
    emit(state.copyWith(status: ReplyStatus.loading));
    // TODO: Update chat history with returned pmid.
    final result = await _replyRepository
        .replyHistoryPersonalMessage(targetUrl: event.targetUrl, formHash: event.formHash, message: event.message)
        .run();
    if (result.isLeft()) {
      final err = result.unwrapErr();
      if (err case ReplyPersonalMessageFailedException()) {
        error('failed to reply chat history');
      } else {
        handle(err);
      }
      // Every failure is told (a network one used to be dropped: no reason, no hint, and the editor closed).
      emit(_failed(err));
      return;
    }
    emit(state.copyWith(status: ReplyStatus.success, needClearText: true));
  }

  Future<void> _onReplyChatRequested(ReplyChatRequested event, _Emit emit) async {
    emit(state.copyWith(status: ReplyStatus.loading));
    // TODO: Update chat history with returned pmid.
    final result = await _replyRepository.replyPersonalMessage(event.touid, event.formData).run();
    if (result.isLeft()) {
      final err = result.unwrapErr();
      if (err is! ReplyPersonalMessageFailedException) {
        handle(err);
      }
      // Every failure is told, see the chat history.
      emit(_failed(err));
      return;
    }
    emit(state.copyWith(status: ReplyStatus.success, needClearText: true));
  }
}
