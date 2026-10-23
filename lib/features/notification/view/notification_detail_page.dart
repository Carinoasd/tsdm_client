import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/constants.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/notification/bloc/notification_detail_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/back_to_home_button.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

/// Show details for a single notice, also provides interaction:
/// * Reply to the notice if notice type is [NoticeType.reply]
/// or [NoticeType.mention].
class NoticeDetailPage extends StatefulWidget {
  /// Constructor.
  const NoticeDetailPage({required this.url, required this.noticeType, super.key});

  /// [NoticeType] of current notice.
  ///
  /// Determines different UI layout.
  final NoticeType noticeType;

  /// Url to fetch the notice.
  final String url;

  @override
  State<NoticeDetailPage> createState() => _NoticeDetailPage();
}

class _NoticeDetailPage extends State<NoticeDetailPage> with LoggerMixin {
  final _replyBarController = ReplyBarController();

  String? _tid;
  String? _pid;
  String? _page;

  Widget _buildBody(BuildContext context, NotificationDetailState state) {
    _tid = state.tid;
    _pid = state.pid;
    _page = state.page;

    // Post can not be null because we only call this function when in
    // success state.
    final post = state.post!;
    // The post as a floor of the thread reader: a rounded surface at a readable width, phones keep most of the width
    // for the text.
    final side = MediaQuery.sizeOf(context).width < 600 ? 6.0 : 16.0;
    // Only the post keeps the side safe area: the reply bar pads the insets itself so its background reaches the
    // screen edges in landscape.
    final postView = SafeArea(
      top: false,
      bottom: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(side, 8, side, 12),
        child: AppContentWidth(
          maxWidth: appReadingMaxWidth,
          child: Card(margin: EdgeInsets.zero, shape: appSurfaceShape(context), child: PostCard(post)),
        ),
      ),
    );
    if (widget.noticeType == NoticeType.rate) {
      return postView;
    }

    if (state.replyParameters != null) {
      _replyBarController.replyAction = post.replyAction;
      context.read<ReplyBloc>().add(ReplyParametersUpdated(state.replyParameters));
    }

    return Column(
      children: [
        Expanded(child: postView),
        // Always show reply bar even thread is locked to keep the same UI as
        // visiting locked thread.
        ReplyBar(
          controller: _replyBarController,
          // Set to [ReplyTypes.notice] to avoid clear reply parameters when
          // [ReplyBar] closed.
          replyType: ReplyTypes.notice,
          disabledEditorFeatures: defaultEditorDisabledFeatures,
          fullScreenDisabledEditorFeatures: defaultFullScreenDisabledEditorFeatures,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (widget.noticeType) {
      NoticeType.reply => context.t.noticePage.noticeDetailPage.titleReply,
      NoticeType.rate => context.t.noticePage.noticeDetailPage.titleRate,
      NoticeType.mention => context.t.noticePage.noticeDetailPage.titleMention,
      NoticeType.invite ||
      NoticeType.newFriend ||
      NoticeType.batchRate => '', // No detail page for invites, impossible.
    };
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => NotificationRepository()),
        RepositoryProvider(create: (_) => const ReplyRepository()),
        BlocProvider(
          create: (context) => ReplyBloc(
            replyRepository: context.repo(),
            storageProvider: getIt.get<StorageProvider>(),
            authenticationRepository: context.repo(),
          ),
        ),
        BlocProvider(
          create: (context) {
            final cubit = NotificationDetailCubit(notificationRepository: context.repo());
            unawaited(cubit.fetchDetail(widget.url));
            return cubit;
          },
        ),
      ],
      child: BlocListener<NotificationDetailCubit, NotificationDetailState>(
        // Tell the reply bar whether the thread is closed as soon as the thread told it, before the bar is first
        // built: told from the builder, the bar was built with the bloc's initial "closed" and showed "帖子已关闭" for a
        // thread open for replies (GitHub #235). Nothing is closed while the page loads.
        listenWhen: (prev, curr) =>
            curr.status == NotificationDetailStatus.success &&
            (prev.status != curr.status || prev.threadClosed != curr.threadClosed),
        listener: (context, state) {
          final bloc = context.read<ReplyBloc>();
          if (state.threadClosed != bloc.state.closed) {
            bloc.add(ReplyThreadClosed(closed: state.threadClosed));
          }
        },
        child: BlocListener<ReplyBloc, ReplyState>(
          // Drop only needClearText changed changes.
          listenWhen: (prev, curr) => prev.status != curr.status,
          listener: (context, state) {
            if (state.status == ReplyStatus.success) {
              showSnackBar(context: context, message: context.t.threadPage.replySuccess);
            } else if (state.status == ReplyStatus.failure) {
              final tr = context.t.threadPage;
              final tid = _tid ?? state.replyParameters?.tid;
              showSnackBar(
                context: context,
                // The editor and the keyboard stay open on failure and this page does not resize for the keyboard.
                bottomInset: MediaQuery.viewInsetsOf(context).bottom,
                message: state.maybeSent
                    ? tr.replyMaybeSent
                    : state.networkFailure
                    ? tr.replyFailedNetwork
                    : tr.replyFailed(err: state.failedReason ?? ''),
                // The reply may be on the forum already: look before sending it again, on the last floor of the thread
                // (fetching this notice again shows only the floor it is about).
                action: state.maybeSent && tid != null
                    ? SnackBarAction(
                        label: tr.refreshToCheck,
                        onPressed: () {
                          if (!mounted) return;
                          unawaited(
                            context.pushNamed(
                              ScreenPaths.threadV1,
                              queryParameters: {'tid': tid, 'lastPost': '1', 'overrideReverseOrder': 'false'},
                            ),
                          );
                        },
                      )
                    : replyInBrowserAction(context, state.browserUrl),
              );
            }
          },
          child: BlocBuilder<NotificationDetailCubit, NotificationDetailState>(
            builder: (context, state) {
              final body = switch (state.status) {
                NotificationDetailStatus.initial ||
                NotificationDetailStatus.loading => const CenteredCircularIndicator(),
                NotificationDetailStatus.success => _buildBody(context, state),
                NotificationDetailStatus.failed => SafeArea(
                  top: false,
                  bottom: false,
                  child: buildRetryButton(context, () async {
                    await context.read<NotificationDetailCubit>().fetchDetail(widget.url);
                  }),
                ),
              };

              return Scaffold(
                // The editor of the reply bar makes room for the keyboard itself (chat_bottom_container), as on the
                // thread page: resizing too lifted it twice the keyboard's height (GitHub #235).
                resizeToAvoidBottomInset: false,
                appBar: AppBar(
                  title: Text(title),
                  actions: [
                    const BackToHomeButton(),
                    IconButton(
                      icon: const Icon(Icons.open_in_new_outlined),
                      tooltip: context.t.general.openInBrowser,
                      onPressed: () async {
                        if (_tid == null || _page == null || _pid == null) {
                          return;
                        }
                        info('find post: tid:$_tid, page:$_page, pid:$_pid');
                        await context.pushNamed(
                          ScreenPaths.threadV1,
                          queryParameters: <String, String>{
                            'tid': _tid!,
                            'pageNumber': _page!,
                            'pid': _pid!,
                            // Set this value to false to reserve the original
                            // post order in thread so that we are heading to the
                            // correct page contains target post.
                            'overrideReverseOrder': 'false',
                          },
                        );
                      },
                    ),
                  ],
                ),
                // The post and the retry keep the side safe area; the reply bar pads itself for all its insets.
                body: body,
              );
            },
          ),
        ),
      ),
    );
  }
}
