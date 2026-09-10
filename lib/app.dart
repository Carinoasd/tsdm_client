import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_styled_toast/flutter_styled_toast.dart';
import 'package:tsdm_client/constants/layout.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/cache/bloc/image_cache_trigger_cubit.dart';
import 'package:tsdm_client/features/cache/repository/image_cache_repository.dart';
import 'package:tsdm_client/features/checkin/bloc/auto_checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/bloc/checkin_bloc.dart';
import 'package:tsdm_client/features/checkin/repository/auto_checkin_repository.dart';
import 'package:tsdm_client/features/checkin/repository/checkin_repository.dart';
import 'package:tsdm_client/features/favorite/repository/favorite_repository.dart';
import 'package:tsdm_client/features/forum/repository/forum_repository.dart';
import 'package:tsdm_client/features/home/cubit/init_cubit.dart';
import 'package:tsdm_client/features/local_notice/show.dart';
import 'package:tsdm_client/features/notification/bloc/auto_notification_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_bloc.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_auto_sync_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_state_cubit.dart';
import 'package:tsdm_client/features/notification/bloc/notification_sync_all_cubit.dart';
import 'package:tsdm_client/features/notification/models/models.dart';
import 'package:tsdm_client/features/notification/repository/notification_info_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_repository.dart';
import 'package:tsdm_client/features/notification/repository/notification_sync_all_repository.dart';
import 'package:tsdm_client/features/profile/repository/profile_repository.dart';
import 'package:tsdm_client/features/replied_thread/cubit/replied_thread_cubit.dart';
import 'package:tsdm_client/features/root/bloc/points_changes_cubit.dart';
import 'package:tsdm_client/features/root/bloc/root_location_cubit.dart';
import 'package:tsdm_client/features/session_expiry/cubit/session_expiry_cubit.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/theme/cubit/theme_cubit.dart';
import 'package:tsdm_client/features/thread_visit_history/bloc/thread_visit_history_bloc.dart';
import 'package:tsdm_client/features/thread_visit_history/repository/thread_visit_history_repository.dart';
import 'package:tsdm_client/features/update/cubit/update_cubit.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/app_routes.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/forum_home_repository/forum_home_repository.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/themes/app_themes.dart';
import 'package:tsdm_client/utils/logger.dart';
import 'package:tsdm_client/utils/platform.dart';
import 'package:tsdm_client/utils/show_dialog.dart';
import 'package:tsdm_client/utils/show_toast.dart';
import 'package:tsdm_client/utils/window_events.dart';
import 'package:window_manager/window_manager.dart';

extension _SignedInteger on int {
  String withSign() => this < 0
      ? '$this'
      : this > 0
      ? '+$this'
      : '0';
}

/// Main app for tsdm_client.
class App extends StatefulWidget {
  /// Constructor.
  const App(
    this.color,
    this.themeModeIndex, {
    required this.autoCheckin,
    required this.autoSyncNoticeSeconds,
    required this.fontFamily,
    required this.checkUpdate,
    super.key,
  });

  /// Initial color value.
  final int color;

  /// Initial theme mode index.
  final int themeModeIndex;

  /// Run auto checkin at startup or not.
  final bool autoCheckin;

  /// Duration to sync notice from server.
  final int autoSyncNoticeSeconds;

  /// Font family.
  final String fontFamily;

