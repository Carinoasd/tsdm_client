/// A floor's draft kept without a hint (the reply of a notification that failed, `keepFailedReplyDraft`) shows the
/// floor replied to when restored in the reply bar.
///
/// * The floor among the floors of the page ([ReplyBarController.floorHintOf]): its hint as the floor's "回覆" button
///   sets it ([floorReplyHint], "回覆 Bob #2").
/// * Not on the page: a hint without the author ("回覆樓層"), the row and its "reply to the thread" button still there.
/// * The hint found is kept in the target: the draft is written with it from then on.
/// * A draft kept with its hint shows its own, as before.
/// * Both restores: the offer of the collapsed box and the offer in the open editor.
library;

import 'dart:async';
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
import 'package:tsdm_client/extensions/bbcode_editor_controller.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/editor/repository/recent_emoji_store.dart';
import 'package:tsdm_client/features/editor/widgets/rich_editor.dart';
import 'package:tsdm_client/features/local_draft/models/local_draft.dart';
import 'package:tsdm_client/features/local_draft/repository/local_draft_store.dart';
import 'package:tsdm_client/features/post/utils/flood_control.dart';
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

const _alice = UserLoginInfo(username: 'Alice', uid: 31);

const _parameters = ReplyParameters(
  fid: '2',
  tid: '9600001',
  postTime: '1700000000',
  formHash: 'f1f2f3f4',
  subject: '',
  viewerUid: 31,
);

const _floorAction = 'forum.php?mod=post&action=reply&fid=2&tid=9600001&repquote=9700002&extra=page%3D1&page=1';

final _floorKey = LocalDraftKey.floorReply('9600001', '9700002');

/// The reply window of the quoted floor, as the plugin answers it.
Map<String, dynamic> _replyQuote() {
  final json =
      jsonDecode(File('test/data/tsdmapp/post_v16_reply_quote.json').readAsStringSync()) as Map<String, dynamic>;
  json['quote_html'] = '';
  return json;
}

