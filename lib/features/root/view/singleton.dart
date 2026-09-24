import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/string.dart';
import 'package:tsdm_client/features/points/stream.dart';
import 'package:tsdm_client/features/root/bloc/points_changes_cubit.dart';
import 'package:tsdm_client/features/root/bloc/root_location_cubit.dart';
import 'package:tsdm_client/features/root/view/root_page.dart';
import 'package:tsdm_client/features/update/cubit/update_cubit.dart';
import 'package:tsdm_client/features/update/models/latest_version_info.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/utils/git_info.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/widgets/custom_alert_dialog.dart';

/// The app wide singleton stands on top of all other pages to act on different events in app.
class RootSingleton extends StatefulWidget {
  /// Constructor.
  const RootSingleton({super.key});

  @override
  State<RootSingleton> createState() => _RootSingletonState();
}

class _RootSingletonState extends State<RootSingleton> with LoggerMixin {
  late final StreamSubscription<String> _pointsChangesSub;
  bool _updateDialogOpen = false;

  Future<void> _showAvailableUpdate(LatestVersionInfo info) async {
    // This singleton is outside MaterialApp. The root navigator's overlay provides the dialog's
    // Navigator, theme and localizations, while reward/check-in snackbars cannot erase the notice.
    final dialogContext = router.routerDelegate.navigatorKey.currentState?.overlay?.context;
    if (_updateDialogOpen || dialogContext == null || !dialogContext.mounted) {
      return;
    }
    _updateDialogOpen = true;
    final tr = context.t;
    bool? openUpdate;
    try {
      openUpdate = await showDialog<bool>(
        context: dialogContext,
        builder: (context) {
          final size = MediaQuery.sizeOf(context);
          return RootPage(
            DialogPaths.updateNotice,
            CustomAlertDialog.sync(
              title: Text(tr.updatePage.availableDialog.title),
              content: SizedBox(
                width: math.min(size.width * 0.8, 800),
                height: math.min(size.height * 0.6, 600),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr.updatePage.availableDialog.version(version: info.version),
                      style: Theme.of(
                        context,
                      ).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
                    ),
                    sizedBoxW8H8,
                    Expanded(child: Markdown(data: info.changelog)),
                  ],
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(tr.general.cancel)),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(tr.settingsPage.othersSection.update),
                ),
              ],
            ),
          );
        },
      );
    } finally {
      _updateDialogOpen = false;
    }
    if ((openUpdate ?? false) && mounted && !context.read<RootLocationCubit>().isIn(ScreenPaths.update)) {
      unawaited(router.pushNamed<void>(ScreenPaths.update));
    }
  }

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
        BlocListener<PointsChangesCubit, PointsChangesValue>(
          listenWhen: (prev, curr) => prev != curr && curr != PointsChangesValue.empty,
          listener: (context, state) {
            final tr = context.t.pointsChangesDialog;

            final kinds = <String>[];
            if (state.ww != 0) {
              kinds.add(tr.points.ww(value: state.ww.withSign()));
            }
            if (state.tsb != 0) {
              kinds.add(tr.points.tsb(value: state.tsb.withSign()));
            }
            if (state.xc != 0) {
              kinds.add(tr.points.xc(value: state.xc.withSign()));
            }
            if (state.tr != 0) {
              kinds.add(tr.points.tr(value: state.tr.withSign()));
            }
            if (state.fh != 0) {
              kinds.add(tr.points.fh(value: state.fh.withSign()));
            }
            if (state.jl != 0) {
              kinds.add(tr.points.jl(value: state.jl.withSign()));
            }
            if (state.specialAttr != 0) {
              kinds.add(tr.points.specialAttr(value: state.specialAttr.withSign()));
            }
            if (state.specialAttr2 != 0) {
              kinds.add(tr.points.specialAttr2(value: state.specialAttr2.withSign()));
            }
            showSnackBar(context: context, message: kinds.join(tr.sep), clearPrevious: true);
          },
        ),
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
              unawaited(_showAvailableUpdate(info));
            }
          },
        ),
      ],
      child: const SizedBox.shrink(),
    );
  }
}

extension _SignedInteger on int {
  String withSign() => this < 0
      ? '$this'
      : this > 0
      ? '+$this'
      : '0';
}
