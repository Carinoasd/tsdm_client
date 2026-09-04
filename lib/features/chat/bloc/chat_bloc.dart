import 'dart:async';

import 'package:dart_mappable/dart_mappable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/features/chat/models/models.dart';
import 'package:tsdm_client/features/chat/repository/chat_repository.dart';
import 'package:tsdm_client/features/chat/utils/parse_chat.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:universal_html/html.dart' as uh;

part 'chat_bloc.mapper.dart';

part 'chat_event.dart';

part 'chat_state.dart';

/// Emit
typedef _Emit = Emitter<ChatState>;

/// Bloc of chat.
///
/// This bloc is originally the login in chat dialog on server side.
///
/// Way to access this page:
/// see `formatChatUrl`.
final class ChatBloc extends Bloc<ChatEvent, ChatState> with LoggerMixin {
  /// Constructor.
  ChatBloc(this._chatRepository) : super(const ChatState()) {
    on<ChatFetchHistoryRequested>(_onChatFetchHistoryRequested);
  }

  final ChatRepository _chatRepository;

  FutureOr<void> _onChatFetchHistoryRequested(ChatFetchHistoryRequested event, _Emit emit) async {
    emit(state.copyWith(status: ChatStatus.loading));

    await await _chatRepository.fetchChat(event.uid).match((e) {
      handle(e);
      emit(state.copyWith(status: ChatStatus.failure));
    }, (v) async => _updateState(v, emit)).run();
  }

  void _updateState(uh.Document document, _Emit emit) {
    final info = parseChatDialog(document);
    if (info == null) {
      emit(state.copyWith(status: ChatStatus.failure));
      return;
    }
    emit(
      state.copyWith(
        status: ChatStatus.success,
        username: info.username,
        online: info.online,
        uid: info.uid,
        chatHistoryUrl: info.chatHistoryUrl,
        spaceUrl: info.spaceUrl,
        chatSendTarget: info.sendTarget,
        messageList: info.messageList,
      ),
    );
  }
}
