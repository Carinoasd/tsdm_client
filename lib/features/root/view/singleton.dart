import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/points/stream.dart';
import 'package:tsdm_client/features/root/bloc/points_changes_cubit.dart';
import 'package:tsdm_client/features/root/bloc/root_location_cubit.dart';
import 'package:tsdm_client/features/update/cubit/update_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/git_info.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';

/// The app wide singleton stands on top of all other pages to act on different events in app.
class RootSingleton extends StatefulWidget {
  /// Constructor.
  const RootSingleton({super.key});

  @override
  State<RootSingleton> createState() => _RootSingletonState();
}

class _RootSingletonState extends State<RootSingleton> with LoggerMixin {
  late final StreamSubscription<String> _pointsChangesSub;

  /// Act on points changes events.
  ///
  /// Each event is a Discuz! `creditnotice` cookie value, parsed by
  /// [PointsChangesValue.fromCreditNotice] and forwarded to the cubit.
  void _onPointsChanges(String event) {
    final value = PointsChangesValue.fromCreditNotice(event);
    if (value == null) {
      info('ignore invalid points changes event: "$event"');
      return;
    }
    context.read<PointsChangesCubit>().recordsChanges(value);
  }

  @override
  void initState() {
    super.initState();
    _pointsChangesSub = pointsChangesStream.stream.listen(_onPointsChanges);
  }

  @override
  void dispose() {
    unawaited(_pointsChangesSub.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<UpdateCubit, UpdateCubitState>(
          listenWhen: (prev, curr) => !curr.loading && prev.loading,
          listener: (context, state) {
            final info = state.latestVersionInfo;
            final tr = context.t.updatePage;
            if (info == null) {
              error('failed to check update state');
              if (state.notice) {
                showSnackBar(context: context, message: tr.failed);
              }
              return;
            }

            final inUpdatePage = context.read<RootLocationCubit>().isIn(ScreenPaths.update);

            if (info.versionCode <= appVersion.split('+').last.parseToInt()!) {
              // Only show the already latest message in update page.
              if (inUpdatePage) {
                showSnackBar(context: context, message: tr.alreadyLatest);
              }
            } else if (!inUpdatePage) {
              showSnackBar(
                context: context,
                message: tr.availableDialog.title,
                action: SnackBarAction(
                  label: context.t.settingsPage.othersSection.update,
                  onPressed: () => router.pushNamed(ScreenPaths.update),
                ),
              );
            }
          },
        ),
      ],
      child: const SizedBox.shrink(),
    );
  }
}
