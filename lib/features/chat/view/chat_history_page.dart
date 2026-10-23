import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/chat/bloc/chat_history_bloc.dart';
import 'package:tsdm_client/features/chat/models/editor_features.dart';
import 'package:tsdm_client/features/chat/repository/chat_repository.dart';
import 'package:tsdm_client/features/chat/widgets/chat_frame.dart';
import 'package:tsdm_client/features/chat/widgets/chat_message_card.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/failure_view.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/list_footer.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

/// Chat history page shows full chat history with another user [uid] and an
/// area to send new messages.
///
/// Full chat history is desc sorted and split 10 messages per page by server.
///
/// Note that an empty page with no message send area may return when the chat
/// history is empty. Usually this happened because user is redirected from chat
/// page that with a user never chatted before.
final class ChatHistoryPage extends StatefulWidget {
  /// Constructor.
  const ChatHistoryPage({required this.uid, super.key});

  /// User id to chat with.
  final String uid;

  @override
  State<ChatHistoryPage> createState() => _ChatHistoryPageState();
}

final class _ChatHistoryPageState extends State<ChatHistoryPage> {
  final _scrollController = ScrollController();
  final _replyBarController = ReplyBarController();

  Widget _buildContent(BuildContext context, ChatHistoryState state) {
    final messages = state.messages;
    final tr = context.t.chatHistoryPage;
    final bloc = context.read<ChatHistoryBloc>();
    void loadEarlier() => bloc.add(ChatHistoryLoadHistoryRequested(uid: widget.uid, page: state.previousPage));
    // Bubbles centered at a readable width; the list keeps the full width for scrolling and loading older pages.
    final Widget messageList = messages.isEmpty
        ? AppStateView(icon: Icons.history_outlined, message: tr.empty)
        : AppCenteredList(
            maxWidth: appReadingMaxWidth,
            builder: (context, side, _) => ListView.builder(
              // Reverse the list view and data received from server to let scroll
              // position keep the same after new pages of data.
              // See `messages` in `ChatHistoryState` for details.
              reverse: true,
              shrinkWrap: true,
              controller: _scrollController,
              padding: side.copyWith(top: 8, bottom: 8),
              // The end of the reversed list (its top) is the earlier messages: built when it comes near, it asks the
              // page before.
              itemCount: messages.length + 1,
              itemBuilder: (context, index) => index < messages.length
                  ? ChatMessageCard(messages[index])
                  : ListFooter(
                      status: listFooterStatus(
                        hasMore: state.previousPage != null,
                        loading: state.status == ChatHistoryStatus.loadingMore,
                        failed: state.loadMoreFailed,
                      ),
                      itemCount: messages.length,
                      failure: state.failure,
                      loadingText: tr.loadingOlder,
                      noMoreText: tr.noOlder,
                      onLoadMore: loadEarlier,
                      onRetry: loadEarlier,
                    ),
            ),
          );

    // Only the messages keep the side safe area: the reply bar pads the insets itself so its background reaches the
    // screen edges in landscape.
    return Column(
      children: [
        Expanded(child: SafeArea(bottom: false, child: messageList)),
        ChatComposerFrame(
          child: ReplyBar(
            controller: _replyBarController,
            replyType: ReplyTypes.chatHistory,
            chatHistorySendTarget: state.sendTarget,
            disabledEditorFeatures: chatPagesDisabledFeatures,
            fullScreenDisabledEditorFeatures: chatPagesDisabledFeatures,
          ),
        ),
      ],
    );
  }

  @override
  void initState() {
    super.initState();
    _markConversationRead();
  }

