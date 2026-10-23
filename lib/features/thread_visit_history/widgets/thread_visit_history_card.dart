import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/reading_progress/cubit/reading_progress_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/widgets/app_surface.dart';

/// Card to show a record of thread visit history.
///
/// Title first, then author, forum and visit time as pills that wrap on narrow windows or with a large font.
class ThreadVisitHistoryCard extends StatelessWidget {
  /// Constructor.
  const ThreadVisitHistoryCard(this.model, {super.key});

  /// History data to show.
  final ThreadVisitHistoryModel model;

  /// The floor the account of this record read to, when it went past the first screen.
  int? _readFloor(BuildContext context) {
    if (context.readOrNull<ReadingProgressCubit>() == null) {
      return null;
    }
    final uid = context.select<ReadingProgressCubit, int?>((cubit) => cubit.state.uid);
    final progress = readingProgressOf(context, '${model.threadId}');
    return uid == model.uid && progress != null && progress.pastFirstScreen ? progress.floor : null;
  }

  @override
  Widget build(BuildContext context) {
    return AppSurface(
      padding: edgeInsetsL12T12R12B12,
      onTap: () async => context.pushNamed(ScreenPaths.threadV1, queryParameters: {'tid': '${model.threadId}'}),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppIconTile(Icons.history_outlined, size: 36),
          sizedBoxW12H12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  model.threadTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                sizedBoxW8H8,
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    AppInfoPill(icon: Icons.person_outline, label: model.username),
                    AppInfoPill(icon: Icons.forum_outlined, label: model.forumName),
                    AppInfoPill(icon: Icons.access_time_outlined, label: model.visitTime.yyyyMMDDHHMMSS()),
                    // How far the reading went: opening the thread goes on from there.
                    if (_readFloor(context) case final floor?)
                      AppInfoPill(
                        key: const ValueKey('visit-history-read-to'),
                        icon: Icons.bookmark_outline,
                        label: context.t.threadVisitHistoryPage.readTo(floor: floor),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