  /// Check update on app startup.
  final bool checkUpdate;

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> with WindowListener, WidgetsBindingObserver, LoggerMixin {
  /// Duration used to debounce the frequency to save window attributes into
  /// storage.
  ///
  /// Only save the latest value to storage if in recent duration no more attr
  /// changes triggered.
  static const _syncDebounceDuration = Duration(milliseconds: 80);

  /// The same value in flutter/lib/src/material/snack_bar.dart;
  static const Duration _snackBarDisplayDuration = Duration(milliseconds: 4000 - 1000);

  /// Temporary store of current window position value.
  Offset _windowPosition = Offset.zero;

  /// Temporary store of current window size value.
  Size _windowSize = Size.zero;

  /// Timer to debounce the saving progress of window position.
  ///
  /// Save [_windowPosition] to storage when timer timeout.
  Timer? windowPositionTimer;

  /// Timer to debounce the saving progress of window size.
  ///
  /// Save [_windowSize] to storage when timer timeout.
  Timer? windowSizeTimer;

  /// Which metrics changes get a log line (GitHub #28).
  final _viewMetricsLogGate = ViewMetricsLogGate();

  void setupWindowPositionTimer() {
    if (windowPositionTimer?.isActive ?? false) {
      windowPositionTimer!.cancel();
    }
    windowPositionTimer = Timer(_syncDebounceDuration, () async {
      talker.debug('save window position to $_windowPosition');
      final settings = getIt.get<SettingsRepository>().currentSettings;
      if (!settings.windowRememberPosition || settings.windowInCenter) {
        // Do nothing if not remembering window position, or window forced in
        // center.
        return;
      }
      // FIXME: Access provider in top-level components is anti-pattern.
      await getIt.get<StorageProvider>().saveOffset(SettingsKeys.windowPosition.name, _windowPosition);
    });
  }

  void setupWindowSizeTimer() {
    if (windowSizeTimer?.isActive ?? false) {
      windowSizeTimer!.cancel();
    }
    windowSizeTimer = Timer(_syncDebounceDuration, () async {
      talker.debug('save window size to $_windowPosition');
      final settings = getIt.get<SettingsRepository>().currentSettings;
      if (!settings.windowRememberSize) {
        // Do nothing if not remembering window size.
        return;
      }
      // FIXME: Access provider in top-level components is anti-pattern.
      await getIt.get<StorageProvider>().saveSize(SettingsKeys.windowSize.name, _windowSize);
    });
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    windowPositionTimer?.cancel();
    windowSizeTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Foreground/background moments anchor the notification tap lines in an exported log: a tap the OS delivers
    // arrives before the resume; a resume with no tap line only says the app came to front without a tap reaching
    // it, whatever brought it there (#14).
    debug('app lifecycle: ${state.name}');
    if (state == AppLifecycleState.resumed) {
      unawaited(logActiveLocalNotifications());
      _logViewMetrics('resumed', always: true);
    }
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    _logViewMetrics('metrics changed');
  }

  /// Log the metrics the framework lays out with, and once more after the next frame so an exported log shows
  /// whether a frame followed the change (GitHub #28: a resize that never reaches the screen). [always] logs even
  /// when nothing changed since the last line, for the resume anchor.
  void _logViewMetrics(String reason, {bool always = false}) {
    final view = View.maybeOf(context);
    if (view == null) {
      return;
    }
    final changed = _viewMetricsLogGate.accept(view);
    if (!changed && !always) {
      return;
    }
    debug('$reason: ${describeViewMetrics(view)}');
    if (changed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => debug('frame painted: ${describeViewMetrics(view)}'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tr = context.t.globalStatePage;

    return MultiRepositoryProvider(
      providers: [
        RepositoryProvider<NotificationInfoRepository>(
          create: (_) => NotificationInfoRepository(),
          dispose: (repo) async => repo.dispose(),
        ),
        RepositoryProvider<NotificationRepository>(
          create: (_) => NotificationRepository(),
          dispose: (repo) async => repo.dispose(),
        ),
        RepositoryProvider<AuthenticationRepository>(
          create: (_) => AuthenticationRepository(),
          dispose: (repo) async => repo.dispose(),
        ),
        RepositoryProvider<CheckinRepository>(create: (_) => CheckinRepository(storageProvider: getIt())),
        RepositoryProvider<ForumHomeRepository>(
          create: (_) => ForumHomeRepository(),
          dispose: (repo) async => repo.dispose(),
        ),
        RepositoryProvider<FavoriteRepository>(
          create: (_) => FavoriteRepository(),
          dispose: (repo) async => repo.dispose(),
        ),
        RepositoryProvider<ProfileRepository>(create: (_) => ProfileRepository()),
        RepositoryProvider<FragmentsRepository>(create: (_) => FragmentsRepository()),
        RepositoryProvider<ForumRepository>(create: (_) => ForumRepository()),
        RepositoryProvider<ImageCacheRepository>(
          create: (_) => ImageCacheRepository(getIt()),
          dispose: (repo) async => repo.dispose(),
        ),
        RepositoryProvider<ImageCacheTriggerCubit>(create: (context) => ImageCacheTriggerCubit(context.repo())),
        RepositoryProvider<ThreadVisitHistoryRepo>(create: (_) => ThreadVisitHistoryRepo(getIt.get<StorageProvider>())),
        RepositoryProvider<AutoCheckinRepository>(
          create: (_) => AutoCheckinRepository(storageProvider: getIt()),
          dispose: (repo) async => repo.dispose(),
        ),
        RepositoryProvider<NotificationSyncAllRepository>(
          create: (context) =>
              NotificationSyncAllRepository(storageProvider: getIt(), notificationRepository: context.repo()),
          dispose: (repo) async => repo.dispose(),
        ),
      ],
      child: MultiBlocProvider(
        providers: [
          BlocProvider(create: (context) => NotificationStateAutoSyncCubit(context.repo())),
          BlocProvider(
            create: (_) => RootLocationCubit(),
            // Set lazy to false to react on first location change.
            lazy: false,
          ),
          BlocProvider(create: (context) => NotificationStateCubit(context.repo())),
          BlocProvider(
            create: (context) {
              final bloc = AutoNotificationCubit(
                authenticationRepository: context.repo(),
                notificationRepository: context.repo(),
                storageProvider: getIt(),
              );
              if (widget.autoSyncNoticeSeconds > 0) {
                bloc.start(Duration(seconds: widget.autoSyncNoticeSeconds));
              }
              return bloc;
            },
          ),
          BlocProvider(
            create: (context) => NotificationBloc(
              notificationRepository: context.repo(),
              infoRepository: context.repo(),
              authRepo: context.repo(),
              storageProvider: getIt(),
            ),
          ),
          // Top level: leaving the progress page must not cancel the run, like the auto checkin.
          BlocProvider(
            create: (context) => NotificationSyncAllCubit(
              repository: context.repo(),
              storageProvider: getIt(),
              authenticationRepository: context.repo(),
              infoRepository: context.repo(),
              autoNotificationCubit: context.read<AutoNotificationCubit>(),
              notificationBloc: context.read<NotificationBloc>(),
            ),
          ),
          BlocProvider(
            create: (context) =>
                SettingsBloc(fragmentsRepository: context.repo(), settingsRepository: getIt.get<SettingsRepository>()),
          ),
          BlocProvider(
            create: (context) =>
                ThreadVisitHistoryBloc(context.repo())..add(const ThreadVisitHistoryFetchAllRequested()),
          ),
          // Become top-level because of background auto-checkin feature.
          BlocProvider(
            create: (context) => CheckinBloc(
              checkinRepository: context.repo(),
              authenticationRepository: context.repo(),
              settingsRepository: getIt(),
            ),
          ),
          BlocProvider(
            create: (context) {
              final bloc = AutoCheckinBloc(
                autoCheckinRepository: context.repo(),
                settingsRepository: getIt(),
                storageProvider: getIt(),
              );
              if (widget.autoCheckin) {
                bloc.add(const AutoCheckinStartRequested());
              }
              return bloc;
            },
          ),
          BlocProvider(
            create: (context) => ThemeCubit(
              accentColor: widget.color >= 0 ? Color(widget.color) : null,
              themeModeIndex: widget.themeModeIndex,
              fontFamily: widget.fontFamily,
            ),
          ),
          BlocProvider(
            create: (context) {
              final cubit = UpdateCubit();
              if (widget.checkUpdate) {
                // We intend to spawn the check process asynchronously, so do not wait it.
                unawaited(cubit.checkUpdate(delay: const Duration(seconds: 1), notice: false));
              }
              return cubit;
            },
          ),
          BlocProvider(create: (_) => PointsChangesCubit()),
          // Local "replied" marks of the current account for thread lists and the thread page (issue #21); not lazy
          // so the marks are loaded before the first list shows.
          BlocProvider(
            create: (context) => RepliedThreadCubit(storageProvider: getIt(), authenticationRepository: context.repo()),
            lazy: false,
          ),
          // Tells once per run which stored accounts have an expired login, and again when the account in use
          // expires while the app runs (issue #25).
          BlocProvider(
            create: (context) {
              final auth = context.repo<AuthenticationRepository>();
              return SessionExpiryCubit(storageProvider: getIt(), currentUid: () => auth.effectiveCurrentUid)..start();
            },
            lazy: false,
          ),
          BlocProvider(
            create: (context) {
              final settings = context.read<SettingsBloc>().state.settingsMap;

              final cubit = InitCubit();
              // We intend to delete legacy files asynchronously, so do not wait it.
              unawaited(cubit.deleteV0LegacyData());
              if (settings.enableAutoClearImageCache) {
                unawaited(cubit.autoClearImageCache(Duration(seconds: settings.autoClearImageCacheDuration)));
              } else {
                cubit.skipAutoClearImageCache();
              }
              unawaited(cubit.autoClearFilePickerCache());
              return cubit;
            },
          ),
        ],
        child: MultiBlocListener(
          listeners: [
            BlocListener<AutoCheckinBloc, AutoCheckinState>(
              listenWhen: (prev, curr) => prev is! AutoCheckinStateFinished && curr is AutoCheckinStateFinished,
              listener: (context, state) {
                if (state is AutoCheckinStateFinished) {
                  talker.debug(
                    'auto checkin finished: succeeded=${state.succeeded.length} failed=${state.failed.length}',
                  );
                  showSnackBar(
                    context: context,
                    message: tr.autoCheckinFinished,
                    clearPrevious: true,
                    // No close icon: with it the bar wrapped onto two rows on small screens (issue #4); swipe,
                    // the action and the timeout still dismiss it.
                    actionOverflowThreshold: 0.6,
                    action: SnackBarAction(
                      label: tr.viewDetail,
                      onPressed: () async => router.pushNamed(ScreenPaths.autoCheckinDetail),
                    ),
                  );
                }
              },
            ),
            BlocListener<NotificationSyncAllCubit, NotificationSyncAllState>(
              listenWhen: (prev, curr) =>
                  prev is! NotificationSyncAllStateFinished && curr is NotificationSyncAllStateFinished,
              listener: (context, state) {
                if (state is NotificationSyncAllStateFinished) {
                  talker.debug('sync all accounts finished: ${state.results.length} account(s)');
                  // The progress page shows the result already: no action to open it again on top of itself.
                  final onPage = context.read<RootLocationCubit>().currentPath == ScreenPaths.notificationSyncAll;
                  showSnackBar(
                    context: context,
                    message: tr.syncAllFinished,
                    clearPrevious: true,
                    actionOverflowThreshold: 0.6,
                    action: onPage
                        ? null
                        : SnackBarAction(
                            label: tr.viewDetail,
                            onPressed: () async => router.pushNamed(ScreenPaths.notificationSyncAll),
                          ),
                  );
                }
              },
            ),
            BlocListener<SessionExpiryCubit, SessionExpiryState>(
              listenWhen: (prev, curr) => prev.noticeSeq != curr.noticeSeq,
              listener: (context, state) {
                // The manage accounts page shows the expired accounts already: no action to open it on top of itself.
                final onPage = context.read<RootLocationCubit>().currentPath == ScreenPaths.manageAccount;
                showSnackBar(
                  context: context,
                  message: tr.sessionExpired.message(count: state.noticeCount),
                  actionOverflowThreshold: 0.6,
                  action: onPage
                      ? null
                      : SnackBarAction(
                          label: tr.sessionExpired.view,
                          onPressed: () async => router.pushNamed(ScreenPaths.manageAccount),
                        ),
                );
              },
            ),
            BlocListener<NotificationBloc, NotificationState>(
              listener: (context, state) {
                if (state.status == NotificationStatus.loading) {
                  final autoSyncState = context.read<AutoNotificationCubit>();
                  if (autoSyncState.state is AutoNoticeStateTicking) {
                    // Restart the auto notification sync process.
                    context.read<AutoNotificationCubit>().restart();
                  }
                } else if (state.status == NotificationStatus.success) {
                  // Update last fetch notification time.
                  // We do it here because it's a global action lives in the entire lifetime of the app, not only when
                  // the notification page is live. This fixes the critical issue where time not updated.
                  if (state.latestTime != null) {
                    context.read<NotificationBloc>().add(NotificationRecordFetchTimeRequested(state.latestTime!));
                  }
                }
              },
            ),
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
                showToast(
                  kinds.join(tr.sep),
                  context: context,
                  duration: _snackBarDisplayDuration,
                  position: const StyledToastPosition(align: Alignment.topCenter, offset: kToolbarHeight),
                  textStyle: Theme.of(context).snackBarTheme.contentTextStyle,
                  backgroundColor: Theme.of(context).snackBarTheme.backgroundColor,
                );
              },
            ),
            BlocListener<NotificationStateAutoSyncCubit, NotificationAutoSyncInfo?>(
              listenWhen: (prev, curr) => curr != null && prev != curr,
              listener: (context, state) async {
                await showLocalNotification(context, state!);
              },
            ),
            BlocListener<InitCubit, InitState>(
              listenWhen: (prev, curr) => prev.v0LegacyDataDeleted != curr.v0LegacyDataDeleted,
              listener: (context, state) async {
                if (!state.v0LegacyDataDeleted) {
                  return;
                }
                final tr = context.t.init.v1DeleteLegacyData;
                await showMessageSingleButtonDialog(context: context, title: tr.title, message: tr.detail);
              },
            ),
          ],
          child: BlocBuilder<ThemeCubit, ThemeState>(
            buildWhen: (prev, curr) => prev != curr,
            builder: (context, state) {
              final themeState = context.watch<ThemeCubit>().state;
              final accentColor = themeState.accentColor;
              final themeModeIndex = themeState.themeModeIndex;
              final fontFamily = themeState.fontFamily;
              final textScaleFactor = context.select<SettingsBloc, double>(
                (bloc) => bloc.state.settingsMap.textScaleFactor,
              );

              final lightTheme = AppTheme.makeLight(context, seedColor: accentColor, fontFamily: fontFamily);
              final darkTheme = AppTheme.makeDark(context, seedColor: accentColor, fontFamily: fontFamily);

              return MaterialApp.router(
                title: context.t.appName,
                routerConfig: router,
                locale: TranslationProvider.of(context).flutterLocale,
                supportedLocales: AppLocaleUtils.supportedLocales,
                localizationsDelegates: GlobalMaterialLocalizations.delegates,
                theme: lightTheme,
                darkTheme: darkTheme,
                themeMode: ThemeMode.values[themeModeIndex],
                scaffoldMessengerKey: snackbarKey,
                builder: (context, child) {
                  final data = MediaQuery.of(context);
                  return MediaQuery(
                    data: data.copyWith(
                      textScaler: TextScaler.linear(textScaleFactor)..clamp(minScaleFactor: 0.7, maxScaleFactor: 1.5),
                    ),
                    child: child ?? sizedBoxEmpty,
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Future<void> onWindowMove() async {
    super.onWindowMove();
    if (isDesktop && !cmdArgs.noWindowChangeRecords) {
      _windowPosition = await windowManager.getPosition();
      setupWindowPositionTimer();
    }
  }

  @override
  Future<void> onWindowResize() async {
    super.onWindowResize();
    if (isDesktop && !cmdArgs.noWindowChangeRecords) {
      _windowSize = await windowManager.getSize();
      setupWindowSizeTimer();
    }
  }
}
