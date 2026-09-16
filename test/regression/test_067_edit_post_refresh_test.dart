import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/features/settings/bloc/settings_bloc.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/thread/v1/bloc/thread_bloc.dart';
import 'package:tsdm_client/features/thread/v1/repository/thread_repository.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/routes/screen_paths.dart';
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

class _RecordingThreadBloc extends ThreadBloc {
  _RecordingThreadBloc()
    : super(
        tid: '42',
        pid: null,
        onlyVisibleUid: null,
        reverseOrder: false,
        exactOrder: null,
        threadRepository: ThreadRepository(),
      );

  final events = <ThreadEvent>[];

  @override
  void add(ThreadEvent event) => events.add(event);
}

final class _OfflineAdapter implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) =>
      throw DioException.connectionError(requestOptions: options, reason: 'offline');

  @override
  void close({bool force = false}) {}
}

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late SettingsBloc settingsBloc;
  late _RecordingThreadBloc threadBloc;
  final initialPostKey = GlobalKey();

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() async {
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
    settingsBloc = SettingsBloc(settingsRepository: settings, fragmentsRepository: FragmentsRepository());
    threadBloc = _RecordingThreadBloc();
  });
  tearDown(() async {
    await settingsBloc.close();
    await threadBloc.close();
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  /// [visible] removes the card from the tree when false. [keyed] wraps the card in a keyed subtree while true, the
  /// way `PostList` marks the floor it scrolled to: flipping it rebuilds the card into a new element.
  Future<GoRouter> openEditor(
    WidgetTester tester, {
    VoidCallback? onEdited,
    ValueNotifier<bool>? visible,
    ValueNotifier<bool>? keyed,
  }) async {
    final post = Post(
      postID: '77',
      postFloor: 41,
      author: const User(name: 'author', url: 'u'),
      publishTime: DateTime(2026, 9, 9),
      data: '<p>old content</p>',
      replyAction: null,
      rateAction: null,
      lastEditUsername: null,
      lastEditTime: null,
      shareLink: null,
      page: 3,
      isDraft: false,
      packetAllTaken: false,
      editUrl: 'forum.php?mod=post&action=edit&fid=1&tid=42&pid=77',
    );
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            body: switch ((visible, keyed)) {
              (null, null) => PostCard(post, onEdited: onEdited),
              (final visible?, _) => ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (_, show, _) => show ? PostCard(post, onEdited: onEdited) : const SizedBox.shrink(),
              ),
              (_, final keyed?) => ValueListenableBuilder<bool>(
                valueListenable: keyed,
                builder: (_, mark, _) {
                  final card = PostCard(post, onEdited: onEdited);
                  return mark ? KeyedSubtree(key: initialPostKey, child: card) : card;
                },
              ),
            },
          ),
        ),
        GoRoute(
          path: '/edit/:editType/:fid',
          name: ScreenPaths.editPost,
          builder: (context, _) => Scaffold(
            body: Column(
              children: [
                TextButton(onPressed: () => context.pop(true), child: const Text('save succeeded')),
                TextButton(onPressed: () => context.pop(), child: const Text('cancel edit')),
              ],
            ),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<SettingsBloc>.value(value: settingsBloc),
          BlocProvider<ThreadBloc>.value(value: threadBloc),
        ],
        child: TranslationProvider(child: MaterialApp.router(routerConfig: router)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.postCard.edit));
    await tester.pumpAndSettle();
    expect(find.text('save succeeded'), findsOneWidget);
    return router;
  }

  testWidgets('saving an edited floor reloads its page instead of page one', (tester) async {
    var positioned = false;
    await openEditor(
      tester,
      onEdited: () {
        expect(threadBloc.events, isEmpty, reason: 'set the scroll target before starting the reload');
        positioned = true;
      },
    );
    await tester.tap(find.text('save succeeded'));
    await tester.pumpAndSettle();
    expect(threadBloc.events, hasLength(1));
    expect(threadBloc.events.single, isA<ThreadJumpPageRequested>().having((e) => e.pageNumber, 'page', 3));
    expect(positioned, isTrue);
  });

  testWidgets('cancelling an edit leaves the thread untouched', (tester) async {
    await openEditor(tester, onEdited: () => fail('cancelling must not change the scroll target'));
    await tester.tap(find.text('cancel edit'));
    await tester.pumpAndSettle();
    expect(threadBloc.events, isEmpty);
  });

  testWidgets('leaving the thread while editing does not reload a closed bloc', (tester) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final router = await openEditor(tester, visible: visible, onEdited: () => fail('the thread page is gone'));
    // The thread page was popped: its card is disposed and its bloc closed.
    visible.value = false;
    await tester.pump();
    // Real async: closing a bloc waits on its stream subscriptions, which never resolve inside the fake clock.
    await tester.runAsync(threadBloc.close);
    expect(threadBloc.isClosed, isTrue);
    router.pop(true);
    await tester.pumpAndSettle();
    expect(threadBloc.events, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a rebuild that re-keys the floor while the editor is open still reloads its page (#76)', (tester) async {
    // After a reply the thread scrolls to the new floor and keys its card; the next rebuild of the page (the editor's
    // keyboard is enough) drops that key again, and the card the user opened the editor from is replaced by a new
    // element. The reload must not depend on the old element still being mounted.
    final keyed = ValueNotifier(true);
    addTearDown(keyed.dispose);
    var positioned = false;
    final router = await openEditor(tester, keyed: keyed, onEdited: () => positioned = true);
    keyed.value = false;
    await tester.pump();
    expect(find.byType(PostCard, skipOffstage: false), findsOneWidget, reason: 'the thread is still there');
    router.pop(true);
    await tester.pumpAndSettle();
    expect(threadBloc.events, hasLength(1), reason: 'the edited page must reload although the card was rebuilt');
    expect(threadBloc.events.single, isA<ThreadJumpPageRequested>().having((e) => e.pageNumber, 'page', 3));
    expect(positioned, isTrue);
    expect(tester.takeException(), isNull);
  });
}
