import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/achievements/cubit/achievements_cubit.dart';
import 'package:tsdm_client/features/achievements/models/achievement_page_data.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/retry_button.dart';
import 'package:tsdm_client/widgets/app_surface.dart';
import 'package:tsdm_client/widgets/indicator.dart';

/// Current account's achievements as supplied by the forum, without reward actions.
class AchievementsPage extends StatefulWidget {
  /// An injected controller is owned by its caller.
  const AchievementsPage({super.key, this.controller});

  /// Optional controller for deterministic tests.
  final AchievementsCubit? controller;
  @override
  State<AchievementsPage> createState() => _AchievementsPageState();
}

class _AchievementsPageState extends State<AchievementsPage> {
  late final AchievementsCubit _cubit;
  StreamSubscription<AuthStatus>? _authSubscription;

  @override
  void initState() {
    super.initState();
    if (widget.controller case final controller?) {
      _cubit = controller;
    } else {
      final auth = context.read<AuthenticationRepository>();
      _cubit = AchievementsCubit(
        currentUid: () => auth.effectiveCurrentUid,
        fetchPage: () => fetchTsdmAppPageHtml(getIt.get<NetClientProvider>(), achievementsUrl),
        ensureStatus: () => TsdmAppApi.ensureStatus(getIt.get<NetClientProvider>()),
        fetchApi: () async =>
            switch (await getIt.get<NetClientProvider>().get(withTsdmAppV4Page(achievementsUrl)).run()) {
              Right(:final value) => value.data,
              Left(:final value) => throw value,
            },
      );
      _authSubscription = auth.status.listen((status) {
        _cubit.invalidate();
        if (status is! AuthStatusLoading) unawaited(_cubit.load());
      });
    }
    unawaited(_cubit.load());
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    if (widget.controller == null) unawaited(_cubit.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => BlocBuilder<AchievementsCubit, AchievementsState>(
    bloc: _cubit,
    builder: (context, state) {
      final tr = context.t.achievementsPage;
      final data = state.data;
      final Widget body;
      if (state.loading) {
        body = const CenteredCircularIndicator();
      } else if (state.needLogin) {
        body = AppStateView(
          icon: Icons.login,
          message: tr.loginRequired,
          action: FilledButton.tonalIcon(
            onPressed: () async {
              await context.pushNamed(ScreenPaths.login);
              if (mounted) await _cubit.load();
            },
            icon: const Icon(Icons.login),
            label: Text(context.t.loginPage.login),
          ),
        );
      } else if (state.failed) {
        body = buildRetryButton(context, () => unawaited(_cubit.load()), message: context.t.general.failedToLoad);
      } else {
        final colorScheme = Theme.of(context).colorScheme;
        final textTheme = Theme.of(context).textTheme;
        body = RefreshIndicator(
          onRefresh: _cubit.load,
          child: AppCenteredList(
            maxWidth: appFormMaxWidth,
            builder: (context, padding, _) => ListView(
              padding: padding.copyWith(top: 12, bottom: 12),
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (data?.empty ?? false)
                  AppSurface(
                    padding: edgeInsetsL16T16R16B16,
                    child: Column(
                      children: [
                        const AppIconTile(Icons.emoji_events_outlined, size: 64),
                        sizedBoxW12H12,
                        Text(tr.empty, textAlign: TextAlign.center, style: textTheme.titleMedium),
                        sizedBoxW8H8,
                        Text(
                          tr.emptyDetail,
                          textAlign: TextAlign.center,
                          style: textTheme.bodyMedium?.copyWith(color: colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  )
                else if (data?.recognized ?? false)
                  AppSurface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AppSectionHeader(
                          tr.title,
                          icon: Icons.emoji_events_outlined,
                          padding: const EdgeInsets.only(bottom: 4),
                        ),
                        Text(tr.sourceNote, style: textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant)),
                        sizedBoxW12H12,
                        AppInsetBlock(
                          padding: edgeInsetsL12T12R12B12,
                          child: SelectionArea(child: Text(data!.content.isEmpty ? tr.notProvided : data.content)),
                        ),
                      ],
                    ),
                  )
                else
                  AppNoticeBanner(
                    message: data?.message.isNotEmpty ?? false ? data!.message : tr.unsupported,
                    tone: AppNoticeTone.warning,
                    selectable: true,
                  ),
                sizedBoxW12H12,
                AppSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline, size: 20, color: colorScheme.primary),
                          sizedBoxW8H8,
                          Expanded(child: Text(tr.browserNotice)),
                        ],
                      ),
                      sizedBoxW8H8,
                      OutlinedButton.icon(
                        icon: const Icon(Icons.open_in_browser_outlined),
                        label: Text(tr.openBrowser),
                        onPressed: () async => context.dispatchAsUrl(achievementsUrl, external: true),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(
          title: Text(tr.title),
          actions: [
            IconButton(
              tooltip: tr.refresh,
              icon: const Icon(Icons.refresh),
              onPressed: state.loading ? null : _cubit.load,
            ),
          ],
        ),
        body: SafeArea(child: body),
      );
    },
  );
}
