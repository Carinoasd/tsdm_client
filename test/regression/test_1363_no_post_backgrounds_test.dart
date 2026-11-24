/// The floors of a thread no longer show the backgrounds members set in the forum's background shop (they were drawn
/// from 1.61.0, plugin 4.1.0):
///
/// 1. the thread page is asked without `tsdmv=4`, even with a `status` that knows it;
/// 2. an answer with `backgrounds` (`schema` 78) gives the same floors as the one without (`schema` 23);
/// 3. a floor of such an answer asks no picture and draws none.
///
/// Fixtures only (cleaned answers of the test forum); nothing is sent.
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/features/tsdmapp/v4.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/image_cache_provider/image_cache_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/shared/repositories/fragments_repository/fragments_repository.dart';
import 'package:tsdm_client/widgets/card/post_card/post_card.dart';

Map<String, dynamic> _answer(String name) =>
    jsonDecode(File('test/data/tsdmapp_410/$name').readAsStringSync()) as Map<String, dynamic>;

List<Post> _posts(Map<String, dynamic> json) => threadPageFromApi(threadApiAnswerOf(json)!, 1).postList;

/// Answers [answer] to everything, and notes each request.
final class _Forum implements HttpClientAdapter {
  _Forum(this.answer);

  final Object? answer;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (answer == null) {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    return ResponseBody.fromString(
      jsonEncode(answer),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late SettingsBloc bloc;

  late Directory tmp;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    // The pictures are kept in a cache directory of their own.
    tmp = Directory.systemTemp.createTempSync('tsdm_no_post_backgrounds_');
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (call) async => switch (call.method) {
        'getApplicationCachePath' || 'getApplicationCacheDirectory' => '${tmp.path}/cache',
        'getApplicationSupportPath' || 'getApplicationSupportDirectory' => '${tmp.path}/support',
        'getTemporaryPath' || 'getTemporaryDirectory' => '${tmp.path}/tmp',
        _ => null,
      },
    );
    await initCache();
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null);
    tmp.deleteSync(recursive: true);
  });

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
    bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    TsdmAppApi.reset();
  });

  tearDown(() async {
    await bloc.close();
    if (getIt.isRegistered<ImageCacheProvider>()) {
      await getIt.get<ImageCacheProvider>().dispose();
    }
    TsdmAppApi.reset();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  test('1. the thread page is asked without tsdmv=4, even when the plugin knows it', () async {
    TsdmAppApi.pluginInfo.value = const TsdmAppPluginInfo(
      version: '4.1.0',
      api: 1,
      nodoc: true,
      v4: TsdmAppV4Flags(on: true),
    );
    expect(TsdmAppV4.on, isTrue);
    final forum = _Forum(_answer('thread_v78_backgrounds.json'));
    getIt.registerFactory<NetClientProvider>(
      () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = forum),
    );
    final page = (await ThreadRepository().fetchThreadPage(tid: '9203680').run()).fold((e) => throw e, (v) => v);
    expect(page.postList, hasLength(6));
    expect(forum.requests, hasLength(1));
    final query = forum.requests.single.uri.queryParameters;
    expect(query, containsPair('tsdmapp', 'json'));
    expect(query.containsKey('tsdmv'), isFalse);
  });

  test('2. an answer with backgrounds gives the same floors as one without', () {
    final newer = _answer('thread_v78_backgrounds.json');
    final older = _answer('thread_v23_same_thread.json');
    expect(newer['schema'], 78);
    expect(newer['backgrounds'], isA<Map<String, dynamic>>());
    expect(older.containsKey('backgrounds'), isFalse);
    expect(_posts(newer), _posts(older));
  });

  testWidgets('3. a floor of an answer with backgrounds asks no picture and draws none', (tester) async {
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.zhCn));
    final images = _Forum(null);
    getIt.registerSingleton<ImageCacheProvider>(
      ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = images)),
    );
    final post = _posts(_answer('thread_v78_backgrounds.json')).first;
    await tester.pumpWidget(
      BlocProvider<SettingsBloc>.value(
        value: bloc,
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Card(
                  margin: EdgeInsets.zero,
                  child: PostCard(
                    post.copyWith(
                      author: User(name: post.author.name, uid: post.author.uid, url: post.author.url),
                      userBriefProfile: null,
                      postMedals: null,
                      badge: null,
                      secondBadge: null,
                      signature: null,
                      pokemon: null,
                      checkin: null,
                    ),
                    key: const ValueKey('card'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byKey(const ValueKey('card')), findsOneWidget);
    expect(images.requests.where((r) => '${r.uri}'.contains('/plugin/background/')), isEmpty);
    final decorated = tester.widgetList<DecoratedBox>(
      find.descendant(of: find.byKey(const ValueKey('card')), matching: find.byType(DecoratedBox)),
    );
    // Nothing but the round avatar is painted with a picture.
    expect(
      decorated
          .map((e) => e.decoration)
          .whereType<BoxDecoration>()
          .where((d) => d.image != null && d.shape != BoxShape.circle),
      isEmpty,
    );
  });
}