/// The forum: the reply window of the floor, nothing else.
final class _Forum implements HttpClientAdapter {
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method != 'GET') {
      throw StateError('unexpected request: ${options.method} ${options.uri}');
    }
    return ResponseBody.fromString(
      jsonEncode(_replyQuote()),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// The draft a failed reply of a notification keeps: the floor's reply link, no hint.
LocalDraft _failedReply({String? hint}) => LocalDraft(
  key: _floorKey,
  body: '通知列沒送出的回覆',
  updatedAt: DateTime(2026, 11, 12, 9),
  fid: '2',
  replyAction: _floorAction,
  hint: hint,
);

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late LocalDraftStore drafts;

  setUpAll(() async {
    talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false));
    await LocaleSettings.setLocale(AppLocale.zhTw);
  });

  setUp(() async {
    TsdmAppApi.reset();
    TsdmAppApi.notePostForm();
    FloodControl.reset();
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    drafts = LocalDraftStore.memory();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerSingleton<LocalDraftStore>(drafts)
      ..registerSingleton<RecentEmojiStore>(RecentEmojiStore.memory())
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.buildNoCookie(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = _Forum()),
      );
    await settings.init();
  });

  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  late AuthenticationRepository auth;
  late ReplyBloc bloc;
  late ReplyBarController controller;

  /// The thread page's reply bar, its draft [stored] for Alice; [onPage] the floors the page has loaded, by pid (null:
  /// a bar no page answers for, as the notice page's).
  Future<void> pumpBar(WidgetTester tester, LocalDraft stored, {Map<String, (String, int)>? onPage}) async {
    tester.view
      ..physicalSize = const Size(420, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    drafts.save(31, stored);
    await _wait(tester, drafts.pendingWrites);
    auth = AuthenticationRepository(user: _alice);
    controller = ReplyBarController();
    bloc = ReplyBloc(replyRepository: const ReplyRepository())
      ..add(const ReplyParametersUpdated(_parameters))
      ..add(const ReplyThreadClosed(closed: false));
    addTearDown(() async {
      await bloc.close();
      await auth.dispose();
    });
    await tester.pumpWidget(
      RepositoryProvider<AuthenticationRepository>.value(
        value: auth,
        child: RepositoryProvider<ReplyRepository>(
          create: (_) => const ReplyRepository(),
          child: BlocProvider<ReplyBloc>.value(
            value: bloc,
            child: TranslationProvider(
              child: MaterialApp(
                home: Builder(
                  builder: (context) {
                    // As the thread page does: the floors it loaded.
                    controller.floorHintOf = onPage == null
                        ? null
                        : (pid) => switch (onPage[pid]) {
                            (final author, final floor) => floorReplyHint(context, author, floor),
                            null => null,
                          };
                    return Scaffold(
                      resizeToAvoidBottomInset: false,
                      body: const Center(child: Text('thread page')),
                      bottomNavigationBar: ReplyBar(controller: controller, replyType: ReplyTypes.thread),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await _io(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('draft-offer-banner')), findsOneWidget, reason: 'the draft is offered');
  }

  /// The offer restored from the collapsed box, or ([inEditor]) from the editor opened on the reply to the thread.
  Future<void> restore(WidgetTester tester, {bool inEditor = false}) async {
    if (inEditor) {
      controller.setHintText('回覆');
      await _settle(tester);
      expect(controller.showingEditor, isTrue);
      expect(controller.draftKey, 'reply:9600001');
      final inSheet = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byKey(const ValueKey('draft-offer-restore')),
      );
      expect(inSheet, findsOneWidget, reason: 'offered in the editor');
      await tester.tap(inSheet);
    } else {
      await tester.tap(find.byKey(const ValueKey('draft-offer-restore')));
    }
    await _settle(tester);
    expect(controller.showingEditor, isTrue);
    expect(controller.draftKey, 'floor:9600001:9700002');
    expect(controller.currentReplyAction, _floorAction);
    expect(tester.widget<RichEditor>(find.byType(RichEditor)).controller.toForumBBCode(), '通知列沒送出的回覆');
  }

  /// The hint the draft is written with now.
  Future<String?> storedHint(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
    await _io(tester);
    return (await _wait(tester, drafts.load(31, _floorKey)))?.hint;
  }

  test('the hint of a floor is the one of its "回覆" button', () {
    // `floorReplyHint` is what the thread page's `replyPostCallback` sets: "<sendReplyHint> <author> #<floor>".
    expect(t.threadPage.sendReplyHint, '回覆');
    expect(t.threadPage.floorReplyHint, '回覆樓層');
  });

  for (final inEditor in [false, true]) {
    final where = inEditor ? 'the editor' : 'the collapsed box';

    testWidgets('$where: the floor on the page, its author and floor; written with it', (tester) async {
      await pumpBar(tester, _failedReply(), onPage: {'9700002': ('Bob', 2)});
      await restore(tester, inEditor: inEditor);
      expect(find.text('回覆 Bob #2'), findsOneWidget);
      expect(await storedHint(tester), '回覆 Bob #2');
      await _unpump(tester);
    });

    testWidgets('$where: the floor not on the page, the generic hint; written with it', (tester) async {
      await pumpBar(tester, _failedReply(), onPage: {'9700003': ('Carol', 3)});
      await restore(tester, inEditor: inEditor);
      expect(find.text('回覆樓層'), findsOneWidget);
      expect(await storedHint(tester), '回覆樓層');
      await _unpump(tester);
    });

    testWidgets('$where: a draft kept with its hint shows its own', (tester) async {
      await pumpBar(tester, _failedReply(hint: '回覆 Bob #2'), onPage: {'9700002': ('Dave', 7)});
      await restore(tester, inEditor: inEditor);
      expect(find.text('回覆 Bob #2'), findsOneWidget);
      expect(find.text('回覆 Dave #7'), findsNothing);
      expect(await storedHint(tester), '回覆 Bob #2');
      await _unpump(tester);
    });
  }

  testWidgets('no page to ask (a notice): the generic hint', (tester) async {
    await pumpBar(tester, _failedReply());
    await restore(tester);
    expect(find.text('回覆樓層'), findsOneWidget);
    await _unpump(tester);
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pumpAndSettle();
}

/// Let the queued work of the stores (in memory, on microtasks) and the frames it causes finish.
Future<void> _io(WidgetTester tester) async {
  await _wait(tester, getIt.get<LocalDraftStore>().pendingWrites);
  await tester.pump();
}

/// [future], once the frames let it complete (the work of the page runs in the fake time of the test).
Future<T> _wait<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  late T value;
  unawaited(
    future.then((v) {
      value = v;
      done = true;
    }),
  );
  for (var i = 0; i < 50 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(done, isTrue, reason: 'the store answered');
  return value;
}

/// Take the page down and let the timers of its indicators run out.
Future<void> _unpump(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await _io(tester);
  await tester.pump(const Duration(seconds: 3));
}
