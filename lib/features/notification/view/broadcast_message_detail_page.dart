import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/extensions/date_time.dart';
import 'package:tsdm_client/features/notification/bloc/broadcast_message_detail_cubit.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/utils/html/html_muncher.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';
import 'package:tsdm_client/widgets/single_line_text.dart';

/// Detail page of a `BroadcastMessage`.
final class BroadcastMessageDetailPage extends StatelessWidget {
  /// Constructor.
  const BroadcastMessageDetailPage({required this.pmid, super.key});

  /// Url to fetch the broadcast message detail data.
  final String pmid;

  Widget _buildBody(BuildContext context, BroadcastMessageDetailState state) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    // One reading surface: sender and date as the header, the message below, centered at a readable width.
    return AppCenteredList(
      maxWidth: appReadingMaxWidth,
      builder: (context, side, _) => SingleChildScrollView(
        padding: side.copyWith(top: 8, bottom: 12).add(context.safePadding()),
        child: AppSurface(
          padding: edgeInsetsL16T16R16B16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AppIconTile(
                    Icons.campaign_outlined,
                    color: colorScheme.tertiaryContainer,
                    foregroundColor: colorScheme.onTertiaryContainer,
                  ),
                  sizedBoxW12H12,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SingleLineText(
                          context.t.noticePage.broadcastMessageTab.system,
                          style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        if (state.dateTime != null)
                          Text(
                            state.dateTime!.yyyyMMDD(),
                            style: textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              const Divider(height: 24),
              munchElement(context, state.messageNode!),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(create: (_) => NotificationRepository()),
        BlocProvider(
          create: (context) {
            final cubit = BroadcastMessageDetailCubit(context.repo());
            unawaited(cubit.fetchDetail(pmid));
            return cubit;
          },
        ),
      ],
      child: BlocBuilder<BroadcastMessageDetailCubit, BroadcastMessageDetailState>(
        builder: (context, state) {
          final body = switch (state.status) {
            BroadcastMessageDetailStatus.initial ||
            BroadcastMessageDetailStatus.loading => const CenteredCircularIndicator(),
            BroadcastMessageDetailStatus.success => _buildBody(context, state),
            BroadcastMessageDetailStatus.failed => buildRetryButton(context, () async {
              await context.read<BroadcastMessageDetailCubit>().fetchDetail(pmid);
            }),
          };

          return Scaffold(
            appBar: AppBar(
              title: Text(context.t.noticePage.broadcastMessageTab.title),
              actions: [
                IconButton(
                  icon: const Icon(Icons.open_in_new_outlined),
                  tooltip: context.t.general.openInBrowser,
                  onPressed: () async => context.dispatchAsUrl('$broadcastMessageDetailUrl$pmid', external: true),
                ),
              ],
            ),
            body: SafeArea(top: false, bottom: false, child: body),
          );
        },
      ),
    );
  }
}
