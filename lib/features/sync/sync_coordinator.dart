import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:tsdm_client/extensions/build_context.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/authentication/repository/models/models.dart';
import 'package:tsdm_client/features/blocking/repository/user_block_repository.dart';
import 'package:tsdm_client/features/floor_bookmark/repository/floor_bookmark_store.dart';
import 'package:tsdm_client/features/forum/utils/frequent_forums.dart';
import 'package:tsdm_client/features/forum_watch/repository/forum_watch_store.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/sync/models/sync_settings.dart';
import 'package:tsdm_client/features/sync/repository/sync_api.dart';
import 'package:tsdm_client/features/sync/repository/sync_local_store.dart';
import 'package:tsdm_client/features/sync/repository/sync_repository.dart';
import 'package:tsdm_client/features/thread_follow/repository/followed_thread_store.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/logger.dart';

/// When the cross-device sync runs: a pull when the app starts with an account and at every login, again when the app
/// comes to the front after [pullAgainAfter] in the background; a push a while after the visit records, the quick
/// phrases, the block list, the fast rate templates, the synced settings, the local drafts, the floor bookmarks, the
/// pinned forums, what is watched for new threads, the fast reply templates, the read later list or the followed
/// threads of the account change on this device. Nothing while the setting is off; a pull when it (or one of its
/// categories) is switched on.
final class SyncCoordinator with LoggerMixin {
  /// Constructor.
  SyncCoordinator({
    required SyncRepository repository,
    required AuthenticationRepository authentication,
    required SettingsRepository settings,
    required UserBlockRepository blocks,
    required StorageProvider storage,
    Stream<int>? draftChanges,
    Stream<int>? bookmarkChanges,
    Stream<int>? watchChanges,
    Stream<int>? followedChanges,
  }) : _repository = repository,
       _authentication = authentication,
       _settings = settings,
       _blocks = blocks,
       _storage = storage,
       _draftChanges = draftChanges,
       _bookmarkChanges = bookmarkChanges,
       _watchChanges = watchChanges,
       _followedChanges = followedChanges;

  /// The coordinator on the app's repositories.
  factory SyncCoordinator.build({
    required AuthenticationRepository authentication,
    required UserBlockRepository blocks,
    NetClientProvider Function(int uid)? buildClient,
  }) {
    final storage = getIt.get<StorageProvider>();
    final settings = getIt.get<SettingsRepository>();
    return SyncCoordinator(
      repository: SyncRepository(
        api: TsdmAppSyncApi(buildClient),
        store: StorageSyncLocalStore(
          storage: storage,
          settings: settings,
          blocks: blocks,
          authentication: authentication,
        ),
        enabled: () => settings.currentSettings.crossDeviceSync,
        currentUid: () => authentication.effectiveCurrentUid,
        categoryEnabled: (category) => categoryEnabledIn(settings.currentSettings, category),
      ),
      authentication: authentication,
      settings: settings,
      blocks: blocks,
      storage: storage,
      draftChanges: LocalDraftStore.app?.changes,
      bookmarkChanges: FloorBookmarkStore.app?.changes,
      watchChanges: ForumWatchStore.app?.configChanges,
      followedChanges: FollowedThreadStore.app?.changes,
    );
  }

  /// Whether [category] goes with the sync by [settings].
  static bool categoryEnabledIn(SettingsMap settings, SyncCategory category) => switch (category) {
    SyncCategory.rateTemplates => settings.crossDeviceSyncRateTemplates,
    SyncCategory.settings => settings.crossDeviceSyncSettings,
    SyncCategory.drafts => settings.crossDeviceSyncDrafts,
    SyncCategory.bookmarks => settings.crossDeviceSyncBookmarks,
    SyncCategory.pinnedForums => settings.crossDeviceSyncPinnedForums,
    SyncCategory.forumWatch => settings.crossDeviceSyncForumWatch,
    SyncCategory.replyTemplates => settings.crossDeviceSyncReplyTemplates,
    SyncCategory.readLater => settings.crossDeviceSyncReadLater,
    SyncCategory.followedThreads => settings.crossDeviceSyncFollowedThreads,
  };

  static String _settingsSnapshotOf(SettingsMap settings) =>
      SyncRepository.encodeSettingsValues(syncedSettingsValues(settings));

  static Set<SyncCategory> _categoriesOf(SettingsMap settings) => {
    for (final c in SyncCategory.values)
      if (categoryEnabledIn(settings, c)) c,
  };

  /// A pull again when the app comes to the front after this long since the last one.
  static const pullAgainAfter = Duration(minutes: 10);

  /// A login right after the start's pull of the same account is not pulled again within this.
  static const pullDedupe = Duration(seconds: 60);

  final SyncRepository _repository;
  final AuthenticationRepository _authentication;
  final SettingsRepository _settings;
  final UserBlockRepository _blocks;
  final StorageProvider _storage;
  final Stream<int>? _draftChanges;
  final Stream<int>? _bookmarkChanges;
  final Stream<int>? _watchChanges;
  final Stream<int>? _followedChanges;

