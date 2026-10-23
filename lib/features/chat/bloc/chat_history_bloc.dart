import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/chat/models/models.dart';
import 'package:tsdm_client/features/chat/repository/chat_repository.dart';
import 'package:tsdm_client/features/chat/utils/chat_page_api.dart';
import 'package:tsdm_client/features/chat/utils/parse_chat.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/utils/load_failure.dart';
import 'package:tsdm_client/utils/logger.dart';

part 'chat_history_bloc.mapper.dart';
part 'chat_history_event.dart';
part 'chat_history_state.dart';

typedef _Emit = Emitter<ChatHistoryState>;

/// Bloc of chat history.
final class ChatHistoryBloc extends Bloc<ChatHistoryEvent, ChatHistoryState> with LoggerMixin {
  /// Constructor.
  ChatHistoryBloc(this._chatRepository) : super(const ChatHistoryState()) {
    // One load at a time, in the order asked for: the reload after a message was sent and a request for an older
    // page issued meanwhile must both apply, the older page after the fresh latest page. Concurrent handling
    // appended the older page to a stale list, and "latest request wins" threw the reload away (PR #81 review).
    on<ChatHistoryLoadHistoryRequested>(_onChatHistoryLoadHistoryRequested, transformer: _sequential);
  }

  final ChatRepository _chatRepository;

  /// Process events one after another, the equivalent of `bloc_concurrency`'s `sequential()`.
  static Stream<E> _sequential<E>(Stream<E> events, EventMapper<E> mapper) => events.asyncExpand(mapper);

  FutureOr<void> _onChatHistoryLoadHistoryRequested(ChatHistoryLoadHistoryRequested event, _Emit emit) async {
    if (event.page == null) {
      emit(state.copyWith(status: ChatHistoryStatus.loading, failure: null));
    } else {
      emit(state.copyWith(status: ChatHistoryStatus.loadingMore, loadMoreFailed: false));
    }
    await await _chatRepository.fetchChatHistory(event.uid, page: event.page).match((e) {
      handle(e);
      _emitFailure(LoadFailure.of(e), emit, event.page);
    }, (v) async => _updateState(v, emit, event.page)).run();
  }

  /// A load of [page] (null: the latest one) that failed with [failure]: the messages shown stay, an earlier page that
  /// failed is told at the end of the list, the latest one by the page; nothing shown yet is the failure.
  void _emitFailure(LoadFailure failure, _Emit emit, int? page) {
    if (state.messages.isEmpty) {
      emit(state.copyWith(status: ChatHistoryStatus.failure, failure: failure));
      return;
    }
    emit(state.copyWith(status: ChatHistoryStatus.success, loadMoreFailed: page != null, failure: failure));
  }

  /// The structured answer of the forum's app API (plugin 2.5.0) built from its fields, the web page (or an older
  /// plugin's answer) parsed as before.
  FutureOr<void> _updateState(TsdmAppPageAnswer answer, _Emit emit, int? page) async {
    final info = switch (answer) {
      TsdmAppStructuredPage(:final json) => chatHistoryFromApi(json),
      TsdmAppWebPage(:final document) => parseChatHistory(document),
    };
    if (info == null) {
      _emitFailure(LoadFailure(LoadFailureKind.unknown, details: 'chat history not found in the answer'), emit, page);
      return;
    }
    emit(
      state.copyWith(
        status: ChatHistoryStatus.success,
        user: User(username: info.username),
        messageCount: info.messageCount,
        pageNumber: page,
        previousPage: info.previousPage,
        nextPage: info.nextPage,
        sendTarget: info.sendTarget,
        // Loading an earlier page appends it; loading the latest page again (first load, or the reload after a
        // message was sent) replaces what is shown, otherwise the same messages would be listed twice.
        messages: page == null ? info.messages : [...state.messages, ...info.messages],
        loadMoreFailed: false,
        failure: null,
      ),
    );
  }
}
