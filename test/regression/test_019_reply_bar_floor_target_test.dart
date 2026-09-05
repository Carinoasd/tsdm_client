import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:tsdm_client/constants/url.dart';
import 'package:tsdm_client/features/authentication/repository/authentication_repository.dart';
import 'package:tsdm_client/features/settings/repositories/settings_repository.dart';
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

/// Serves the recorded X5 reply window and success hook (see test_014) to the real reply repository.
final class _FakeAdapter implements HttpClientAdapter {
  final requests = <({String method, Uri uri, Map<String, String> form})>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    var body = '';
    if (requestStream != null) {
      body = utf8.decode(await requestStream.fold<List<int>>([], (a, b) => a..addAll(b)));
    }
    requests.add((method: options.method, uri: options.uri, form: body.isEmpty ? {} : Uri.splitQueryString(body)));
    final name = options.method == 'GET'
        ? 'reply_window_x5.xml'
        : options.uri.queryParameters['handlekey'] == 'fastpost'
        ? 'reply_success_fastpost_x5.xml'
        : 'reply_success_reply_x5.xml';
    return ResponseBody.fromString(
      File('test/data/$name').readAsStringSync(),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/xml; charset=utf-8'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const _params = ReplyParameters(fid: '4', tid: '1264975', postTime: '1788597210', formHash: 'XXXXXXXX', subject: '  ');
const _floorAction =
    'forum.php?mod=post&action=reply&fid=4&tid=1264975&reppost=77983792&extra=page%3D1&page=1&usesig=1&replyuid=1113';
const _hint = '回复 Alice #10';

class _Host extends StatefulWidget {
  const _Host(this.controller, {super.key});

  final ReplyBarController controller;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  bool showBar = true;

  void setBar({required bool shown}) => setState(() => showBar = shown);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: const Center(child: Text('thread page')),
      bottomNavigationBar: showBar
          ? ReplyBar(controller: widget.controller, replyType: ReplyTypes.thread)
          : const SizedBox.shrink(),
    );
  }
}

void main() {
  late AppDatabase db;
  late StorageProvider storage;
  late SettingsRepository settings;
  late _FakeAdapter adapter;

  setUpAll(() => talker = TalkerFlutter.init(settings: TalkerSettings(enabled: false)));
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    storage = StorageProvider(db, {}, {});
    settings = SettingsRepository(storage);
    adapter = _FakeAdapter();
    getIt
      ..registerSingleton<StorageProvider>(storage)
      ..registerSingleton<SettingsRepository>(settings)
      ..registerSingleton<CookieProvider>(CookieProvider.buildEmpty())
      ..registerSingleton<NetErrorSaver>(NetErrorSaver())
      ..registerFactory<CookieProvider>(CookieProvider.buildEmpty, instanceName: ServiceKeys.empty)
      ..registerFactory<NetClientProvider>(
        () => NetClientProvider.build(dio: Dio(BaseOptions(baseUrl: baseUrl))..httpClientAdapter = adapter),
      );
    await settings.init();
  });
  tearDown(() async {
    await getIt.reset();
    await settings.dispose();
    await db.close();
  });

  Future<(ReplyBarController, GlobalKey<_HostState>, ReplyBloc)> pumpPage(WidgetTester tester) async {
    final controller = ReplyBarController();
    final key = GlobalKey<_HostState>();
    // Logged in, thread open: the collapsed box is tappable and the floor hint is rendered.
    final auth = AuthenticationRepository(user: const UserLoginInfo(username: 'Alice', uid: 1000));
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
            child: MaterialApp(home: _Host(controller, key: key)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (controller, key, bloc);
  }

  Future<void> waitFor(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 80 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 25));
    }
    expect(done(), isTrue);
  }

  testWidgets('a floor reply leaves no floor target behind once the thread reloaded', (tester) async {
    final (controller, key, bloc) = await pumpPage(tester);

    // Tap "reply" on a floor: what the thread page does in replyPostCallback.
    controller
      ..replyAction = _floorAction
      ..setHintText(_hint);
    await tester.pumpAndSettle();
    expect(controller.showingEditor, isTrue);
    expect(find.text(_hint), findsOneWidget, reason: 'the editor shows the floor it replies to');

    // Send. The editor does this through _sendReplyPostMessage; drive the bloc the same way.
    bloc.add(const ReplyToPostRequested(replyParameters: _params, replyAction: _floorAction, replyMessage: 'hi'));
    await waitFor(tester, () => bloc.state.status == ReplyStatus.success);
    await tester.pumpAndSettle();
    expect(adapter.requests.map((r) => r.method), ['GET', 'POST'], reason: 'window fetched, reply posted');

    // What the thread page does on success: close the editor, reload (the bar disappears and comes back).
    controller.closeEditor();
    await tester.pumpAndSettle();
    key.currentState!.setBar(shown: false);
    await tester.pumpAndSettle();
    key.currentState!.setBar(shown: true);
    await tester.pumpAndSettle();
    expect(find.text('thread page'), findsOneWidget);

    // Open the editor again through the collapsed box, as for a plain thread reply.
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(controller.showingEditor, isTrue);
    expect(find.text(_hint), findsNothing, reason: 'the floor target must not survive a successful reply');
    expect(find.textContaining('Alice #10'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing the editor without sending keeps the floor target for the next opening', (tester) async {
    final (controller, key, bloc) = await pumpPage(tester);
    controller
      ..replyAction = _floorAction
      ..setHintText(_hint);
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsOneWidget);

    controller.closeEditor();
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsOneWidget, reason: 'an unsent floor reply is still pending');

    // Dismiss the target with the "do not reply to this floor" button.
    await tester.tap(find.byIcon(Icons.clear_outlined));
    await tester.pumpAndSettle();
    expect(find.text(_hint), findsNothing);
    expect(bloc.state.status, ReplyStatus.initial);
    expect(key.currentState, isNotNull);
  });

  testWidgets('leaving the page with the editor open does not touch the disposed reply box', (tester) async {
    final (controller, _, _) = await pumpPage(tester);
    controller.setHintText(_hint);
    await tester.pumpAndSettle();
    expect(controller.showingEditor, isTrue);

    // Pop the whole page while the editor is open: wrapper and editor are disposed in the same frame.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'the draft sync must not write to the disposed controller');
  });
}
