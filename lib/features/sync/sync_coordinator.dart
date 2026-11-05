import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/features/sync/repository/sync_local_store.dart';
import 'package:tsdm_client/features/sync/repository/sync_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// When the cross-device sync runs: a pull when the app starts with an account and at every login, again when the app
/// comes to the front after [pullAgainAfter] in the background; a push a while after the visit records, the quick
/// phrases or the block list of the account change on this device. Nothing while the setting is off; a pull when it
/// is switched on.
final class SyncCoordinator with LoggerMixin {
  /// Constructor.
  SyncCoordinator({
    required SyncRepository repository,
    required AuthenticationRepository authentication,
    required SettingsRepository settings,
    required UserBlockRepository blocks,
    required StorageProvider storage,
  }) : _repository = repository,
       _authentication = authentication,
       _settings = settings,
       _blocks = blocks,
       _storage = storage;

  /// The coordinator on the app's repositories.
  factory SyncCoordinator.build({
    required AuthenticationRepository authentication,
    required UserBlockRepository blocks,
    NetClientProvider? client,
  }) {
    final storage = getIt.get<StorageProvider>();
    final settings = getIt.get<SettingsRepository>();
    return SyncCoordinator(
      repository: SyncRepository(
        api: TsdmAppSyncApi(client ?? getIt.get<NetClientProvider>()),
        store: StorageSyncLocalStore(
          storage: storage,
          settings: settings,
          blocks: blocks,
          authentication: authentication,
        ),
        enabled: () => settings.currentSettings.crossDeviceSync,
        currentUid: () => authentication.effectiveCurrentUid,
      ),
      authentication: authentication,
      settings: settings,
      blocks: blocks,
      storage: storage,
    );
  }

  /// A pull again when the app comes to the front after this long since the last one.
  static const pullAgainAfter = Duration(minutes: 10);

  /// A login right after the start's pull of the same account is not pulled again within this.
  static const pullDedupe = Duration(seconds: 60);

  final SyncRepository _repository;
  final AuthenticationRepository _authentication;
  final SettingsRepository _settings;
  final UserBlockRepository _blocks;
  final StorageProvider _storage;

  StreamSubscription<AuthStatus>? _authSub;
  StreamSubscription<void>? _settingsSub;
  StreamSubscription<UserBlockList>? _blocksSub;
  StreamSubscription<void>? _visitsSub;
  int? _uid;
  String? _phrases;
  bool? _enabled;

  /// The repository (the tests, the settings page).
  SyncRepository get repository => _repository;

  /// Start following the account, the settings and the local changes.
  void start() {
    _phrases = _settings.currentSettings.editorQuickPhrases;
    _enabled = _settings.currentSettings.crossDeviceSync;
    _follow(_authentication.effectiveCurrentUid, pull: true);
    _authSub = _authentication.status.listen((status) {
      // A login (or the stored session verified) pulls; the start above pulled the same account a moment ago.
      _follow(_authentication.effectiveCurrentUid, pull: status is AuthStatusAuthed);
    });
    _settingsSub = _settings.settings.listen((settings) {
      final enabled = settings.crossDeviceSync;
      if (enabled != _enabled) {
        _enabled = enabled;
        if (enabled && _uid != null) {
          unawaited(_repository.pull(_uid!));
        }
      }
      final phrases = settings.editorQuickPhrases;
      if (phrases != _phrases) {
        _phrases = phrases;
        unawaited(_repository.onPhrasesChanged(_uid, phrases));
      }
    });
    _blocksSub = _blocks.changes.listen((list) {
      if (list.ownerUid == _uid && _uid != null) {
        _repository.schedulePush(_uid!);
      }
    });
  }

  void _follow(int? uid, {required bool pull}) {
    if (uid != _uid) {
      _uid = uid;
      // A write scheduled for the account before must not run for this one.
      _repository.cancelScheduled();
      unawaited(_visitsSub?.cancel());
      _visitsSub = null;
      if (uid != null) {
        var first = true;
        _visitsSub = _storage.watchThreadVisitProgress(uid).listen(
          (_) {
            // The first value is the current state, not a change.
            if (first) {
              first = false;
              return;
            }
            if (_uid == uid) {
              _repository.schedulePush(uid);
            }
          },
          onError: (Object e, StackTrace st) => error('sync: failed to watch the visits: $e', e, st),
        );
      }
    }
    if (pull && uid != null) {
      unawaited(_repository.pull(uid, dedupe: pullDedupe));
    }
  }

  /// The app came to the front: a pull when the last one asked for this account is [pullAgainAfter] ago or more
  /// (one still on its way counts as asked).
  void onResumed() {
    final uid = _uid;
    if (uid != null) {
      unawaited(_repository.pull(uid, dedupe: pullAgainAfter));
    }
  }

  /// Stop.
  Future<void> dispose() async {
    await _authSub?.cancel();
    await _settingsSub?.cancel();
    await _blocksSub?.cancel();
    await _visitsSub?.cancel();
    await _repository.dispose();
  }
}

/// Tells the [SyncCoordinator] above it when the app comes to the front.
final class SyncResumeWatcher extends StatefulWidget {
  /// Constructor.
  const SyncResumeWatcher({super.key});

  @override
  State<SyncResumeWatcher> createState() => _SyncResumeWatcherState();
}

final class _SyncResumeWatcherState extends State<SyncResumeWatcher> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      context.readOrNull<SyncCoordinator>()?.onResumed();
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
