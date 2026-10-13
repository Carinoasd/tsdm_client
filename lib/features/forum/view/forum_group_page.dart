import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/widgets/account_reload_scope.dart';
import 'package:tsdm_client/features/forum/bloc/forum_group_bloc.dart';
import 'package:tsdm_client/features/multi_user/widgets/current_account_avatar.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/card/forum_card.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// The forum group page is the page corresponding to urls with `gid` query parameter.
class ForumGroupPage extends StatefulWidget {
  /// Constructor.
  const ForumGroupPage({required this.gid, this.title, super.key});

  /// Optional initial title.
  ///
  /// Usually is the title of forum group.
  final String? title;

  /// The group id to fetch data.
  final String gid;

  @override
  State<ForumGroupPage> createState() => _ForumGroupPageState();
}

class _ForumGroupPageState extends State<ForumGroupPage> {
  Widget _buildContent(BuildContext context, ForumGroup forumGroup) {
    final forums = forumGroup.forumList;
    // One column on phones, two on wide windows; large cards in a wider area on desktop windows, like the topics
    // page (phones keep the compact cards at any width). The width is measured inside the page's SafeArea, so side
    // insets are already excluded.
    return AppCenteredList(
      builder: (context, _, width) {
        final layout = forumCardListLayout(width, Theme.of(context).platform);
        return ListView.separated(
          padding: layout.side
              .copyWith(top: layout.large ? 16 : 8, bottom: layout.large ? 20 : 0)
              .add(context.safePadding()),
          itemCount: appRowCount(forums.length, layout.columns),
          itemBuilder: (context, row) => AppColumnsRow(
            row: row,
            columns: layout.columns,
            count: forums.length,
            gap: layout.gap,
            itemBuilder: (_, index) => ForumCard(forums[index], large: layout.large),
          ),
          separatorBuilder: (_, _) => layout.separator,
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // The boards listed are the ones the account in use may see: loaded again for another account.
    return AccountReloadScope(
      child: BlocProvider(
        create: (context) => ForumGroupBloc(context.repo())..add(ForumGroupLoadRequested(widget.gid)),
        child: BlocBuilder<ForumGroupBloc, ForumGroupBaseState>(
          builder: (context, state) {
            final body = switch (state) {
              ForumGroupInitial() || ForumGroupLoading() => const CenteredCircularIndicator(),
              ForumGroupSuccess(:final forumGroup) => _buildContent(context, forumGroup),
              ForumGroupFailure() => buildRetryButton(
                context,
                () => context.read<ForumGroupBloc>().add(ForumGroupLoadRequested(widget.gid)),
              ),
            };

            final String? title;
            if (state case ForumGroupSuccess()) {
              title = state.forumGroup.name;
            } else {
              title = null;
            }

            return Scaffold(
              appBar: AppBar(
                title: Text(title ?? widget.title ?? ''),
                // Which account browses the forums, with more than one saved account (GitHub #184).
                actions: const [CurrentAccountAvatarButton(lastAction: true)],
              ),
              body: SafeArea(bottom: false, child: body),
            );
          },
        ),
      ),
    );
  }
}
