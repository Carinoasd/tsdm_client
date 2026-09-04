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
    on<ChatHistoryLoadHistoryRequested>(_onChatHistoryLoadHistoryRequested);
  }

  final ChatRepository _chatRepository;

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
        messages: [...state.messages, ...info.messages],
      ),
    );
  }
}
