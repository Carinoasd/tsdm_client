import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/latest_thread/bloc/latest_thread_bloc.dart';
import 'package:tsdm_client/features/latest_thread/repository/latest_thread_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/widgets/card/thread_card/thread_card.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Url of the Discuz! built-in "latest replies" guide page.
const latestReplyUrl = '$baseUrl/forum.php?mod=guide&view=new';

/// Homepage section listing the latest replied threads.
///
/// Since the forum upgraded to Discuz! X5 the plugin that provided the homepage swiper and pinned threads is gone,
/// leaving the homepage almost empty. This section fills it with the forum's built-in latest replies guide page
/// (`forum.php?mod=guide&view=new`), which is visible to guests as well. Only the first [maxCount] threads are
/// shown here, the full list is one tap away on the latest thread page.
///
/// The section owns its [LatestThreadBloc]: the homepage rebuilds this widget after every refresh, so the list is
/// fetched again together with the rest of the homepage.
class LatestReplySection extends StatelessWidget {
  /// Constructor.
  const LatestReplySection({this.maxCount = 10, super.key});

  /// Maximum number of threads shown in the section.
  final int maxCount;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) =>
          LatestThreadBloc(latestThreadRepository: LatestThreadRepository())
            ..add(const LatestThreadRefreshRequested(latestReplyUrl)),
      child: BlocBuilder<LatestThreadBloc, LatestThreadState>(
        builder: (context, state) {
          final tr = context.t.homepage.latestReplySection;
          final body = switch (state.status) {
            LatestThreadStatus.initial || LatestThreadStatus.loading => const Padding(
              padding: edgeInsetsL12T12R12,
              child: CenteredCircularIndicator(),
            ),
            LatestThreadStatus.failed => ListTile(
              leading: const Icon(Icons.refresh_outlined),
              title: Text(tr.retry),
              onTap: () => context.read<LatestThreadBloc>().add(const LatestThreadRefreshRequested(latestReplyUrl)),
            ),
            LatestThreadStatus.success => Column(
              children: [
                ...state.threadList.take(maxCount).map(LatestThreadCard.new),
                ListTile(
                  leading: const Icon(Icons.more_horiz_outlined),
                  title: Text(tr.more),
                  onTap: () async =>
                      context.pushNamed(ScreenPaths.latestThread, queryParameters: {'url': latestReplyUrl}),
                ),
              ],
            ),
          };

          return Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: edgeInsetsL12T12R12,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(tr.title, style: Theme.of(context).textTheme.titleLarge),
                  sizedBoxW12H12,
                  body,
                  sizedBoxW12H12,
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