  StreamSubscription<AuthStatus>? _authSub;
  StreamSubscription<List<FastRateTemplateModel>>? _templatesSub;
  StreamSubscription<int>? _draftsSub;
  StreamSubscription<int>? _bookmarksSub;
  StreamSubscription<int>? _watchSub;
  StreamSubscription<int>? _followedSub;
  StreamSubscription<List<FastReplyTemplateModel>>? _replyTemplatesSub;
  String? _replyTemplates;
  StreamSubscription<void>? _readLaterSub;
  String? _pinned;
  String? _settingsSnapshot;
  String? _templates;
  Set<SyncCategory> _categories = const {};
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
    _settingsSnapshot = _settingsSnapshotOf(_settings.currentSettings);
    _categories = _categoriesOf(_settings.currentSettings);
    _follow(_authentication.effectiveCurrentUid, pull: true);
    _authSub = _authentication.status.listen((status) {
      // A login (or the stored session verified) pulls; the start above pulled the same account a moment ago.
      _follow(_authentication.effectiveCurrentUid, pull: status is AuthStatusAuthed);
    });
    _settingsSub = _settings.settings.listen((settings) {
      final enabled = settings.crossDeviceSync;
      final categories = _categoriesOf(settings);
      final switchedOn = categories.difference(_categories).isNotEmpty;
      _categories = categories;
      if (enabled != _enabled) {
        _enabled = enabled;
        if (enabled && _uid != null) {
          unawaited(_repository.pull(_uid!));
        }
      } else if (enabled && switchedOn && _uid != null) {
        unawaited(_repository.pull(_uid!));
      }
      final snapshot = _settingsSnapshotOf(settings);
      if (snapshot != _settingsSnapshot) {
        _settingsSnapshot = snapshot;
        unawaited(_repository.onSettingsChanged(_uid, snapshot));
      }
      final phrases = settings.editorQuickPhrases;
      if (phrases != _phrases) {
        _phrases = phrases;
        unawaited(_repository.onPhrasesChanged(_uid, phrases));
      }
      // The pinned forums of the account in use (a forum visited lately is no change of them).
      final pinned = _pinnedOf(settings, _uid);
      if (pinned != _pinned) {
        _pinned = pinned;
        if (_uid case final uid?) {
          _repository.schedulePush(uid);
        }
      }
    });
    _blocksSub = _blocks.changes.listen((list) {
      if (list.ownerUid == _uid && _uid != null) {
        _repository.schedulePush(_uid!);
      }
    });
    _templatesSub = _storage.watchAllFastRateTemplate().listen(
      (templates) {
        final snapshot = SyncRepository.encodeRateTemplates(templates);
        // The first value is the current state, not a change.
        final before = _templates;
        _templates = snapshot;
        if (before != null && before != snapshot) {
          unawaited(_repository.onRateTemplatesChanged(_uid, snapshot));
        }
      },
      onError: (Object e, StackTrace st) => error('sync: failed to watch the rate templates: $e', e, st),
    );
    _draftsSub = _draftChanges?.listen((uid) {
      if (uid == _uid) {
        _repository.schedulePush(uid);
      }
    });
    _bookmarksSub = _bookmarkChanges?.listen((uid) {
      if (uid == _uid) {
        _repository.schedulePush(uid);
      }
    });
    _watchSub = _watchChanges?.listen((uid) {
      if (uid == _uid) {
        _repository.schedulePush(uid);
      }
    });
    _followedSub = _followedChanges?.listen((uid) {
      if (uid == _uid) {
        _repository.schedulePush(uid);
      }
    });
    _replyTemplatesSub = _storage.watchAllFastReplyTemplate().listen(
      (templates) {
        final snapshot = SyncRepository.encodeReplyTemplates(templates);
        // The first value is the current state, not a change.
        final before = _replyTemplates;
        _replyTemplates = snapshot;
        if (before != null && before != snapshot) {
          unawaited(_repository.onReplyTemplatesChanged(_uid, snapshot));
        }
      },
      onError: (Object e, StackTrace st) => error('sync: failed to watch the reply templates: $e', e, st),
    );
  }

  static String? _pinnedOf(SettingsMap settings, int? uid) =>
      uid == null ? null : FrequentForumsStore.syncSnapshot(settings, uid);

  void _follow(int? uid, {required bool pull}) {
    if (uid != _uid) {
      _uid = uid;
      // The pinned forums of this account as they are now: no change of them yet.
      _pinned = _pinnedOf(_settings.currentSettings, uid);
      // A write scheduled for the account before must not run for this one.
      _repository.cancelScheduled();
      unawaited(_visitsSub?.cancel());
      unawaited(_readLaterSub?.cancel());
      _visitsSub = null;
      _readLaterSub = null;
      if (uid != null) {
        _visitsSub = _pushOnChange(uid, _storage.watchThreadVisitChanges(uid), 'visits');
        _readLaterSub = _pushOnChange(uid, _storage.watchReadLater(uid), 'read later list');
      }
    }
    if (pull && uid != null) {
      unawaited(_repository.pull(uid, dedupe: pullDedupe));
    }
  }

  /// A write for account [uid] after each change [changes] reports while it is the account in use; the first value is
  /// the current state, not a change.
  StreamSubscription<void> _pushOnChange(int uid, Stream<Object?> changes, String what) {
    var first = true;
    return changes.listen(
      (_) {
        if (first) {
          first = false;
          return;
        }
        if (_uid == uid) {
          _repository.schedulePush(uid);
        }
      },
      onError: (Object e, StackTrace st) => error('sync: failed to watch the $what: $e', e, st),
    );
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
    await _templatesSub?.cancel();
    await _draftsSub?.cancel();
    await _bookmarksSub?.cancel();
    await _watchSub?.cancel();
    await _followedSub?.cancel();
    await _replyTemplatesSub?.cancel();
    await _readLaterSub?.cancel();
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
