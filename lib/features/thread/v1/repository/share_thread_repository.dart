import 'package:tsdm_client/exceptions/exceptions.dart';
import 'package:tsdm_client/features/chat/repository/chat_repository.dart';
import 'package:tsdm_client/features/chat/utils/parse_chat.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

/// Send a thread to a friend as a private message (GitHub #23).
///
/// Same two steps as the chat page: open the chat dialog of the friend for the form values, then post the message.
final class ShareThreadRepository with LoggerMixin {
  /// Constructor.
  const ShareThreadRepository({
    this.chatRepository = const ChatRepository(),
    this.replyRepository = const ReplyRepository(),
  });

  /// Fetches the chat dialog (form values).
  final ChatRepository chatRepository;

  /// Posts the message.
  final ReplyRepository replyRepository;

  /// Send [message] to user [uid].
  AsyncVoidEither sendToFriend({required String uid, required String message}) =>
      chatRepository.fetchChat(uid).flatMap((document) {
        final info = parseChatDialog(document);
        if (info == null) {
          error('share thread: chat dialog of $uid has no send form');
          return AsyncVoidEither.left(ChatDataDocumentNotFoundException());
        }
        final target = info.sendTarget;
        return replyRepository.replyPersonalMessage(target.touid, {
          'pmsubmit': target.pmsubmit,
          'touid': target.touid,
          'formhash': target.formHash,
          'handlekey': target.handleKey,
          'message': message,
          'messageappend': target.messageAppend,
        });
      });
}
