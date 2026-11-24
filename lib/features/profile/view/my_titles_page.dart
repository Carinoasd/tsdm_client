import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/profile/bloc/current_title_cubit.dart';
import 'package:tsdm_client/features/profile/bloc/my_titles_cubit.dart';
import 'package:tsdm_client/features/profile/repository/my_titles_repository.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_badge.dart';
import 'package:tsdm_client/features/profile/widgets/secondary_title_card.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Preferred width of a title card; the grid fits as many as the width allows.
const _cardExtent = 208.0;

/// Spacing between title cards.
const _cardSpacing = 12.0;

/// Page showing current user's titles.
///
/// With link to visit title shop.
class MyTitlesPage extends StatefulWidget {
  /// Constructor.
  const MyTitlesPage({super.key});

  @override
  State<MyTitlesPage> createState() => _MyTitlesPageState();
}

class _MyTitlesPageState extends State<MyTitlesPage> {
  @override
  Widget build(BuildContext context) {
    final tr = context.t.myTitlesPage;
    return MultiBlocProvider(
      providers: [
        RepositoryProvider(
          create: (_) => MyTitlesRepository(),
        ),
        BlocProvider(
          create: (context) {
            // The page belongs to the account logged in when it opened: hand what it reads over to the current title
            // badge only for that account.
            final uid = context.readOrNull<AuthenticationRepository>()?.currentUser?.uid;
            final currentTitle = context.readOrNull<CurrentTitleCubit>();
            final cubit = MyTitlesCubit(
              context.repo(),
              onTitlesChanged: currentTitle == null ? null : (titles) => currentTitle.record(uid: uid, titles: titles),
            );
            unawaited(cubit.fetchAvailableSecondaryTitles());
            return cubit;
          },
        ),
      ],
      child: BlocConsumer<MyTitlesCubit, MyTitlesState>(
        listener: (context, state) {
          if (state.status == MyTitlesStatus.failure) {
            showSnackBar(context: context, message: context.t.general.failedToLoad);
          }
        },
        builder: (context, state) {
          final body = switch (state.status) {
            MyTitlesStatus.initial || MyTitlesStatus.loadingTitles => const CenteredCircularIndicator(),
            MyTitlesStatus.failure when state.titles.isEmpty => buildRetryButton(
              context,
              () async => context.read<MyTitlesCubit>().fetchAvailableSecondaryTitles(),
            ),
            MyTitlesStatus.switchingTitle || MyTitlesStatus.success || MyTitlesStatus.failure => ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: SingleChildScrollView(
                padding: edgeInsetsL16T16R16B16,
                child: AppContentWidth(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _CurrentTitleHeader(state),
                      sizedBoxW16H16,
                      if (state.titles.isEmpty)
                        Padding(
                          padding: edgeInsetsT12,
                          child: Text(
                            tr.empty,
                            textAlign: TextAlign.center,
                            style: Theme.of(
                              context,
                            ).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                        )
                      else
                        LayoutBuilder(
                          builder: (context, constraints) {
                            final columns = ((constraints.maxWidth + _cardSpacing) / (_cardExtent + _cardSpacing))
                                .floor()
                                .clamp(1, 8);
                            final width = (constraints.maxWidth - _cardSpacing * (columns - 1)) / columns;
                            return Wrap(
                              spacing: _cardSpacing,
                              runSpacing: _cardSpacing,
                              children: state.titles
                                  .map(
                                    (e) => SizedBox(
                                      width: width,
                                      child: SecondaryTitleCard(e, key: ValueKey(e.id)),
                                    ),
                                  )
                                  .toList(),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
            ),
          };

          return Scaffold(
            appBar: AppBar(
              title: Text(tr.title),
              actions: [
                IconButton(
                  icon: const Icon(Icons.shopping_bag_outlined),
                  tooltip: tr.openTitleShop,
                  onPressed: () async {
                    final cubit = context.read<MyTitlesCubit>();
                    await context.pushNamed(ScreenPaths.titleShop);
                    // A purchase adds an owned title (never equipped); show it on return.
                    if (!cubit.isClosed) await cubit.fetchAvailableSecondaryTitles();
                  },
                ),
              ],
            ),
            body: SafeArea(top: false, child: body),
          );
        },
      ),
    );
  }
}

/// The title in use with its image, the unset action and a hint on how to switch.
class _CurrentTitleHeader extends StatelessWidget {
  const _CurrentTitleHeader(this.state);

  final MyTitlesState state;

  @override
  Widget build(BuildContext context) {
    final tr = context.t.myTitlesPage;
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final current = state.titles.firstWhereOrNull((v) => v.activated);
    final description = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          current == null ? tr.noneActivated : tr.activated(name: current.name),
          style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        if (state.titles.isNotEmpty) ...[
          sizedBoxW4H4,
          Text(tr.tapToUse, style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
        ],
      ],
    );
    final unset = current == null
        ? null
        : TextButton(
            onPressed: state.status == MyTitlesStatus.switchingTitle
                ? null
                : () async => context.read<MyTitlesCubit>().unsetSecondaryTitle(),
            child: Text(tr.unset),
          );
    return AppSurface(
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The title in use at its natural 184px width when there is room, complete in any case.
          final badgeWidth = SecondaryTitleBadge.fitWidth(constraints.maxWidth);
          final Widget leading = current != null
              ? SecondaryTitleBadge(current.imageUrl, width: badgeWidth, semanticLabel: current.name)
              : Icon(Icons.lightbulb_outline, color: colorScheme.onSurfaceVariant);
          // Side by side only when the text keeps a readable width next to the badge.
          if (current == null || constraints.maxWidth - badgeWidth >= 240) {
            return Row(
              children: [
                leading,
                sizedBoxW12H12,
                Expanded(child: description),
                if (unset != null) ...[sizedBoxW8H8, unset],
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              leading,
              sizedBoxW12H12,
              Row(
                children: [
                  Expanded(child: description),
                  if (unset != null) ...[sizedBoxW8H8, unset],
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
