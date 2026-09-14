import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart' show Left, Right;
import 'package:go_router/go_router.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/achievements/cubit/achievements_cubit.dart';
import 'package:tsdm_client/features/achievements/models/achievement_page_data.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/utils/retry_button.dart';
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
        fetchPage: () async {
          final result = await getIt.get<NetClientProvider>().get(achievementsUrl).run();
          return switch (result) {
            Right(:final value) => value.data as String,
            Left(:final value) => throw value,
          };
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
        body = Center(
          child: TextButton(
            onPressed: () async {
              await context.pushNamed(ScreenPaths.login);
              if (mounted) await _cubit.load();
            },
            child: Text(tr.loginRequired),
          ),
        );
      } else if (state.failed) {
        body = buildRetryButton(context, () => unawaited(_cubit.load()), message: context.t.general.failedToLoad);
      } else {
        body = RefreshIndicator(
          onRefresh: _cubit.load,
          child: ListView(
            padding: const EdgeInsets.all(16),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (data?.empty ?? false) ...[
                const Padding(padding: EdgeInsets.all(24), child: Icon(Icons.emoji_events_outlined, size: 56)),
                Text(tr.empty, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(tr.emptyDetail, textAlign: TextAlign.center),
                ),
              ] else if (data?.recognized ?? false) ...[
                Text(tr.sourceNote),
                const SizedBox(height: 16),
                SelectionArea(child: Text(data!.content.isEmpty ? tr.notProvided : data.content)),
              ] else
                Text(data?.message.isNotEmpty ?? false ? data!.message : tr.unsupported),
              const SizedBox(height: 16),
              Text(tr.browserNotice),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.open_in_browser_outlined),
                  label: Text(tr.openBrowser),
                  onPressed: () async => context.dispatchAsUrl(achievementsUrl, external: true),
                ),
              ),
            ],
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
