import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/extensions/fp.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/chinese_display/chinese_display.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';
import 'package:tsdm_client/widgets/heroes.dart';
import 'package:tsdm_client/widgets/single_line_text.dart';

/// Card shows thread operation log.
class OperationLogCard extends StatelessWidget {
  /// Constructor.
  const OperationLogCard({required this.latestAction, required this.tid, super.key});

  /// The latest action to show.
  final String latestAction;

  /// Thread id.
  final String tid;

  Future<void> _showOperationLogDialog(BuildContext context, String tid) async {
    final tr = context.t.threadPage.operationLog;
    await showDialog<void>(
      context: context,
      builder: (_) {
        return RootPage(
          DialogPaths.showOperationLog,
          CustomAlertDialog.future(
            title: Row(
              children: [
                const AppIconTile(Icons.manage_history_outlined, size: 36),
                sizedBoxW12H12,
                Expanded(child: Text(tr.title)),
              ],
            ),
            future: context.read<ThreadRepository>().fetchOperationLog(tid).run(),
            successBuilder: (context, data) {
              if (data.isLeft()) {
                return AppNoticeBanner(tone: AppNoticeTone.error, message: context.t.general.failedToLoad);
              }

              final colorScheme = Theme.of(context).colorScheme;
              final textTheme = Theme.of(context).textTheme;
              // One block per operation: operator (opens the profile), time, and the action in the primary color.
              final content = data.unwrap().map(
                (e) => AppInsetBlock(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      GestureDetector(
                        onTap: () async =>
                            context.pushNamed(ScreenPaths.profile, queryParameters: {'username': e.username}),
                        child: HeroUserAvatar(username: e.username, avatarUrl: null, disableHero: true),
                      ),
                      sizedBoxW12H12,
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            GestureDetector(
                              onTap: () async =>
                                  context.pushNamed(ScreenPaths.profile, queryParameters: {'username': e.username}),
                              child: Text(
                                e.username,
                                style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                              ),
                            ),
                            SingleLineText(
                              e.time.yyyyMMDDHHMMSS(),
                              style: textTheme.labelSmall?.copyWith(color: colorScheme.outline),
                            ),
                            sizedBoxW4H4,
                            Text(
                              context.displayText('${e.action}${e.duration != null ? "（${e.duration}）" : ""}'),
                              style: textTheme.bodyMedium?.copyWith(color: colorScheme.primary),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );

              return Column(
                spacing: 8,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: content.toList(),
              );
            },
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // A tappable inset row: the latest moderation, the full log behind the chevron.
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(appInnerRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async => _showOperationLogDialog(context, tid),
        child: Padding(
          padding: edgeInsetsL12T8R12B8,
          child: Row(
            children: [
              Icon(Icons.manage_history_outlined, size: 18, color: colorScheme.primary),
              sizedBoxW8H8,
              Expanded(
                child: Text(
                  context.displayText(latestAction),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                ),
              ),
              Icon(Icons.chevron_right, size: 18, color: colorScheme.outline),
            ],
          ),
        ),
      ),
    );
  }
}
