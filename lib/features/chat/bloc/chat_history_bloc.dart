import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:dart_mappable/dart_mappable.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/chat/models/models.dart';
import 'package:tsdm_client/features/chat/repository/chat_repository.dart';
import 'package:tsdm_client/features/chat/utils/parse_chat.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

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
      emit(state.copyWith(status: ChatHistoryStatus.loading));
    } else {
      emit(state.copyWith(status: ChatHistoryStatus.loadingMore));
    }
    await await _chatRepository.fetchChatHistory(event.uid, page: event.page).match((e) {
      handle(e);
      emit(state.copyWith(status: ChatHistoryStatus.failure));
    }, (v) async => _updateState(v, emit, event.page)).run();
  }

  FutureOr<void> _updateState(uh.Document document, _Emit emit, int? page) async {
    final info = parseChatHistory(document);
    if (info == null) {
      emit(state.copyWith(status: ChatHistoryStatus.failure));
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
      ),
    );
  }
}