  /// Opening the conversation reads it, however the page was reached (the notification list, a profile, a friend
  /// card), so record that on the unread state right away.
  void _markConversationRead() {
    final peerUid = int.tryParse(widget.uid);
    final uid = context.readOrNull<AuthenticationRepository>()?.currentUser?.uid;
    final bloc = context.readOrNull<NotificationBloc>();
    if (peerUid == null || uid == null || bloc == null) {
      return;
    }
    bloc.add(NotificationMarkReadRequested(RecordMarkPersonalMessage(uid: uid, peerUid: peerUid, alreadyRead: true)));
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.chatHistoryPage;
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (context) => const ChatRepository()),
        RepositoryProvider(create: (context) => const ReplyRepository()),
        BlocProvider(create: (context) => ReplyBloc(replyRepository: context.repo())),
        BlocProvider(
          create: (context) =>
              ChatHistoryBloc(context.repo())..add(ChatHistoryLoadHistoryRequested(uid: widget.uid, page: null)),
        ),
      ],
      child: MultiBlocListener(
        listeners: [
          // A reload of the latest page that failed keeps the messages on screen and says so (an earlier page that
          // failed is told at the top of the list).
          BlocListener<ChatHistoryBloc, ChatHistoryState>(
            listenWhen: (prev, curr) =>
                prev.status == ChatHistoryStatus.loading &&
                curr.status == ChatHistoryStatus.success &&
                !curr.loadMoreFailed &&
                curr.failure != null,
            listener: (context, state) {
              final bloc = context.read<ChatHistoryBloc>();
              showRefreshFailedSnackBar(
                context,
                state.failure,
                onRetry: () {
                  if (!bloc.isClosed) {
                    bloc.add(ChatHistoryLoadHistoryRequested(uid: widget.uid, page: null));
                  }
                },
              );
            },
          ),
          BlocListener<ReplyBloc, ReplyState>(
            listenWhen: (prev, curr) => prev.status != curr.status,
            listener: (context, state) {
              // Close the editor through its controller and drop the focus first, the snack bar last: a `context.pop()`
              // issued once the sheet is already gone pops this page, and when the snack bar threw (a debug assertion
              // while a scaffold was being torn down) the editor and the keyboard used to stay up.
              if (state.status == ReplyStatus.success) {
                _replyBarController.closeEditor();
                FocusManager.instance.primaryFocus?.unfocus();
                showSnackBar(context: context, message: tr.success);
                // Show the message just sent: reload the latest page (GitHub #76).
                context.read<ChatHistoryBloc>().add(ChatHistoryLoadHistoryRequested(uid: widget.uid, page: null));
              } else if (state.status == ReplyStatus.failure) {
                // Every failure is told, and the editor stays open with the message for another try.
                final chatTr = context.t.chatPage;
                final historyBloc = context.read<ChatHistoryBloc>();
                showSnackBar(
                  context: context,
                  message: state.maybeSent
                      ? chatTr.maybeSent
                      : state.networkFailure
                      ? chatTr.failedNetwork
                      : tr.failed(message: state.failedReason ?? ''),
                  // The keyboard stays up and this page does not resize for it: lift the hint above it.
                  bottomInset: MediaQuery.viewInsetsOf(context).bottom,
                  // The message may be in the dialog already: look before sending it again.
                  action: state.maybeSent
                      ? SnackBarAction(
                          label: chatTr.refresh,
                          onPressed: () {
                            if (historyBloc.isClosed) return;
                            historyBloc.add(ChatHistoryLoadHistoryRequested(uid: widget.uid, page: null));
                          },
                        )
                      : null,
                );
              }
            },
          ),
        ],
        child: BlocBuilder<ChatHistoryBloc, ChatHistoryState>(
          builder: (context, state) {
            final body = switch (state.status) {
              ChatHistoryStatus.initial => const CenteredCircularIndicator(),
              // A reload keeps the messages on screen instead of flashing a spinner.
              ChatHistoryStatus.loading when state.messages.isEmpty => const CenteredCircularIndicator(),
              ChatHistoryStatus.loading ||
              ChatHistoryStatus.success ||
              ChatHistoryStatus.loadingMore => _buildContent(context, state),
              ChatHistoryStatus.failure => SafeArea(
                bottom: false,
                child: FailureView(
                  failure: state.failure,
                  onRetry: () => context.read<ChatHistoryBloc>().add(
                    ChatHistoryLoadHistoryRequested(uid: widget.uid, page: state.pageNumber),
                  ),
                ),
              ),
            };

            PreferredSizeWidget? bottom;
            if ((state.user.username != null || state.user.uid != null) && state.messageCount > 0) {
              bottom = ChatPeerHeader(
                text: tr.info(user: state.user.username ?? state.user.uid ?? '', count: state.messageCount),
              );
            }

            return Scaffold(
              // Required by chat_bottom_container in reply bar.
              resizeToAvoidBottomInset: false,
              appBar: AppBar(title: Text(tr.title), bottom: bottom),
              body: body,
            );
          },
        ),
      ),
    );
  }
}
