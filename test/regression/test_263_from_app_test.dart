/// The forum's app API (plugin 3.3.0) records the floors posted, replied or edited from the app and the web page prints
/// "来自天使动漫App" beside their time: the app shows the same in the floor's header.
///
/// 1. the structured thread page: `from_app` 1 marks the floor ([Post.fromApp]), 0 or absent (an older plugin) not;
/// 2. the web page (an older plugin, or the page read instead): the plugin's own span `#tsdmappfrom<pid>` in the floor;
/// 3. the floor's card shows it after the time.
///
/// Fixtures only; nothing is sent.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/utils/parse_thread_document.dart';
import 'package:tsdm_client/features/thread/v1/utils/thread_page_api.dart';
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
import 'package:universal_html/parsing.dart';

import 'draft_fixtures.dart';

/// A schema 15 thread page of the test forum (two floors, 6732 and 6735) with `from_app` set as [fromApp] gives it
/// (by pid); without an entry the field is left out, as an older plugin answers.
Map<String, dynamic> _page(Map<int, Object?> fromApp) {
  final json =
      jsonDecode(File('test/data/tsdmapp/thread_v15_282_author.json').readAsStringSync()) as Map<String, dynamic>;
  for (final post in (json['posts'] as List).cast<Map<String, dynamic>>()) {
    post.remove('from_app');
    final pid = post['pid'] as int;
    if (fromApp.containsKey(pid)) {
      post['from_app'] = fromApp[pid];
    }
  }
  return json;
}

/// The plugin's span on the web page, as its hook prints it after the floor's header.
const _span = '<span class="xg1 tsdmapp-from" id="tsdmappfrom457">来自天使动漫App</span>';

/// No network: the card's images do not load.
final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

/// The card shows nothing that needs these.
Post _bare(Post post) => post.copyWith(
  author: User(name: post.author.name, uid: post.author.uid, url: post.author.url),
  userBriefProfile: null,
  postMedals: null,
  badge: null,
  secondBadge: null,
  signature: null,
  pokemon: null,
  checkin: null,
);

void main() {
  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  group('1. the structured thread page', () {
    test('from_app 1 marks the floor; 0, absent or anything else does not', () {
      final posts = threadPageFromApi(_page({6732: 1, 6735: 0}), 1).postList;
      expect({for (final p in posts) p.postID: p.fromApp}, {'6732': true, '6735': false});
      final older = threadPageFromApi(_page({}), 1).postList;
      expect(older.every((p) => !p.fromApp), isTrue, reason: 'a plugin before 3.3.0');
      final odd = threadPageFromApi(_page({6732: '1', 6735: true}), 1).postList;
      expect(odd.first.fromApp, isTrue, reason: 'a number written as text, as the other fields');
    });
  });

  group('2. the web page', () {
    test("the plugin's span in the floor marks it; a page without it does not", () {
      final html = draftThread(draft: false, secondPost: true);
      final marked = html.replaceFirst(
        '<em id="authorposton457">发表于 2026-09-01 12:00:00</em>',
        '<em id="authorposton457">发表于 2026-09-01 12:00:00</em>$_span',
      );
      expect(marked, contains(_span));
      final posts = parseThreadDocument(parseHtmlDocument(marked), 1).postList;
      expect({for (final p in posts) p.postID: p.fromApp}, {'456': false, '457': true});
      expect(parseThreadDocument(parseHtmlDocument(html), 1).postList.every((p) => !p.fromApp), isTrue);
    });
  });

  group('3. the floor card', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late SettingsBloc bloc;

    setUp(() async {
      await LocaleSettings.setLocale(AppLocale.zhTw);
      db = AppDatabase(NativeDatabase.memory());
      final storage = StorageProvider(db, {}, {});
      settings = SettingsRepository(storage);
      getIt
        ..registerSingleton<StorageProvider>(storage)
        ..registerSingleton<SettingsRepository>(settings)
        ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
        ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
        ..registerSingleton<NetErrorSaver>(NetErrorSaver())
        ..registerSingleton<ImageCacheProvider>(
          ImageCacheProvider(NetClientProvider.buildNoCookie(dio: Dio()..httpClientAdapter = _OfflineAdapter())),
        );
      await settings.init();
      bloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    });
    tearDown(() async {
      await bloc.close();
      await getIt.reset();
      await settings.dispose();
      await db.close();
      await LocaleSettings.setLocale(AppLocale.en);
    });

    testWidgets('shows "來自天使動漫App" after the time of a floor sent from the app, nothing for the others', (
      tester,
    ) async {
      final posts = threadPageFromApi(_page({6732: 1, 6735: 0}), 1).postList;
      await tester.pumpWidget(
        BlocProvider<SettingsBloc>.value(
          value: bloc,
          child: TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Column(children: [for (final p in posts) PostCard(_bare(p))]),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(t.postCard.fromApp, '來自天使動漫App');
      expect(find.textContaining(t.postCard.fromApp), findsOneWidget);
      final line = tester.widget<Text>(find.textContaining(t.postCard.fromApp));
      expect(line.data, endsWith(' · ${t.postCard.fromApp}'));
    });
  });
}
