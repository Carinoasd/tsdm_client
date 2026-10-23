import 'package:system_network_proxy/system_network_proxy.dart';
import 'package:tsdm_client/features/editor/repository/recent_emoji_store.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/offline_thread/repository/offline_thread_repository.dart';
import 'package:tsdm_client/features/pokemon/repository/adventure_cache.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/proxy_provider/proxy_provider.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/connection/connection.dart' as conn;
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/saved_answer_store.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/utils/platform.dart';

/// Instance names can be used.
abstract final class ServiceKeys {
  /// Net client without cookie.
  static const noCookie = 'normal';

  /// Cookie provider empty user info and cookie.
  static const empty = 'empty';
}

/// 3. All providers **MUST NOT** be directly used by blocs or elsewhere.
///
/// This rule is to ensure clear and lightweight dependencies.
Future<void> initProviders() async {
  if (!isWeb) {
    // Only init cache directories on native platforms.
    await initCache();
  }

  // For `ProxyProvider`.
  // system_network_proxy is only available on desktop platforms.
  if (isDesktop) {
    SystemNetworkProxy.init();
  }

  // TODO: These separated init steps make it not testable.

  /// Dart analyzer does not work on conditional export.
  // ignore: undefined_function
  final db = AppDatabase(conn.connect());
  final preloadedCookie = await preloadCookie(db);
  // The image cache table is not read here any more: rows are looked up by their url when an image is shown. Read
  // whole before the first frame, a large table (150 000 rows) doubled the time to it.
  final storageProvider = StorageProvider.forApp(db, preloadedCookie);

  final settingsRepo = SettingsRepository(storageProvider);
  await settingsRepo.init();

  getIt
    ..registerSingleton(ProxyProvider())
    ..registerSingleton(db)
    ..registerSingleton(storageProvider)
    ..registerSingleton(settingsRepo, dispose: (s) async => s.dispose())
    ..registerSingleton(CookieProvider.build())
    ..registerFactory(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
    ..registerSingleton(ImageCacheProvider.new)
    ..registerFactory(NetClientProvider.build)
    ..registerFactory(NetClientProvider.buildNoCookie, instanceName: ServiceKeys.noCookie)
    ..registerSingleton(NetErrorSaver())
    ..registerSingleton(AdventureCache())
    // The last homepage and guide of each account, shown at the next start while they are asked again.
    ..registerSingleton(SavedAnswerStore())
    // One write queue for every thread page, the settings and the cache sheet.
    ..registerSingleton(OfflineThreadRepository())
    // The drafts the editors did not send, a file per account; the emojis used lately.
    ..registerSingleton(LocalDraftStore())
    ..registerSingleton(RecentEmojiStore());
  await getIt.allReady();

  getIt.registerSingleton(
    ImageCacheProvider(getIt.get<NetClientProvider>(instanceName: ServiceKeys.noCookie)),
    dispose: (s) async => s.dispose(),
  );
  await getIt.allReady();
}
