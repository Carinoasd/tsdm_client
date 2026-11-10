/// The emoji panel of the reply bar offers the custom emoji packs, as the post editor does: a tap uploads the image as
/// an attachment (or reuses the upload) and puts `[attachimg]aid[/attachimg]` into the reply, and the reply binds the
/// attachment when it is sent (`attachnew[aid][description]`).
///
/// Measured on the test forum (Discuz X5, plugin 3.6.0): the fast reply of the thread and the reply window of a floor
/// both bind an upload posted with `attachnew[aid][description]` (`forum_attachment` gets the reply's tid and pid, the
/// upload leaves `forum_attachment_unused`, the post shows the image). The reply window of a floor (`infloat=yes`)
/// gives no `attach` block, the reply page of the thread (without `infloat`) gives the upload with its hash.
///
/// Synthetic accounts and forms only (the recorded forms of test_236): nothing reaches a forum.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/custom_emoji/models/custom_emoji.dart';
import 'package:tsdm_client/features/custom_emoji/repository/custom_emoji_store.dart';
import 'package:tsdm_client/features/custom_emoji/utils/custom_emoji_image.dart';
import 'package:tsdm_client/features/custom_emoji/widgets/custom_emoji_grid.dart';
import 'package:tsdm_client/features/editor/repository/recent_emoji_store.dart';
import 'package:tsdm_client/features/editor/widgets/emoji_panel.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
import 'package:tsdm_client/features/tsdmapp/tsdmapp_api.dart';
import 'package:tsdm_client/i18n/strings.g.dart';
import 'package:tsdm_client/instance.dart';
import 'package:tsdm_client/shared/models/models.dart';
import 'package:tsdm_client/shared/providers/cookie_provider/cookie_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_client_provider.dart';
import 'package:tsdm_client/shared/providers/net_client_provider/net_error_saver.dart';
import 'package:tsdm_client/shared/providers/providers.dart';
import 'package:tsdm_client/shared/providers/storage_provider/models/database/database.dart';
import 'package:tsdm_client/shared/providers/storage_provider/storage_provider.dart';
import 'package:tsdm_client/widgets/reply_bar/bloc/reply_bloc.dart';
import 'package:tsdm_client/widgets/reply_bar/models/reply_types.dart';
import 'package:tsdm_client/widgets/reply_bar/reply_bar.dart';
import 'package:tsdm_client/widgets/reply_bar/repository/reply_repository.dart';

const _dir = 'test/data/tsdmapp';

/// The account of the recorded reply page (`uid` 35).
const _uid = 35;

const _params = ReplyParameters(fid: '2', tid: '9600001', postTime: '1700000000', formHash: 'f1f2f3f4', subject: '');

const _floorAction = 'forum.php?mod=post&action=reply&fid=2&tid=9600001&repquote=9700002&extra=&page=1';

Map<String, dynamic> _json(String name) => jsonDecode(File('$_dir/$name').readAsStringSync()) as Map<String, dynamic>;

/// Answers the reply page of the thread ([page], `post_v16_reply.json`), the window of a floor
/// (`post_v16_reply_float.json`), the upload (aid [aid]) and the reply (`write_v13_reply_ok.json`); records every
/// request with its form.
final class _Forum implements HttpClientAdapter {
  _Forum({Map<String, dynamic>? page}) : page = page ?? _json('post_v16_reply.json');

  final Map<String, dynamic> page;
  int aid = 1700;

  /// The next reply gets a server error (the forum may have stored it).
  bool failNextReply = false;
  final requests = <({String method, Uri uri, Map<String, String> form})>[];

  List<Uri> get uploads => [
    for (final r in requests)
      if (r.uri.path.endsWith('/misc.php')) r.uri,
  ];

  List<Map<String, String>> get replies => [
    for (final r in requests)
      if (r.method == 'POST' && r.uri.queryParameters['replysubmit'] == 'yes') r.form,
  ];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancel) async {
    final uri = options.uri;
    final multipart = '${options.contentType}'.startsWith('multipart');
    var body = '';
    if (requestStream != null) {
      final bytes = await requestStream.fold<List<int>>([], (a, b) => a..addAll(b));
      body = multipart ? '' : utf8.decode(bytes);
    }
    requests.add((method: options.method, uri: uri, form: body.isEmpty ? {} : Uri.splitQueryString(body)));
    final q = uri.queryParameters;
    String answer;
    if (uri.path.endsWith('/misc.php')) {
      answer = 'DISCUZUPLOAD|1|0|${aid++}|1|202611/10/emoji.png|emoji.png|0';
    } else if (options.method == 'POST') {
      if (failNextReply) {
        failNextReply = false;
        return ResponseBody.fromString('Bad Gateway', 502);
      }
      answer = File('$_dir/write_v13_reply_ok.json').readAsStringSync();
    } else if (q['action'] == 'reply' && q['infloat'] == 'yes') {
      answer = File('$_dir/post_v16_reply_float.json').readAsStringSync();
    } else if (q['action'] == 'reply') {
      answer = jsonEncode(page);
    } else {
      throw DioException.connectionError(requestOptions: options, reason: 'offline');
    }
    return ResponseBody.fromString(
      answer,
      200,
      headers: {
        Headers.contentTypeHeader: [if (answer.startsWith('{')) 'application/json' else 'text/plain; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Uint8List _png() => img.encodePng(img.Image(width: 24, height: 24)..clear(img.ColorRgb8(200, 80, 40)));

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late Directory dir;
  late _Forum forum;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));

  Future<CustomEmojiStore> registerStore({bool withImage = true}) async {
    final store = CustomEmojiStore(directory: () async => dir, prepare: (bytes) async => prepareCustomEmoji(bytes));
    await store.load();
    final pack = await store.createPack('貓');
    if (withImage) {
      await store.addImages(pack.id, [() async => _png()]);
    }
    getIt.registerSingleton<CustomEmojiStore>(store);
    return store;
  }

  void registerForum(_Forum adapter) {
    forum = adapter;
    getIt.registerFactory<NetClientProvider>(
      () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
    );
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('reply_bar_custom_emoji_');
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty);
    await settings.init();
    TsdmAppApi.notePostForm();
    EmojiPanel.debugGroups = const [];
  });

  tearDown(() async {
    EmojiPanel.debugGroups = null;
    TsdmAppApi.reset();
    await getIt.reset();
    await settings.dispose();
    await db.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('A. the reply binds the attachments it was given', () {
    test('the fast reply of the thread posts attachnew for each', () async {
      registerForum(_Forum());
      final result = await const ReplyRepository()
          .replyToThread(replyParameters: _params, replyMessage: 'a [attachimg]1700[/attachimg]', attachNew: [1700])
          .run();
      expect(result.isRight(), isTrue);
      final form = forum.replies.single;
      expect(form['attachnew[1700][description]'], '');
      expect(form['message'], 'a [attachimg]1700[/attachimg]');
    });

    test('the reply window of a floor posts attachnew with the served fields', () async {
      registerForum(_Forum());
      final result = await const ReplyRepository()
          .replyToPost(replyParameters: _params, replyAction: _floorAction, replyMessage: 'b', attachNew: [1701, 1702])
          .run();
      expect(result.isRight(), isTrue);
      final form = forum.replies.single;
      expect(form['attachnew[1701][description]'], '');
      expect(form['attachnew[1702][description]'], '');
      expect(form['reppid'], '9700002', reason: 'the served fields of the window go as before');
    });

    test('nothing more without any', () async {
      registerForum(_Forum());
      await const ReplyRepository().replyToThread(replyParameters: _params, replyMessage: 'c').run();
      expect(forum.replies.single.keys.where((e) => e.startsWith('attachnew')), isEmpty);
    });
  });

  group('B. the emoji panel', () {
    Future<void> pumpPanel(WidgetTester tester, {required CustomEmojiSender? send, List<String>? picked}) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: EmojiPanel(onPicked: (code) => picked?.add(code), sendCustomEmoji: send),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a pack with images is a tab only where the reply takes custom emojis', (tester) async {
      final store = await tester.runAsync(registerStore);
      final pack = store!.packs.value.single;
      await pumpPanel(tester, send: null);
      expect(find.byKey(ValueKey('emoji-panel-pack-${pack.id}')), findsNothing);

      await pumpPanel(tester, send: (_) async => null);
      expect(find.byKey(ValueKey('emoji-panel-pack-${pack.id}')), findsOneWidget);
      expect(find.text('貓'), findsOneWidget);
    });

    testWidgets('an empty pack is no tab', (tester) async {
      final store = await tester.runAsync(() => registerStore(withImage: false));
      await pumpPanel(tester, send: (_) async => '[attachimg]1[/attachimg]');
      expect(find.byKey(ValueKey('emoji-panel-pack-${store!.packs.value.single.id}')), findsNothing);
    });

    testWidgets('a tap gives the attachment code, never one of the recent emojis', (tester) async {
      final store = await tester.runAsync(registerStore);
      final recent = RecentEmojiStore.memory();
      getIt.registerSingleton<RecentEmojiStore>(recent);
      final emoji = store!.packs.value.single.emojis.single;
      final picked = <String>[];
      final sent = <CustomEmoji>[];
      await pumpPanel(
        tester,
        picked: picked,
        send: (e) async {
          sent.add(e);
          return '[attachimg]1700[/attachimg]';
        },
      );
      await tester.tap(find.byKey(ValueKey('emoji-panel-pack-${store.packs.value.single.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('custom-emoji-pick-${emoji.sha256}')));
      await tester.pumpAndSettle();
      expect(sent.map((e) => e.sha256), [emoji.sha256]);
      expect(picked, ['[attachimg]1700[/attachimg]']);
      expect(recent.recent.value, isEmpty);
    });
  });

  testWidgets('B. the group shown stays when the packs come in', (tester) async {
    final store = (await tester.runAsync(registerStore))!;
    final send = ValueNotifier<CustomEmojiSender?>(null);
    addTearDown(send.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<CustomEmojiSender?>(
              valueListenable: send,
              builder: (context, value, _) => EmojiPanel(
                onPicked: (_) {},
                sendCustomEmoji: value,
                groups: const [
                  EmojiGroup(name: 'G1', id: '1', routeName: 'g1', emojiList: []),
                  EmojiGroup(name: 'G2', id: '2', routeName: 'g2', emojiList: []),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('G2'));
    await tester.pumpAndSettle();
    TabController controller() => tester.widget<TabBar>(find.byType(TabBar)).controller!;
    expect(controller().index, 3);

    send.value = (_) async => null;
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('emoji-panel-pack-${store.packs.value.single.id}')), findsOneWidget);
    expect(controller().index, 4, reason: 'still G2, one tab further');
  });

  group('C. the reply bar', () {
    Future<(ReplyBarController, ReplyBloc)> pumpBar(WidgetTester tester) async {
      final controller = ReplyBarController();
      final auth = AuthenticationRepository(
        user: const UserLoginInfo(username: 'Alice', uid: _uid),
      );
      final bloc = ReplyBloc(replyRepository: const ReplyRepository())
        ..add(const ReplyThreadClosed(closed: false))
        ..add(const ReplyParametersUpdated(_params));
      addTearDown(() async {
        await bloc.close();
        await auth.dispose();
      });
      await tester.pumpWidget(
        RepositoryProvider<AuthenticationRepository>.value(
          value: auth,
          child: BlocProvider<ReplyBloc>.value(
            value: bloc,
            child: TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  resizeToAvoidBottomInset: false,
                  body: const Center(child: Text('thread page')),
                  bottomNavigationBar: ReplyBar(controller: controller, replyType: ReplyTypes.thread),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (controller, bloc);
    }

    /// Let the fake forum answer: its futures run outside the fake clock. Pumped frame by frame: a spinner turns while
    /// an upload or a reply is on its way.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> openPanelAndTap(WidgetTester tester, CustomEmojiStore store) async {
      await tester.tap(find.byKey(const ValueKey('reply-bar-emoji')));
      await settle(tester);
      final pack = store.packs.value.single;
      await tester.tap(find.byKey(ValueKey('emoji-panel-pack-${pack.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('custom-emoji-pick-${pack.emojis.single.sha256}')));
      await settle(tester);
    }

    testWidgets('a custom emoji goes up once, into the reply, and the reply binds it', (tester) async {
      final store = (await tester.runAsync(registerStore))!;
      registerForum(_Forum());
      final (controller, bloc) = await pumpBar(tester);
      controller.setHintText('');
      await settle(tester);
      expect(controller.showingEditor, isTrue);
      expect(
        forum.requests.where((r) => r.method == 'GET' && r.uri.queryParameters['infloat'] == null),
        isNotEmpty,
        reason: 'the reply page of the thread is asked for its upload',
      );

      await openPanelAndTap(tester, store);
      expect(forum.uploads, hasLength(1));
      expect(store.uploadedAid(_uid, store.packs.value.single.emojis.single.sha256), 1700);

      // The same emoji again: the code of the attachment already in the reply, no second upload.
      final pack = store.packs.value.single;
      await tester.tap(find.byKey(ValueKey('custom-emoji-pick-${pack.emojis.single.sha256}')));
      await settle(tester);
      expect(forum.uploads, hasLength(1));

      await tester.tap(find.byKey(const ValueKey('reply-bar-send')));
      await settle(tester);
      expect(bloc.state.status, ReplyStatus.success);
      final form = forum.replies.single;
      expect(form['message'], contains('[attachimg]1700[/attachimg]'));
      expect(form.keys.where((e) => e.startsWith('attachnew')), ['attachnew[1700][description]']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unused upload of the account the reply page lists is reused, not uploaded again', (tester) async {
      final store = (await tester.runAsync(registerStore))!;
      final sha = store.packs.value.single.emojis.single.sha256;
      store.rememberUpload(_uid, sha, 1603);
      final page = _json('post_v16_reply.json');
      (page['attach'] as Map<String, dynamic>)['unused'] = [
        {'aid': 1603, 'isimage': 1, 'filename': 'a.png'},
      ];
      registerForum(_Forum(page: page));
      final (controller, bloc) = await pumpBar(tester);
      controller.setHintText('');
      await settle(tester);

      await openPanelAndTap(tester, store);
      expect(forum.uploads, isEmpty);

      await tester.tap(find.byKey(const ValueKey('reply-bar-send')));
      await settle(tester);
      expect(bloc.state.status, ReplyStatus.success);
      expect(forum.replies.single.keys.where((e) => e.startsWith('attachnew')), ['attachnew[1603][description]']);
    });

    testWidgets('a reply stored after its editor closed binds nothing of it again', (tester) async {
      final store = (await tester.runAsync(registerStore))!;
      registerForum(_Forum());
      final (controller, bloc) = await pumpBar(tester);
      controller.setHintText('');
      await settle(tester);
      await openPanelAndTap(tester, store);
      expect(forum.uploads, hasLength(1));

      // Sent, and the editor closed before the forum answered.
      await tester.tap(find.byKey(const ValueKey('reply-bar-send')));
      await tester.pump();
      controller.closeEditor();
      await settle(tester);
      expect(bloc.state.status, ReplyStatus.success);
      expect(forum.replies.single.keys.where((e) => e.startsWith('attachnew')), ['attachnew[1700][description]']);

      // The same emoji in the next reply: a new upload, never the attachment of the reply stored.
      controller.setHintText('');
      await settle(tester);
      await openPanelAndTap(tester, store);
      expect(forum.uploads, hasLength(2));
      await tester.tap(find.byKey(const ValueKey('reply-bar-send')));
      await settle(tester);
      expect(forum.replies, hasLength(2));
      expect(forum.replies.last.keys.where((e) => e.startsWith('attachnew')), ['attachnew[1701][description]']);
      expect(forum.replies.last['message'], isNot(contains('[attachimg]1700[/attachimg]')));
    });

    for (final stored in [true, false]) {
      testWidgets('a reply that may have been stored binds its emojis again only while unused: stored $stored', (
        tester,
      ) async {
        final store = (await tester.runAsync(registerStore))!;
        final page = _json('post_v16_reply.json');
        registerForum(_Forum(page: page)..failNextReply = true);
        final (controller, bloc) = await pumpBar(tester);
        controller.setHintText('');
        await settle(tester);
        await openPanelAndTap(tester, store);
        await tester.tap(find.byKey(const ValueKey('reply-bar-send')));
        await settle(tester);
        expect(bloc.state.status, ReplyStatus.failure);
        expect(bloc.state.maybeSent, isTrue);
        expect(forum.replies.single.keys.where((e) => e.startsWith('attachnew')), ['attachnew[1700][description]']);

        // What the forum keeps unused now tells whether the first one was stored.
        (page['attach'] as Map<String, dynamic>)['unused'] = [
          if (!stored) {'aid': 1700, 'isimage': 1, 'filename': 'emoji.png'},
        ];
        await tester.tap(find.byKey(const ValueKey('reply-bar-send')));
        await settle(tester);
        expect(bloc.state.status, ReplyStatus.success);
        expect(forum.replies, hasLength(2));
        expect(
          forum.replies.last.keys.where((e) => e.startsWith('attachnew')),
          stored ? isEmpty : ['attachnew[1700][description]'],
          reason: 'an attachment the forum bound to the reply it stored never moves to the next one',
        );
      });
    }

    for (final keptUnused in [true, false]) {
      testWidgets('the code of an own upload in a restored draft is bound only while unused: $keptUnused', (
        tester,
      ) async {
        final store = (await tester.runAsync(registerStore))!;
        store.rememberUpload(_uid, store.packs.value.single.emojis.single.sha256, 1603);
        final page = _json('post_v16_reply.json');
        if (keptUnused) {
          (page['attach'] as Map<String, dynamic>)['unused'] = [
            {'aid': 1603, 'isimage': 1, 'filename': 'a.png'},
          ];
        }
        registerForum(_Forum(page: page));
        final (controller, bloc) = await pumpBar(tester);
        controller.setHintText('');
        await settle(tester);
        controller.insertBBCode('draft [attachimg]1603[/attachimg] [attachimg]99[/attachimg]');
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const ValueKey('reply-bar-send')));
        await settle(tester);
        expect(bloc.state.status, ReplyStatus.success);
        final form = forum.replies.single;
        expect(form['message'], contains('[attachimg]1603[/attachimg]'));
        expect(
          form.keys.where((e) => e.startsWith('attachnew')),
          keptUnused ? ['attachnew[1603][description]'] : isEmpty,
          reason: 'one not of this account (99) never, one bound elsewhere never',
        );
      });
    }

    testWidgets('a remembered upload the forum no longer keeps unused is uploaded again', (tester) async {
      final store = (await tester.runAsync(registerStore))!;
      final sha = store.packs.value.single.emojis.single.sha256;
      store.rememberUpload(_uid, sha, 1603);
      registerForum(_Forum());
      final (controller, _) = await pumpBar(tester);
      controller.setHintText('');
      await settle(tester);

      await openPanelAndTap(tester, store);
      expect(forum.uploads, hasLength(1));
      expect(store.uploadedAid(_uid, sha), 1700);
    });

    testWidgets('no pack tab where the forum offers no image upload', (tester) async {
      final store = (await tester.runAsync(registerStore))!;
      final page = _json('post_v16_reply.json');
      ((page['attach'] as Map<String, dynamic>)['upload'] as Map<String, dynamic>)['image'] = 0;
      registerForum(_Forum(page: page));
      final (controller, _) = await pumpBar(tester);
      controller.setHintText('');
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('reply-bar-emoji')));
      await settle(tester);
      expect(find.byKey(const ValueKey('emoji-panel')), findsOneWidget);
      expect(find.byKey(ValueKey('emoji-panel-pack-${store.packs.value.single.id}')), findsNothing);
    });

    testWidgets('no pack tab in a private message', (tester) async {
      final store = (await tester.runAsync(registerStore))!;
      registerForum(_Forum());
      final controller = ReplyBarController();
      final auth = AuthenticationRepository(
        user: const UserLoginInfo(username: 'Alice', uid: _uid),
      );
      final bloc = ReplyBloc(replyRepository: const ReplyRepository());
      addTearDown(() async {
        await bloc.close();
        await auth.dispose();
      });
      await tester.pumpWidget(
        RepositoryProvider<AuthenticationRepository>.value(
          value: auth,
          child: BlocProvider<ReplyBloc>.value(
            value: bloc,
            child: TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  bottomNavigationBar: ReplyBar(controller: controller, replyType: ReplyTypes.chat),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('reply-bar-emoji')));
      await settle(tester);
      expect(find.byKey(const ValueKey('emoji-panel')), findsOneWidget);
      expect(find.byKey(ValueKey('emoji-panel-pack-${store.packs.value.single.id}')), findsNothing);
      expect(forum.requests, isEmpty, reason: 'no reply page is asked for a private message');
    });
  });
}
